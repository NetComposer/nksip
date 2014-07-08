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

-export([insert/2, insert/3, find/1, find/2, dump_msgs/0, reset_msgs/0]).
-export([version/0, deps/0, parse_config/1, init/2, terminate/2]).

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").


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
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(nksip:optslist()) ->
    {ok, nksip:optslist()} | {error, term()}.

parse_config(Opts) ->
    case nksip_lib:get_value(nksip_debug, Opts) of
        {nksip_debug, Trace} when is_boolean(Trace) ->
            Cached1 = nksip_lib:get_value(cached_configs, Opts, []),
            Cached2 = nksip_lib:store_value(config_nksip_debug, Trace, Cached1),
            Opts1 = nksip_lib:store_value(cached_configs, Cached2, Opts),
            {ok, Opts1};
        {nksip_debug, _} ->
            {error, {invalid_config, nksip_debug}};
        false ->
            {ok, Opts}
    end.


%% @doc Called when the plugin is started 
-spec init(nksip:app_id(), nksip_sipapp_srv:state()) ->
    {ok, nksip_siapp_srv:state()}.

init(_AppId, SipAppState) ->
    case whereis(nksip_debug_sup) of
        undefined ->
            case nksip_debug_app:start() of
                ok ->
                    {ok, SipAppState};
                {error, _Error} ->
                    error("Could not start nksip_debug application")
            end;
        _ ->
            {ok, SipAppState}
    end.



%% @doc Called when the plugin is shutdown
-spec terminate(nksip:app_id(), nksip_sipapp_srv:state()) ->
    {ok, nksip_sipapp_srv:state()}.

terminate(_AppId, SipAppState) ->  
    {ok, SipAppState}.



%% ===================================================================
%% Public
%% ===================================================================


%% @private
insert(#sipmsg{app_id=AppId, call_id=CallId}, Info) ->
    insert(AppId, CallId, Info).


%% @private
insert(AppId, CallId, Info) ->
    case AppId:config_nksip_debug() of
        true ->
            Time = nksip_lib:l_timestamp(),
            Info1 = case Info of
                {Type, Str, Fmt} when Type==debug; Type==info; Type==notice; 
                                      Type==warning; Type==error ->
                    {Type, nksip_lib:msg(Str, Fmt)};
                _ ->
                    Info
            end,
            AppName = AppId:name(),
            ets:insert(nksip_debug_msgs, {CallId, Time, AppName, Info1});
        _ ->
            ok
    end.


%% @private
find(CallId) ->
    Lines = lists:sort([{Time, AppId, Info} || {_, Time, AppId, Info} 
                         <- ets:lookup(nksip_debug_msgs, CallId)]),
    [{nksip_lib:l_timestamp_to_float(Time), AppId, Info} 
        || {Time, AppId, Info} <- Lines].


%% @private
find(AppId, CallId) ->
    [{Start, Info} || {Start, C, Info} <- find(CallId), C==AppId].


%% @private
dump_msgs() ->
    ets:tab2list(nksip_debug_msgs).


%% @private
reset_msgs() ->
    ets:delete_all_objects(nksip_debug_msgs).
