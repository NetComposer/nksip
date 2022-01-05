
%% -------------------------------------------------------------------
%%
%% nksip_call.hrl: SIP call processing types
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

-ifndef(NKSIP_CALL_HRL_).
-define(NKSIP_CALL_HRL_, 1).

-include_lib("nklib/include/nklib.hrl").


-define(CALL_DEBUG(Txt, Args),
    case erlang:get(nksip_debug) of
        true -> ?CALL_LOG(debug, Txt, Args);
        _ -> ok
    end).


-define(CALL_DEBUG(Txt, Args, Call),
    case erlang:get(nksip_debug) of
        true -> ?CALL_LOG(debug, Txt, Args, Call);
        _ -> ok
    end).


-define(CALL_LOG(Type, Txt, Args),
    lager:Type("NkSIP CALL " ++ Txt, Args)).


-define(CALL_LOG(Type, Txt, Args, Call),
    lager:Type(
        [
            {package, Call#call.srv_id},
            {call_id, Call#call.call_id}
        ],
        "NKSIP CALL '~s' (~s) " ++ Txt,
        [
            Call#call.call_id,
            Call#call.srv_id |
            Args
        ]
    )).


-type prack() :: {
    RSeq::nksip:cseq(), 
    CSeq::nksip:cseq(), 
    CSeqMethod:: nksip:method(),
    DialogId :: nksip_dialog_lib:id()
}.


-record(trans, {
    id :: nksip_call:trans_id(),
    class :: uac | uas,
    status :: nksip_call_uac:status() | nksip_call_uas:status(),
    start :: nklib_util:timestamp(),
    from :: none | {srv, {pid(), term()}} | {fork, nksip_call_fork:id()},
    opts :: nksip:optslist(),
    trans_id :: integer(),
    request :: nksip:request(),
    method :: nksip:method(),
    ruri :: nksip:uri(),
    transp :: nkpacket:transport(),
    response :: nksip:response(),
    code :: 0 | nksip:sip_code(),
    to_tags = [] :: [nksip:tag()],
    stateless :: boolean(),
    iter = 1 :: pos_integer(),
    cancel :: undefined | to_cancel | cancelled,
    loop_id :: integer(),
    timeout_timer :: {nksip_call_lib:timeout_timer(), reference()},
    retrans_timer :: {nksip_call_lib:retrans_timer(), reference()},
    next_retrans :: non_neg_integer(),
    expire_timer :: {nksip_call_lib:expire_timer(), reference()},
    ack_trans_id :: integer(),
    meta = [] :: nksip:optslist()
}).


-record(fork, {
    id :: nksip_call_fork:id(),
    class :: uac | uas,
    start :: nklib_util:timestamp(),
    request :: nksip:request(),
    method :: nksip:method(),
    opts :: nksip:optslist(),
    uriset :: nksip:uri_set(),          
    uacs :: [integer()],
    pending :: [integer()],
    responses :: [nksip:response()], 
    final :: false | '2xx' | '6xx',
    meta = [] :: nksip:optslist() 
}).


-record(provisional_event, {
    id :: {Id::nksip_subscription_lib:id(), Tag::binary()},
    timer_n :: reference()
}).


-type call_auth() :: {
    nksip_dialog_lib:id(), 
    nkpacket:nkport(), 
    inet:ip_address(), 
    inet:port_number()
}.


-type call_msg() :: {
    nksip_sipmsg:id(),
    nksip_call:trans_id(),
    nksip_dialog_lib:id()
}.


-record(call_times, {
    t1 :: integer(),
    t2 :: integer(),
    t4 :: integer(), 
    tc :: integer(),
    trans :: integer(),
    dialog :: integer()
}).


%% Current Meta uses:
%% - nksip_min_se: Pre-dialog received MinSE header

-record(call, {
    srv_id :: nkservice:package_id(),
    srv_ref :: reference(),
    call_id :: nksip:call_id(),
    hibernate :: atom(),
    next :: integer(),
    trans = [] :: [#trans{}],
    forks = [] :: [#fork{}],
    dialogs = [] :: [#dialog{}],
    auths = [] :: [call_auth()],
    msgs = [] :: [call_msg()],
    events = [] :: [#provisional_event{}],
    times :: #call_times{},
    dests = #{} :: #{},
    meta = [] :: nksip:optslist()
}).


%%-define(GET_CONFIG(SrvId, Key), (SrvId:config_nksip())#config.Key).


-record(config, {
    allow :: [binary()],
    supported :: [binary()],
    event_expires :: integer(),
    event_expires_offset :: integer(),
    nonce_timeout :: integer(),
    from :: #uri{},
    accept :: [binary()],
    events :: [binary()],
    route :: [#uri{}],
    no_100 :: boolean(),
    max_calls :: integer(),
    local_host :: auto | binary(),
    local_host6 :: auto | binary(),
    tos :: integer(),
    debug :: [atom()],
    times :: #call_times{},
    udp_max_size :: integer()
}).



-endif.
