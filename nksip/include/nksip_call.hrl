%% -------------------------------------------------------------------
%%
%% nksip_call.hrl: SIP call processing types
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

-ifndef(NKSIP_CALL_HRL_).
-define(NKSIP_CALL_HRL_, 1).

-define(call_debug(Txt, List, SD),
        ?debug(SD#call.app_id, SD#call.call_id, Txt, List)).

-define(call_info(Txt, List, SD),
        ?info(SD#call.app_id, SD#call.call_id, Txt, List)).

-define(call_notice(Txt, List, SD),
        ?notice(SD#call.app_id, SD#call.call_id, Txt, List)).

-define(call_warning(Txt, List, SD),
        ?warning(SD#call.app_id, SD#call.call_id, Txt, List)).

-define(call_error(Txt, List, SD),
        ?error(SD#call.app_id, SD#call.call_id, Txt, List)).

-define(MSG_KEEP_TIME, 5).          % Time to keep removed sip msgs in memory


-record(raw_sipmsg, {
    id :: nksip_request:id() | nksip_response:id(),
    class :: nksip_parse:msg_class(),
    app_id :: nksip:app_id(),
    call_id :: nksip:call_id(),
    start :: nksip_lib:l_timestamp(),
    headers :: [{binary(), binary()}],
    body :: nksip:body(),
    transport :: nksip_transport:transport()
}).


-record(trans, {
    id :: nksip_call_uac:id() | nksip_call_uas:id(),
    class :: uac | uas,
    status :: nksip_call_uac:status() | nksip_call_uas:status(),
    start :: nksip_lib:timestamp(),
    from :: {srv, from()} | {fork, nksip_call_fork:id()},
    opts :: nksip_lib:proplist(),
    trans_id :: integer(),
    request :: nksip:request(),
    method :: nksip:method(),
    ruri :: nksip:uri(),
    proto :: nksip:protocol(),
    response :: nksip:response(),
    code :: 0 | nksip:response_code(),
    to_tags = [] :: [nksip:tag()],
    stateless :: boolean(),
    timeout_timer :: {nksip_call_lib:timeout_timer(), reference()},
    retrans_timer :: {nksip_call_lib:retrans_timer(), reference()},
    next_retrans :: non_neg_integer(),
    expire_timer :: {nksip_call_lib:expire_timer(), reference()},
    cancel :: undefined | to_cancel | cancelled,
    loop_id :: integer(),
    ack_trans_id :: integer(),
    iter = 1 :: integer()
}).

-record(fork, {
    id :: nksip_call_fork:id(),
    class :: uac | uas,
    start :: nksip_lib:timestamp(),
    request :: nksip:request(),
    method :: nksip:method(),
    opts :: nksip_lib:proplist(),
    uriset :: nksip:uri_set(),          
    uacs :: [integer()],
    pending :: [integer()],
    responses :: [nksip:response()], 
    final :: false | '2xx' | '6xx'
}).


-record(global, {
    global_id :: binary(),
    max_calls :: integer(),
    max_trans_time :: integer(),
    max_dialog_time :: integer(),
    t1 :: integer(),
    t2 :: integer(),
    t4 :: integer(),
    tc :: integer()
}).


-record(call, {
    app_id :: nksip:app_id(),
    call_id :: nksip:call_id(),
    global :: #global{},
    app_opts :: nksip_lib:proplist(),
    keep_time :: integer(),
    hibernate :: atom(),
    next :: integer(),
    trans = [] :: [#trans{}],
    forks = [] :: [#fork{}],
    msgs = [] :: [#sipmsg{}],
    dialogs = [] :: [#dialog{}]
}).


-endif.
