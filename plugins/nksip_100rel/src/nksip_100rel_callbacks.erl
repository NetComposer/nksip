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
         nkcb_parse_uas_opt/4,
         nkcb_uas_sent_reply/3, nkcb_uas_method/4]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%



%% @doc Called to parse specific UAC options
-spec nkcb_parse_uac_opt(nksip:optslist(), nksip:request(), nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uac_opt(PluginOpts, Req, Opts) ->
    case nksip_100rel:parse_config(PluginOpts, [], Opts) of
        {ok, Unknown, Opts2} ->
            {continue, [Unknown, Req, Opts2]};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Called after the UAC pre processes a response
-spec nkcb_uac_pre_response(nksip:response(),  nksip_call:trans(), nksip:call()) ->
    {ok, nksip:call()} | continue.

nkcb_uac_pre_response(Resp, UAC, Call) ->
    case nksip_100rel:is_prack_retrans(Resp, UAC) of
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
    nksip_100rel:maybe_send_prack(Resp, UAC, Call).


%% @doc Called to parse specific UAS options
-spec nkcb_parse_uas_opt(nksip:optslist(), nksip:request(), nksip:response(), 
                         nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uas_opt(PluginOpts, Req, Resp, Opts) ->
    case lists:member(do100rel, PluginOpts) of
        true ->
            case lists:member(<<"100rel">>, Req#sipmsg.supported) of
                true -> 
                    case lists:keymember(require, 1, Opts) of
                        true -> 
                            move_to_last;
                        false ->
                            #sipmsg{require=Require} = Resp,
                            Require1 = nksip_lib:store_value(<<"100rel">>, Require),
                            Resp1 = Resp#sipmsg{require=Require1},
                            PluginOpts1 = PluginOpts -- [do100rel],
                            {continue, [PluginOpts1, Req, Resp1, Opts]}
                    end;
                false -> 
                    PluginOpts1 = PluginOpts -- [do100rel],
                    {continue, [PluginOpts1, Req, Resp, Opts]}
            end;
        false ->
            {continue, [PluginOpts, Req, Resp, Opts]}
    end.


%% @doc Called when a new reponse has been sent
-spec nkcb_uas_sent_reply({nksip:response(), nksip:optlist()}, 
                             nksip_call:trans(), nksip_call:call()) ->
    {continue, list()} | {error, term()}.

nkcb_uas_sent_reply({Resp, SendOpts}, UAS, Call) ->
    case lists:member(rseq, SendOpts) of
        true ->
            case nksip_100rel:uas_check_prack(Resp, UAS) of
                {ok, Resp1, UAS1} ->
                    {continue, [{Resp1, SendOpts}, UAS1, Call]};
                {error, Error} ->
                    {error, Error}
            end;
        false -> 
            {continue, [{Resp, SendOpts}, UAS, Call]}
    end.



 %% @doc Called when a new request has to be processed
-spec nkcb_uas_method(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:trans(), nksip_call:call()} | {continue, list()}.

nkcb_uas_method('PRACK', Req, UAS, Call) ->
    {UAS1, Call1} = nksip_100rel:uas_method(Req, UAS, Call),
    {ok, UAS1, Call1};

nkcb_uas_method(Method, Req, UAS, Call) ->
    {continue, [Method, Req, UAS, Call]}.

