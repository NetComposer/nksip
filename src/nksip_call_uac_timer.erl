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

%% @private Call UAC Timers
-module(nksip_call_uac_timer).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([timer/3]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), nksip_call:trans_id(), nksip_call:call()) ->
    nksip_call:call().

timer(Tag, TransId, #call{trans=Trans}=Call) ->
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uac}=UAC ->
            do_timer(Tag, UAC, Call);
        false ->
            ?CALL_LOG(warning, "Call ignoring uac timer (~p, ~p)", [Tag, TransId], Call),
            Call
    end.


%% @private
-spec do_timer(nksip_call_lib:timer(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().


% INVITE retrans
do_timer(timer_a, UAC, Call) ->
    #trans{id=_TransId, request=Req, status=_Status} = UAC,
    case nksip_call_uac_transp:resend_request(Req, []) of
        {ok, _} ->
            ?CALL_LOG(info, "UAC ~p (~p) retransmitting 'INVITE'", [_TransId, _Status], Call),
            UAC1 = nksip_call_lib:retrans_timer(timer_a, UAC, Call),
            update(UAC1, Call);
        {error, _} ->
            ?CALL_LOG(notice, "UAC ~p (~p) could not retransmit 'INVITE'", [_TransId, _Status], Call),
            Reply = {service_unavailable, <<"Resend Error">>},
            {Resp, _} = nksip_reply:reply(Req, Reply),
            nksip_call_uac:response(Resp, Call)
    end;

% INVITE timeout
do_timer(timer_b, #trans{id=_TransId, request=Req, status=_Status}, Call) ->
    ?CALL_LOG(notice, "UAC ~p 'INVITE' (~p) timeout (timer B) fired", [_TransId, _Status], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer B Timeout">>}),
    nksip_call_uac:response(Resp, Call);

% INVITE after provisional
do_timer(timer_c, #trans{id=_TransId, request=Req}, Call) ->
    ?CALL_LOG(notice, "UAC ~p 'INVITE' timer C Fired", [_TransId], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer C Timeout">>}),
    nksip_call_uac:response(Resp, Call);

% Finished in INVITE completed
do_timer(timer_d, #trans{id=_TransId, status=_Status}=UAC, Call) ->
    ?CALL_DEBUG("UAC ~p 'INVITE' (~p) yimer D fired", [_TransId, _Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% INVITE accepted finished
do_timer(timer_m,  #trans{id=_TransId, status=_Status}=UAC, Call) ->
    ?CALL_DEBUG("UAC ~p 'INVITE' (~p) timer M fired", [_TransId, _Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% No INVITE retrans
do_timer(timer_e, UAC, Call) ->
    #trans{id=_TransId, status=_Status, method=_Method, request=Req} = UAC,
    case nksip_call_uac_transp:resend_request(Req, []) of
        {ok, _} ->
            ?CALL_LOG(info, "UAC ~p (~p) retransmitting ~p", [_TransId, _Status, _Method], Call),
            UAC1 = nksip_call_lib:retrans_timer(timer_e, UAC, Call),
            update(UAC1, Call);
        {error, _} ->
            ?CALL_LOG(notice, "UAC ~p (~p) could not retransmit ~p", [_TransId, _Status, _Method], Call),
            Msg = {service_unavailable, <<"Resend Error">>},
            {Resp, _} = nksip_reply:reply(Req, Msg),
            nksip_call_uac:response(Resp, Call)
    end;

% No INVITE timeout
do_timer(timer_f, #trans{id=_TransId, status=_Status, method=_Method, request=Req}, Call) ->
    ?CALL_LOG(notice, "UAC ~p ~p (~p) timeout (timer F) fired", [_TransId, _Method, _Status], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    nksip_call_uac:response(Resp, Call);

% No INVITE completed finished
do_timer(timer_k,  #trans{id=_TransId, status=_Status, method=_Method}=UAC, Call) ->
    ?CALL_DEBUG("UAC ~p ~p (~p) timer K fired", [_TransId, _Method, _Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

do_timer(expire, #trans{id=_TransId, status=Status}=UAC, Call) ->
    UAC1 = UAC#trans{expire_timer=undefined},
    if
        Status==invite_calling; Status==invite_proceeding ->
            ?CALL_DEBUG("UAC ~p 'INVITE' (~p) timer Expire fired, sending CANCEL",
                        [_TransId, Status], Call),
            UAC2 = UAC1#trans{status=invite_proceeding},
            nksip_call_uac:cancel(UAC2, [], update(UAC2, Call));
        true ->
            ?CALL_DEBUG("UAC ~p 'INVITE' (~p) timer Expire fired", [_TransId, Status], Call),
            update(UAC1, Call)
    end.

