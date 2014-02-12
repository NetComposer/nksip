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

%% @doc Generic tranport connection process
-module(nksip_transport_conn).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_listener/5, connect/5, send/2, async_send/2, stop/2]).
-export([start_refresh/3, stop_refresh/1, receive_refresh/2, get_transport/1]).
-export([incoming/2]).
-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).

-include("nksip.hrl").

-define(MAX_BUFFER, 65535).



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new listening server
-spec start_listener(nksip:app_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_listener(AppId, Proto, Ip, Port, Opts) ->
    Transp = #transport{
        proto = Proto,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = case Proto of
        udp -> nksip_transport_udp:get_listener(AppId, Transp, Opts);
        tcp -> nksip_transport_tcp:get_listener(AppId, Transp, Opts);
        tls -> nksip_transport_tcp:get_listener(AppId, Transp, Opts);
        sctp -> nksip_transport_sctp:get_listener(AppId, Transp, Opts);
        _ -> {error, invalid_transport}
    end,
    nksip_transport_sup:add_transport(AppId, Spec).

    
%% @doc Starts a new connection to a remote server
-spec connect(nksip:app_id(), nksip:protocol(),
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
connect(AppId, Proto, Ip, Port, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, Proto, Class) of
        [{Transp, Pid}|_] -> 
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port},
            case Proto of
                udp -> nksip_transport_udp:connect(Pid, Transp1, Opts);
                tcp -> nksip_transport_tcp:connect(AppId, Transp1, Opts);
                tls -> nksip_transport_tcp:connect(AppId, Transp1, Opts);
                sctp -> nksip_transport_sctp:connect(Pid, Transp1, Opts)
            end;
        [] ->
            {error, no_listening_transport}
    end.


%% @doc Sends a new request or response to a started connection
-spec send(pid(), #sipmsg{}|binary()) ->
    ok | {error, term()}.

send(Pid, #sipmsg{}=SipMsg) ->
    #sipmsg{app_id=AppId, class=Class, call_id=CallId, transport=Transp} = SipMsg,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
    Packet = nksip_unparse:packet(SipMsg),
    case send(Pid, Packet) of
        ok ->
            case Class of
                {req, Method} ->
                    nksip_trace:insert(SipMsg, {Proto, Ip, Port, Method, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok;
                {resp, Code, _Reason} ->
                    nksip_trace:insert(SipMsg, {Proto, Ip, Port, Code, Packet}),
                    nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transp, Packet),
                    ok
            end;
        {error, Error} ->
            ?notice(AppId, CallId, "could not send ~p message: ~p", [Proto, Error]),
            {error, Error}
    end;

send(Pid, Packet) when is_binary(Packet) ->
    case catch gen_server:call(Pid, {send, Packet}) of
        ok -> ok;
        {'EXIT', Error} -> {error, Error}
    end.


%% @private Sends a new request or response to a started connection
-spec async_send(pid(), binary()) ->
    ok.

async_send(Pid, Packet) when is_binary(Packet) ->
    gen_server:cast(Pid, {send, Packet}).


%% @doc Stops a started connection
stop(Pid, Reason) ->
    gen_server:cast(Pid, {stop, Reason}).


%% @doc Start a time-alive series, with result notify
%% If `Ref' is not `undefined', a message will be sent to self() using `Ref'
%% after the fist successful ping response
-spec start_refresh(pid(), pos_integer(), term()) ->
    ok | error.

start_refresh(Pid, Secs, Ref) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    case catch gen_server:call(Pid, {start_refresh, Time, Ref, self()}) of
        {ok, Pid} -> {ok, Pid};
        _ -> error
    end.

%% @doc Start a time-alive series, with result notify
-spec stop_refresh(pid()) ->
    ok.

stop_refresh(Pid) ->
    gen_server:cast(Pid, stop_refresh).


%% @doc Updates timeout on no incoming packet
-spec receive_refresh(pid(), pos_integer()) ->
    ok | error.

receive_refresh(Pid, Secs) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    case catch gen_server:call(Pid, {receive_refresh, Time}) of
        ok -> ok;
        _ -> error
    end.


%% @private Gets the transport record (and extends the timeout)
-spec get_transport(pid()) ->
    {ok, nksip:transport()} | error.

get_transport(Pid) ->
    case is_process_alive(Pid) of
        true ->
            case catch gen_server:call(Pid, get_transport) of
                {ok, Transp} -> {ok, Transp};
                _ -> error
            end;
        false ->
            error 
    end.


%% @private 
-spec parse(pid(), binary()) ->
    ok.

incoming(Pid, Packet) when is_binary(Packet) ->
    gen_server:cast(Pid, {incoming, Packet}).



%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link(AppId, Transport, Socket, Timeout) -> 
    gen_server:start_link(?MODULE, [AppId, Transport, Socket, Timeout], []).

-record(state, {
    app_id :: nksip:app_id(),
    proto :: nksip:protocol(),
    transport :: nksip_transport:transport(),
    socket :: port() | ssl:sslsocket(),
    timeout :: non_neg_integer(),
    nat_ip :: inet:ip_address(),
    nat_port :: inet:port_number(),
    in_refresh :: boolean(),
    refresh_timer :: reference(),
    refresh_time :: pos_integer(),
    refresh_notify = [] :: [from()],
    buffer = <<>> :: binary()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transport, Socket, Timeout]) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    nksip_proc:put({nksip_connection, {AppId, Proto, Ip, Port}}, Transport), 
    nksip_proc:put(nksip_transports, {AppId, Transport}),
    ?notice(AppId, "created ~p connection ~p (~p) ~p", 
            [Proto, {Ip, Port}, self(), Timeout]),
    State = #state{
        app_id = AppId,
        proto = Proto,
        transport = Transport, 
        socket = Socket, 
        timeout = Timeout,
        in_refresh = false,
        buffer = <<>>
    },
    {ok, State, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Packet}, From, State) ->
    Reply = do_send(Packet, State),
    gen_server:reply(From, Reply),
    case Reply of
        ok -> do_noreply(State);
        {error, _} -> do_stop(normal, State)
    end;

handle_call({start_refresh, Secs, Ref, Pid}, From, State) ->
    #state{refresh_timer=RefreshTimer, refresh_notify=RefreshNotify} = State,
    nksip_lib:cancel_timer(RefreshTimer),
    gen_server:reply(From, ok),
    RefreshNotify1 = case Ref of
        undefined -> RefreshNotify;
        _ -> [{Ref, Pid}|RefreshNotify]
    end,
    State1 = State#state{refresh_time=1000*Secs, refresh_notify = RefreshNotify1},
    handle_info({timeout, none, refresh}, State1);

handle_call({receive_refresh, Secs}, From, State) ->
    gen_server:reply(From, ok),
    do_noreply(State#state{timeout=1000*Secs});

handle_call(get_transport, From, #state{transport=Transp}=State) ->
    gen_server:reply(From, {ok, Transp}),
    do_noreply(State);

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    do_noreply(State).


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({send, Packet}, State) ->
    case do_send(Packet, State) of
        ok -> do_noreply(State);
        {error, _} -> do_stop(send_error, State)
    end;

handle_cast({incoming, Packet}, State) ->
    parse(Packet, State);

handle_cast({stun, {ok, StunIp, StunPort}}, State) ->
    #state{
        nat_ip = NatIp, 
        nat_port = NatPort, 
        refresh_time = RefreshTime,
        refresh_notify = RefreshNotify
    } = State,
    case 
        {NatIp, NatPort} == {undefined, undefined} orelse
        {NatIp, NatPort} == {StunIp, StunPort}
    of
        true ->
            lists:foreach(fun({Ref, Pid}) -> Pid ! Ref end, RefreshNotify),
            State1 = State#state{
                nat_ip = StunIp,
                nat_port = StunPort,
                refresh_timer = erlang:start_timer(RefreshTime, self(), refresh),
                refresh_notify = []
            },
            do_noreply(State1);
        false ->
            do_stop(stun_changed, State)
    end;

handle_cast({stun, error}, State) ->
    do_stop(stun_error, State);

handle_cast(stop_refresh, #state{refresh_timer=RefreshTimer}=State) ->
    nksip_lib:cancel_timer(RefreshTimer),
    State1 = State#state{
        in_refresh = false, 
        refresh_timer = undefined, 
        refresh_time = undefined
    },
    do_noreply(State1);

handle_cast({stop, Reason}, State) ->
    do_stop(Reason, State);

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    do_noreply(State).


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

%% @private
handle_info({tcp, Socket, Packet}, #state{socket=Socket}=State) ->
    inet:setopts(Socket, [{active, once}]),
    parse(Packet, State);

handle_info({ssl, Socket, Packet}, #state{socket=Socket}=State) ->
    ssl:setopts(Socket, [{active, once}]),
    parse(Packet, State);

handle_info({tcp_closed, Socket}, #state{socket=Socket}=State) ->
    do_stop(normal, State);

handle_info({ssl_closed, Socket}, #state{socket=Socket}=State) ->
    do_stop(normal, State);

% Received from Ranch when the listener is ready
handle_info({shoot, _ListenerPid}, #state{proto=tcp, socket=Socket}=State) ->
    inet:setopts(Socket, [{active, once}]),
    do_noreply(State);

handle_info({shoot, _ListenerPid}, #state{proto=tls, socket=Socket}=State) ->
    ssl:setopts(Socket, [{active, once}]),
    do_noreply(State);

handle_info({timeout, _, refresh}, #state{proto=udp}=State) ->
    #state{app_id=AppId, transport=Transp} = State,
    #transport{remote_ip=Ip, remote_port=Port} = Transp,
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, udp, Class) of
        [{_, Pid}|_] -> 
            nksip_transport_udp:send_stun_async(Pid, Ip, Port),
            do_noreply(State#state{refresh_timer=undefined});
        [] ->
            do_stop(no_listening_transport, State)
    end;

handle_info({timeout, _, refresh}, State) ->
    lager:notice("Sending refresh"),
    case do_send(<<"\r\n\r\n">>, State) of
        ok -> do_noreply(State#state{in_refresh=true, refresh_timer=undefined});
        {error, _} -> do_stop(send_error, State)
    end;

handle_info({timeout, _, refreshed}, State) ->
    do_stop(refreshed_timeout, State);
    
handle_info(timeout, State) ->
    do_stop(process_timeout, State);

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    do_noreply(State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, #state{app_id=AppId, socket=Socket, transport=Transp}) ->  
    #transport{proto=Proto, sctp_id=AssocId} = Transp,
    ?notice(AppId, "~p connection process stopped (~p)", [Proto, self()]),
    case Proto of
        udp -> ok;
        tcp -> gen_tcp:close(Socket);
        tls -> ssl:close(Socket);
        sctp -> gen_sctp:eof(Socket, #sctp_assoc_change{assoc_id=AssocId});
        _ -> ok
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
do_send(Packet, State) ->
    #state{app_id=AppId, socket=Socket, transport=Transp} = State,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port, sctp_id=AssocId} = Transp,
    case
        case Proto of
            udp -> gen_udp:send(Socket, Ip, Port, Packet);
            tcp -> gen_tcp:send(Socket, Packet);
            tls -> ssl:send(Socket, Packet);
            sctp -> gen_sctp:send(Socket, AssocId, 0, Packet)
        end
    of
        ok -> 
            ok;
        {error, Error} ->
            ?notice(AppId, "could not send ~p message: ~p", [Proto, Error]),
            {error, Error}
    end.


%% @private
parse(<<>>, State) ->
    do_noreply(State);

parse(Packet, State) ->
    #state{
        app_id = AppId,
        proto = Proto,
        transport = Transp,
        buffer = Buff, 
        in_refresh = InRefresh, 
        refresh_time = RefreshTime,
        refresh_notify = RefreshNotify
    } = State,
    case 
        (Proto==tcp orelse Proto==tls) andalso
        byte_size(Packet) + byte_size(Buff) > ?MAX_BUFFER 
    of
        true ->
            ?warning(AppId, "dropping TCP/TLS closing because of max_buffer", []),
            do_stop(max_buffer, State);
        false ->
            case do_parse(AppId, Transp, <<Buff/binary, Packet/binary>>) of
                {ok, Rest} ->
                    parse(Rest, State);
                {more, Rest} when Proto==udp; Proto==sctp ->
                    ?notice(AppId, "ignoring data after ~p msg: ~p", [Proto, Rest]),
                    do_noreply(State);
                {more, Rest} ->
                    do_noreply(State#state{buffer=Rest});
                {rnrn, Rest} when Proto==tcp; Proto==tls; Proto==sctp ->
                    case do_send(<<"\r\n">>, State) of
                        ok -> parse(Rest, State);
                        {error, _} -> stop(send_error, State)
                    end;
                {rnrn, Rest} ->
                    parse(Rest, State);
                {rn, Rest} when Proto==tcp; Proto==tls; Proto==sctp ->
                    lists:foreach(fun({Ref, Pid}) -> Pid ! Ref end, RefreshNotify),
                    RefreshTimer = case InRefresh of
                        true -> erlang:start_timer(RefreshTime, self(), refresh);
                        false -> undefined
                    end,
                    State1 = State#state{
                        in_refresh = false, 
                        refresh_timer = RefreshTimer,
                        refresh_notify = [],
                        buffer = Rest
                    },
                    parse(Rest, State1);
                {rn, Rest} ->
                    parse(Rest, State);
                error -> 
                    stop(parse_error, State)
            end
    end.


%% @private
do_parse(AppId, Transp, Packet) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
    case nksip_parse:packet(AppId, Transp, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=_Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transp, Packet),
            nksip_trace:insert(AppId, CallId, {Proto, Ip, Port, Packet}),
            case nksip_call_router:incoming_sync(RawMsg) of
                ok -> {ok, More};
                {error, _} -> error
            end;
        {rnrn, More} ->
            {rnrn, More};
        {rn, More} ->
            {rn, More};
        {more, More} -> 
            {ok, More};
        {error, Error} ->
            ?notice(AppId, "error processing ~p request: ~p", [Proto, Error]),
            error
    end.
                    



% do_parse(Packet, #state{app_id=AppId, transport=Transport}=State) ->
%     #transport{proto=Proto, remote_ip=Ip, remote_port=Port}=Transport,
%     case nksip_parse:packet(AppId, Transport, Packet) of
%         {ok, #raw_sipmsg{call_id=CallId, class=_Class}=RawMsg, More} -> 
%             nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport, Packet),
%             nksip_trace:insert(AppId, CallId, {Proto, Ip, Port, Packet}),
%             case nksip_call_router:incoming_sync(RawMsg) of
%                 ok ->
%                     case More of
%                         <<>> -> 
%                             {ok, <<>>};
%                         _ when Proto==udp; Proto==sctp ->
%                             ?notice(AppId, "ignoring data after ~p msg: ~p", 
%                                    [Proto, More]),
%                             {ok, <<>>};
%                         _ ->
%                             do_parse(More, State)
%                     end;
%                 {error, _} ->
%                     error
%             end;
%         {rnrn, More} when Proto==tcp; Proto==tls; Proto==sctp -> 
%             case do_send(<<"\r\n">>, State) of
%                 ok -> do_parse(More, State);
%                 {error, _} -> error
%             end;
%         {rnrn, More} ->
%             do_parse(More, State);
%         {rn, More} when Proto==tcp; Proto==tls; Proto==sctp ->
%             {rn, More};
%         {rn, More} when Proto==udp; Proto==sctp ->
%             ?notice(AppId, "ignoring data after ~p msg: ~p", [Proto, More]),
%             {ok, <<>>};
        

%         {more, More} when Proto==udp; Proto==sctp ->
%             ?notice(AppId, "ignoring data after ~p msg: ~p", [Proto, More]),
%             {ok, <<>>};
%         {more, More} -> 
%             {ok, More};
%         {error, Error} ->
%             ?notice(AppId, "error processing ~p request: ~p", [Proto, Error]),
%             error
%     end.


%% @private
do_noreply(#state{in_refresh=true}=State) -> 
    {noreply, State, 10000};

do_noreply(#state{timeout=Timeout}=State) -> 
    {noreply, State, Timeout}.


%% @private
do_stop(Reason, #state{app_id=AppId, proto=Proto}=State) ->
    case Reason of
        normal -> ok;
        _ -> ?notice(AppId, "~p connection stop: ~p", [Proto, Reason])
    end,
    {stop, normal, State}.








