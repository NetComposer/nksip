%% -------------------------------------------------------------------
%%
%% nksip.hrl: Common types and records definition
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

-ifndef(NKSIP_HRL_).
-define(NKSIP_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================

-define(VERSION, "0.1.0").
-define(SUPPORTED, <<>>).
-define(ACCEPT, <<"application/sdp">>).
-define(ALLOW, <<"INVITE, ACK, CANCEL, BYE, OPTIONS">>).
-define(ALLOW_DIALOG, <<"INVITE, ACK, CANCEL, BYE, OPTIONS">>).

-define(MSG_PROCESSORS, 8).
-define(SRV_TIMEOUT, 30000).


-define(debug(AppId, Txt, Opts), 
        lager:debug([{core, AppId}], "SipApp ~p "++Txt, [AppId|Opts])).
-define(debug(AppId, CallId, Txt, Opts), 
        nksip_trace:insert(AppId, CallId, {debug, Txt, Opts}),
        lager:debug([{core, AppId}, {call_id, CallId}],
                     "SipApp ~p (~s) "++Txt, [AppId, CallId|Opts])).

-define(info(AppId, Txt, Opts), 
        lager:info([{core, AppId}], "SipApp ~p "++Txt, [AppId|Opts])).
-define(info(AppId, CallId, Txt, Opts), 
        nksip_trace:insert(AppId, CallId, {info, Txt, Opts}),
        lager:info([{core, AppId}, {call_id, CallId}],
         "SipApp ~p (~s) "++Txt, [AppId, CallId|Opts])).

-define(notice(AppId, Txt, Opts), 
        lager:notice([{core, AppId}], "SipApp ~p "++Txt, [AppId|Opts])).
-define(notice(AppId, CallId, Txt, Opts), 
        nksip_trace:insert(AppId, CallId, {notice, Txt, Opts}),
        lager:notice([{core, AppId}, {call_id, CallId}],
         "SipApp ~p (~s) "++Txt, [AppId, CallId|Opts])).

-define(warning(AppId, Txt, Opts), 
        lager:warning([{core, AppId}], "SipApp ~p "++Txt, [AppId|Opts])).
-define(warning(AppId, CallId, Txt, Opts), 
        nksip_trace:insert(AppId, CallId, {warning, Txt, Opts}),
        lager:warning([{core, AppId}, {call_id, CallId}],
         "SipApp ~p (~s) "++Txt, [AppId, CallId|Opts])).

-define(error(AppId, Txt, Opts), 
        lager:error([{core, AppId}], "SipApp ~p "++Txt, [AppId|Opts])).
-define(error(AppId, CallId, Txt, Opts), 
        nksip_trace:insert(AppId, CallId, {error, Txt, Opts}),
        lager:error([{core, AppId}, {call_id, CallId}],
         "SipApp ~p (~s) "++Txt, [AppId, CallId|Opts])).


-include_lib("ssl/src/ssl_internal.hrl"). 


%% ===================================================================
%% Types
%% ===================================================================

-type gen_server_time() :: 
        non_neg_integer() | hibernate.

-type gen_server_init(State) ::
        {ok, State} | {ok, State, gen_server_time()} | ignore.

-type gen_server_cast(State) :: 
        {noreply, State} | {noreply, State, gen_server_time()} |
        {stop, term(), State}.

-type gen_server_info(State) :: 
        gen_server_cast(State).

-type gen_server_call(State) :: 
        {reply, term(), State} | {reply, term(), State, gen_server_time()} |
        {stop, term(), term(), State} | gen_server_cast(State).

-type gen_server_code_change(State) ::
        {ok, State}.

-type gen_server_terminate() ::
        ok.



%% ===================================================================
%% Records
%% ===================================================================


% Transport's is calculated, for udp transports, as a hash of {udp, local_ip, local_port},
% and for other transports as of {proto, remote_ip, remote_port}

-record(transport, {
    proto :: nksip:protocol(),
    local_ip :: inet:ip_address(),
    local_port :: inet:port_number(),
    remote_ip :: inet:ip_address(),
    remote_port :: inet:port_number(),
    listen_ip :: inet:ip_address(),         % Ip this transport must report as listening
    listen_port :: inet:port_number()      % Port
}).

-record(sipmsg, {
    class :: req | resp,
    id :: nksip_request:id() | nksip_response:id(),
    app_id :: nksip:app_id(),
    method :: nksip:method(),
    ruri :: nksip:uri(),
    vias :: [nksip:via()],
    from :: nksip:uri(),
    to :: nksip:uri(),
    call_id :: nksip:call_id(),
    cseq :: nksip:cseq(),
    cseq_method :: nksip:method(),
    forwards :: non_neg_integer(),
    routes :: [nksip:uri()],
    contacts :: [nksip:uri()],
    headers :: [nksip:header()],
    content_type :: [nksip_lib:token()],
    body :: nksip:body(),
    response :: nksip:response_code(),
    from_tag :: nksip:tag(),
    to_tag :: nksip:tag(),
    expire :: nksip_lib:timestamp(),
    % pid :: pid(),   % Remove??
    transport :: nksip_transport:transport(),
    start :: nksip_lib:l_timestamp(),
    opts = [] :: nksip_lib:proplist()
}).

-record(reqreply, {
    code = 200 :: nksip:response_code(),
    headers = [] :: [nksip:header()],
    body = <<>> :: nksip:body(),
    opts = [] :: nksip_lib:proplist()
}).

-record(uri, {
    disp = <<>> :: binary(),
    scheme = sip :: nksip:scheme(),
    user = <<>> :: binary(), 
    pass = <<>> :: binary(), 
    domain = <<"invalid.invalid">> :: binary(), 
    port = 0 :: inet:port_number(),             % 0 means "no port in message"
    opts = [] :: nksip_lib:proplist(),
    headers = [] :: [binary()|nksip:header()],
    ext_opts = [] :: nksip_lib:proplist(),
    ext_headers = [] :: [binary()|nksip:header()]
}).

-record(via, {
    proto = udp :: nksip:protocol(),
    domain = <<"invalid.invalid">> :: binary(),
    port = 0 :: inet:port_number(),
    opts = [] :: nksip_lib:proplist()
}).

-record(dialog, {
    id :: nksip_dialog:id(),
    app_id :: nksip:app_id(),
    call_id :: nksip:call_id(),
    created :: nksip_lib:timestamp(),
    updated :: nksip_lib:timestamp(),
    answered :: nksip_lib:timestamp(),
    status :: nksip_dialog:status(),
    local_seq :: 0 | nksip:cseq(),
    remote_seq :: 0 | nksip:cseq(),
    local_uri :: nksip:uri(),
    local_tag :: nksip:tag(),
    remote_uri :: nksip:uri(),
    local_target :: nksip:uri(),        % Only for use in proxy
    remote_target :: nksip:uri(),
    route_set :: [nksip:uri()],
    early :: boolean(),
    secure :: boolean(),
    local_sdp :: nksip_sdp:sdp(),
    remote_sdp :: nksip_sdp:sdp(),
    media_started :: boolean(),
    stop_reason :: nksip_dialog:stop_reason(),
    request :: nksip:request(),
    response :: nksip:response(),
    ack :: nksip:request(),
    remotes :: [{inet:ip_address(), inet:port_number()}],
    timeout_timer :: reference(),
    retrans_timer :: reference(),
    next_retrans :: integer()
}).


-record(sdp_m, {
    media :: binary(),                  % <<"audio">>, ...
    port = 0 :: inet:port_number(),
    nports = 1 :: integer(),
    proto = <<"RTP/AVP">> :: binary(),      
    fmt = [] :: [binary()],             % <<"0">>, <<"101">> ...
    info :: binary(),
    connect :: nksip_sdp:address(),
    bandwidth = [] :: [binary()],
    key :: binary(),
    attributes = [] :: [nksip_sdp:sdp_a()]
}).

-record(sdp, {
    sdp_vsn = <<"0">> :: binary(),
    user = <<"-">> :: binary(),
    id = 0 :: non_neg_integer(), 
    vsn = 0 :: non_neg_integer(), 
    address = {<<"IN">>, <<"IP4">>, <<"0.0.0.0">>} :: nksip_sdp:address(),
    session = <<"nksip">> :: binary(), 
    info :: binary(),
    uri :: binary(),
    email :: binary(),
    phone :: binary(),
    connect :: nksip_sdp:address(),
    bandwidth = [] :: [binary()],
    time = [] :: [nksip_sdp:sdp_t()],
    zone :: binary(),
    key :: binary(),
    attributes = [] :: [nksip_sdp:sdp_a()],
    medias = [] :: [nksip_sdp:sdp_m()]
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

-ifndef(P).
-define(P(S,P), io:format(S++"\n", P)).
-define(P(S), ?P(S, [])).
-endif.

-ifndef(I).
-define(I(S,P), lager:info(S++"\n", P)).
-define(I(S), ?I(S, [])).
-endif.

