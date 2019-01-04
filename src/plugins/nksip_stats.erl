%% -------------------------------------------------------------------
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

%% @doc NkSIP Stats Plugin
%% This is a (yet) very simple stats collection plugin
-module(nksip_stats).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([info/0, get_uas_avg/0, response_time/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets some statistics about current number of calls, dialogs, queues, etc.
-spec info() ->
    nksip:optslist().

info() ->
    [
        {calls, nklib_counters:value(nksip_calls)},
        {dialogs, nklib_counters:value(nksip_dialogs)},
        {routers_queue, nksip_router:pending_msgs()},
        {routers_pending, nksip_router:pending_work()},
        {connections, nklib_counters:value(nksip_connections)},
        {counters_queue, nklib_counters:pending_msgs()},
        {core_queues, nkservice_srv:pending_msgs()},
        {uas_response, nksip_stats:get_uas_avg()}
    ].


%% @doc Gets the call statistics for the current period.
-spec get_uas_avg() ->
    {Min::integer(), Max::integer(), Avg::integer(), Std::integer()}.

get_uas_avg() ->
    gen_server:call(nksip_stats_srv, get_uas_avg).


%% @private Informs the module about the last response time
-spec response_time(nklib_util:l_timestamp()) ->
    ok.

response_time(Time) when is_number(Time) ->
    gen_server:cast(nksip_stats_srv, {response_time, Time}).



