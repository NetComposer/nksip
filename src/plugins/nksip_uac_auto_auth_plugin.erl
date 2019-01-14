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

%% @doc NkSIP Registrar Plugin
-module(nksip_uac_auto_auth_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").


-export([plugin_deps/0, plugin_config/3, plugin_cache/3]).


%% ===================================================================
%% Plugin specific
%% ===================================================================


plugin_deps() ->
    [nksip].


plugin_config(_PkgId,  Config, #{class:=?PACKAGE_CLASS_SIP}) ->
    Syntax = nksip_uac_auto_auth:syntax(),
    nklib_syntax:parse_all(Config, Syntax).


plugin_cache(_PkgId, Config, _Service) ->
    Cache = #{
        max_tries => maps:get(sip_uac_auto_auth_max_tries, Config, 5),
        passwords => maps:get(sip_pass, Config, [])
    },
    {ok, Cache}.

