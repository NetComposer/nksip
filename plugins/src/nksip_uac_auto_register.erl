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

%% @doc Plugin implementing automatic registrations and pings support for Services.
-module(nksip_uac_auto_register).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_ping/4, stop_ping/2, get_pings/1]).
-export([start_register/4, stop_register/2, get_registers/1]).
-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).

-include("nksip_uac_auto_register.hrl").


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


plugin_start(#{id:=SrvId, cache:=OldCache}=SrvSpec) ->
    case nkservice_util:parse_syntax(SrvSpec, syntax(), defaults()) of
        {ok, SrvSpec2} ->
            Cache = maps:with([sip_uac_auto_register_timer], SrvSpec2),
            lager:info("Plugin ~p started (~p)", [?MODULE, SrvId]),
            {ok, SrvSpec2#{cache:=maps:merge(OldCache, Cache)}};
        {error, Error} ->
            {stop, Error}
    end.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    gen_server:cast(SrvId, nksip_uac_auto_register_terminate),
    SrvSpec2 = maps:without(maps:keys(syntax()), SrvSpec),
    lager:info("Plugin ~p stopped (~p)", [?MODULE, SrvId]),
    {ok, SrvSpec2}.


syntax() ->
    #{
        sip_uac_auto_register_timer => {integer, 1, none}
    }.

defaults() ->
    #{
        sip_uac_auto_register_timer => 5
    }.





%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nkservice:name()|nkservice:id(), term(), nksip:user_uri(), 
                     nksip:optslist()) -> 
    {ok, boolean()} | {error, term()}.

start_register(Srv, RegId, Uri, Opts) when is_list(Opts) ->
    try
        case nkservice_server:find(Srv) of
            {ok, SrvId} -> ok;
            _ -> SrvId = throw(service_not_found)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_call_uac_make:make(SrvId, 'REGISTER', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {nksip_uac_auto_register_start_reg, RegId, Uri, Opts},
        nkservice_server:call(SrvId, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started registration serie.
-spec stop_register(nkservice:name()|nkservice:id(), term()) -> 
    ok | not_found.

stop_register(Srv, RegId) ->
    nkservice_server:call(Srv, {nksip_uac_auto_register_stop_reg, RegId}).
    

%% @doc Get current registration status.
-spec get_registers(nkservice:name()|nkservice:id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(Srv) ->
    nkservice_server:call(Srv, nksip_uac_auto_register_get_regs).



%% @doc Starts a new automatic ping serie.
-spec start_ping(nkservice:name()|nkservice:id(), term(), nksip:user_uri(), 
                 nksip:optslist()) -> 
    {ok, boolean()} | {error, invalid_uri}.


start_ping(Srv, PingId, Uri, Opts) when is_list(Opts) ->
    try
        case nkservice_server:find(Srv) of
            {ok, SrvId} -> ok;
            _ -> SrvId = throw(service_not_found)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_call_uac_make:make(SrvId, 'OPTIONS', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {nksip_uac_auto_register_start_ping, PingId, Uri, Opts},
        nkservice_server:call(SrvId, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started ping serie.
-spec stop_ping(nkservice:name()|nkservice:id(), term()) -> 
    ok | not_found.

stop_ping(Srv, PingId) ->
    nkservice_server:call(Srv, {nksip_uac_auto_register_stop_ping, PingId}).
    

%% @doc Get current ping status.
-spec get_pings(nkservice:name()|nkservice:id()) -> 
    [{PingId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_pings(Srv) ->
    nkservice_server:call(Srv, nksip_uac_auto_register_get_pings).

