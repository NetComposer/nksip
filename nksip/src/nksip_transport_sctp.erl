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

%% @private SCTP Transport.
%% This module is used for both inbound and outbound TCP and TLS connections.

-module(nksip_transport_sctp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_server/2, start_client/4, send/2, stop/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("kernel/include/inet_sctp.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private
start_server(AppId, Transport) -> 
    gen_server:start_link(?MODULE, [server, AppId, Transport], []).

%% @private
start_client(AppId, Transport, Socket, Assoc) ->
    gen_server:start_link(?MODULE, [client, AppId, Transport, Socket, Assoc]).

%% @private Sends a new SCTP request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, #sipmsg{app_id=AppId, call_id=CallId, transport=Transport}=SipMsg) ->
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    Packet = nksip_unparse:packet(SipMsg),
    case catch gen_server:call(Pid, {send, Packet}) of
        ok ->
            nksip_trace:insert(SipMsg, {sctp_out, Ip, Port, Packet}),
            nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transport, Packet),
            ok;
        {'EXIT', Error} ->
            ?notice(AppId, CallId, "could not send SCTP message: ~p", [Error]),
            error
    end.


%% @private
stop(Pid) ->
    gen_server:cast(Pid, stop).


%% ===================================================================
%% gen_server
%% ===================================================================



-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port() | #sslsocket{},
    assoc :: #sctp_assoc_change{},
    timeout :: integer()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([server, AppId, Transport]) ->
    #transport{listen_ip=Ip, listen_port=Port} = Transport,
    Opts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
    case gen_sctp:open(Port, Opts) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Transport1 = Transport#transport{local_port=Port1, listen_port=Port1},
            ok = gen_sctp:listen(Socket, true),
            nksip_proc:put(nksip_transports, {AppId, Transport1}),
            nksip_proc:put({nksip_listen, AppId}, Transport1),

            Self = self(),
            spawn_link(fun() -> listener(Socket, Self) end),
            {ok, 
                #state{
                    app_id = AppId, 
                    transport = Transport1, 
                    socket = Socket
                }};
        {error, Error} ->
            ?error(AppId, "could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end;


init([client, AppId, Transport, Socket, Assoc]) ->
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transport), 
    nksip_proc:put(nksip_transports, {AppId, Transport}),
    nksip_counters:async([nksip_transport_sctp]),
    Timeout = nksip_config:get(tcp_timeout),
    State = #state{
        app_id = AppId, 
        transport = Transport, 
        socket = Socket,
        assoc = Assoc,
        timeout = Timeout
    },
    {ok, State, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Packet}, _From, State) ->
    #state{
        app_id = AppId, 
        socket = Socket,
        timeout = Timeout,
        assoc = Assoc
    } = State,
    case gen_sctp:send(Socket, Assoc, 0, Packet) of
        ok -> 
            {reply, ok, State, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send SCTP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({data, {Ip, Port, Stream, AssocId, Data}}, State) ->
    #state{app_id=AppId} = State,
    ?notice(AppId, "SCTP listener data: ~p\n~p", [{Ip, Port, Stream, AssocId}, Data]),
    parse(Data, Ip, Port, State),
    {noreply, State};

handle_cast({listener_error, Error}, #state{app_id=AppId}=State) ->
    ?notice(AppId, "SCTP listener error ~p", [Error]),
    {stop, Error, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({sctp, _Socket, _Ip, _Port, {_Anc, SAC}}, State) ->
    #state{app_id=AppId, timeout=Timeout} = State,
    ?warning(AppId, "SCTP received SAC: ~p", [SAC]),
    {noreply, State, Timeout};

handle_info({sctp, Socket, Ip, Port, Data}, State) ->
    #state{app_id=AppId, socket=Socket, timeout=Timeout} = State,
    ?warning(AppId, "SCTP received data: ~p", [Data]),
    parse(Data, Ip, Port, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State, Timeout};

handle_info(timeout, State) ->
    #state{
        app_id = AppId,
        transport = #transport{remote_ip=Ip, remote_port=Port},
        socket = Socket,
        assoc = Assoc
    } = State,
    ?debug(AppId, "SCTP connection from ~p:~p timeout", [Ip, Port]),
    gen_sctp:eof(Socket, Assoc),
    {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received nexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


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
listener(Socket, Pid) ->
    case gen_sctp:recv(Socket) of
        {error, Error} ->
            gen_server:cast(Pid, {listener_error, Error});
        {ok, {Ip, Port, [Info], Data}} ->
            #sctp_sndrcvinfo{stream=Stream, assoc_id=AssocId} = Info,
            gen_server:cast(Pid, {incoming, {Ip, Port, Stream, AssocId, Data}}),
            listener(Socket, Pid)
    end.


%% @private
parse(Packet, Ip, Port, #state{app_id=AppId, transport=Transport}=State) ->   
    Transport1 = Transport#transport{remote_ip=Ip, remote_port=Port},
    case nksip_parse:packet(AppId, Transport1, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport1, Packet),
            nksip_trace:insert(AppId, CallId, {in_udp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after UDP msg: ~p", [More])
            end;
        {rnrn, More} ->
            parse(More, Ip, Port, State);
        {more, More} -> 
            ?notice(AppId, "ignoring incomplete UDP msg: ~p", [More])
    end.
