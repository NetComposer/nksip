%% -------------------------------------------------------------------
%%
%% uac_test: Basic Test Suite
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

-module(uac_test_client1).
-export([sip_invite/2, sip_options/2, sip_info/2, sip_message/2]).

-include_lib("nkserver/include/nkserver_module.hrl").

sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    Sleep = case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> nklib_util:to_integer(Sleep0);
        {ok, _} -> 0
    end,
    Prov = case nksip_request:header(<<"x-nk-prov">>, Req) of
        {ok, [<<"true">>]} -> true;
        {ok, _} -> false
    end,
    {ok, ReqId} = nksip_request:get_handle(Req),
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(ringing, ReqId); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip_request:reply({ok, []}, ReqId);
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip_request:reply({ok, [{body, SDP}]}, ReqId);
                <<"busy">> ->
                    nksip_request:reply(busy, ReqId);
                <<"increment">> ->
                    {ok, SDP1} = nksip_dialog:get_meta(invite_local_sdp, DialogId),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({ok, [{body, SDP2}]}, ReqId);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_options(Req, _Call) ->
    case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> 
            {ok, ReqId} = nksip_request:get_handle(Req),
            spawn(
                fun() ->
                    nksip_request:reply(101, ReqId), 
                    timer:sleep(nklib_util:to_integer(Sleep0)),
                    nksip_request:reply({ok, [contact]}, ReqId)
                end),
            noreply; 
        {ok, _} -> 
            {reply, {ok, [contact]}}
    end.


sip_info(Req, _Call) ->
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    {reply, {ok, [{add, "x-nk-method", "info"}, {add, "x-nk-dialog", DialogId}]}}.


sip_message(Req, _Call) ->
    case nksip_request:header(<<"x-nk-reply">>, Req) of
        {ok, [RepBin]} ->
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            {ok, [
                {_, Expires},
                {_, [Date]},
                {_, [ContentType]},
                {_, Body}

            ]} = nksip_request:get_metas([expires, <<"date">>, <<"content-type">>, body], Req),
            Pid ! {Ref, {ok, Expires, Date, ContentType, Body}},
            {reply, ok};
        {ok, _} ->
            {reply, decline}
    end.

