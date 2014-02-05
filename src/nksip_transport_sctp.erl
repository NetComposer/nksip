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
-export([start_link/3, start_refresh/1, start_refresh/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).
-export([parse/4]).

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
        {?MODULE, start_link, [AppId, Transp, Opts]},
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
            Autoclose = nksip_config:get_cached(sctp_timeout, Opts),
            SocketOpts = [
                binary, {active, false},
                {sctp_initmsg, #sctp_initmsg{num_ostreams=1, max_instreams=1}},
                {sctp_autoclose, Autoclose},    
                {sctp_default_send_param, #sctp_sndrcvinfo{stream=0, flags=[unordered]}}
            ],
            % We could start a new association using existing listening socket
            % but it is not clear how many to allow
            case gen_sctp:open(0, SocketOpts) of
                {ok, Socket}  ->
                    {ok, {LocalIp, LocalPort}} = inet:sockname(Socket),
                    case gen_sctp:connect(Socket, Ip, Port, SocketOpts) of
                        {ok, Assoc} ->
                            #sctp_assoc_change{assoc_id=AssocId} = Assoc,
                            Transp = ListenTransp#transport{
                                local_ip = LocalIp,
                                local_port = LocalPort,
                                remote_ip = Ip,
                                remote_port = Port,
                                sctp_id=AssocId
                            },
                            Spec = {
                                {AppId, sctp, Ip, Port, make_ref()},
                                {nksip_transport_sctp_conn, start_link, 
                                    [AppId, Transp, Socket, 1000*Autoclose]},
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
    case catch gen_server:call(Pid, get_socket, 30000) of
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


%% @doc Start a time-alive series (default time)
-spec start_refresh(pid()) ->
    ok.

start_refresh(Pid) ->
    start_refresh(Pid, ?DEFAULT_TCP_KEEPALIVE).


%% @doc Start a time-alive series
-spec start_refresh(pid(), pos_integer()) ->
    ok.

start_refresh(Pid, Secs) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    gen_server:cast(Pid, {start_refresh, Time}).



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link(AppId, Transp, Opts) -> 
    gen_server:start_link(?MODULE, [server, AppId, Transp, Opts], []).


-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    % assocs :: dict(),
    timeout :: integer()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transp, Opts]) ->
    #transport{listen_ip=Ip, listen_port=Port} = Transp,
    Opts1 = [
        binary, {reuseaddr, true}, {ip, Ip}, {active, once},
        {sctp_initmsg, 
            #sctp_initmsg{num_ostreams=?OUT_STREAMS, max_instreams=?IN_STREAMS}},
        % {sctp_autoclose, Autoclose},    
        {sctp_default_send_param, #sctp_sndrcvinfo{stream=0, flags=[unordered]}}
    ],
    Timeout = 1000*nksip_config:get_cached(sctp_timeout, Opts),
    case gen_sctp:open(Port, Opts1) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Transp1 = Transp#transport{local_port=Port1, listen_port=Port1},
            ok = gen_sctp:listen(Socket, true),
            nksip_proc:put(nksip_transports, {AppId, Transp1}),
            nksip_proc:put({nksip_listen, AppId}, Transp1),
            State = #state{
                app_id = AppId, 
                transport = Transp1, 
                socket = Socket,
                % assocs = dict:new()
                timeout = Timeout
            },
            {ok, State};
        {error, Error} ->
            ?error(AppId, "could not start SCTP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).


handle_call(get_socket, _From, #state{socket=Socket}=State) ->
    {reply, {ok, Socket}, State};

% handle_call(get_assocs, _From, #state{assocs=Assocs}=State) ->
%     {reply, {ok, dict:to_list(Assocs)}, State};

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

% handle_info({sctp, Socket, _Ip, _Port, 
%             {_Anc, #sctp_assoc_change{state=shutdown_comp}}}, 
%             #state{socket=Socket, type=client}=State) ->
%     gen_sctp:close(Socket),
%     {stop, normal, State};

handle_info({sctp, Socket, Ip, Port, {Anc, SAC}}, State) ->
    #state{app_id=AppId, socket=Socket, transport=Transp, timeout=Timeout} = State,
    case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            ?warning(AppId, "Server SCTP: comm_up: ~p", [AssocId]),
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
            nksip_transport_sctp_conn:start_link(AppId, Transp1, Socket, Timeout);
        #sctp_assoc_change{state=shutdown_comp, assoc_id=AssocId} ->
            ?warning(AppId, "Server SCTP: shutdown_comp", []),
            case nksip_transport:get_connected(AppId, sctp, Ip, Port) of
                [{#transport{sctp_id=AssocId}, Pid}] ->
                    gen_server:cast(Pid, stop);
                _ ->
                    ?notice(AppId, 
                            "SCTP received shutdown_comp for unknown connection", [])
            end;
        #sctp_paddr_change{addr=Addr, state=addr_confirmed, assoc_id=AssocId} ->
            ?warning(AppId, "Server SCTP: addr_confirmed: ~p, ~p", [Addr, AssocId]),
            {Ip1, Port1} = Addr,
            case nksip_transport:get_connected(AppId, sctp, Ip1, Port1) of
                [{#transport{sctp_id=AssocId}, _Pid}] ->
                    ?notice(AppId, 
                            "SCTP received addr_confirmed for known connection", []);
                _ ->
                    Transp1 = Transp#transport{remote_ip=Ip1, remote_port=Port1, 
                                               sctp_id=AssocId},
                    nksip_transport_sctp_conn:start_link(AppId, Transp1, Socket, Timeout)
            end;
        #sctp_shutdown_event{assoc_id=AssocId} ->
            ?warning(AppId, "Server SCTP: #sctp_shutdown_event: ~p", [AssocId]),
            case nksip_transport:get_connected(AppId, sctp, Ip, Port) of
                [{#transport{sctp_id=AssocId}, Pid}] ->
                    gen_server:cast(Pid, stop);
                _ ->
                    ?notice(AppId, 
                            "SCTP received shutdown_comp for unknown connection", [])
            end;
        Data when is_binary(Data) ->
            [#sctp_sndrcvinfo{assoc_id=AssocId}] = Anc,
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
            parse(AppId, Transp1, Socket, Data);
        Other ->
            ?warning(AppId, "SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other])
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

% handle_info(timeout, State) ->
%     #state{app_id=AppId, socket=Socket} = State,
%     ?debug(AppId, "SCTP connection timeout", []),
%     gen_sctp:close(Socket),
%     {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p (~p)", [?MODULE, Info, State]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, #state{app_id=AppId, socket=Socket}) ->  
    ?debug(AppId, "SCTP server process stopped", []),
    gen_sctp:close(Socket).



%% ===================================================================
%% Internal
%% ===================================================================



%% @private
parse(AppId, Transp, Socket, Packet) ->   
    case nksip_parse:packet(AppId, Transp, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transp, Packet),
            nksip_trace:insert(AppId, CallId, {in_sctp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after SCTP msg: ~p", [More])
            end;
        {rnrn, More} ->
            #transport{sctp_id=AssocId} = Transp,
            gen_sctp:send(Socket, AssocId, 0, <<"\r\n\r\n">>),
            parse(AppId, Transp, Socket, More);
        {more, More} -> 
            ?notice(AppId, "ignoring incomplete SCTP msg: ~p", [More]);
        {error, Error} ->
            ?notice(AppId, "error ~p processing SCTP msg", [Error])
    end.


% %% @private
% add_connection(Ip, Port, AssocId, State) ->
%     #state{type=Type, app_id=AppId, assocs=Assocs, transport=Transp} = State,
%     ?warning(AppId, "SCTP (~p) new connection from ~p:~p: ~p", 
%            [Type, Ip, Port, AssocId]),
%     Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
%     nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp1),
%     State#state{assocs=dict:store(AssocId, [{Ip, Port}], Assocs)}.


%% @private
% remove_connection(AssocId, State) ->
%     #state{type=Type, app_id=AppId, assocs=Assocs} = State,
%     case dict:find(AssocId, Assocs) of
%         {ok, Dests} -> 
%             ?debug(AppId, "SCTP (~p) removed connection: ~p", [Type, AssocId]),
%             lists:foreach(
%                 fun({Ip, Port}) -> 
%                     nksip_proc:del({nksip_connection, {AppId, sctp, Ip, Port}})
%                 end,
%                 Dests),
%             State#state{assocs=dict:erase(AssocId, Assocs)};
%         error ->
%             State
%     end.


% %% @private
% add_ip(Ip, Port, AssocId, State) ->
%     #state{type=Type, app_id=AppId, assocs=Assocs, transport=Transp} = State,
%     Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
%     case dict:find(AssocId, Assocs) of
%         {ok, Dests} ->
%             case lists:member({Ip, Port}, Dests) of
%                 true ->
%                     State;
%                 false ->
%                     ?debug(AppId, "SCTP ~p (~p) updated connection: ~p:~p", 
%                              [AssocId, Type, Ip, Port]),
%                     nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp1),
%                     State#state{assocs=dict:append(AssocId, {Ip, Port}, Assocs)}
%             end;
%         error ->
%             State
%     end.

   
    

