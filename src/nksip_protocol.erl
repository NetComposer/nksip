%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Protocol behaviour
-module(nksip_protocol).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).

-export([transports/1, default_port/1, encode/2, naptr/2]).
-export([conn_init/1, conn_parse/2, conn_encode/2, conn_bridge/3, conn_handle_call/3,
         conn_handle_cast/2, conn_handle_info/2, conn_stop/2]).
-export([listen_init/1, listen_parse/4, listen_handle_call/3,
         listen_handle_cast/2, listen_handle_info/2, listen_stop/2]).


-type conn_state() :: nkpacket_protocol:conn_state().
-type listen_state() :: nkpacket_protocol:listen_state().



%% ===================================================================
%% Callbacks
%% ===================================================================

-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(sip) -> [udp, tcp, tls, sctp, ws, wss];
transports(sips) -> [tls, wss].


-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(udp) -> 5060;
default_port(tcp) -> 5060;
default_port(tls) -> 5061;
default_port(sctp) -> 5060;
default_port(ws) -> 80;
default_port(wss) -> 443;
default_port(_) -> invalid.


%% @doc Implement this function to provide a 'quick' encode function, 
%% in case you don't need the connection state to perform the encode.
%% Do not implement it or return 'continue' to call conn_encode/2
-spec encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

encode(_, _) ->
    continue.


%% @doc Implement this function to allow NAPTR DNS queries.
-spec naptr(nklib:scheme(), string()) ->
    {ok, nkpacket:transport()} | invalid.

naptr(sip, "sips+d2t") -> {ok, tls};
naptr(sip, "sip+d2u") -> {ok, udp};
naptr(sip, "sip+d2t") -> {ok, tcp};
naptr(sip, "sip+d2s") -> {ok, sctp};
naptr(sip, "sips+d2w") -> {ok, wss};
naptr(sip, "sip+d2w") -> {ok, ws};
naptr(sips, "sips+d2t") -> {ok, tls};
naptr(sips, "sips+d2w") -> {ok, wss};
naptr(_, _) -> invalid.



%% ===================================================================
%% Connection callbacks
%% ===================================================================

-record(conn_state, {
    % srv_id :: nkservice:id(),
    % proto :: nksip:protocol(),
    % transport :: nkpacket:nkport(),
    % socket :: port() | ssl:sslsocket(),
    % timeout :: non_neg_integer(),
    % nat_ip :: inet:ip_address(),
    % nat_port :: inet:port_number(),
    % in_refresh :: boolean(),
    % refresh_timer :: reference(),
    % refresh_time :: pos_integer(),
    % refresh_notify = [] :: [{pid(), term()}],
    buffer = <<>> :: binary(),
    rnrn_pattern :: binary:cp(),
    % ws_frag = #message{},            % store previous ws fragmented message
    % ws_pid :: pid()                  % ws protocol's pid
}).




%% Connection callbacks, if implemented, are called during the life cicle of a
%% connection

%% @doc Called when the connection starts
-spec conn_init(nkpacket:nkport()) ->
    {ok, conn_state()} | {stop, term()}.

conn_init(_) ->
    State = #conn_state{
        rnrn_pattern = binary:compile_pattern(<<"\r\n\r\n">>)
    },
    {ok, State}.


%% @doc This function is called when a new message arrives to the connection
-spec conn_parse(nkpacket:incoming(), conn_state()) ->
    {ok, conn_state()} | {bridge, nkpacket:nkport()} | 
    {stop, Reason::term(), conn_state()}.

conn_parse(_Msg, #conn_state{}=ConnState) ->




    {ok, ConnState}.





%% @doc This function is called when a new message must be send to the connection
-spec conn_encode(term(), conn_state()) ->
    {ok, nkpacket:outcoming(), conn_state()} | {error, term(), conn_state()} |
    {stop, Reason::term(), conn_state()}.

conn_encode(_Term, ConnState) ->
    {error, not_defined, ConnState}.


%% @doc This function is called on incoming data for bridged connections
-spec conn_bridge(nkpacket:incoming(), up|down, conn_state()) ->
    {ok, nkpacket:incoming(), conn_state()} | {skip, conn_state()} | 
    {stop, term(), conn_state()}.

conn_bridge(Data, _Type, ConnState) ->
    {ok, Data, ConnState}.


%% @doc Called when the connection received a gen_server:call/2,3
-spec conn_handle_call(term(), {pid(), term()}, conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_call(_Msg, _From, ListenState) ->
    {stop, not_defined, ListenState}.


%% @doc Called when the connection received a gen_server:cast/2
-spec conn_handle_cast(term(), conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_cast(_Msg, ListenState) ->
    {stop, not_defined, ListenState}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_info(_Msg, ListenState) ->
    {stop, not_defined, ListenState}.

%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), conn_state()) ->
    ok.

conn_stop(_Reason, _State) ->
    ok.





%% ===================================================================
%% Connection callbacks
%% ===================================================================


parse(Binary, #conn_state{buffer=Buffer}=State) ->
    Data = case Buffer of
        <<>> -> Binary;
        _ -> <<Buffer/binary, Binary/binary>>
    end,
    case do_parse(Data, State) of
        {ok, State1} -> 
            {ok, State1};
        {error, Error} -> 
            {stop, Error, State)
    end.


%% @private
-spec do_parse(binary(), #state{}) ->
    {ok, #state{}} | {error, term()}.

do_parse(<<>>, State) ->
    {ok, State#state{buffer = <<>>}};

%% For TCP and UDP, we send a \r\n\r\n, remote must reply with \r\n
do_parse(<<"\r\n\r\n", Rest/binary>>, #state{srv_id=SrvId, proto=Proto}=State) 
        when Proto==tcp; Proto==udp; Proto==tls; Proto==sctp ->
    ?debug(SrvId, <<>>, "transport responding to refresh", []),
    case do_send(<<"\r\n">>, State) of
        ok -> do_parse(Rest, State);
        {error, _} -> {error, send_error}
    end;

do_parse(<<"\r\n">>, #state{proto=udp}=State) ->
    {ok, State};

do_parse(<<"\r\n", Rest/binary>>, #state{proto=Proto}=State) 
        when Proto==tcp; Proto==tls; Proto==sctp ->
    #state{
        srv_id = SrvId,
        refresh_notify = RefreshNotify, 
        refresh_time = RefreshTime,
        in_refresh = InRefresh
    } = State,
    lists:foreach(fun({Ref, Pid}) -> Pid ! Ref end, RefreshNotify),
    RefreshTimer = case InRefresh of
        true -> 
            ?debug(SrvId, <<>>, "transport received refresh, next in ~p secs", 
                        [round(RefreshTime/1000)]),
            erlang:start_timer(RefreshTime, self(), refresh);
        false -> 
            undefined
    end,
    State1 = State#state{
        in_refresh = false, 
        refresh_timer = RefreshTimer,
        refresh_notify = [],
        buffer = Rest
    },
    do_parse(Rest, State1);

do_parse(Data, #state{srv_id=SrvId, proto=Proto})
        when (Proto==tcp orelse Proto==tls) andalso byte_size(Data) > ?MAX_MSG ->
    ?warning(SrvId, <<>>, "dropping TCP/TLS closing because of max_buffer", []),
    {error, msg_too_large};

do_parse(Data, State) ->
    #state{
        srv_id = SrvId,
        proto = Proto,
        transport = Transp,
        rnrn_pattern = RNRN
    } = State,
    case binary:match(Data, RNRN) of
        nomatch when Proto==tcp; Proto==tls ->
            {ok, State#state{buffer=Data}};
        nomatch ->
            ?notice(SrvId, <<>>, "ignoring partial ~p msg: ~p", [Proto, Data]),
            {error, parse_error};
        {Pos, 4} ->
            do_parse(SrvId, Transp, Data, Pos+4, State)
    end.


%% @private
-spec do_parse(nkservice:id(), nksip:transport(), binary(), integer(), #state{}) ->
    {ok, #state{}} | {error, term()}.

do_parse(SrvId, Transp, Data, Pos, State) ->
    #transport{proto=Proto} = Transp,
    case extract(Proto, Data, Pos) of
        {ok, CallId, Msg, Rest} ->
            SrvId:nks_sip_connection_recv(SrvId, CallId, Transp, Msg),
            case nksip_router:incoming_sync(SrvId, CallId, Transp, Msg) of
                ok -> 
                    do_parse(Rest, State);
                {error, Error} -> 
                    ?notice(SrvId, <<>>, 
                            "error processing ~p request: ~p", [Proto, Error]),
                    {error, Error}
            end;
        partial when Proto==tcp; Proto==tls ->
            {ok, State#state{buffer=Data}};
        partial ->
            ?notice(SrvId, <<>>, "ignoring partial msg ~p: ~p", [Proto, Data]),
            {ok, State};
        {error, Error} ->
            reply_error(Data, Error, State),
            {error, parse_error}
    end.

%% @private Parse for WS/WSS
-spec parse_ws(binary(), #state{}) ->
    {noreply, #state{}} | {stop, term(), #state{}}.

parse_ws(Packet, #state{srv_id=SrvId, ws_frag=FragMsg}=State) ->
    {Result, State1} = case FragMsg of
        undefined -> 
            {
                wsock_message:decode(Packet, []), 
                State
            };
        _ -> 
            {
                wsock_message:decode(Packet, FragMsg, []), 
                State#state{ws_frag=undefined}
            }
    end,
    case Result of
        Msgs when is_list(Msgs) ->
            case do_parse_ws_messages(Msgs, State1) of
                {ok, State2} -> 
                    do_noreply(State2);
                {error, Error} -> 
                    ?warning(SrvId, <<>>, "websocket parsing error: ~p", [Error]),
                    do_stop(Error, State)
            end;
        {error, Error} ->
            ?notice(SrvId, <<>>, "websocket parsing error: ~p", [Error]),
            do_stop(ws_error, State1)
    end.


%% @private
-spec do_parse_ws_messages([#message{}], #state{}) ->
    {ok, #state{}} | {error, term()}.

do_parse_ws_messages([], State) ->
    {ok, State};
        
do_parse_ws_messages([#message{type=fragmented}=Msg|Rest], State) ->
    do_parse_ws_messages(Rest, State#state{ws_frag=Msg});

do_parse_ws_messages([#message{type=Type, payload=Data}|Rest], State) 
        when Type==text; Type==binary ->
    case do_parse(nklib_util:to_binary(Data), State) of
        {ok, State1} -> 
            do_parse_ws_messages(Rest, State1);
        {error, Error} -> 
            {error, Error}
    end;

do_parse_ws_messages([#message{type=close}|_], _State) ->
    {error, ws_close};

do_parse_ws_messages([#message{type=ping}|Rest], State) ->
    do_parse_ws_messages(Rest, State);

do_parse_ws_messages([#message{type=pong}|Rest], State) ->
    do_parse_ws_messages(Rest, State).


%% @private
do_noreply(#state{in_refresh=true}=State) -> 
    {noreply, State, 10000};

do_noreply(#state{timeout=Timeout}=State) -> 
    {noreply, State, Timeout}.


%% @private
do_stop(Reason, #state{srv_id=SrvId, proto=Proto}=State) ->
    case Reason of
        normal -> ok;
        _ -> ?debug(SrvId, <<>>, "~p connection stop: ~p", [Proto, Reason])
    end,
    {stop, normal, State}.


%% @private
-spec extract(nksip:protocol(), binary(), integer()) ->
    {ok, nksip:call_id(), binary(), binary()} | partial | {error, binary()}.

extract(Proto, Data, Pos) ->
    case 
        re:run(Data, nksip_config_cache:re_call_id(), [{capture, all_but_first, binary}])
    of
        {match, [_, CallId]} ->
            case 
                re:run(Data, nksip_config_cache:re_content_length(), 
                       [{capture, all_but_first, list}])
            of
                {match, [_, CL0]} ->
                    case catch list_to_integer(CL0) of
                        CL when is_integer(CL), CL>=0 ->
                            MsgSize = Pos+CL,
                            case byte_size(Data) of
                                MsgSize ->
                                    {ok, CallId, Data, <<>>};
                                BS when BS<MsgSize andalso (Proto==tcp orelse Proto==tls) ->
                                    partial;
                                BS when BS<MsgSize ->
                                    {error, <<"Invalid Content-Length">>};
                                _ when Proto==tcp; Proto==tls ->
                                    {Msg, Rest} = split_binary(Data, MsgSize),
                                    {ok, CallId, Msg, Rest};
                                _ ->
                                    {error, <<"Invalid Content-Length">>}
                            end;
                        _ ->
                            {error, <<"Invalid Content-Length">>}
                    end;
                _ ->
                    {error, <<"Invalid Content-Length">>}
            end;
        _ ->
            {error, <<"Invalid Call-ID">>}
    end.


%% @private
-spec reply_error(binary(), binary(), #state{}) ->
    ok.

reply_error(Data, Msg, #state{srv_id=SrvId}=State) ->
    case nksip_parse_sipmsg:parse(Data) of
        {ok, {req, _, _}, Headers, _} ->
            Resp = nksip_unparse:response(Headers, 400, Msg),
            do_send(Resp, State);
        O ->
            ?notice(SrvId, <<>>, "error parsing request: ~s", [O])
    end.




























