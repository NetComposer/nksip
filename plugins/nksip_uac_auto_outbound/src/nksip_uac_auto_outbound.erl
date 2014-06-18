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
-module(nksip_uac_auto_outbound).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_register/5, stop_register/2, get_registers/1]).
-export([version/0, deps/0, parse_config/2]).


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
    [{nksip_uac_auto, "^0\."}].


%% @doc Parses this plugin specific configuration
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Defaults = [
        {nksip_uac_auto_outbound_all_fail, 30},        % (secs)
        {nksip_uac_auto_outbound_any_ok, 90},          % (secs)
        {nksip_uac_auto_outbound_max_time, 1800}       % (secs)
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),
    parse_config(PluginOpts1, [], Config).



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nksip:app_name()|nksip:app_id(), term(), nksip:user_uri(), pos_integer(),
                        nksip:optslist()) -> 
    {ok, boolean()} | {error, invalid_uri}.

start_register(App, RegId, Uri, Time, Opts) 
                when is_integer(Time), Time > 0, is_list(Opts) ->
    case nksip_parse:uris(Uri) of
        [ValidUri] -> 
            Msg = {'$nksip_uac_auto_start_register', RegId, ValidUri, Time, Opts},
            nksip:call(App, Msg);
        _ -> 
            {error, invalid_uri}
    end.


%% @doc Stops a previously started registration serie.
-spec stop_register(nksip:app_name()|nksip:app_id(), term()) -> 
    ok | not_found.

stop_register(App, RegId) ->
    nksip_uac_auto:stop_register(App, RegId).
    

%% @doc Get current registration status.
-spec get_registers(nksip:app_name()|nksip:app_id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(App) ->
    nksip_uac_auto:get_registers(App).



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
        {nksip_uac_auto_outbound_all_fail, Secs} ->
            case is_integer(Secs) andalso Secs>=1 of
                true -> update;
                false -> error
            end;
        {nksip_uac_auto_outbound_any_ok, Secs} ->
            case is_integer(Secs) andalso Secs>=1 of
                true -> update;
                false -> error
            end;
        {nksip_uac_auto_outbound_max_time, Secs} -> 
            case is_integer(Secs) andalso Secs>=1 of
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

