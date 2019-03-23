%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP Registrar Plugin Callbacks
-module(nksip_registrar_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_registrar.hrl").
-export([plugin_deps/0, plugin_config/3, plugin_cache/3]).

%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


%% @doc
plugin_config(_PkgId,  Config, #{class:=?PACKAGE_CLASS_SIP}) ->
    Syntax = #{
        sip_allow => words,
        sip_registrar_default_time => {integer, 5, none},
        sip_registrar_min_time => {integer, 1, none},
        sip_registrar_max_time => {integer, 60, none}
    },
    case nklib_syntax:parse_all(Config, Syntax) of
        {ok, Config2} ->
            Allow1 = maps:get(sip_allow, Config2, nksip_syntax:default_allow()),
            Allow2 = nklib_util:store_value(<<"REGISTER">>, Allow1),
            Config3 = Config2#{sip_allow=>Allow2},
            {ok, Config3};
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_PkgId, Config, _Service) ->
    Cache = #{
        times => #nksip_registrar_time{
            min = maps:get(sip_registrar_min_time, Config, 60),
            max = maps:get(sip_registrar_max_time, Config, 86400),
            default = maps:get(sip_registrar_default_time, Config, 3600)
        }
    },
    {ok, Cache}.



