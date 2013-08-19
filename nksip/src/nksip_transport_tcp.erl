%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @private TCP/TLS Transport.
%% This module is used for both inbound and outbound TCP and TLS connections.

-module(nksip_transport_tcp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send/2, stop/1]).
-export([start_link/3, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_BUFFER, 64*1024*1024).

%% ===================================================================
%% Private
%% ===================================================================

%% @private Sends a new TCP or TLS request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, #sipmsg{sipapp_id=AppId, call_id=CallId, transport=Transport}=SipMsg) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    Packet = nksip_unparse:packet(SipMsg),
    case catch gen_server:call(Pid, {send, Packet}) of
        ok ->
            nksip_trace:insert(SipMsg, {tcp_out, Proto, Ip, Port, Packet}),
            nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transport, Packet),
            ok;
        {'EXIT', Error} ->
            ?notice(AppId, CallId, "could not send TCP message: ~p", [Error]),
            error
    end.


%% @private
stop(Pid) ->
    gen_server:cast(Pid, stop).


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transport, Socket) -> 
    gen_server:start_link(?MODULE, [AppId, Transport, Socket], []).

-record(state, {
    sipapp_id :: nksip:sipapp_id(),
    transport :: nksip_transport:transport(),
    socket :: port() | #sslsocket{},
    timeout :: non_neg_integer(),
    buffer = <<>> :: binary()
}).


%% @private
init([AppId, Transport, Socket]) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    process_flag(priority, high),
    nksip_proc:put({nksip_connection, {AppId, Proto, Ip, Port}}, Transport), 
    nksip_proc:put(nksip_transports, {AppId, Transport}),
    nksip_counters:async([nksip_transport_tcp]),
    Timeout = 1000 * nksip_config:get(tcp_timeout),
    {ok, 
        #state{
            sipapp_id = AppId,
            transport = Transport, 
            socket = Socket, 
            timeout = Timeout,
            buffer = <<>>}, Timeout}.


%% @private
handle_call({send, Packet}, _From, 
            #state{
                sipapp_id = AppId, 
                socket = Socket,
                transport = #transport{proto=Proto},
                timeout = Timeout
            }=State) ->
    case socket_send(Proto, Socket, Packet) of
        ok -> 
            {reply, ok, State, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send TCP message: ~p", [Error]),
            {stop, normal, State}
    end.


%% @private
handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.


%% @private 
handle_info({tcp, Socket, Packet}, #state{
                sipapp_id = AppId, 
                buffer = Buff, 
                transport = #transport{proto=Proto},
                timeout = Timeout
            } = State)
            when byte_size(<<Buff/binary, Packet/binary>>) > ?MAX_BUFFER ->
    ?warning(AppId, "dropping TCP/TLS closing because of max_buffer", []),
    socket_close(Proto, Socket),
    {noreply, State, Timeout};

%% @private
handle_info({tcp, Socket, Packet}, 
            #state{
                transport = #transport{proto=Proto},
                buffer = Buff, 
                socket = Socket,
                timeout = Timeout
            } = State) ->
    socket_active(Proto, Socket),
    Rest = parse(<<Buff/binary, Packet/binary>>, State),
    {noreply, State#state{buffer=Rest}, Timeout};

handle_info({ssl, Socket, Packet}, State) ->
    handle_info({tcp, Socket, Packet}, State);

handle_info({tcp_closed, Socket}, 
            #state{
                sipapp_id = AppId,
                socket = Socket, 
                transport = #transport{remote_ip=Ip, remote_port=Port}
            } = State) ->
    ?debug(AppId, "closed TCP connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info({ssl_closed, Socket}, 
            #state{
                sipapp_id = AppId,
                socket = Socket, 
                transport = #transport{remote_ip=Ip, remote_port=Port}
            } = State) ->
    ?debug(AppId, "closed TLS connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info(timeout,  
            #state{
                sipapp_id = AppId,
                socket = Socket,
                transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}
            } = State) ->
    ?debug(AppId, "TCP/TLS connection from ~p:~p timeout", [Ip, Port]),
    socket_close(Proto, Socket),
    {stop, normal, State};

% Received from Ranch when the listener is ready
handle_info({shoot, _ListenerPid}, 
            #state{socket=Socket, transport=#transport{proto=Proto}}=State) ->
    socket_active(Proto, Socket),
    {noreply, State, State#state.timeout};

handle_info(Info, State) -> 
    lager:warning("Module ~p received nexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
parse(Packet, #state{sipapp_id=AppId, socket=Socket, transport=Transport}=State) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port}=Transport,
    case nksip_parse:packet(AppId, Transport, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=_Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport, Packet),
            nksip_trace:insert(AppId, CallId, {tcp_in, Proto, Ip, Port, Packet}),
            case nksip_call:incoming_sync(RawMsg) of
                ok ->
                    case More of
                        <<>> -> <<>>;
                        _ -> parse(More, State)
                    end;
                {error, max_calls} ->
                    socket_close(Proto, Socket),
                    <<>>
            end;
        {rnrn, More} ->
            socket_send(Proto, Socket, <<"\r\n">>),
            parse(More, State);
        {more, More} -> 
            More
    end.


%% @private
socket_send(tcp, Socket, Packet) -> gen_tcp:send(Socket, Packet);
socket_send(tls, Socket, Packet) -> ssl:send(Socket, Packet).


%% @private
socket_active(tcp, Socket) -> inet:setopts(Socket, [{active, once}]);
socket_active(tls, Socket) -> ssl:setopts(Socket, [{active, once}]).


%% @private
socket_close(tcp, Socket) -> gen_tcp:close(Socket);
socket_close(tls, Socket) -> ssl:close(Socket).
