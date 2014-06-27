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
-include("../../../include/nksip_call.hrl").

-export([check_auth/4]).
-export([version/0, deps/0, parse_config/2, parse_config/3]).

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

%%%%%%%%%%%%%%%%%%%%%%%%


% @doc Called after the UAC processes a response
-spec check_auth(nksip:request(), nksip:response(), nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

check_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = TransId,
        opts = Opts,
        method = Method, 
        code = Code, 
        from = From,
        iter = Iters
    } = UAC,
    IsProxy = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code==401 orelse Code==407) andalso Method/='CANCEL' andalso 
        (not IsProxy)
    of
        true ->
            #call{app_id=AppId, call_id=CallId} = Call,
            Max = case nksip_lib:get_value(nksip_uac_auto_auth_max_tries, Opts) of
                undefined -> 
                    nksip_sipapp_srv:config(AppId, nksip_uac_auto_auth_max_tries);
                Max0 ->
                    Max0
            end,
            case Iters < Max andalso nksip_auth:make_request(Req, Resp, Opts) of
                {ok, Req1} ->
                    {ok, nksip_call_uac_req:resend(Req1, UAC, Call)};
                {error, Error} ->
                    ?debug(AppId, CallId, 
                           "UAC ~p could not generate new auth request: ~p", 
                           [TransId, Error]),    
                    continue;
                false ->
                    continue
            end;
        false ->
            continue
    end.


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
                true -> {update, nksip_uac_auto_auth_max_tries, Tries};
                false -> error
            end;
        {pass, PassTerm} ->
            case get_pass(PassTerm) of
                {ok, Realm, Pass} ->
                    Passes0 = nksip_lib:get_value(passes, Config, []),
                    Passes1 = nksip_lib:store_value(Realm, Pass, Passes0),
                    {update, passes, Passes1};
                error ->
                    error
            end;
        {passes, Passes} when is_list(Passes) ->
            Passes0 = nksip_lib:get_value(passes, Config, []),
            {update, passes, Passes++Passes0};
        _ ->
            unknown
    end,
    case Op of
        {update, Key, Val} ->
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        error ->
            {error, {invalid_config, element(1, Term)}};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.



%% @private
get_pass(PassTerm) ->
    case PassTerm of
        _ when is_list(PassTerm) -> 
            {ok, <<>>, list_to_binary(PassTerm)};
        _ when is_binary(PassTerm) -> 
            {ok, <<>>, PassTerm};
        {Realm, Pass} when 
            (is_list(Realm) orelse is_binary(Realm)) andalso
            (is_list(Pass) orelse is_binary(Pass)) ->
            {ok, nksip_lib:to_binary(Realm), nksip_lib:to_binary(Pass)};
        _ ->
            error
    end.


