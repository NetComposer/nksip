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

%% @doc Plugin implementing automatic registrations and pings support for Services.
-module(nksip_uac_auto_register).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_ping/4, stop_ping/2, get_pings/1]).
-export([start_register/4, stop_register/2, get_registers/1]).
-export([version/0, deps/0, parse_config/1, init/2, terminate/2]).

-include("nksip_uac_auto_register.hrl").


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.1".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [nksip].


%% @doc Parses this plugin specific configuration
-spec parse_config(nksip:optslist()) ->
    {ok, nksip:optslist()} | {error, term()}.

parse_config(Opts) ->
    Defaults = [{nksip_uac_auto_register_timer, 5}],                   % (secs)
    Opts1 = nklib_util:defaults(Opts, Defaults),
    case nklib_util:get_value(nksip_uac_auto_register_timer, Opts1) of
        Timer when is_integer(Timer), Timer>0 -> 
            {ok, Opts1};
        _ -> 
            {error, {invalid_config, nksip_uac_auto_register_timer}}
    end.


%% @doc Called when the plugin is started 
-spec init(nkservice:spec(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

init(_ServiceSpec, #{srv_id:=SrvId}=ServiceState) ->
    Timer = 1000 * SrvId:cache_sip_uac_auto_register_timer(),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_register_timer'),
    State = #state{pings=[], regs=[]},
    {ok, ServiceState#{nksip_uac_auto_register=>State}}.


%% @doc Called when the plugin is shutdown
-spec terminate(nkservice:id(), nkservice_server:sub_state()) ->
   {ok, nkservice_server:sub_state()}.

terminate(SrvId, ServiceState) ->  
    #state{regs=Regs} = maps:get(nksip_uac_auto_register, ServiceState),
    lists:foreach(
        fun(#sipreg{ok=Ok}=Reg) -> 
            case Ok of
                true -> 
                    SrvId:nks_sip_uac_auto_register_launch_unregister(Reg, true, ServiceState);
                false ->
                    ok
            end
        end,
        Regs),
    {ok, maps:remove(nksip_uac_auto_register, ServiceState)}.




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nkservice:name()|nkservice:id(), term(), nksip:user_uri(), 
                     nksip:optslist()) -> 
    {ok, boolean()} | {error, term()}.

start_register(App, RegId, Uri, Opts) when is_list(Opts) ->
    try
        case nkservice_server:find(App) of
            {ok, SrvId} -> ok;
            _ -> SrvId = throw(invalid_app)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_call_uac_make:make(SrvId, 'REGISTER', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {'$nksip_uac_auto_register_start_register', RegId, Uri, Opts},
        nkservice_server:call(App, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started registration serie.
-spec stop_register(nkservice:name()|nkservice:id(), term()) -> 
    ok | not_found.

stop_register(App, RegId) ->
    nkservice_server:call(App, {'$nksip_uac_auto_register_stop_register', RegId}).
    

%% @doc Get current registration status.
-spec get_registers(nkservice:name()|nkservice:id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(App) ->
    nkservice_server:call(App, '$nksip_uac_auto_register_get_registers').



%% @doc Starts a new automatic ping serie.
-spec start_ping(nkservice:name()|nkservice:id(), term(), nksip:user_uri(), 
                 nksip:optslist()) -> 
    {ok, boolean()} | {error, invalid_uri}.


start_ping(App, PingId, Uri, Opts) when is_list(Opts) ->
    try
        case nkservice_server:find(App) of
            {ok, SrvId} -> ok;
            _ -> SrvId = throw(invalid_app)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_call_uac_make:make(SrvId, 'OPTIONS', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {'$nksip_uac_auto_register_start_ping', PingId, Uri, Opts},
        nkservice_server:call(App, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started ping serie.
-spec stop_ping(nkservice:name()|nkservice:id(), term()) -> 
    ok | not_found.

stop_ping(App, PingId) ->
    nkservice_server:call(App, {'$nksip_uac_auto_register_stop_ping', PingId}).
    

%% @doc Get current ping status.
-spec get_pings(nkservice:name()|nkservice:id()) -> 
    [{PingId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_pings(App) ->
    nkservice_server:call(App, '$nksip_uac_auto_register_get_pings').

