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

%% @doc NkSIP Outbound Plugin
-module(nksip_outbound).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").

-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.2".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [nksip].


plugin_start(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
    UpdFun = fun(Supported) -> nklib_util:store_value(<<"outbound">>, Supported) end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec),
    {ok, SrvSpec2}.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    UpdFun = fun(Supported) -> Supported -- [<<"outbound">>] end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec),
    {ok, SrvSpec2}.



%% ===================================================================
%% Public
%% ===================================================================


