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

%% @private Timer (RFC4028) support functions
-module(nksip_call_timer).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([uac_received_422/4, uac_update_timer/3, uas_check_422/2, uas_update_timer/3]).
-export([get_timer/4, proxy_request/2, proxy_response/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_422_TRIES, 5).

%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec get_timer(nksip:request(), nksip:response(), uac|uas, nksip_call:call()) ->
    {refresher | refreshed | none, integer()}.

get_timer(Req, #sipmsg{class={resp, Code, _}}=Resp, Class, Call)
             when Code>=200 andalso Code<300 ->
    #call{app_id=_AppId, opts=#call_opts{app_opts=AppOpts}} = Call,
    Default = nksip_config:get_cached(session_expires, AppOpts),
    {SE, Refresh} = case nksip_parse:session_expires(Resp) of
        {ok, SE0, Refresh0} ->
            {SE0, Refresh0};
        undefined ->            
            case nksip_parse:session_expires(Req) of
                {ok, SE0, Refresh0} -> {SE0, Refresh0};
                _ -> {Default, undefined}
            end;
        invalid ->
            ?call_warning("Invalid Session-Expires in response", [], Call),
            {Default, undefined}
    end,
    Type = case Class==Refresh of
        true -> refresher;
        false when Refresh/=undefined -> refreshed;
        false -> none
    end,
    ?call_info("Session Timer updated (~p, ~p)", [{Class, Refresh, Type}, SE], Call),
    {Type, SE}.


%% @private
-spec uac_update_timer(nksip:method(), nksip:dialog(), nksip_call:call()) ->
    [nksip:header()].

uac_update_timer(Method, Dialog, Call) ->
    #dialog{id=DialogId, invite=Invite} = Dialog,
    case Invite of
        #invite{session_expires=SE, refresh_timer=RefreshTimer} when
                is_integer(SE) andalso (Method=='INVITE' orelse Method=='UPDATE') ->
            {SE1, MinSE} = case 
                nksip_call_dialog:get_meta(nksip_min_se, DialogId, Call)
            of
                undefined -> {SE, undefined};
                CurrMinSE -> {max(SE, CurrMinSE), CurrMinSE}
            end,
            % Do not change the roles, if a refresh is sent from the 
            % refreshed instead of the refresher
            Class = case is_reference(RefreshTimer) of
                true -> uac;
                false -> uas
            end,
            [
                {session_expires, {SE1, Class}} |
                case is_integer(MinSE) of true -> [{min_se, MinSE}]; false -> [] end
            ];
        _ ->
            []
    end.


%% @private
-spec uac_received_422(nksip:request(), nksip:response(), 
                       nksip_call:trans(), nksip_call:call()) ->
    {resend, nksip:request(), nksip_call:call()} | false.

uac_received_422(Req, Resp, UAC, Call) ->
    #sipmsg{dialog_id=DialogId} = Resp,
    #trans{
        method = Method, 
        code = Code, 
        iter = Iter
    } = UAC,
    case 
        Code==422 andalso 
        (Method=='INVITE' orelse Method=='UPDATE') andalso
        Iter < ?MAX_422_TRIES
    of 
        true ->
            case nksip_sipmsg:header(Resp, <<"Min-SE">>, integers) of
                [RespMinSE] ->
                    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
                    ConfigMinSE = nksip_config:get_cached(min_session_expires, AppOpts),
                    CurrentMinSE = case 
                        nksip_call_dialog:get_meta(nksip_min_se, DialogId, Call)
                    of
                        undefined -> ConfigMinSE;
                        CurrentMinSE0 -> CurrentMinSE0
                    end,
                    NewMinSE = max(CurrentMinSE, RespMinSE),
                    Call1 = case NewMinSE of 
                        CurrentMinSE -> 
                            Call;
                        _ -> 
                            nksip_call_dialog:update_meta(nksip_min_se, NewMinSE, 
                                                          DialogId, Call)
                    end,
                    case nksip_parse:session_expires(Req) of
                        {ok, SE0, Class0} ->
                            SE1 = max(SE0, NewMinSE),
                            SEHd = case Class0 of
                                uac -> {SE1, [{<<"refresher">>, <<"uac">>}]};
                                uas -> {SE1, [{<<"refresher">>, <<"uas">>}]};
                                undefined -> SE1
                            end,
                            Headers1 = nksip_headers:update(Req, [
                                {single, <<"Session-Expires">>, SEHd},
                                {single, <<"Min-SE">>, NewMinSE}
                            ]),
                            Req1 = Req#sipmsg{headers=Headers1},
                            {resend, Req1, Call1};
                        _ -> 
                            false
                    end;
                _ ->
                    false
            end;
        false ->
            false
    end.


%% @private
-spec uas_check_422(nksip:request(), nksip_call:call()) ->
    continue | {update, nksip:request(), nksip_call:call()} | 
               {reply, nksip:user_reply(), nksip_call:call()}.

uas_check_422(#sipmsg{class={req, Method}}=Req, Call) ->
    case Method=='INVITE' orelse Method=='UPDATE' of
        true ->
            case nksip_parse:session_expires(Req) of
                undefined ->
                    continue;
                invalid ->
                    {reply, invalid_request, Call};
                {ok, SE, _} ->
                    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
                    case nksip_config:get_cached(min_session_expires, AppOpts) of
                        MinSE when SE < MinSE ->
                            #sipmsg{dialog_id=DialogId} = Req,
                            Call1 = case 
                                nksip_call_dialog:get_meta(nksip_min_se, DialogId, Call)
                            of
                                MinSE -> Call;
                                _ -> nksip_call_dialog:update_meta(nksip_min_se, MinSE, 
                                                                   DialogId, Call)
                            end,
                            case nksip_sipmsg:supported(Req, <<"timer">>) of
                                true ->
                                    {reply, {422, [{<<"Min-SE">>, MinSE}]}, Call1};
                                false ->
                                    % No point in returning 422
                                    % Update in case we are a proxy
                                    Headers1 = nksip_headers:update(Req, 
                                                    [{single, <<"Min-SE">>, MinSE}]),
                                    {update, Req#sipmsg{headers=Headers1}, Call1}
                            end;
                        _ ->
                            continue
                    end
            end;
        false ->
            continue
    end.




%% @private
-spec uas_update_timer(nksip:request(), nksip:response(), nksip_call:call()) ->
    nksip:response().

uas_update_timer(
        Req, #sipmsg{class={resp, Code, _}, cseq_method=Method}=Resp, Call)
        when Code>=200 andalso Code<300 andalso 
             (Method=='INVITE' orelse Method=='UPDATE') ->
    case nksip_sipmsg:supported(Resp, <<"timer">>) of
        true ->
            #sipmsg{require=Require} = Resp,
            #call{opts=#call_opts{app_opts=AppOpts}} = Call,
            ReqSupport = nksip_sipmsg:supported(Req, <<"timer">>), 
            ReqMinSE = case nksip_sipmsg:header(Req, <<"Min-SE">>, integers) of
                [ReqMinSE0] -> ReqMinSE0;
                _ -> 90
            end,
            {ReqSE, ReqRefresh} = case 
                ReqSupport andalso nksip_parse:session_expires(Req) 
            of
                {ok, ReqSE0, ReqRefresh0} -> {ReqSE0, ReqRefresh0};
                _ -> {0, undefined}
            end,
            Default = nksip_config:get_cached(session_expires, AppOpts),
            SE = case ReqSE of
                0 -> max(ReqMinSE, Default);
                _ -> max(ReqMinSE, min(ReqSE, Default))
            end,
            Refresh = case ReqRefresh of
                uac -> <<"uac">>;
                uas -> <<"uas">>;
                undefined -> <<"uas">>
            end,
            SE_Token = {SE, [{<<"refresher">>, Refresh}]},
            Headers1 = nksip_headers:update(Resp, 
                            [{default_single, <<"Session-Expires">>, SE_Token}]),
            % Add 'timer' to response's Require only if supported by uac
            Require1 = case ReqSupport of
                true -> nksip_lib:store_value(<<"timer">>, Require);
                false -> Require
            end,
            Resp#sipmsg{require=Require1, headers=Headers1};
        false ->
            Resp
    end;

uas_update_timer(_Req, Resp, _Call) ->
    Resp.


%% @private
-spec proxy_request(nksip:request(), nksip_call:call()) ->
    nksip:request().

proxy_request(#sipmsg{class={req, Method}}=Req, Call)
                 when Method=='INVITE'; Method=='UPDATE' ->
    ReqMinSE = case nksip_sipmsg:header(Req, <<"Min-SE">>, integers) of
        [ReqMinSE0] -> ReqMinSE0;
        _ -> 90
    end,
    ReqSE = case nksip_parse:session_expires(Req) of
        {ok, ReqSE0, _} -> ReqSE0;
        _ -> 0
    end,
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    Default = nksip_config:get_cached(session_expires, AppOpts),
    SE = case ReqSE of
        0 -> max(ReqMinSE, Default);
        _ -> max(ReqMinSE, min(ReqSE, Default))
    end,
    case SE of
        ReqSE -> 
            Req;
        _ -> 
            Headers1 = nksip_headers:update(Req, [{single, <<"Session-Expires">>, SE}]),
            Req#sipmsg{headers=Headers1}
    end;

proxy_request(Req, _Call) ->
    Req.


%% @private
-spec proxy_response(nksip:request(), nksip:response()) ->
    nksip:response().

proxy_response(Req, Resp) ->
    case nksip_parse:session_expires(Resp) of
        {ok, _, _} ->
            Resp;
        undefined ->
            case nksip_parse:session_expires(Req) of
                {ok, SE, _} ->
                    case nksip_sipmsg:supported(Req, <<"timer">>) of
                        true ->
                            SE_Token = {SE, [{<<"refresher">>, <<"uac">>}]},
                            Headers1 = nksip_headers:update(Resp, 
                                [{single, <<"Session-Expires">>, SE_Token}]),
                            #sipmsg{require=Require} = Resp,
                            Require1 = nksip_lib:store_value(<<"timer">>, Require),
                            Resp#sipmsg{require=Require1, headers=Headers1};
                        false ->
                            Resp
                    end;
                _ ->
                    Resp
            end
    end.




