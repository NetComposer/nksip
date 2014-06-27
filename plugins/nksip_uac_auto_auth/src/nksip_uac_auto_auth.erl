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

%% @doc NkSIP UAC Auto Authentication Plugin
-module(nksip_uac_auto_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").

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
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Defaults = [
        {nksip_uac_auto_auth_max_tries, 5}
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),
    parse_config(PluginOpts1, [], Config).





%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec parse_config(PluginConfig, Unknown, Config) ->
    {ok, Unknown, Config} | {error, term()}
    when PluginConfig::nksip:optslist(), Unknown::nksip:optslist(), 
         Config::nksip:optslist().

parse_config([], Unknown, Config) ->
    {ok, Unknown, Config};


parse_config([Term|Rest], Unknown, Config) ->
    Op = case Term of
        {nksip_uac_auto_auth_max_tries, Tries} ->
            case is_integer(Tries) andalso Tries>=0 of
                true -> update;
                false -> error
            end;
        {pass, Pass} ->
            case Pass of
                _ when is_list(Pass) -> 
                    {pass, <<>>, list_to_binary(Pass)};
                _ when is_binary(Pass) -> 
                    {pass, <<>>, Pass};
                {Pass0, Realm0} when 
                    (is_list(Pass0) orelse is_binary(Pass0)) andalso
                    (is_list(Realm0) orelse is_binary(Realm0)) ->
                    {pass, nksip_lib:to_binary(Realm0), nksip_lib:to_binary(Pass0)};
                _ ->
                    error
            end;
        {passes, Passes} when is_list(Passes) ->
            Passes0 = nksip_lib:get_value(passes, Config, []),
            {update, Passes++Passes0};
        _ ->
            unknown
    end,
    case Op of
        {pass, Realm1, Pass1} ->
            Passes0 = nksip_lib:get_value(passes, Config, []),
            Passes1 = nksip_lib:store_value(Realm1, Pass1, Passes0),
            Config1 = [{passes, Passes1}|lists:keydelete(passes, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        update ->
            Key = element(1, Term),
            Val = element(2, Term),
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        {update, Val} ->
            Key = element(1, Term),
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        error ->
            {error, {invalid_config, element(1, Term)}};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.


