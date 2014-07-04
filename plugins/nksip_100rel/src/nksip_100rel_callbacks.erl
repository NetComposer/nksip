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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_100rel_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").

-export([nkcb_parse_uac_opt/3, 
         nkcb_uac_pre_response/3, nkcb_uac_response/4, 
         nkcb_parse_uas_opt/4, nkcb_uas_timer/3,
         nkcb_uas_send_reply/3, nkcb_uas_sent_reply/1, nkcb_uas_method/4]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%



%% @doc Called to parse specific UAC options
-spec nkcb_parse_uac_opt(nksip:optslist(), nksip:request(), nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uac_opt(PluginOpts, Req, Opts) ->
    case nksip_100rel_lib:parse_config(PluginOpts, [], Opts) of
        {ok, Unknown, Opts2} ->
            {continue, [Unknown, Req, Opts2]};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Called after the UAC pre processes a response
-spec nkcb_uac_pre_response(nksip:response(),  nksip_call:trans(), nksip:call()) ->
    {ok, nksip:call()} | continue.

nkcb_uac_pre_response(Resp, UAC, Call) ->
    case nksip_100rel_lib:is_prack_retrans(Resp, UAC) of
        true ->
            ?call_info("UAC received retransmission of reliable provisional "
                       "response", []),
            {ok, Call};
        false ->
            continue
    end.


%% @doc Called after the UAC processes a response
-spec nkcb_uac_response(nksip:request(), nksip:response(), 
                        nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

nkcb_uac_response(_Req, Resp, UAC, Call) ->
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
                true -> nksip_100rel_lib:send_prack(Resp, Id, DialogId, Call);
                false -> continue
            end;
        _ ->
            continue
    end.


%% @doc Called to parse specific UAS options
-spec nkcb_parse_uas_opt(nksip:optslist(), nksip:request(), nksip:response(), 
                         nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uas_opt(PluginOpts, Req, Resp, Opts) ->
    #sipmsg{class={req, Method}, require=ReqRequire, supported=ReqSupported} = Req,
    #sipmsg{class={resp, Code, _}, require=RespRequire} = Resp,
    case 
        (Method=='INVITE' andalso Code>100 andalso Code<200
        andalso lists:member(<<"100rel">>, ReqRequire))
        orelse
        lists:member(do100rel, PluginOpts) 
    of
        true ->
            case lists:member(<<"100rel">>, ReqSupported) of
                true -> 
                    Resp1 = case lists:member(<<"100rel">>, RespRequire) of
                        true -> Resp;
                        false -> Resp#sipmsg{require=[<<"100rel">>|RespRequire]}
                    end,
                    PluginOpts1 = PluginOpts -- [do100rel],
                    {continue, [PluginOpts1, Req, Resp1, Opts]};
                false -> 
                    PluginOpts1 = PluginOpts -- [do100rel],
                    {continue, [PluginOpts1, Req, Resp, Opts]}
            end;
        false ->
            {continue, [PluginOpts, Req, Resp, Opts]}
    end.


%% @doc Called when a new reponse is going to be sent
-spec nkcb_uas_send_reply({nksip:response(), nksip:optlist()}, 
                             nksip_call:trans(), nksip_call:call()) ->
    {continue, list()} | {error, term()}.

nkcb_uas_send_reply({Resp, SendOpts}, UAS, Call) ->
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true ->
            case nksip_100rel_lib:uas_store_info(Resp, UAS) of
                {ok, Resp1, UAS1} ->
                    {continue, [{Resp1, SendOpts}, UAS1, Call]};
                {error, Error} ->
                    {error, Error}
            end;
        false -> 
            {continue, [{Resp, SendOpts}, UAS, Call]}
    end.


%% @doc Called when a new reponse is sent
-spec nkcb_uas_sent_reply(nksip_call:call()) ->
    {ok, nksip_call:call()} | {continue, list()}.

nkcb_uas_sent_reply(#call{trans=[UAS|_]}=Call) ->
    #trans{status=Status, response=Resp, code=Code} = UAS,
    case nksip_sipmsg:require(<<"100rel">>, Resp) of
        true when Status==invite_proceeding, Code<200 ->
            UAS1 = nksip_100rel_lib:timeout_timer(UAS, Call),
            UAS2 = nksip_100rel_lib:retrans_timer(UAS1, Call),
            {ok, nksip_call_lib:update(UAS2, Call)};
        _ ->
            {continue, [Call]}
    end.



 %% @doc Called when a new request has to be processed
-spec nkcb_uas_method(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:trans(), nksip_call:call()} | {continue, list()}.

nkcb_uas_method('PRACK', Req, UAS, Call) ->
    {UAS1, Call1} = nksip_100rel_lib:uas_method(Req, UAS, Call),
    {ok, UAS1, Call1};

nkcb_uas_method(Method, Req, UAS, Call) ->
    {continue, [Method, Req, UAS, Call]}.


%% @doc Called when a UAS timer is fired
-spec nkcb_uas_timer(nksip_call_lib:timer()|term(), nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:call()} | continue.

nkcb_uas_timer(nksip_100rel_prack_retrans, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    UAS2 = case nksip_transport_uas:resend_response(Resp, []) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p reliable response", 
                       [Id, Code]),
            nksip_100rel_lib:retrans_timer(UAS, Call);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p reliable response", 
                         [Id, Code]),
            UAS1 = UAS#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAS1, Call)
    end,
    {ok, nksip_call_lib:update(UAS2, Call)};

nkcb_uas_timer(nksip_100rel_prack_timeout, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p reliable provisional response timeout", [Id, Method]),
    Reply = {internal_error, <<"Reliable Provisional Response Timeout">>},
    {_, Call1} = nksip_call_uas_reply:reply(Reply, UAS, Call),
    {ok, Call1};

nkcb_uas_timer(_Tag, _UAS, _Call) ->
    continue.
