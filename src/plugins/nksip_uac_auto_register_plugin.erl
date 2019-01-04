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

-module(nksip_uac_auto_register_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([plugin_deps/0, plugin_config/4, plugin_cache/4]).

-include("nksip.hrl").


%% ===================================================================
%% Plugin specific
%% ===================================================================


plugin_deps() ->
    [nksip].


plugin_config(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    Syntax = #{
        sip_uac_auto_register_timer => {integer, 1, none}
    },
    nklib_syntax:parse_all(Config, Syntax).


plugin_cache(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
    {ok, #{register_time => maps:get(sip_uac_auto_register_timer, Config, 5)}}.

