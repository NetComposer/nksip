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

%% @doc NkSIP Stats Plugin Callbacks
-module(nksip_stats_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([plugin_deps/0, plugin_start/3]).



% ===================================================================
%% Plugin specific
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_start(_PkgId, _Config, #{class:=?PACKAGE_CLASS_SIP}) ->
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
            {ok, _Pid} = supervisor:start_child(nksip_sup, Child),
            ok;
        _ ->
            ok
    end.



