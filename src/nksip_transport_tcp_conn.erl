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

%% @private TCP/TLS Transport Connection
-module(nksip_transport_tcp_conn).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include("nksip.hrl").

-define(MAX_BUFFER, 64*1024*1024).



%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transport, Socket, Timeout) -> 
    gen_server:start_link(?MODULE, [AppId, Transport, Socket, Timeout], []).

-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port() | ssl:sslsocket(),
    timeout :: non_neg_integer(),
    refresher_timer :: reference(),
    refresher_time :: pos_integer(),
    refreshed_timer :: reference(),
    buffer = <<>> :: binary()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transport, Socket, Timeout]) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    process_flag(priority, high),
    nksip_proc:put({nksip_connection, {AppId, Proto, Ip, Port}}, Transport), 
    nksip_proc:put(nksip_transports, {AppId, Transport}),
    nksip_counters:async([?MODULE]),
    State = #state{
        app_id = AppId,
        transport = Transport, 
        socket = Socket, 
        timeout = Timeout,
        buffer = <<>>
    },
    {ok, State, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Packet}, _From, State) ->
    #state{
        app_id = AppId, 
        socket = Socket,
        transport = #transport{proto=Proto},
        timeout = Timeout
    } = State,
    case socket_send(Proto, Socket, Packet) of
        ok -> 
            {reply, ok, State, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send TCP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({start_refresh, Secs}, State) ->
    #state{
        refresher_timer = RefresherTimer, 
        refreshed_timer = RefreshedTimer,
        timeout = Timeout
    } = State,
    nksip_lib:cancel_timer(RefresherTimer),
    nksip_lib:cancel_timer(RefreshedTimer),
    Time = 1000*Secs,
    State1 = State#state{
        refresher_timer = erlang:start_timer(Time, self(), refresher),
        refresher_time = Time,
        refreshed_timer = undefined
    },
    {noreply, State1, Timeout};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({tcp, Socket, Packet}, #state{buffer=Buff}=State)
            when byte_size(<<Buff/binary, Packet/binary>>) > ?MAX_BUFFER ->
    #state{
        app_id = AppId, 
        transport = #transport{proto=Proto},
        timeout = Timeout
    } = State,
    ?warning(AppId, "dropping TCP/TLS closing because of max_buffer", []),
    socket_close(Proto, Socket),
    {noreply, State, Timeout};

%% @private
handle_info({tcp, Socket, Packet}, State) ->
    #state{
        transport = #transport{proto=Proto},
        buffer = Buff, 
        socket = Socket,
        timeout = Timeout,
        refresher_time = RefresherTime,
        refreshed_timer = RefreshedTimer
    } = State,
    setopts(Proto, Socket, [{active, once}]),
    Rest = parse(<<Buff/binary, Packet/binary>>, State),
    RefresherTimer = case is_reference(RefreshedTimer) of
        true -> 
            nksip_lib:cancel_timer(RefreshedTimer),
            erlang:start_timer(RefresherTime, self(), refresher);
        false -> 
            undefined
    end,
    State1 = State#state{
        buffer = Rest,
        refresher_timer = RefresherTimer,
        refreshed_timer = undefined
    },
    {noreply, State1, Timeout};

handle_info({ssl, Socket, Packet}, State) ->
    handle_info({tcp, Socket, Packet}, State);

handle_info({tcp_closed, Socket}, State) ->
    #state{
        app_id = AppId,
        transport = #transport{remote_ip=Ip, remote_port=Port},
        socket = Socket
    } = State,
    ?debug(AppId, "closed TCP connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info({ssl_closed, Socket}, State) ->
    #state{
        app_id = AppId,
        socket = Socket, 
        transport = #transport{remote_ip=Ip, remote_port=Port}
    } = State,
    ?debug(AppId, "closed TLS connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info(timeout, State) ->
    #state{
        app_id = AppId,
        socket = Socket,
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}
    } = State,
    ?debug(AppId, "TCP/TLS connection from ~p:~p timeout", [Ip, Port]),
    socket_close(Proto, Socket),
    {stop, normal, State};

% Received from Ranch when the listener is ready
handle_info({shoot, _ListenerPid}, State) ->
    #state{socket=Socket, transport=#transport{proto=Proto}} = State,
    setopts(Proto, Socket, [{active, once}]),
    {noreply, State, State#state.timeout};

handle_info({timeout, _, refresher}, State) ->
    #state{
        app_id = AppId, 
        socket = Socket,
        transport = #transport{proto=Proto},
        timeout = Timeout
    } = State,
    case socket_send(Proto, Socket, <<"\r\n\r\n">>) of
        ok -> 
            State1 = State#state{
                refresher_timer = undefined,
                refreshed_timer = erlang:start_timer(10000, self(), refreshed)
            },
            {noreply, State1, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send TCP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_info({timeout, _, refreshed}, #state{app_id=AppId}=State) ->
    ?notice(AppId, "TCP refresher timeout", []),
    {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received nexpected info: ~p", [?MODULE, Info]),
    {noreply, State, State#state.timeout}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
parse(Packet, #state{app_id=AppId, socket=Socket, transport=Transport}=State) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port}=Transport,
    case nksip_parse:packet(AppId, Transport, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=_Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport, Packet),
            nksip_trace:insert(AppId, CallId, {tcp_in, Proto, Ip, Port, Packet}),
            case nksip_call_router:incoming_sync(RawMsg) of
                ok ->
                    case More of
                        <<>> -> <<>>;
                        _ -> parse(More, State)
                    end;
                {error, _} ->
                    socket_close(Proto, Socket),
                    <<>>
            end;
        {rnrn, More} ->
            socket_send(Proto, Socket, <<"\r\n">>),
            parse(More, State);
        {more, More} -> 
            More;
        {error, Error} ->
            ?notice(AppId, "error ~p processing TCP/TLS request", [Error]),
            socket_close(Proto, Socket),
            <<>>           
    end.


%% @private
socket_send(tcp, Socket, Packet) -> gen_tcp:send(Socket, Packet);
socket_send(tls, Socket, Packet) -> ssl:send(Socket, Packet).


%% @private
setopts(tcp, Socket, Opts) -> inet:setopts(Socket, Opts);
setopts(tls, Socket, Opts) -> ssl:setopts(Socket, Opts).


%% @private
socket_close(tcp, Socket) -> gen_tcp:close(Socket);
socket_close(tls, Socket) -> ssl:close(Socket).


