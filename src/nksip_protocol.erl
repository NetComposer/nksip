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

-export([start_refresh/3, stop_refresh/1, get_refresh/1]).
-export([transports/1, default_port/1, encode/2, naptr/2]).
-export([conn_init/1, conn_parse/3, conn_encode/3, conn_stop/3]).
-export([conn_handle_call/4, conn_handle_cast/3, conn_handle_info/3]).

-type conn_state() :: nkpacket_protocol:conn_state().

-include("nksip.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").


-define(MAX_MSG, 65535).
-define(MAX_UDP, 1500).

%% ===================================================================
%% User
%% ===================================================================


%% @doc Start a time-alive series, with result notify
%% If `Ref' is not `undefined', a message will be sent to self() using `Ref'
%% (self() ! Ref) after the fist successful ping response
-spec start_refresh(pid(), pos_integer(), term()) ->
    ok | error.

start_refresh(Pid, Secs, Ref) when is_integer(Secs), Secs>0 ->
    Opts = #{timeout => 15000},
    case nklib_util:call(Pid, {start_refresh, Secs, Ref, self()}, Opts) of
        ok -> ok;
        _ -> error
    end.

%% @doc Start a time-alive series, with result notify
-spec stop_refresh(pid()) ->
    ok.

stop_refresh(Pid) ->
    gen_server:cast(Pid, stop_refresh).


%% @private
-spec get_refresh(pid()) ->
    {true, integer(), integer()} | false.

get_refresh(Pid) ->
    nklib_util:call(Pid, get_refresh, #{timeout=>15000}).



%% ===================================================================
%% Callbacks
%% ===================================================================

-spec transports(nklib:scheme()) ->
    [nkpacket:transport() | {nkpacket:transport(), nkpacket:transport()}].

transports(sip) -> [udp, tcp, tls, sctp, ws, wss];
transports(sips) -> [tls, wss, {tcp, tls}, {ws, wss}].


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
-spec encode(nksip:request()|nksip:response(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

encode(#sipmsg{srv_id=SrvId}=SipMsg, _NkPort) ->
    Packet = nksip_unparse:packet(SipMsg),
    SrvId:nks_sip_connection_sent(SipMsg, Packet),
    {ok, Packet};

encode(Bin, _NkPort) when is_binary(Bin) ->
    {ok, Bin}.


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
    buffer = <<>> :: binary(),
    rnrn_pattern :: binary:cp(),
    in_refresh = false :: boolean(),
    refresh_time :: pos_integer(),
    refresh_timer :: reference(),
    nat_ip :: inet:ip_address(),
    nat_port :: inet:port_number(),
    refresh_notify = [] :: [{pid(), term()}]
}).




%% Connection callbacks, if implemented, are called during the life cicle of a
%% connection

%% @doc Called when the connection starts
-spec conn_init(nkpacket:nkport()) ->
    {ok, conn_state()} | {stop, term()}.

conn_init(_NkPort) ->
    % lager:warning("CONN INIT ~p: ~p (~p)", [SrvId:name(), P, self()]),
    State = #conn_state{
        rnrn_pattern = binary:compile_pattern(<<"\r\n\r\n">>)
    },
    {ok, State}.


%% @doc This function is called when a new message arrives to the connection
-spec conn_parse(nkpacket:incoming()|close, nkpacket:nkport(), conn_state()) ->
    {ok, conn_state()} | {bridge, nkpacket:nkport()} | 
    {stop, Reason::term(), conn_state()}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({binary, Binary}, NkPort, State) ->
    conn_parse(Binary, NkPort, State);

conn_parse({text, Binary}, NkPort, State) ->
    conn_parse(Binary, NkPort, State);

conn_parse(Binary, NkPort, #conn_state{buffer=Buffer}=State) ->
    Data = case Buffer of
        <<>> -> Binary;
        _ -> <<Buffer/binary, Binary/binary>>
    end,
    case do_parse(Data, NkPort, State) of
        {ok, State1} -> 
            {ok, State1};
        {error, Error} -> 
            {stop, Error, State}
    end.


%% @doc This function is called when a new message must be send to the connection
-spec conn_encode(term(), nkpacket:nkport(), conn_state()) ->
    {ok, nkpacket:outcoming(), conn_state()} | {error, term(), conn_state()} |
    {stop, Reason::term(), conn_state()}.

conn_encode(_Term, _NkPort, ConnState) ->
    {error, not_defined, ConnState}.


%% @doc Called when the connection received a gen_server:call/2,3
-spec conn_handle_call(term(), {pid(), term()}, nkpacket:nkport(), conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_call({start_refresh, Secs, Ref, Pid}, From, NkPort, State) ->
    #conn_state{refresh_timer=RefreshTimer, refresh_notify=RefreshNotify} = State,
    nklib_util:cancel_timer(RefreshTimer),
    gen_server:reply(From, ok),
    RefreshNotify1 = case Ref of
        undefined -> RefreshNotify;
        _ -> [{Ref, Pid}|RefreshNotify]
    end,
    State1 = State#conn_state{refresh_time=1000*Secs, refresh_notify=RefreshNotify1},
    conn_handle_info({timeout, none, refresh}, NkPort, State1);

conn_handle_call(get_refresh, From, _NkPort, State) ->
    #conn_state{
        in_refresh = InRefresh, 
        refresh_timer = RefreshTimer, 
        refresh_time = RefreshTime
    } = State,
    Reply = case InRefresh of
        true -> 
            {true, 0, round(RefreshTime/1000)};
        false when is_reference(RefreshTimer) -> 
            {true, round(erlang:read_timer(RefreshTimer)/1000), round(RefreshTime/1000)};
        false -> 
            false
    end,
    gen_server:reply(From, Reply),
    {ok, State};


conn_handle_call(Msg, _From, _NkPort, State) ->
    lager:error("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection received a gen_server:cast/2
-spec conn_handle_cast(term(), nkpacket:nkport(), conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_cast(stop_refresh, _NkPort, State) ->
    #conn_state{refresh_timer=RefreshTimer} = State,
    nklib_util:cancel_timer(RefreshTimer),
    State1 = State#conn_state{
        in_refresh = false, 
        refresh_time = undefined,
        refresh_timer = undefined
    },
    {ok, State1};

conn_handle_cast(Msg, _NkPort, State) ->
    lager:error("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), conn_state()) ->
    {ok, conn_state()} | {stop, Reason::term(), conn_state()}.

conn_handle_info({timeout, _, refresh}, #nkport{transp=udp}=NkPort, State) ->
    #nkport{srv_id={nksip, SrvId}} = NkPort,
    {ok, {_, udp, Ip, Port}} = nkpacket:get_remote(NkPort),
    case get_listening(NkPort) of
        {ok, Pid} ->
            ?debug(SrvId, <<>>, "transport sending STUN", []),
            nkpacket_transport_udp:send_stun_async(Pid, Ip, Port),
            {ok, State#conn_state{refresh_timer=undefined}};
        false ->
            {stop, no_listening_transport, State}
    end;

conn_handle_info({timeout, _, refresh}, #nkport{srv_id={nksip, SrvId}}=NkPort, State) ->
    ?debug(SrvId, <<>>, "transport sending refresh", []),
    case do_send(<<"\r\n\r\n">>, NkPort) of
        ok -> 
            {ok, State#conn_state{in_refresh=true, refresh_timer=undefined}};
        {error, _} -> 
            {stop, send_error, State}
    end;

conn_handle_info({stun, {ok, StunIp, StunPort}}, NkPort, State) ->
    #nkport{srv_id={nksip, SrvId}} = NkPort,
    #conn_state{
        nat_ip = NatIp, 
        nat_port = NatPort, 
        refresh_time = RefreshTime,
        refresh_notify = RefreshNotify
    } = State,
    ?debug(SrvId, <<>>, "transport received STUN", []),
    case 
        {NatIp, NatPort} == {undefined, undefined} orelse
        {NatIp, NatPort} == {StunIp, StunPort}
    of
        true ->
            case RefreshTime of
                undefined ->
                    lager:warning("STUN UNDEFINED: ~p", [self()]);
                _ ->
                    ok
            end,


            lists:foreach(fun({Ref, Pid}) -> Pid ! Ref end, RefreshNotify),
            State1 = State#conn_state{
                nat_ip = StunIp,
                nat_port = StunPort,
                refresh_timer = erlang:start_timer(RefreshTime, self(), refresh),
                refresh_notify = []
            },
            {ok, State1};
        false ->
            {stop, stun_changed, State}
    end;

conn_handle_info({stun, error}, _NkPort, State) ->
    {stop, stun_error, State};

conn_handle_info(Msg, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Msg]),
    {ok, State}.


%% @doc Called when the connection stops
-spec conn_stop(Reason::term(), nkpacket:nkport(), conn_state()) ->
    ok.

conn_stop(_Reason, _NkPort, _State) ->
    ok.







%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec do_parse(binary(), nkpacket:nkport(), #conn_state{}) ->
    {ok, #conn_state{}} | {error, term()}.

do_parse(<<>>, _NkPort, State) ->
    {ok, State#conn_state{buffer = <<>>}};

%% For TCP and UDP, we send a \r\n\r\n, remote must reply with \r\n
do_parse(<<"\r\n\r\n", Rest/binary>>, 
         #nkport{srv_id={nksip, SrvId}, transp=Transp}=NkPort, State) 
         when Transp==tcp; Transp==udp; Transp==tls; Transp==sctp ->
    ?debug(SrvId, <<>>, "transport responding to refresh", []),
    case do_send(<<"\r\n">>, NkPort) of
        ok -> 
            do_parse(Rest, NkPort, State);
        {error, _} -> 
            {error, send_error}
    end;

do_parse(<<"\r\n">>, #nkport{transp=udp}, State) ->
    {ok, State};

do_parse(<<"\r\n", Rest/binary>>, #nkport{transp=Transp}=NkPort, State) 
        when Transp==tcp; Transp==tls; Transp==sctp ->
    #nkport{srv_id={nksip, SrvId}} = NkPort,
    #conn_state{
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
    State1 = State#conn_state{
        in_refresh = false, 
        refresh_timer = RefreshTimer,
        refresh_notify = [],
        buffer = Rest
    },
    do_parse(Rest, NkPort, State1);

do_parse(Data, #nkport{srv_id={nksip, SrvId}, transp=Transp}, _State) 
        when (Transp==tcp orelse Transp==tls) andalso byte_size(Data) > ?MAX_MSG ->
    ?warning(SrvId, <<>>, "dropping TCP/TLS closing because of max_buffer", []),
    {error, msg_too_large};

do_parse(Data, #nkport{srv_id={nksip, SrvId}, transp=Transp}=NkPort, State) ->
    #conn_state{rnrn_pattern = RNRN} = State,
    case binary:match(Data, RNRN) of
        nomatch when Transp==tcp; Transp==tls ->
            {ok, State#conn_state{buffer=Data}};
        nomatch ->
            ?notice(SrvId, <<>>, "ignoring partial ~p msg: ~p", [Transp, Data]),
            {error, parse_error};
        {Pos, 4} ->
            do_parse(SrvId, NkPort, Data, Pos+4, State)
    end.


%% @private
-spec do_parse(nksip:srv_id(), nkpacket:nkport(), binary(), integer(), #conn_state{}) ->
    {ok, #conn_state{}} | {error, term()}.

do_parse(SrvId, #nkport{transp=Transp}=NkPort, Data, Pos, State) ->
    case extract(Transp, Data, Pos) of
        {ok, CallId, Msg, Rest} ->
            SrvId:nks_sip_connection_recv(SrvId, CallId, NkPort, Msg),
            case nksip_router:incoming_sync(SrvId, CallId, NkPort, Msg) of
                ok -> 
                    do_parse(Rest, NkPort, State);
                {error, Error} -> 
                    ?notice(SrvId, <<>>, 
                            "error processing ~p request: ~p", [Transp, Error]),
                    {error, Error}
            end;
        partial when Transp==tcp; Transp==tls ->
            {ok, State#conn_state{buffer=Data}};
        partial ->
            ?notice(SrvId, <<>>, "ignoring partial msg ~p: ~p", [Transp, Data]),
            {ok, State};
        {error, Error} ->
            reply_error(Data, Error, NkPort, State),
            {error, parse_error}
    end.


%% @private
-spec extract(nkpacket:transport(), binary(), integer()) ->
    {ok, nksip:call_id(), binary(), binary()} | partial | {error, binary()}.

extract(Transp, Data, Pos) ->
    case 
        re:run(Data, nksip_config_cache:re_call_id(), 
               [{capture, all_but_first, binary}])
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
                                BS when BS<MsgSize andalso 
                                        (Transp==tcp orelse Transp==tls) ->
                                    partial;
                                BS when BS<MsgSize ->
                                    {error, <<"Invalid Content-Length">>};
                                _ when Transp==tcp; Transp==tls ->
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
-spec reply_error(binary(), binary(), nkpacket:nkport(), #conn_state{}) ->
    ok.

reply_error(Data, Msg, #nkport{srv_id={nksip, SrvId}}=NkPort, _State) ->
    case nksip_parse_sipmsg:parse(Data) of
        {ok, {req, _, _}, Headers, _} ->
            Resp = nksip_unparse:response(Headers, 400, Msg),
            do_send(Resp, NkPort);
        O ->
            ?notice(SrvId, <<>>, "error parsing request: ~s", [O])
    end.



%% @private
-spec do_send(binary(), nkpacket:nkport()) ->
    ok | {error, term()}.

do_send(Packet, NkPort) ->
    nkpacket_connection_lib:raw_send(NkPort, Packet).


%% @private
get_listening(#nkport{srv_id=TSrvId, transp=Transp, local_ip=Ip}) ->
    case nkpacket:get_listening(nksip_protocol, Transp, #{srv_id=>TSrvId, ip=>Ip}) of
        [#nkport{pid=Pid}|_] -> {ok, Pid};
        [] -> false
    end.
