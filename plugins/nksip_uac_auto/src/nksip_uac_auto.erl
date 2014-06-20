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

%% @doc Plugin implementing automatic registrations and pings support for SipApps.
-module(nksip_uac_auto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_ping/4, stop_ping/2, get_pings/1]).
-export([start_register/4, stop_register/2, get_registers/1]).
-export([version/0, deps/0, parse_config/2, init/2, terminate/2]).

-include("nksip_uac_auto.hrl").


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
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Defaults = [
        {nksip_uac_auto_timer, 5}                     % (secs)
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),
    parse_config(PluginOpts1, [], Config).


%% @doc Called when the plugin is started 
-spec init(nksip:app_id(), nksip_sipapp_srv:state()) ->
    {ok, nksip_siapp_srv:state()}.

init(AppId, SipAppState) ->
    Timer = 1000 * nksip_sipapp_srv:config(AppId, nksip_uac_auto_timer),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_timer'),
    State = #state{pings=[], regs=[]},
    SipAppState1 = nksip_sipapp_srv:set_meta(nksip_uac_auto, State, SipAppState),
    {ok, SipAppState1}.


%% @doc Called when the plugin is shutdown
-spec terminate(nksip:app_id(), nksip_sipapp_srv:state()) ->
   {ok, nksip_sipapp_srv:state()}.

terminate(AppId, SipAppState) ->  
    #state{regs=Regs} = nksip_sipapp_srv:get_meta(nksip_uac_auto, SipAppState),
    lists:foreach(
        fun(#sipreg{ok=Ok}=Reg) -> 
            case Ok of
                true -> 
                    AppId:nkcb_uac_auto_launch_unregister(Reg, true, SipAppState);
                false ->
                    ok
            end
        end,
        Regs),
    SipAppState1 = nksip_sipapp_srv:set_meta(nksip_uac_auto, undefined, SipAppState),
    {ok, SipAppState1}.




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nksip:app_name()|nksip:app_id(), term(), nksip:user_uri(), 
                     nksip:optslist()) -> 
    {ok, boolean()} | {error, term()}.

start_register(App, RegId, Uri, Opts) when is_list(Opts) ->
    try
        case nksip:find_app_id(App) of
            {ok, AppId} -> ok;
            _ -> AppId = throw(invalid_app)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_uac_lib:make(AppId, 'REGISTER', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {'$nksip_uac_auto_start_register', RegId, Uri, Opts},
        nksip:call(App, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started registration serie.
-spec stop_register(nksip:app_name()|nksip:app_id(), term()) -> 
    ok | not_found.

stop_register(App, RegId) ->
    nksip:call(App, {'$nksip_uac_auto_stop_register', RegId}).
    

%% @doc Get current registration status.
-spec get_registers(nksip:app_name()|nksip:app_id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(App) ->
    nksip:call(App, '$nksip_uac_auto_get_registers').



%% @doc Starts a new automatic ping serie.
-spec start_ping(nksip:app_name()|nksip:app_id(), term(), nksip:user_uri(), 
                 nksip:optslist()) -> 
    {ok, boolean()} | {error, invalid_uri}.


start_ping(App, PingId, Uri, Opts) when is_list(Opts) ->
    try
        case nksip:find_app_id(App) of
            {ok, AppId} -> ok;
            _ -> AppId = throw(invalid_app)
        end,
        case lists:keymember(meta, 1, Opts) of
            true -> throw(meta_not_allowed);
            false -> ok
        end,
        case nksip_uac_lib:make(AppId, 'OPTIONS', Uri, Opts) of
            {ok, _, _} -> ok;
            {error, MakeError} -> throw(MakeError)
        end,
        Msg = {'$nksip_uac_auto_start_ping', PingId, Uri, Opts},
        nksip:call(App, Msg)
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Stops a previously started ping serie.
-spec stop_ping(nksip:app_name()|nksip:app_id(), term()) -> 
    ok | not_found.

stop_ping(App, PingId) ->
    nksip:call(App, {'$nksip_uac_auto_stop_ping', PingId}).
    

%% @doc Get current ping status.
-spec get_pings(nksip:app_name()|nksip:app_id()) -> 
    [{PingId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_pings(App) ->
    nksip:call(App, '$nksip_uac_auto_get_pings').


%% ===================================================================
%% Private
%% ===================================================================


% @private
-spec parse_config(PluginConfig, Unknown, Config) ->
    {ok, Unknown, Config} | {error, term()}
    when PluginConfig::nksip:optslist(), Unknown::nksip:optslist(), 
         Config::nksip:optslist().

parse_config([], Unknown, Config) ->
    {ok, Unknown, Config};

parse_config([Term|Rest], Unknown, Config) ->
    Op = case Term of
        {nksip_uac_auto_timer, Timer} ->
            case is_integer(Timer) andalso Timer>0 of
                true -> update;
                false -> error
            end;
        _ ->
            unknown
    end,
    case Op of
        update ->
            Key = element(1, Term),
            Val = element(2, Term),
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        error ->
            {error, {invalid_config, element(1, Term)}};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.
