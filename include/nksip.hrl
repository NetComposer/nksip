%%
%% nksip.hrl: Common types and records definition
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-ifndef(NKSIP_HRL_).
-define(NKSIP_HRL_, 1).

-define(PACKAGE_CLASS_SIP, <<"Sip">>).


%% ===================================================================
%% Defines
%% ===================================================================

-define(VERSION, "0.5.0").

%%-define(
%%    DO_LOG(Level, Srv, CallId, Text, Opts),
%%    case CallId of
%%        <<>> ->
%%            lager:Level([{app, Srv}], "~p "++Text, [Srv|Opts]);
%%        _ ->
%%            lager:Level([{app, Srv}, {call_id, CallId}], "~p (~s) "++Text, [Srv, CallId|Opts])
%%    end).
%%
%%-define(DO_DEBUG(SrvId, CallId, Level, Text, List),
%%    case element(1, SrvId:config_nksip()) of
%%        false -> ok;
%%        _ -> SrvId:nks_sip_debug(SrvId, CallId, {Level, Text, List})
%%    end).
%%
%%
%%-define(debug(SrvId, CallId, Text, List),
%%    ?DO_DEBUG(SrvId, CallId, debug, Text, List),
%%    case SrvId:log_level() >= 8 of
%%        true -> ?DO_LOG(debug, SrvId:name(), CallId, Text, List);
%%        false -> ok
%%    end).
%%
%%-define(info(SrvId, CallId, Text, List),
%%    ?DO_DEBUG(SrvId, CallId, info, Text, List),
%%    case SrvId:log_level() >= 7 of
%%        true -> ?DO_LOG(info, SrvId:name(), CallId, Text, List);
%%        false -> ok
%%    end).
%%
%%-define(notice(SrvId, CallId, Text, List),
%%    ?DO_DEBUG(SrvId, CallId, notice, Text, List),
%%    case SrvId:log_level() >= 6 of
%%        true -> ?DO_LOG(notice, SrvId:name(), CallId, Text, List);
%%        false -> ok
%%    end).
%%
%%-define(warning(SrvId, CallId, Text, List),
%%    ?DO_DEBUG(SrvId, CallId, warning, Text, List),
%%    case SrvId:log_level() >= 5 of
%%        true -> ?DO_LOG(warning, SrvId:name(), CallId, Text, List);
%%        false -> ok
%%    end).
%%
%%-define(error(SrvId, CallId, Text, List),
%%    ?DO_DEBUG(SrvId, CallId, error, Text, List),
%%    case SrvId:log_level() >= 4 of
%%        true -> ?DO_LOG(error, SrvId:name(), CallId, Text, List);
%%        false -> ok
%%    end).




-define(SIP_DEBUG(Txt, Args),
    case erlang:get(nksip_debug) of
        true -> ?SIP_LOG(debug, Txt, Args);
        _ -> ok
    end).


-define(SIP_DEBUG(Txt, Args, State),
    case erlang:get(nksip_debug) of
        true -> ?SIP_LOG(debug, Txt, Args, State);
        _ -> ok
    end).


-define(SIP_LOG(Type, Txt, Args),
    lager:Type("NkSIP " ++ Txt, Args)).


-define(SIP_LOG(Type, Txt, Args, SipMsg),
    lager:Type(
        [
            {srv, SipMsg#sipmsg.srv},
            {package, SipMsg#sipmsg.srv_id},
            {call_id, SipMsg#sipmsg.call_id}
        ],
        "NKSIP (~s/~s/~s) " ++ Txt,
        [
            SipMsg#sipmsg.srv,
            SipMsg#sipmsg.srv_id,
            SipMsg#sipmsg.call_id
        ]
    )).



-include_lib("kernel/include/inet_sctp.hrl").



%% ===================================================================
%% Records
%% ===================================================================



-record(sipmsg, {
    id :: nksip_sipmsg:id(),
    class :: {req, nksip:method()} | {resp, nksip:sip_code(), binary()},
    srv_id :: nkserver:id(),
    dialog_id :: nksip_dialog_lib:id() | undefined,
    ruri :: nksip:uri() | undefined,
    vias = [] :: [nksip:via()],
    from :: {nksip:uri(), FromTag::binary()} | undefined,
    to :: {nksip:uri(), ToTag::binary()} | undefined,
    call_id :: nksip:call_id(),
    cseq :: {nksip:cseq(), nksip:method()} | undefined,
    forwards :: non_neg_integer() | undefined,
    routes = [] :: [nksip:uri()],
    contacts = [] :: [nksip:uri()],
    content_type :: nksip:token() | undefined,
    require = [] :: [binary()],
    supported = [] :: [binary()],
    expires :: non_neg_integer() | undefined,
    event :: nksip:token() | undefined,
    headers = [] :: [nksip:header()],
    body = <<>> :: nksip:body(),
    to_tag_candidate = <<>> :: nksip:tag(),
    nkport :: nkpacket:nkport() | undefined,
    start :: nklib_util:l_timestamp(),
    meta = [] :: nksip:optslist()   % No current use
}).


-record(reqreply, {
    code = 200 :: nksip:sip_code(),
    headers = [] :: [nksip:header()],
    body = <<>> :: nksip:body(),
    opts = [] :: nksip:optslist()
}).

-record(via, {
    transp = udp :: nkpacket:transport() | binary(),
    domain = <<"invalid.invalid">> :: binary(),
    port = 0 :: inet:port_number(),
    opts = [] :: nksip:optslist()
}).


-record(invite, {
    status :: nksip_dialog:invite_status(),
    answered :: nklib_util:timestamp() | undefined,
    class :: uac | uas | proxy | undefined,
    request :: nksip:request() | undefined,
    response :: nksip:response() | undefined,
    ack :: nksip:request() | undefined,
    local_sdp :: nksip_sdp:sdp() | undefined,
    remote_sdp :: nksip_sdp:sdp() | undefined,
    media_started :: boolean() | undefined,
    sdp_offer :: nksip_call_dialog:sdp_offer(),
    sdp_answer :: nksip_call_dialog:sdp_offer(),
    timeout_timer :: reference() | undefined,
    retrans_timer :: reference() | undefined,
    next_retrans :: integer() | undefined
}).


-record(subscription, {
    id :: nksip_subscription_lib:id(),
    event :: nksip:token(),
    expires :: pos_integer() | undefined,
    status :: nksip_subscription:status(),
    class :: uac | uas,
    answered :: nklib_util:timestamp() | undefined,
    timer_n :: reference() | undefined,
    timer_expire :: reference() | undefined,
    timer_middle :: reference() | undefined,
    last_notify_cseq :: nksip:cseq() | undefined
}).


%% Meta current uses:
%% - {nksip_min_se, MinSE}

-record(dialog, {
    id :: nksip_dialog_lib:id(),
    srv_id :: nkserver:id(),
    call_id :: nksip:call_id(),
    created :: nklib_util:timestamp(),
    updated :: nklib_util:timestamp(),
    local_seq :: 0 | nksip:cseq() | undefined,
    remote_seq :: 0 | nksip:cseq() | undefined,
    local_uri :: nksip:uri() | undefined,
    remote_uri :: nksip:uri() | undefined,
    local_target :: nksip:uri(),        % Only for use in proxy
    remote_target :: nksip:uri(),
    route_set :: [nksip:uri()],
    blocked_route_set :: boolean(),
    early :: boolean(),
    secure :: boolean(),
    caller_tag :: nksip:tag(),
    invite :: nksip:invite() | undefined,
    subscriptions = [] :: [#subscription{}],
    supported = [] :: [nksip:token()],
    meta = [] :: nksip:optslist()
}).



-record(sdp_m, {
    media :: binary(),                  % <<"audio">>, ...
    port = 0 :: inet:port_number(),
    nports = 1 :: integer(),
    proto = <<"RTP/AVP">> :: binary(),      
    fmt = [] :: [binary()],             % <<"0">>, <<"101">> ...
    info :: binary() | undefined,
    connect :: nksip_sdp:address() | undefined,
    bandwidth = [] :: [binary()],
    key :: binary() | undefined,
    attributes = [] :: [nksip_sdp:sdp_a()]
}).

-record(sdp, {
    sdp_vsn = <<"0">> :: binary(),
    user = <<"-">> :: binary(),
    id = 0 :: non_neg_integer(), 
    vsn = 0 :: non_neg_integer(), 
    address = {<<"IN">>, <<"IP4">>, <<"0.0.0.0">>} :: nksip_sdp:address(),
    session = <<"nksip">> :: binary(), 
    info :: binary() | undefined,
    uri :: binary() | undefined,
    email :: binary() | undefined,
    phone :: binary() | undefined,
    connect :: nksip_sdp:address() | undefined,
    bandwidth = [] :: [binary()],
    time = [] :: [nksip_sdp:sdp_t()],
    zone :: binary() | undefined,
    key :: binary() | undefined,
    attributes = [] :: [nksip_sdp:sdp_a()],
    medias = [] :: [nksip_sdp:sdp_m()]
}).


-record(candidate, {
    m_id :: binary(),
    m_index :: integer(),
    a_line :: binary(),
    last = false :: boolean()
    % type :: offer | answer
}).

-endif.


%% ===================================================================
%% Macros
%% ===================================================================

% Thks to http://rustyklophaus.com/articles/20110209-BeautifulErlangTiming.html
-ifndef(TIMEON).
-define(TIMEON, 
    erlang:put(debug_timer, [now()|
                                case erlang:get(debug_timer) == undefined of 
                                    true -> []; 
                                    false -> erlang:get(debug_timer) end])).
-define(TIMEOFF(Var), 
    io:format("~s :: ~10.2f ms : ~p~n", [
        string:copies(" ", length(erlang:get(debug_timer))), 
        (timer:now_diff(now(), hd(erlang:get(debug_timer)))/1000), Var
    ]), 
    erlang:put(debug_timer, tl(erlang:get(debug_timer)))).
-endif.

% -ifndef(P).
% -define(P(S,P), io:format(S++"\n", P)).
% -define(P(S), ?P(S, [])).
% -endif.

% -ifndef(I).
% -define(I(S,P), lager:info(S++"\n", P)).
% -define(I(S), ?I(S, [])).
% -endif.

