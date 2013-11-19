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
-module(nksip_transport_sctp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_listener/4, connect/4, send/2, send/3, stop/1]).
-export([start_server/3, start_client/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include("nksip.hrl").

-define(IN_STREAMS, 10).
-define(OUT_STREAMS, 10).


%% ===================================================================
%% Private
%% ===================================================================



%% @private Starts a new listening server
-spec start_listener(nksip:app_id(), inet:ip_address(), inet:port_number(), 
                   nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_listener(AppId, Ip, Port, Opts) ->
    Transp = #transport{
        proto = sctp,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = {
        {AppId, sctp, Ip, Port}, 
        {?MODULE, start_server, [AppId, Transp, Opts]},
        permanent, 
        5000, 
        worker, 
        [?MODULE]
    },
    nksip_transport_sup:add_transport(AppId, Spec).


%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), inet:ip_address(), inet:port_number(), 
                   nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.

connect(AppId, Ip, Port, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, sctp, Class) of
        [{ListenTransp, _Pid}|_] ->
            SocketOpts = outbound_opts(Opts),
            case gen_sctp:open(0, SocketOpts) of
                {ok, Socket}  ->
                    {ok, {LocalIp, LocalPort}} = inet:sockname(Socket),
                    Timeout = 64 * nksip_config:get(timer_t1),
                    case gen_sctp:connect(Socket, Ip, Port, [], Timeout) of
                        {ok, Assoc} ->
                            #sctp_assoc_change{assoc_id=AssocId} = Assoc,
                            Transp = ListenTransp#transport{
                                local_ip = LocalIp,
                                local_port = LocalPort,
                                remote_ip = Ip,
                                remote_port = Port,
                                sctp_id = AssocId
                            },
                            Spec = {
                                {AppId, sctp, Ip, Port, make_ref()},
                                {?MODULE, start_client, [AppId, Transp, Socket]},
                                temporary,
                                5000,
                                worker,
                                [?MODULE]
                            },
                            {ok, Pid} = nksip_transport_sup:add_transport(AppId, Spec),
                            gen_sctp:controlling_process(Socket, Pid),
                            inet:setopts(Socket, [{active, once}]),
                            ?debug(AppId, "connected to ~s:~p (sctp)", 
                                   [nksip_lib:to_host(Ip), Port]),
                            {ok, Pid, Transp};
                        {error, Error} ->
                            {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        [] ->
            {error, no_listening_transport}
    end.


%% @private Sends a new SCTP request or response
-spec send(pid(), #sipmsg{}|binary()) ->
    ok | error.

send(Pid, #sipmsg{}=SipMsg) ->
    #sipmsg{
        app_id = AppId,
        class = Class,
        call_id = CallId,
        transport=#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId} = Transp
    } = SipMsg,
    Packet = nksip_unparse:packet(SipMsg),
    case send(Pid, AssocId, Packet) of
        ok ->
            case Class of
                {req, Method} ->
                    nksip_trace:insert(SipMsg, {sctp_out, Ip, Port, Method, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok;
                {resp, Code, _Reason} ->
                    nksip_trace:insert(SipMsg, {sctp_out, Ip, Port, Code, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok
            end;
        {error, Error} ->
            ?info(AppId, "error sending SCTP msg to ~p, ~p (~p)", [Ip, Port, Error]),
            error
    end.


%% @private
-spec send(pid(), integer(), binary()) ->
    ok | {error, term()}.

send(Pid, AssocId, Data) ->
    case catch gen_server:call(Pid, get_socket, 6000) of
        {ok, Socket} -> 
            gen_sctp:send(Socket, AssocId, 0, Data);
        {'EXIT', Error} -> 
            {error, Error};
        {error, Error} -> 
            {error, Error}
    end.


%% @private
stop(Pid) ->
    gen_server:cast(Pid, stop).


%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_server(AppId, Transp, Opts) -> 
    gen_server:start_link(?MODULE, [server, AppId, Transp, Opts], []).


%% @private
start_client(AppId, Transp, Socket) -> 
    gen_server:start_link(?MODULE, [client, AppId, Transp, Socket], []).


-record(state, {
    type :: server | client,
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    assocs :: dict()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([server, AppId, Transp, _Opts]) ->
    #transport{listen_ip=Ip, listen_port=Port} = Transp,
    Autoclose = round(nksip_config:get(sctp_timeout)/1000),
    Opts1 = [
        binary, {reuseaddr, true}, {ip, Ip}, {active, once},
        {sctp_initmsg, 
            #sctp_initmsg{num_ostreams=?OUT_STREAMS, max_instreams=?IN_STREAMS}},
        {sctp_autoclose, Autoclose},    
        {sctp_default_send_param, #sctp_sndrcvinfo{stream=0, flags=[unordered]}}
    ],
    case gen_sctp:open(Port, Opts1) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Transp1 = Transp#transport{local_port=Port1, listen_port=Port1},
            ok = gen_sctp:listen(Socket, true),
            nksip_proc:put(nksip_transports, {AppId, Transp1}),
            nksip_proc:put({nksip_listen, AppId}, Transp1),
            State = #state{
                type = server,
                app_id = AppId, 
                transport = Transp1, 
                socket = Socket,
                assocs = dict:new()
            },
            {ok, State};
        {error, Error} ->
            ?error(AppId, "could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end;

init([client, AppId, Transp, Socket]) ->
    #transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId} = Transp,
    nksip_proc:put(nksip_transports, {AppId, Transp}),
    State = #state{
        type = client,
        app_id = AppId, 
        transport = Transp, 
        socket = Socket,
        assocs = dict:new()
    },
    State1 = add_connection(Ip, Port, AssocId, State),
    {ok, State1}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(get_socket, _From, #state{socket=Socket}=State) ->
    {reply, {ok, Socket}, State};

handle_call(get_assocs, _From, #state{assocs=Assocs}=State) ->
    {reply, {ok, dict:to_list(Assocs)}, State};

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({sctp, Socket, _Ip, _Port, 
            {_Anc, #sctp_assoc_change{state=shutdown_comp}}}, 
            #state{socket=Socket, type=client}=State) ->
    gen_sctp:close(Socket),
    {stop, normal, State};

handle_info({sctp, Socket, Ip, Port, {_Anc, SAC}}, #state{socket=Socket}=State) ->
    #state{app_id=AppId} = State,
    State1 = case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            add_connection(Ip, Port, AssocId, State);
        #sctp_assoc_change{state=shutdown_comp, assoc_id=AssocId} ->
            remove_connection(AssocId, State);
        #sctp_paddr_change{addr=Addr, state=addr_confirmed, assoc_id=AssocId} ->
            {Ip1, Port1} = Addr,
            add_ip(Ip1, Port1, AssocId, State);
        #sctp_shutdown_event{assoc_id=AssocId} ->
            remove_connection(AssocId, State);
        Data when is_binary(Data) ->
            parse(Data, Ip, Port, State),
            State;
        Other ->
            ?warning(AppId, "SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other]),
            State
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State1};

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

terminate(_Reason, #state{app_id=AppId, type=Type, socket=Socket}) ->  
    ?debug(AppId, "SCTP ~p process stopped", [Type]),
    gen_sctp:close(Socket).



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
parse(Packet, Ip, Port, #state{app_id=AppId, transport=Transp}=State) ->   
    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
    case nksip_parse:packet(AppId, Transp1, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transp1, Packet),
            nksip_trace:insert(AppId, CallId, {in_sctp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after SCTP msg: ~p", [More])
            end;
        {rnrn, More} ->
            parse(More, Ip, Port, State);
        {more, More} -> 
            ?notice(AppId, "ignoring incomplete SCTP msg: ~p", [More]);
        {error, Error} ->
            ?notice(AppId, "error ~p processing SCTP msg", [Error])
    end.


%% @private
add_connection(Ip, Port, AssocId, State) ->
    #state{type=Type, app_id=AppId, assocs=Assocs, transport=Transp} = State,
    ?debug(AppId, "SCTP (~p) new connection from ~p:~p: ~p", 
           [Type, Ip, Port, AssocId]),
    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
    nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp1),
    State#state{assocs=dict:store(AssocId, [{Ip, Port}], Assocs)}.


%% @private
remove_connection(AssocId, State) ->
    #state{type=Type, app_id=AppId, assocs=Assocs} = State,
    case dict:find(AssocId, Assocs) of
        {ok, Dests} -> 
            ?debug(AppId, "SCTP (~p) removed connection: ~p", [Type, AssocId]),
            lists:foreach(
                fun({Ip, Port}) -> 
                    nksip_proc:del({nksip_connection, {AppId, sctp, Ip, Port}})
                end,
                Dests),
            State#state{assocs=dict:erase(AssocId, Assocs)};
        error ->
            State
    end.


%% @private
add_ip(Ip, Port, AssocId, State) ->
    #state{type=Type, app_id=AppId, assocs=Assocs, transport=Transp} = State,
    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
    case dict:find(AssocId, Assocs) of
        {ok, Dests} ->
            case lists:member({Ip, Port}, Dests) of
                true ->
                    State;
                false ->
                    ?debug(AppId, "SCTP ~p (~p) updated connection: ~p:~p", 
                             [AssocId, Type, Ip, Port]),
                    nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp1),
                    State#state{assocs=dict:append(AssocId, {Ip, Port}, Assocs)}
            end;
        error ->
            State
    end.

   
%% @private
outbound_opts(_Opts) ->
    Autoclose = round(nksip_config:get(sctp_timeout)/1000),
    [
        binary, {active, false},
        {sctp_initmsg, #sctp_initmsg{num_ostreams=1, max_instreams=1}},
        {sctp_autoclose, Autoclose},    
        {sctp_default_send_param, #sctp_sndrcvinfo{stream=0, flags=[unordered]}}
    ].

