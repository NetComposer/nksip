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

%% @doc NkSIP GRUU Plugin
-module(nksip_gruu).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").

-export([get_gruu_pub/1, get_gruu_temp/1, registrar_find/2]).
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
%% If nksip_registrar is activated, it will update it
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [nksip, nksip_registrar].


plugin_start(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
    UpdFun = fun(Supported) -> nklib_util:store_value(<<"gruu">>, Supported) end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec),
    {ok, SrvSpec2}.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    UpdFun = fun(Supported) -> Supported -- [<<"gruu">>] end,
    SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec),
    {ok, SrvSpec2}.


% %% @doc Parses this plugin specific configuration
% -spec parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% parse_config(Opts) ->
%     Supported = nklib_util:get_value(sip_supported, Opts),
%     Opts1 = case lists:member(<<"gruu">>, Supported) of
%         true -> Opts;
%         false -> nklib_util:store_value(sip_supported, Supported++[<<"gruu">>], Opts)
%     end,
%     {ok, Opts1}.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets the last detected public GRUU
-spec get_gruu_pub(nkservice:name()|nkservice:id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.

get_gruu_pub(Srv) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> 
            case nksip_app:get({nksip_gruu_pub, SrvId}) of
                undefined -> undefined;
                Value -> {ok, Value}
            end;
        _ -> 
            {error, not_found}
    end.


%% @doc Gets the last detected temporary GRUU
-spec get_gruu_temp(nkservice:name()|nkservice:id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.

get_gruu_temp(Srv) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> 
            case nksip_app:get({nksip_gruu_temp, SrvId}) of
                undefined -> undefined;
                Value -> {ok, Value}
            end;
        _ -> 
            {error, not_found}
    end.


%% @doc Use this function instead of nksip_registrar:find/2,4 to decode the generated GRUUs.
-spec registrar_find(nkservice:name()|nkservice:id(), nksip:uri()) ->
    [nksip:uri()].

registrar_find(Srv, Uri) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> 
            nksip_gruu_lib:find(SrvId, Uri);
        _ ->
            []
    end.

    