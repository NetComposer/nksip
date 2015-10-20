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

%% @doc NkSIP UAC Auto Authentication Plugin
-module(nksip_uac_auto_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-export([check_auth/4, syntax/0]).
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
-spec deps() ->
    [atom()].
    
deps() ->
    [nksip].



plugin_start(#{id:=SrvId, cache:=OldCache}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
    case nkservice_util:parse_syntax(SrvSpec, syntax(), defaults()) of
        {ok, SrvSpec2} ->
            Cache = maps:with([sip_uac_auto_auth_max_tries, sip_pass], SrvSpec2),
            {ok, SrvSpec2#{cache:=maps:merge(OldCache, Cache)}};
        {error, Error} ->
            {stop, Error}
    end.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    SrvSpec2 = maps:without(maps:keys(syntax()), SrvSpec),
    {ok, SrvSpec2}.


syntax() ->
    #{
        sip_uac_auto_auth_max_tries => {integer, 1, none},
        sip_pass => fun parse_passes/3
    }.

defaults() ->
    #{
        sip_uac_auto_auth_max_tries => 5,
        sip_pass => []
    }.


parse_passes(_, Passes, _) when is_list(Passes), not is_integer(hd(Passes)) ->
    check_passes(Passes, []);

parse_passes(_, Pass, _) ->
    check_passes([Pass], []).




% %% @doc Parses this plugin specific configuration
% -spec parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% parse_config(Opts) ->
%     Defaults = [{sip_uac_auto_auth_max_tries, 5}],
%     Opts1 = nklib_util:defaults(Opts, Defaults),
%     do_parse_config(Opts1).
    

% %% @doc Parses this plugin specific configuration
% -spec do_parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% do_parse_config(Opts) ->
%     try
%         case nklib_util:get_value(sip_uac_auto_auth_max_tries, Opts) of
%             undefined ->
%                 ok;
%             Tries when is_integer(Tries), Tries>=0 -> 
%                 ok;
%             _ -> 
%                 throw(sip_uac_auto_auth_max_tries)
%         end,
%         case nklib_util:get_value(pass, Opts) of
%             undefined ->
%                 case nklib_util:get_value(passes, Opts) of
%                     undefined -> 
%                         {ok, Opts};
%                     Passes ->
%                         case check_passes(Passes, []) of
%                             {ok, Passes1} -> 
%                                 {ok, nklib_util:store_value(passes, Passes1, Opts)};
%                             error -> 
%                                 throw(passes)
%                         end
%                 end;
%             Pass ->
%                 case lists:keymember(passes, 1, Opts) of
%                     false -> ok;
%                     true -> throw(passes)
%                 end,
%                 case check_passes([Pass], []) of
%                     {ok, Passes} -> 
%                         {ok, [{passes, Passes}|lists:keydelete(pass, 1, Opts)]};
%                     error -> 
%                         throw(pass)
%                 end
%         end
%     catch
%         throw:OptName -> {error, {invalid_config, OptName}}
%     end.




%% ===================================================================
%% Private
%% ===================================================================


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
            #call{srv_id=SrvId, call_id=CallId} = Call,
            Max = case nklib_util:get_value(sip_uac_auto_auth_max_tries, Opts) of
                undefined -> 
                    SrvId:cache_sip_uac_auto_auth_max_tries();
                Max0 ->
                    Max0
            end,
            DefPasses = SrvId:cache_sip_pass(),
            Passes = case nklib_util:get_value(sip_pass, Opts) of
                undefined -> DefPasses;
                Passes0 -> Passes0++DefPasses
            end,
            case 
                Passes/=[] andalso Iters < Max andalso 
                nksip_auth:make_request(Req, Resp, [{sip_pass, Passes}|Opts]) 
            of
                {ok, Req1} ->
                    {ok, nksip_call_uac:resend(Req1, UAC, Call)};
                {error, Error} ->
                    ?debug(SrvId, CallId, 
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


