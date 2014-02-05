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

%% @private UDP Transport Module.
-module(nksip_transport_udp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_listener/4, send/2, send_stun_sync/3, send_stun_async/3]).
-export([get_port/1, connect/3, start_refresh/2, receive_refresh/2]).
-export([start_link/3, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).
-export([parse/3]).

-include("nksip.hrl").

-define(MAX_UDP, 1500).


%% ===================================================================
%% Private
%% ===================================================================



%% @private Starts a new listening server
-spec start_listener(nksip:app_id(), inet:ip_address(), inet:port_number(), 
                   nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_listener(AppId, Ip, Port, Opts) ->
    Transp = #transport{
        proto = udp,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = {
        {AppId, udp, Ip, Port}, 
        {?MODULE, start_link, [AppId, Transp, Opts]},
        permanent, 
        5000, 
        worker, 
        [?MODULE]
    },
    nksip_transport_sup:add_transport(AppId, Spec).


%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), inet:ip_address(), inet:port_number()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
%% @private Registers a new connection
connect(AppId, Ip, Port) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, udp, Class) of
        [{_Transp, Pid}|_] -> 
            case catch gen_server:call(Pid, {connect, Ip, Port}) of
                {ok, Pid1, Transp1} -> {ok, Pid1, Transp1};
                _ -> {error, internal_error}
            end;
        [] -> 
            {error, no_listening_transport}
    end.


%% @private Sends a new UDP request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, SipMsg) ->
    #sipmsg{
        class = Class,
        app_id = AppId, 
        call_id = CallId,
        transport=#transport{remote_ip=Ip, remote_port=Port} = Transp
    } = SipMsg,
    Packet = nksip_unparse:packet(SipMsg),
    case do_send(Pid, Packet) of
        ok ->
            case Class of
                {req, Method} ->
                    nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Method, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok;
                {resp, Code, _Reaosn} ->
                    nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Code, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok
            end;
        {error, closed} ->
            error;
        {error, too_large} ->
            error;
        {error, Error} ->
            ?notice(AppId, CallId, "could not send UDP msg to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            error
    end.


%% @private Sends a new packet
-spec do_send(pid(), binary()) ->
    ok | {error, term()}.

do_send(Pid, Packet) when byte_size(Packet) =< ?MAX_UDP ->
    % This call can be sent to the nksip_transport_udp_conn process
    case catch gen_server:call(Pid, {send, Packet}, 60000) of
        ok -> ok;
        {error, Error} -> {error, Error};
        {'EXIT', {noproc, _}} -> {error, closed};
        {'EXIT', Error} -> {error, Error}
    end;

do_send(_Pid, Packet) ->
    lager:debug("Coult not send UDP packet (too large: ~p)", [byte_size(Packet)]),
    {error, too_large}.


%% @private Sends a STUN binding request
send_stun_sync(Pid, Ip, Port) ->
    case catch gen_server:call(Pid, {send_stun, Ip, Port}, 30000) of
        {stun, {StunIp, StunPort}} -> {ok, StunIp, StunPort};
        _ -> error
    end.


%% @private Sends a STUN binding request
send_stun_async(Pid, Ip, Port) ->
    gen_server:cast(Pid, {send_stun, Ip, Port, self()}).


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).


%% @doc Start a time-alive series
-spec start_refresh(pid(), pos_integer()) ->
    ok | error.

start_refresh(Pid, Secs) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    case catch gen_server:call(Pid, {start_refresh, Time}) of
        ok -> ok;
        _ -> error
    end.


%% @doc Updates timeout on no incoming packet
-spec receive_refresh(pid(), pos_integer()) ->
    ok | error.

receive_refresh(Pid, Secs) ->
    case catch gen_server:call(Pid, {receive_refresh, Secs}) of
        ok -> ok;
        _ -> error
    end.


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transp, Opts) -> 
    gen_server:start_link(?MODULE, [AppId, Transp, Opts], []).


-record(stun, {
    id :: binary(),
    dest :: {inet:ip_address(), inet:port_number()},
    packet :: binary(),
    retrans_timer :: reference(),
    next_retrans :: integer(),
    from :: from()
}).

-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    tcp_pid :: pid(),
    stuns :: [#stun{}],
    timer_t1 :: pos_integer()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, #transport{listen_ip=Ip, listen_port=Port}=Transp, Opts]) ->
    case open_port(AppId, Ip, Port, 5) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Self = self(),
            spawn(fun() -> start_tcp(AppId, Ip, Port1, Self) end),
            Transp1 = Transp#transport{local_port=Port1, listen_port=Port1},
            nksip_proc:put(nksip_transports, {AppId, Transp1}),
            nksip_proc:put({nksip_listen, AppId}, Transp1),
            State = #state{
                app_id = AppId, 
                transport = Transp1, 
                socket = Socket,
                tcp_pid = undefined,
                stuns = [],
                timer_t1 = nksip_config:get_cached(timer_t1, Opts)
            },
            {ok, State};
        {error, Error} ->
            ?error(AppId, "B could not start UDP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({connect, Ip, Port}, _From, State) ->
    {Pid, Transp1} = do_connect(Ip, Port, State),
    {reply, {ok, Pid, Transp1}, State};

% It should not be used normally, use the nksip_transport_udp_conn version
handle_call({send, Ip, Port, Packet}, _From, #state{socket=Socket}=State) ->
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State};

handle_call({send_stun, Ip, Port}, From, State) ->
    {noreply, do_send_stun(Ip, Port, {call, From}, State)};

handle_call(get_port, _From, #state{transport=#transport{listen_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(Msg, _Form, State) -> 
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({matching_tcp, {ok, Pid}}, State) ->
    {noreply, State#state{tcp_pid=Pid}};

handle_cast({matching_tcp, {error, Error}}, State) ->
    {stop, {matching_tcp, {error, Error}}, State};

handle_cast({send_stun, Ip, Port, Pid}, State) ->
    {noreply, do_send_stun(Ip, Port, {cast, Pid}, State)};

handle_cast(Msg, State) -> 
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({udp, Socket, _Ip, _Port, <<_, _>>}, #state{socket=Socket}=State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, State) ->
    #state{
        app_id = AppId,
        socket = Socket
    } = State,
    ok = inet:setopts(Socket, [{active, once}]),
    case nksip_stun:decode(Packet) of
        {request, binding, TransId, _} ->
            Response = nksip_stun:binding_response(TransId, Ip, Port),
            gen_udp:send(Socket, Ip, Port, Response),
            {Pid, _Transp} = do_connect(Ip, Port, State),
            gen_server:cast(Pid, stun_request),
            ?debug(AppId, "sent STUN bind response to ~p:~p", [Ip, Port]),
            {noreply, State};
        {response, binding, TransId, Attrs} ->
            {noreply, do_stun_response(TransId, Attrs, State)};
        error ->
            ?notice(AppId, "received unrecognized UDP packet: ~s", [Packet]),
            {noreply, State}
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    do_process(Ip, Port, Packet, State),
    read_packets(100, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({timeout, Ref, stun_retrans}, #state{stuns=Stuns}=State) ->
    {value, Stun1, Stuns1} = lists:keytake(Ref, #stun.retrans_timer, Stuns),
    {noreply, do_stun_retrans(Stun1, State#state{stuns=Stuns1})};
   
handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
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




%% ========= STUN processing ================================================

%% @private
do_send_stun(Ip, Port, From, State) ->
    #state{app_id=AppId, timer_t1=T1, stuns=Stuns, socket=Socket} = State,
    {Id, Packet} = nksip_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            ?debug(AppId, "sent STUN request to ~p", [{Ip, Port}]),
            Stun = #stun{
                id = Id,
                dest = {Ip, Port},
                packet = Packet,
                retrans_timer = erlang:start_timer(T1, self(), stun_retrans),
                next_retrans = 2*T1,
                from = From
            },
            State#state{stuns=[Stun|Stuns]};
        {error, Error} ->
            ?notice(AppId, "could not send UDP STUN request to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            Msg = {stun_request, error},
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, Msg);
                {cast, CastPid} -> gen_server:cast(CastPid, Msg)
            end,
            State
    end.


%% @private
do_stun_retrans(Stun, State) ->
    #stun{dest={Ip, Port}, packet=Packet, next_retrans=Next} = Stun,
    #state{app_id=AppId, stuns=Stuns, timer_t1=T1, socket=Socket} = State,
    case Next =< (16*T1) of
        true ->
            case gen_udp:send(Socket, Ip, Port, Packet) of
                ok -> 
                    ?notice(AppId, "sent STUN refresh", []),
                    Stun1 = Stun#stun{
                        retrans_timer = erlang:start_timer(Next, self(), stun_retrans),
                        next_retrans = 2*Next
                    },
                    State#state{stuns=[Stun1|Stuns]};
                {error, Error} ->
                    ?notice(AppId, "could not send UDP STUN request to ~p:~p: ~p", 
                          [Ip, Port, Error]),
                    do_stun_timeout(Stun, State)
            end;
        false ->
            do_stun_timeout(Stun, State)
    end.


%% @private
do_stun_response(TransId, Attrs, State) ->
    #state{app_id=AppId, stuns=Stuns} = State,
    case lists:keytake(TransId, #stun.id, Stuns) of
        {value, #stun{retrans_timer=Retrans, from=From}, Stuns1} ->
            nksip_lib:cancel_timer(Retrans),
            case nksip_lib:get_value(xor_mapped_address, Attrs) of
                {StunIp, StunPort} -> 
                    ok;
                _ ->
                    case nksip_lib:get_value(mapped_address, Attrs) of
                        {StunIp, StunPort} -> ok;
                        _ -> StunIp = StunPort = undefined
                    end
            end,
            Msg = {stun_response, {StunIp, StunPort}},
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, Msg);
                {cast, CastPid} -> gen_server:cast(CastPid, Msg)
            end,
            State#state{stuns=Stuns1};
        false ->
            ?notice(AppId, "received unexpected STUN response", []),
            State
    end.


%% @private
do_stun_timeout(Stun, #state{app_id=AppId}=State) ->
    #stun{dest={Ip, Port}, from=From} = Stun,
    ?notice(AppId, "STUN request to ~p timeout", [{Ip, Port}]),
    case From of
        {call, CallFrom} -> gen_server:reply(CallFrom, {stun, error});
        {cast, CastPid} -> gen_server:cast(CastPid, {stun, error})
    end,
    State.
        

%% ===================================================================
%% Internal
%% ===================================================================


%% @private
start_tcp(AppId, Ip, Port, Pid) ->
    case nksip_transport:start_transport(AppId, tcp, Ip, Port, []) of
        {ok, TcpPid} -> gen_server:cast(Pid, {matching_tcp, {ok, TcpPid}});
        {error, Error} -> gen_server:cast(Pid, {matching_tcp, {error, Error}})
    end.

%% @private Checks if a port is available for UDP and TCP
-spec open_port(nksip:app_id(), inet:ip_address(), inet:port_number(), integer()) ->
    {ok, port()} | {error, term()}.

open_port(AppId, Ip, Port, Iter) ->
    Opts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
    case gen_udp:open(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            lager:warning("UDP port ~p is in use, waiting (~p)", [Port, Iter]),
            timer:sleep(1000),
            open_port(AppId, Ip, Port, Iter-1);
        {error, Error} ->
            {error, Error}
    end.


%% @private 
read_packets(0, _State) ->
    ok;
read_packets(N, #state{socket=Socket}=State) ->
    case gen_udp:recv(Socket, 0, 0) of
        {error, _} -> 
            ok;
        {ok, {Ip, Port, Packet}} -> 
            do_process(Ip, Port, Packet, State),
            read_packets(N-1, State)
    end.


%% @private
%% TODO: test if it is quicket to parse locally and send only a notification
%% to process
do_process(Ip, Port, Packet, State) ->
    {Pid, _} = do_connect(Ip, Port, State),
    gen_server:cast(Pid, {udp, Packet}).


%% @private
do_connect(Ip, Port, State) ->
    #state{app_id=AppId, transport=Transp, socket=Socket}= State,
    case nksip_transport:get_connected(AppId, udp, Ip, Port) of
        [{Transp1, Pid}] -> 
            {Pid, Transp1};
        [] ->
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
            {ok, Pid} = nksip_transport_udp_conn:start_link(AppId, Transp1, Socket, []),
            {Pid, Transp1}
    end.


%% @private
parse(AppId, Transp, Packet) ->
    case nksip_parse:packet(AppId, Transp, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transp, Packet),
            nksip_trace:insert(AppId, CallId, {in_udp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after UDP msg: ~p", [More])
            end;
        {rnrn, More} ->
            parse(AppId, Transp, More);
        {more, More} ->
            ?notice(AppId, "ignoring extrada data ~s processing UDP msg", [More]);
        {error, Error} ->
            ?notice(AppId, "error ~p processing UDP msg", [Error])
    end.

