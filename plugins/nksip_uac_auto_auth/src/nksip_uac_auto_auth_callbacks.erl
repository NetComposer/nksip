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

%% @doc NkSIP Registrar Plugin Callbacks
-module(nksip_uac_auto_auth_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").


-export([nkcb_parse_uac_opt/3, nkcb_uac_response/4]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Called to parse specific UAC options
-spec nkcb_parse_uac_opt(nksip:optslist(), nksip:request(), nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uac_opt(PluginOpts, #sipmsg{app_id=AppId}=Req, Opts) ->
    AppPasses = nksip_sipapp_srv:get_config(AppId, passes, []),
    PluginOpts1 = [{passes, AppPasses}|PluginOpts],
    case nksip_uac_auto_auth:parse_config(PluginOpts1, [], Opts) of
        {ok, Unknown, Config1} ->
            {continue, [Unknown, Req, Config1]};
        {error, Error} ->
            {error, Error}
    end.




    case Pass of
        Pass0 when is_list(Pass0); is_binary(Pass0) -> 
            Pass1 = nksip_lib:to_binary(Pass0),
            Passes1 = nksip_lib:store_value(<<>>, Pass1, Passes0),
            Opts1 = nksip_lib:store_value(passes, Passes1, Opts),
            {ok, {update, Req, Opts1}};
        {Pass0, Realm0} when 
            (is_list(Pass0) orelse is_binary(Pass0)) andalso
            (is_list(Realm0) orelse is_binary(Realm0)) ->
            Pass1 = nksip_lib:to_binary(Pass0),
            Realm1 = nksip_lib:to_binary(Realm0),
            Passes1 = nksip_lib:store_value(Realm1, Pass1, Passes0),
            Opts1 = nksip_lib:store_value(passes, Passes1, Opts),
            {ok, {update, Req, Opts1}};
        _ ->
            error
    end;

nkcb_parse_uac_opt({passes, Passes}, Req, Opts) ->
    Passes0 = nksip_lib:get_value(passes, Opts, []),
    Opts1 = nksip_lib:store_value(passes, Passes++Passes0, Opts),
    {update, Req, Opts1};

        
nkcb_parse_uac_opt(_Term, _Req, _Opts) ->
    continue.



% @doc Called after the UAC processes a response
-spec nkcb_uac_response(nksip:request(), nksip:response(), 
                        nksip_call:trans(), nksip:call()) ->
    {ok, nksip:request(), nksip:response(), nksip_call:trans(), nksip:call()}.

nkcb_uac_response(Req, Resp, UAC, Call) ->
     #trans{
        id = Id,
        opts = Opts,
        method = Method, 
        code = Code, 
        from = From,
        iter = Iters
    } = UAC,
    #call{app_id=AppId, call_id=CallId} = Call,
    IsProxy = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code==401 orelse Code==407) andalso Method/='CANCEL' andalso 
        (not IsProxy)
    of
        true ->
            Max = nksip_sipapp_srv:config(AppId, nksip_uac_auto_auth_max_tries),
            case Iters < Max andalso nksip_auth:make_request(Req, Resp, Opts) of
                {ok, Req1} ->
                    Call1 = nksip_call_uac_req:resend(Req1, UAC, Call),
                    {ok, Req, Resp, UAC, Call1};
                {error, Error} ->
                    ?debug(AppId, CallId, 
                           "UAC ~p could not generate new auth request: ~p", [Id, Error]),    
                    continue;
                false ->
                    continue
            end;
        false ->
            continue
    end.
