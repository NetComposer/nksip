%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP Reliable Provisional Responses Plugin
-module(nksip_100rel).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

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
    [atom()].
    
deps() ->
    [nksip].


plugin_start(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
    UpdFun1 = fun(Allow) -> nklib_util:store_value(<<"PRACK">>, Allow) end,
    SrvSpec1 = nksip_util:plugin_update_value(sip_allow, UpdFun1, SrvSpec),
    UpdFun2 = fun(Supported) -> nklib_util:store_value(<<"100rel">>, Supported) end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun2, SrvSpec1),
    {ok, SrvSpec2}.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    UpdFun1 = fun(Allow) -> Allow -- [<<"PRACK">>] end,
    SrvSpec1 = nksip_util:plugin_update_value(sip_allow, UpdFun1, SrvSpec),
    UpdFun2 = fun(Supported) -> Supported -- [<<"100rel">>] end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun2, SrvSpec1),
    {ok, SrvSpec2}.


% %% @doc Parses this plugin specific configuration
% -spec parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% parse_config(Opts) ->
%     Allow = nklib_util:get_value(sip_allow, Opts),
%     Opts1 = case lists:member(<<"PRACK">>, Allow) of
%         true -> 
%             Opts;
%         false -> 
%             nklib_util:store_value(sip_allow, Allow++[<<"PRACK">>], Opts)
%     end,
%     Supported = nklib_util:get_value(sip_supported, Opts),
%     Opts2 = case lists:member(<<"100rel">>, Supported) of
%         true -> Opts1;
%         false -> nklib_util:store_value(sip_supported, Supported++[<<"100rel">>], Opts1)
%     end,
%     {ok, Opts2}.


