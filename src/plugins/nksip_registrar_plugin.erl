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

%% @doc NkSIP Registrar Plugin Callbacks
-module(nksip_registrar_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("nksip_registrar.hrl").
-export([plugin_deps/0, plugin_config/3, get_config/2]).


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


%% @doc
plugin_config(?PACKAGE_CLASS_SIP, #{id:=PkgId, config:=Config}=Spec, _Service) ->
    Syntax = #{
        sip_allow => words,
        sip_registrar_default_time => {integer, 5, none},
        sip_registrar_min_time => {integer, 1, none},
        sip_registrar_max_time => {integer, 60, none},
        '__allow_unknown' => true
    },
    case nklib_syntax:parse(Config, Syntax) of
        {ok, Config2, _} ->
            Allow1 = maps:get(sip_allow, Config, nksip_syntax:default_allow()),
            Allow2 = nklib_util:store_value(<<"REGISTER">>, Allow1),
            Config3 = Config2#{sip_allow=>Allow2},
            Spec3 = Spec#{config := Config3},
            CacheItems = #{
                nksip_registrar => #nksip_registrar_time{
                    min = maps:get(sip_registrar_min_time, Config2, 60),
                    max = maps:get(sip_registrar_max_time, Config2, 86400),
                    default = maps:get(sip_registrar_default_time, Config2, 3600)
                }
            },
            Spec4 = nkservice_config_util:set_cache_items(nksip, PkgId, CacheItems, Spec3),
            {ok, Spec4};
        {error, Error} ->
            {error, Error}
    end;

plugin_config(_Class, _Package, _Service) ->
    continue.


%% @doc
get_config(SrvId, PkgId) ->
    nkservice_util:get_cache(SrvId, nksip, PkgId, nksip_registrar).





%%plugin_stop(?PACKAGE_CLASS_SIP, #{id:=PkgId, config:=Config}=Spec, _Pid, #{id:=SrvId}) ->
%%    nksip_registrar:clear(SrvId, PkgId),
%%    Allow1 = maps:get(sip_allow, Config, []),
%%    Allow2 = Allow1 -- [<<"REGISTER">>],
%%    {ok, Config#{sip_allow=>Allow2}}.

