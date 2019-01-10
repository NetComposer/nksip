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

%% @doc NkSIP OUTBOUND Plugin Callbacks
-module(nksip_outbound_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([plugin_deps/0, plugin_config/3]).


plugin_deps() ->
    [nksip].


plugin_config(_PkgId,  Config, #{class:=?PACKAGE_CLASS_SIP}) ->
    Supported1 = maps:get(sip_supported, Config, nksip_syntax:default_supported()),
    Supported2 = nklib_util:store_value(<<"outbound">>, Supported1),
    Config2 = Config#{sip_supported=>Supported2},
    {ok, Config2}.



%%plugin_stop(Config, _Service) ->
%%    Supported1 = maps:get(sip_supported, Config, []),
%%    Supported2 = Supported1 -- [<<"outbound">>],
%%    {ok, Config#{sip_supported=>Supported2}}.

