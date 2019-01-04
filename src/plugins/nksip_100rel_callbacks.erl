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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_100rel_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([sip_prack/2]).
-export([nksip_parse_uac_opts/2,
         nksip_uac_pre_response/3, nksip_uac_response/4,
         nksip_parse_uas_opt/3, nksip_uas_timer/3,
         nksip_uas_send_reply/3, nksip_uas_sent_reply/1, nksip_uas_method/4]).



%% ===================================================================
%% Specific
%% ===================================================================


%% @doc Called when a valid PRACK request is received.
-spec sip_prack(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_prack(_Req, _Call) ->
    {reply, ok}.



%% ===================================================================
%% SIP Core
%% ===================================================================


%% @doc Called to parse specific UAC options
-spec nksip_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {error, term()}|{continue, list()}.

nksip_parse_uac_opts(Req, Opts) ->
    case lists:keyfind(prack_callback, 1, Opts) of
        {prack_callback, Fun} when is_function(Fun, 2) ->
            {continue, [Req, Opts]};
        {prack_callback, _} ->
            {error, {invalid_config, prack_callback}};
        false ->
            {continue, [Req, Opts]}
    end.


%% @doc Called after the UAC pre processes a response
-spec nksip_uac_pre_response(nksip:response(),  nksip_call:trans(), nksip:call()) ->
    {ok, nksip:call()} | continue.

nksip_uac_pre_response(Resp, UAC, Call) ->
    case nksip_100rel:is_prack_retrans(Resp, UAC) of
        true ->
            ?CALL_LOG(info, "UAC received retransmission of reliable provisional "
                       "response", [], Call),
            {ok, Call};
        false ->
            continue
    end.


%% @doc Called after the UAC processes a response
-spec nksip_uac_response(nksip:request(), nksip:response(),
                        nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

nksip_uac_response(_Req, Resp, UAC, Call) ->
    #trans{id=Id, from=From, method=Method} = UAC,
    #sipmsg{
        class = {resp, Code, _Reason}, 
        dialog_id = DialogId,
        require = Require
    } = Resp,
    case From of
        {fork, _} ->
            continue;
        _ when Method=='INVITE', Code>100, Code<200 ->
            case lists:member(<<"100rel">>, Require) of
                true ->
                    nksip_100rel:send_prack(Resp, Id, DialogId, Call);
                false ->
                    continue
            end;
        _ ->
            continue
    end.


%% @doc Called to parse specific UAS options
-spec nksip_parse_uas_opt(nksip:request(), nksip:response(), nksip:optslist()) ->
    {continue, list()}.

nksip_parse_uas_opt(Req, Resp, Opts) ->
    #sipmsg{class={req, Method}, require=ReqRequire, supported=ReqSupported} = Req,
    #sipmsg{class={resp, Code, _}, require=RespRequire} = Resp,
    case 
        (Method=='INVITE' andalso Code>100 andalso Code<200
        andalso lists:member(<<"100rel">>, ReqRequire))
        orelse
        lists:member(do100rel, Opts) 
    of
        true ->
            case lists:member(<<"100rel">>, ReqSupported) of
                true -> 
                    Resp1 = case lists:member(<<"100rel">>, RespRequire) of
                        true ->
                            Resp;
                        false ->
                            Resp#sipmsg{require=[<<"100rel">>|RespRequire]}
                    end,
                    Opts1 = nklib_util:delete(Opts, do100rel),
                    {continue, [Req, Resp1, Opts1]};
                false -> 
                    Opts1 = nklib_util:delete(Opts, do100rel),
                    {continue, [Req, Resp, Opts1]}
            end;
        false ->
            {continue, [Req, Resp, Opts]}
    end.


%% @doc Called when a new reponse is going to be sent
-spec nksip_uas_send_reply({nksip:response(), nksip:optslist()},
                             nksip_call:trans(), nksip_call:call()) ->
    {continue, list()} | {error, term()}.

nksip_uas_send_reply({Resp, SendOpts}, UAS, Call) ->
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true ->
            case nksip_100rel:uas_store_info(Resp, UAS) of
                {ok, Resp1, UAS1} ->
                    {continue, [{Resp1, SendOpts}, UAS1, Call]};
                {error, Error} ->
                    {error, Error}
            end;
        false -> 
            {continue, [{Resp, SendOpts}, UAS, Call]}
    end.


%% @doc Called when a new reponse is sent
-spec nksip_uas_sent_reply(nksip_call:call()) ->
    {ok, nksip_call:call()} | {continue, list()}.

nksip_uas_sent_reply(#call{trans=[UAS|_]}=Call) ->
    #trans{status=Status, response=Resp, code=Code} = UAS,
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true when Status==invite_proceeding, Code<200 ->
            UAS1 = nksip_100rel:timeout_timer(UAS, Call),
            UAS2 = nksip_100rel:retrans_timer(UAS1, Call),
            {ok, nksip_call_lib:update(UAS2, Call)};
        _ ->
            {continue, [Call]}
    end.



 %% @doc Called when a new request has to be processed
-spec nksip_uas_method(nksip:method(), nksip:request(),
                      nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:trans(), nksip_call:call()} | {continue, list()}.

nksip_uas_method('PRACK', Req, UAS, Call) ->
    {UAS1, Call1} = nksip_100rel:uas_method(Req, UAS, Call),
    {ok, UAS1, Call1};

nksip_uas_method(Method, Req, UAS, Call) ->
    {continue, [Method, Req, UAS, Call]}.


%% @doc Called when a UAS timer is fired
-spec nksip_uas_timer(nksip_call_lib:timer()|term(), nksip_call:trans(),
                        nksip_call:call()) ->
    {ok, nksip_call:call()} | continue.

nksip_uas_timer(nksip_100rel_prack_retrans, #trans{id=_Id, response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, _Code, _Reason}} = Resp,
    UAS2 = case nksip_call_uas_transp:resend_response(Resp, []) of
        {ok, _} ->
            ?CALL_LOG(info, "UAS ~p retransmitting 'INVITE' ~p reliable response",
                       [_Id, _Code], Call),
            nksip_100rel:retrans_timer(UAS, Call);
        {error, _} -> 
            ?CALL_LOG(notice, "UAS ~p could not retransmit 'INVITE' ~p reliable response",
                         [_Id, _Code], Call),
            UAS1 = UAS#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAS1, Call)
    end,
    {ok, nksip_call_lib:update(UAS2, Call)};

nksip_uas_timer(nksip_100rel_prack_timeout, #trans{id=_Id, method=_Method}=UAS, Call) ->
    ?CALL_LOG(notice, "UAS ~p ~p reliable provisional response timeout", [_Id, _Method], Call),
    Reply = {internal_error, <<"Reliable Provisional Response Timeout">>},
    {ok, nksip_call_uas:do_reply(Reply, UAS, Call)};

nksip_uas_timer(_Tag, _UAS, _Call) ->
    continue.
