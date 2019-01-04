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
-module(nksip_event_compositor_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").
-include("nksip_event_compositor.hrl").

-export([plugin_deps/0, plugin_config/4, plugin_cache/4]).


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_config(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    Syntax = #{
        sip_event_compositor_default_expires => {integer, 1, none}
    },
    case nklib_syntax:parse_all(Config, Syntax) of
        {ok, Config2} ->
            Allow1 = maps:get(sip_allow, Config, nksip_syntax:default_allow()),
            Allow2 = nklib_util:store_value(<<"PUBLISH">>, Allow1),
            Config3 = Config2#{sip_allow=>Allow2},
            {ok, Config3};
        {error, Error} ->
            {error, Error}
    end.


plugin_cache(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    Expires = maps:get(sip_event_compositor_default_expires, Config, 60),
    {ok, #{expires=>Expires}}.


%%plugin_stop(Config, _Service) ->
%%    Allow1 = maps:get(sip_allow, Config, []),
%%    Allow2 = Allow1 -- [<<"PUBLISH">>],
%%    {ok, Config#{sip_allow=>Allow2}}.

