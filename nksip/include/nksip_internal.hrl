%% -------------------------------------------------------------------
%%
%% nksip_internal.hrl: Internal types
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

-ifndef(NKSIP_INTERNAL_HRL_).
-define(NKSIP_INTERNAL_HRL_, 1).

-record(dlg_state, {
    dialog :: nksip_dialog:dialog(),
    from_tag :: binary(),               % Creation from tag
    proto :: nksip:protocol(),
    invite_request :: nksip:request(),
    invite_response :: nksip:response(),
    ack_request :: nksip:request(),
    is_first :: boolean(),
    % started_sent :: boolean(),
    started_media :: boolean(),
    remotes :: [{inet:ip_address(), inet:port_number()}],
    t1 :: integer(),
    t2 :: integer(),
    timer :: reference(),
    retrans_timer :: reference(),
    retrans_next :: integer(),
    invite_queue :: [{{reference(), pid()}, nksip:cseq()}]
}).

-endif.
