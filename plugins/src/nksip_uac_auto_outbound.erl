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
-module(nksip_uac_auto_outbound).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_register/4, stop_register/2, get_registers/1]).
-export([version/0, plugin_deps/0, plugin_start/1, plugin_stop/1]).

-include("nksip_uac_auto_outbound.hrl").


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.2".


%% @doc Dependant plugins
-spec plugin_deps() ->
    [atom()].
    
plugin_deps() ->
    [nksip_uac_auto_register, nksip_outbound].



plugin_start(#{id:=SrvId, cache:=OldCache}=SrvSpec) ->
    case nkservice_util:parse_syntax(SrvSpec, syntax(), defaults()) of
        {ok, SrvSpec1} ->
            Cache = maps:with(maps:keys(syntax()), SrvSpec1),
            lager:info("Plugin ~p started (~p)", [?MODULE, SrvId]),
            {ok, SrvSpec1#{cache=>maps:merge(OldCache, Cache)}};
        {error, Error} ->
            {stop, Error}
    end.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    gen_server:cast(SrvId, nksip_uac_auto_outbound_terminate),
    SrvSpec2 = maps:without(maps:keys(syntax()), SrvSpec),
    lager:info("Plugin ~p stopped (~p)", [?MODULE, SrvId]),
    {ok, SrvSpec2}.



syntax() ->
    #{
        sip_uac_auto_outbound_all_fail => {integer, 1, none},
        sip_uac_auto_outbound_any_ok => {integer, 1, none},
        sip_uac_auto_outbound_max_time => {integer, 1, none},
        sip_uac_auto_outbound_default_udp_ttl => {integer, 1, none},
        sip_uac_auto_outbound_default_tcp_ttl => {integer, 1, none}
    }.


defaults() ->
    #{
        sip_uac_auto_outbound_all_fail => 30,
        sip_uac_auto_outbound_any_ok => 90,
        sip_uac_auto_outbound_max_time => 1800,
        sip_uac_auto_outbound_default_udp_ttl => 25,
        sip_uac_auto_outbound_default_tcp_ttl => 120
    }.




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nkservice:name()|nksip:srv_id(), term(), nksip:user_uri(),                 nksip:optslist()) -> 
    {ok, boolean()} | {error, term()}.

start_register(Srv, RegId, Uri, Opts) when is_list(Opts) ->
    Opts1 = [{user, [nksip_uac_auto_outbound]}|Opts],
    nksip_uac_auto_register:start_register(Srv, RegId, Uri, Opts1).


%% @doc Stops a previously started registration serie.
-spec stop_register(nkservice:name()|nksip:srv_id(), term()) -> 
    ok | not_found.

stop_register(Srv, RegId) ->
    nksip_uac_auto_register:stop_register(Srv, RegId).
    

%% @doc Get current registration status.
-spec get_registers(nkservice:name()|nksip:srv_id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(Srv) ->
    nkservice:call(Srv, nksip_uac_auto_outbound_get_regs).

    
