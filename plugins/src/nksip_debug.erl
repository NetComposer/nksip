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

%% @doc NkSIP Deep Debug plugin
-module(nksip_debug).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([start/1, stop/1, print/1, print_all/0]).
-export([insert/2, insert/3, find/1, find/2, dump_msgs/0, reset_msgs/0]).
-export([version/0, deps/0, init/2, terminate/2]).

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").


% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.1".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [nksip].


% %% @doc Parses this plugin specific configuration
% -spec parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% parse_config(Opts) ->
%     case nklib_util:get_value(nksip_debug, Opts, false) of
%         Trace when is_boolean(Trace) ->
%             Cached1 = nklib_util:get_value(cached_configs, Opts, []),
%             Cached2 = nklib_util:store_value(config_nksip_debug, Trace, Cached1),
%             Opts1 = nklib_util:store_value(cached_configs, Cached2, Opts),
%             {ok, Opts1};
%         _ ->
%             {error, {invalid_config, nksip_debug}}
%     end.


%% @doc Called when the plugin is started 
-spec init(nkservice:spec(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

init(_SrvId, ServiceState) ->
    case whereis(nksip_debug_srv) of
        undefined ->
            Child = {
                nksip_debug_srv,
                {nksip_debug_srv, start_link, []},
                permanent,
                5000,
                worker,
                [nksip_debug_srv]
            },
            {ok, _Pid} = supervisor:start_child(nksip_sup, Child);
        _ ->
            ok
    end,
    {ok, ServiceState}.



%% @doc Called when the plugin is shutdown
-spec terminate(term(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

terminate(_Reason, ServiceState) ->  
    {ok, ServiceState}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Configures a Service to start debugging
-spec start(nkservice:id()|nkservice:name()) ->
    ok | {error, term()}.

start(App) ->
    case nkservice_server:find(App) of
        {ok, SrvId} ->
            Plugins1 = SrvId:config_plugins(),
            Plugins2 = nklib_util:store_value(nksip_debug, Plugins1),
            case nksip:update(SrvId, [{plugins, Plugins2}, {debug, true}]) of
                {ok, _} -> ok;
                {error, Error} -> {error, Error}
            end;
        not_found ->
            {error, sipapp_not_found}
    end.


%% @doc Stop debugging in a specific Service
-spec stop(nkservice:id()|nkservice:name()) ->
    ok | {error, term()}.

stop(App) ->
    case nkservice_server:find(App) of
        {ok, SrvId} ->
            Plugins = SrvId:config_plugins() -- [nksip_debug],
            case nksip:update(App, [{plugins, Plugins}, {debug, false}]) of
                {ok, _} -> ok;
                {error, Error} -> {error, Error}
            end;
        not_found ->
            {error, sipapp_not_found}
    end.    



%% ===================================================================
%% Internal
%% ===================================================================



%% @private
insert(#sipmsg{srv_id=SrvId, call_id=CallId}, Info) ->
    insert(SrvId, CallId, Info).


%% @private
insert(SrvId, CallId, Info) ->
    Time = nklib_util:l_timestamp(),
    Info1 = case Info of
        {Type, Str, Fmt} when Type==debug; Type==info; Type==notice; 
                              Type==warning; Type==error ->
            {Type, nklib_util:msg(Str, Fmt)};
        _ ->
            Info
    end,
    AppName = SrvId:name(),
    catch ets:insert(nksip_debug_msgs, {CallId, Time, AppName, Info1}).


%% @private
find(CallId) ->
    Lines = lists:sort([{Time, SrvId, Info} || {_, Time, SrvId, Info} 
                         <- ets:lookup(nksip_debug_msgs, nklib_util:to_binary(CallId))]),
    [{nklib_util:l_timestamp_to_float(Time), SrvId, Info} 
        || {Time, SrvId, Info} <- Lines].


%% @private
find(SrvId, CallId) ->
    [{Start, Info} || {Start, C, Info} <- find(CallId), C==SrvId].


%% @private
print(CallId) ->
    [{Start, _, _}|_] = Lines = find(CallId),
    lists:foldl(
        fun({Time, App, Info}, Acc) ->
            io:format("~f (~f, ~f) ~p\n~p\n\n\n", 
                      [Time, (Time-Start)*1000, (Time-Acc)*1000, App, Info]),
            Time
        end,
        Start,
        Lines).


%% @private
print_all() ->
    [{_, Start, _, _}|_] = Lines = lists:keysort(2, dump_msgs()),
    lists:foldl(
        fun({CallId, Time, App, Info}, Acc) ->
            io:format("~p (~p, ~p) ~s ~p\n~p\n\n\n", 
                      [Time, (Time-Start), (Time-Acc), CallId, App, Info]),
            Time
        end,
        Start,
        Lines).


%% @private
dump_msgs() ->
    ets:tab2list(nksip_debug_msgs).


%% @private
reset_msgs() ->
    ets:delete_all_objects(nksip_debug_msgs).
