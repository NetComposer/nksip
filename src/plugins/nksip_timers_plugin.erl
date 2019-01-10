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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_timers_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([plugin_deps/0, plugin_config/3, plugin_cache/3]).


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_config(_PkgId,  Config, #{class:=?PACKAGE_CLASS_SIP}) ->
    Syntax = #{
        sip_timers_se =>  {integer, 5, none},
        sip_timers_min_se => {integer, 1, none}
    },
    case nklib_syntax:parse_all(Config, Syntax) of
        {ok, Config2} ->
            Supported1 = maps:get(sip_supported, Config, nksip_syntax:default_supported()),
            Supported2 = nklib_util:store_value(<<"timer">>, Supported1),
            Config3 = Config2#{sip_supported=>Supported2},
            {ok, Config3};
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_PkgId, Config, _Service) ->
    SE = maps:get(sip_timers_se, Config, 1800),      % (secs) 30 min
    MinSE = maps:get(sip_timers_min_se, Config, 90), % (secs) 90 secs (min 90, recom. 1800)
    {ok, #{se_minse => {SE, MinSE}}}.

%%
%%plugin_stop(Config, _Service) ->
%%    Supported1 = maps:get(sip_supported, Config, []),
%%    Supported2 = Supported1 -- [<<"timer">>],
%%    {ok, Config#{sip_supported=>Supported2}}.
