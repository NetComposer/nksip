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

%% @doc NkSIP Deep Debug plugin
-module(nksip_debug).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([start/1, stop/1, print/1, print_all/0]).
-export([insert/2, insert/3, find/1, find/2, dump_msgs/0, reset_msgs/0]).
-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).
-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").


% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.2".


%% @doc Dependant plugins
-spec deps() ->
    [atom()].
    
deps() ->
    [nksip].


plugin_start(#{id:=SrvId, cache:=Cache}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
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
    Debug = maps:get(sip_debug, SrvSpec, false),
    {ok, SrvSpec#{cache=>Cache#{sip_debug=>Debug}}}.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    {ok, SrvSpec}.





%% ===================================================================
%% Public
%% ===================================================================

%% @doc Configures a Service to start debugging
-spec start(nkservice:id()|nkservice:name()) ->
    ok | {error, term()}.

start(Srv) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} ->
            Plugins1 = SrvId:plugins(),
            Plugins2 = nklib_util:store_value(nksip_debug, Plugins1),
            case nksip:update(SrvId, #{plugins=>Plugins2, sip_debug=>true}) of
                ok -> ok;
                {error, Error} -> {error, Error}
            end;
        not_found ->
            {error, service_not_found}
    end.


%% @doc Stop debugging in a specific Service
-spec stop(nkservice:id()|nkservice:name()) ->
    ok | {error, term()}.

stop(Srv) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} ->
            Plugins = SrvId:plugins() -- [nksip_debug],
            case nksip:update(Srv, #{plugins=>Plugins, sip_debug=>false}) of
                ok -> ok;
                {error, Error} -> {error, Error}
            end;
        not_found ->
            {error, service_not_found}
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
    SrvName = SrvId:name(),
    catch ets:insert(nksip_debug_msgs, {CallId, Time, SrvName, Info1}).


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
        fun({Time, Srv, Info}, Acc) ->
            io:format("~f (~f, ~f) ~p\n~p\n\n\n", 
                      [Time, (Time-Start)*1000, (Time-Acc)*1000, Srv, Info]),
            Time
        end,
        Start,
        Lines).


%% @private
print_all() ->
    [{_, Start, _, _}|_] = Lines = lists:keysort(2, dump_msgs()),
    lists:foldl(
        fun({CallId, Time, Srv, Info}, Acc) ->
            io:format("~p (~p, ~p) ~s ~p\n~p\n\n\n", 
                      [Time, (Time-Start), (Time-Acc), CallId, Srv, Info]),
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
