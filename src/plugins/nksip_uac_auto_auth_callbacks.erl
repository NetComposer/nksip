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

%% @doc NkSIP Registrar Plugin Callbacks
-module(nksip_uac_auto_auth_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").


-export([nksip_parse_uac_opts/2, nksip_uac_response/4]).
-export([plugin_deps/0, plugin_syntax/0, plugin_config/2]).


%% ===================================================================
%% Plugin specific
%% ===================================================================


plugin_deps() ->
    [nksip].


plugin_syntax() ->
    #{
        sip_uac_auto_auth_max_tries => {integer, 1, none},
        sip_pass => fun parse_passes/3
    }.


plugin_config(Config, _Service) ->
    Tries = maps:get(sip_uac_auto_auth_max_tries, Config, 5),
    Pass = maps:get(sip_pass, Config, []),
    {ok, Config, nksip_uac_auto_auth:make_config(Tries, Pass)}.




%% ===================================================================
%% Core SIP callbacks
%% ===================================================================


%% @doc Called to parse specific UAC options
-spec nksip_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {continue, list()} | {error, term()}.

nksip_parse_uac_opts(#sipmsg{srv =_SrvId}=Req, Opts) ->
    case nklib_config:parse_config(Opts, plugin_syntax()) of
        {ok, Opts2, _Rest} ->
            {continue, [Req, nklib_util:store_values(Opts2, Opts)]};
        {error, Error} ->
            {error, Error}
    end.


% @doc Called after the UAC processes a response
-spec nksip_uac_response(nksip:request(), nksip:response(),
                        nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

nksip_uac_response(Req, Resp, UAC, Call) ->
    nksip_uac_auto_auth:check_auth(Req, Resp, UAC, Call).



%% ===================================================================
%% Internal
%% ===================================================================

parse_passes(_, [], _) ->
    {ok, []};

parse_passes(_, Passes, _) when is_list(Passes), not is_integer(hd(Passes)) ->
    check_passes(Passes, []);

parse_passes(_, Pass, _) ->
    check_passes([Pass], []).



%% @private
check_passes([], Acc) ->
    {ok, lists:reverse(Acc)};

check_passes([PassTerm|Rest], Acc) ->
    case PassTerm of
        _ when is_list(PassTerm) -> 
            check_passes(Rest, [{<<>>, list_to_binary(PassTerm)}|Acc]);
        _ when is_binary(PassTerm) -> 
            check_passes(Rest, [{<<>>, PassTerm}|Acc]);
        {Realm, Pass} when 
            (is_list(Realm) orelse is_binary(Realm)) andalso
            (is_list(Pass) orelse is_binary(Pass)) ->
            Acc1 = [{nklib_util:to_binary(Realm), nklib_util:to_binary(Pass)}|Acc],
            check_passes(Rest, Acc1);
        _ ->
            error
    end.

