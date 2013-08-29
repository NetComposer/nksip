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


-record(raw_sipmsg, {
    sipapp_id :: nksip:sipapp_id(),
    transport :: nksip_transport:transport(),
    start :: nksip_lib:l_timestamp(),
    call_id :: nksip:call_id(),
    class :: nksip_parse:msg_class(),
    headers :: [{binary(), binary()}],
    body :: nksip:body()
}).


-record(trans, {
    class :: uac | uas,
    id :: integer(),
    status :: nksip_call_uas:status(),
    fork_id :: integer(),
    request :: nksip:request(),
    method :: nksip:method(),
    ruri :: nksip:uri(),
    proto :: nksip_transport:protocol(),
    opts :: nksip_lib:proplist(),
    response :: nksip:response(),
    code :: nksip:response_code(),
    stateless :: boolean(),
    timeout_timer :: {atom(), reference()},
    retrans_timer :: {atom(), reference()},
    next_retrans :: non_neg_integer(),
    expire_timer :: {atom(), reference()},
    cancel :: boolean() | {from(), nksip:request()},
    loop_id :: binary(),
    ack_trans_id :: integer(),
    first_to_tag = <<>> :: binary(),
    iter = 1 :: integer()
}).

-record(fork, {
    id :: integer(),
    trans_id :: integer(),
    uriset :: nksip:uri_set(),          
    request :: nksip:request(),
    next :: integer(),
    opts :: nksip_lib:proplist(),       
    pending :: [integer()],
    responses :: [#sipmsg{}], 
    final :: false | '2xx' | '6xx',
    timeout :: reference()
}).

-record(call, {
    app_id :: nksip:sipapp_id(),
    call_id :: nksip:call_id(),
    send_100 :: boolean(),
    keep_time :: integer(),
    next :: integer(),
    hibernate :: boolean(),
    trans = [] :: [#trans{}],
    forks = [] :: [#fork{}],
    msgs = [] :: [#sipmsg{}],
    dialogs = [] :: [nksip_dialog:dialog()]
}).

-endif.
