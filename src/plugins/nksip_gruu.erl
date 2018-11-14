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

%% @doc NkSIP GRUU Plugin
-module(nksip_gruu).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").

-export([get_gruu_pub/1, get_gruu_temp/1, registrar_find/2]).



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets the last detected public GRUU
-spec get_gruu_pub(nkservice:name()|nksip:srv_id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.

get_gruu_pub(Srv) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} -> 
            case nksip_app:get({nksip_gruu_pub, SrvId}) of
                undefined -> undefined;
                Value -> {ok, Value}
            end;
        _ -> 
            {error, not_found}
    end.


%% @doc Gets the last detected temporary GRUU
-spec get_gruu_temp(nkservice:name()|nksip:srv_id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.

get_gruu_temp(Srv) ->
    case nkservice_srv:get_srv_id(Srv) of
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
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} -> 
            nksip_gruu_lib:find(SrvId, Uri);
        _ ->
            []
    end.

    