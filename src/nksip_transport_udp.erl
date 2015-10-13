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

-export([send_stun_sync/3, send_stun_async/3, get_port/1]).
-export([get_listener/3, connect/2]).
-export([start_link/3, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @private Sends a STUN binding request
%% It does not open a new NkSIP's UDP connection
send_stun_sync(Pid, Ip, Port) ->
    case catch gen_server:call(Pid, {send_stun, Ip, Port}, 30000) of
        {ok, StunIp, StunPort} -> 
            {ok, StunIp, StunPort};
        error -> 
            error
    end.


%% @private Sends a STUN binding request
send_stun_async(Pid, Ip, Port) ->
    gen_server:cast(Pid, {send_stun, Ip, Port, self()}).


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).



%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkservice:id(), nksip:transport(), nksip:optslist()) ->
    term().

get_listener(SrvId, #transport{listen_ip=Ip, listen_port=Port}=Transp, Opts) ->
    {
        {SrvId, udp, Ip, Port}, 
        {?MODULE, start_link, [SrvId, Transp, Opts]},
        permanent, 
        5000, 
        worker, 
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(pid(), nksip:transport()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
connect(Pid, #transport{remote_ip=Ip, remote_port=Port}) ->
    case catch gen_server:call(Pid, {connect, Ip, Port}, 30000) of
        {ok, Pid1, Transp1} -> 
            {ok, Pid1, Transp1};
        {error, Error} ->
            {error, Error};
        {'EXIT', Error} -> 
            {error, Error}
    end.


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(SrvId, Transp, Opts) -> 
    gen_server:start_link(?MODULE, [SrvId, Transp, Opts], []).


-record(stun, {
    id :: binary(),
    dest :: {inet:ip_address(), inet:port_number()},
    packet :: binary(),
    retrans_timer :: reference(),
    next_retrans :: integer(),
    from :: {pid(), term()}
}).

-record(state, {
    srv_id :: nkservice:id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    tcp_pid :: pid(),
    stuns :: [#stun{}],
    timer_t1 :: pos_integer(),
    timeout :: pos_integer()
}).


%% @private 
init([SrvId, #transport{listen_ip=Ip, listen_port=Port}=Transp, Opts]) ->
    case open_port(SrvId, Ip, Port, 5) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            Self = self(),
            spawn(fun() -> start_tcp(SrvId, Ip, Port1, Opts, Self) end),
            Transp1 = Transp#transport{local_port=Port1, listen_port=Port1},
            nklib_proc:put(nksip_transports, {SrvId, Transp1}),
            nklib_proc:put({nksip_listen, SrvId}, Transp1),
            State = #state{
                srv_id = SrvId, 
                transport = Transp1, 
                socket = Socket,
                tcp_pid = undefined,
                stuns = [],
                timer_t1 = nklib_util:get_value(sip_timer_t1, Opts),
                timeout = 1000*nklib_util:get_value(sip_udp_timeout, Opts)
            },
            {ok, State};
        {error, Error} ->
            ?error(SrvId, <<>>, "could not start UDP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
handle_call({connect, Ip, Port}, _From, State) ->
    {reply, do_connect(Ip, Port, State), State};

% It should not be used normally, use the nksip_connection version
handle_call({send, Ip, Port, Packet}, _From, #state{socket=Socket}=State) ->
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State};

handle_call({send_stun, Ip, Port}, From, #state{srv_id=SrvId}=State) ->
    {noreply, do_send_stun(SrvId, Ip, Port, {call, From}, State)};

handle_call(get_port, _From, #state{transport=#transport{listen_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(Msg, _Form, State) -> 
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_cast({matching_tcp, {ok, Pid}}, State) ->
    {noreply, State#state{tcp_pid=Pid}};

handle_cast({matching_tcp, {error, Error}}, State) ->
    {stop, {matching_tcp, {error, Error}}, State};

handle_cast({send_stun, Ip, Port, Pid}, #state{srv_id=SrvId}=State) ->
    {noreply, do_send_stun(SrvId, Ip, Port, {cast, Pid}, State)};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_info({udp, Socket, _Ip, _Port, <<_, _>>}, #state{socket=Socket}=State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, State) ->
    #state{srv_id=SrvId, socket=Socket} = State,
    ok = inet:setopts(Socket, [{active, once}]),
    case nksip_stun:decode(Packet) of
        {request, binding, TransId, _} ->
            case do_connect(Ip, Port, State) of
                {ok, Pid, _Transp} ->    
                    Response = nksip_stun:binding_response(TransId, Ip, Port),
                    nksip_connection:async_send(Pid, Response),
                    ?debug(SrvId, <<>>, "sent STUN bind response to ~p:~p", [Ip, Port]),
                    {noreply, State};
                {error, Error} ->
                    ?notice(SrvId, <<>>, "Error starting UDP connection: ~p", [Error]),
                    {noreply, State}
            end;
        {response, binding, TransId, Attrs} ->
            {noreply, do_stun_response(TransId, Attrs, State)};
        error ->
            ?notice(SrvId, <<>>, "received unrecognized UDP packet: ~s", [Packet]),
            {noreply, State}
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    read_packets(Ip, Port, Packet, State, 100),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({timeout, Ref, stun_retrans}, #state{stuns=Stuns}=State) ->
    {value, Stun1, Stuns1} = lists:keytake(Ref, #stun.retrans_timer, Stuns),
    {noreply, do_stun_retrans(Stun1, State#state{stuns=Stuns1})};
   
handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
terminate(_Reason, _State) ->  
    ok.




%% ========= STUN processing ================================================

%% @private
do_send_stun(SrvId, Ip, Port, From, State) ->
    #state{timer_t1=T1, stuns=Stuns, socket=Socket} = State,
    {Id, Packet} = nksip_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            ?debug(SrvId, <<>>, "sent STUN request to ~p", [{Ip, Port}]),
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
            ?notice(SrvId, <<>>, "could not send UDP STUN request to ~p:~p: ~p", 
                         [Ip, Port, Error]),
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, error);
                {cast, CastPid} -> gen_server:cast(CastPid, {stun, error})
            end,
            State
    end.


%% @private
do_stun_retrans(Stun, State) ->
    #stun{dest={Ip, Port}, packet=Packet, next_retrans=Next} = Stun,
    #state{srv_id=SrvId, stuns=Stuns, timer_t1=T1, socket=Socket} = State,
    case Next =< (16*T1) of
        true ->
            case gen_udp:send(Socket, Ip, Port, Packet) of
                ok -> 
                    ?info(SrvId, <<>>, "sent STUN refresh", []),
                    Stun1 = Stun#stun{
                        retrans_timer = erlang:start_timer(Next, self(), stun_retrans),
                        next_retrans = 2*Next
                    },
                    State#state{stuns=[Stun1|Stuns]};
                {error, Error} ->
                    ?notice(SrvId, <<>>, "could not send UDP STUN request to ~p:~p: ~p", 
                                 [Ip, Port, Error]),
                    do_stun_timeout(Stun, State)
            end;
        false ->
            do_stun_timeout(Stun, State)
    end.


%% @private
do_stun_response(TransId, Attrs, State) ->
    #state{srv_id=SrvId, stuns=Stuns} = State,
    case lists:keytake(TransId, #stun.id, Stuns) of
        {value, #stun{retrans_timer=Retrans, from=From}, Stuns1} ->
            nklib_util:cancel_timer(Retrans),
            case nklib_util:get_value(xor_mapped_address, Attrs) of
                {StunIp, StunPort} -> 
                    ok;
                _ ->
                    case nklib_util:get_value(mapped_address, Attrs) of
                        {StunIp, StunPort} -> ok;
                        _ -> StunIp = StunPort = undefined
                    end
            end,
            Msg = {ok, StunIp, StunPort},
            case From of
                {call, CallFrom} -> gen_server:reply(CallFrom, Msg);
                {cast, CastPid} -> gen_server:cast(CastPid, {stun, Msg})
            end,
            State#state{stuns=Stuns1};
        false ->
            ?notice(SrvId, <<>>, "received unexpected STUN response", []),
            State
    end.


%% @private
do_stun_timeout(Stun, State) ->
    #stun{dest={Ip, Port}, from=From} = Stun,
    #state{srv_id=SrvId} = State,
    ?notice(SrvId, <<>>, "STUN request to ~p timeout", [{Ip, Port}]),
    case From of
        {call, CallFrom} -> gen_server:reply(CallFrom, error);
        {cast, CastPid} -> gen_server:cast(CastPid, {stun, error})
    end,
    State.
        

%% ===================================================================
%% Internal
%% ===================================================================


%% @private
start_tcp(SrvId, Ip, Port, Opts, Pid) ->
    case nksip_transport:start_transport(SrvId, tcp, Ip, Port, Opts) of
        {ok, TcpPid} -> 
            gen_server:cast(Pid, {matching_tcp, {ok, TcpPid}});
        {error, Error} -> 
            gen_server:cast(Pid, {matching_tcp, {error, Error}})
    end.

%% @private Checks if a port is available for UDP and TCP
-spec open_port(nkservice:id(), inet:ip_address(), inet:port_number(), integer()) ->
    {ok, port()} | {error, term()}.

open_port(SrvId, Ip, Port, Iter) ->
    Opts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
    case gen_udp:open(Port, Opts) of
        {ok, Socket} ->
            {ok, Socket};
        {error, eaddrinuse} when Iter > 0 ->
            ?warning(SrvId, <<>>, "UDP port ~p is in use, waiting (~p)", [Port, Iter]),
            timer:sleep(1000),
            open_port(SrvId, Ip, Port, Iter-1);
        {error, Error} ->
            {error, Error}
    end.


%% @private 
read_packets(Ip, Port, Packet, #state{socket=Socket}=State, N) ->
    case do_connect(Ip, Port, State) of
        {ok, Pid, _} ->
            nksip_connection:incoming(Pid, Packet),
            case N>0 andalso gen_udp:recv(Socket, 0, 0) of
                {ok, {Ip1, Port1, Packet1}} -> 
                    read_packets(Ip1, Port1, Packet1, State, N-1);
                _ ->
                    ok
            end;
        {error, _} ->
            ok
    end.


%% @private
do_connect(Ip, Port, State) ->
    #state{srv_id=SrvId, transport=Transp, socket=Socket, timeout=Timeout}= State,
    case nksip_transport:get_connected(SrvId, udp, Ip, Port, <<>>) of
        [{Transp1, Pid}|_] -> 
            {ok, Pid, Transp1};
        [] ->
            case nksip_connection:is_max(SrvId) of
                false ->
                    Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
                    {ok, Pid} = nksip_connection:start_link(SrvId, Transp1, 
                                                            Socket, Timeout),
                    {ok, Pid, Transp1};
                true ->
                    {error, max_connections}
            end
    end.



