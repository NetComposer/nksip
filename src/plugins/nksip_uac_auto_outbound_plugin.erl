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

%% @private
-module(nksip_uac_auto_outbound_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_config/4, plugin_cache/4, plugin_stop/4]).


-include("nksip.hrl").
%%-include("nksip_call.hrl").
%%-include("nksip_uac_auto_register.hrl").
-include("nksip_uac_auto_outbound.hrl").
%%-include_lib("nkserver/include/nkserver.hrl").

%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip_uac_auto_register, nksip_outbound].


plugin_config(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    Syntax = #{
        sip_uac_auto_outbound_all_fail => {integer, 1, none},
        sip_uac_auto_outbound_any_ok => {integer, 1, none},
        sip_uac_auto_outbound_max_time => {integer, 1, none},
        sip_uac_auto_outbound_default_udp_ttl => {integer, 1, none},
        sip_uac_auto_outbound_default_tcp_ttl => {integer, 1, none}
    },
    case nklib_syntax:parse_all(Config, Syntax) of
        {ok, Config2} ->
            Allow1 = maps:get(sip_allow, Config, nksip_syntax:default_allow()),
            Allow2 = nklib_util:store_value(<<"REGISTER">>, Allow1),
            Config3 = Config2#{sip_allow=>Allow2},
            {ok, Config3};
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    Cache = #nksip_uac_auto_outbound{
        all_fail =maps:get(sip_uac_auto_outbound_all_fail, Config, 30),
        any_ok = maps:get(sip_uac_auto_outbound_any_ok, Config, 90),
        max_time = maps:get(sip_uac_auto_outbound_max_time, Config, 1800),
        udp_ttl = maps:get(sip_uac_auto_outbound_default_udp_ttl, Config, 25),
        tcp_ttl = maps:get(sip_uac_auto_outbound_default_tcp_ttl, Config, 120)
    },
    {ok, #{config=>Cache}}.


plugin_stop(PkgId, ?PACKAGE_CLASS_SIP, _Config, _Package) ->
    gen_server:cast(PkgId, nksip_uac_auto_outbound_terminate),
    ok.
