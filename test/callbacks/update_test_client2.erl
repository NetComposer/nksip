%% -------------------------------------------------------------------
%%
%% update_test: UPDATE method test
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

-module(update_test_client2).

-include_lib("nkserver/include/nkserver_module.hrl").
-include_lib("nksip/include/nksip.hrl").

-export([sip_invite/2, sip_ack/2, sip_update/2, sip_dialog_update/3, sip_session_update/3]).

sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    {ok, Body} = nksip_request:body(Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            case Op of
                <<"basic">> ->
                    SDP1 = nksip_sdp:increment(Body),
                    ok = nksip_request:reply({rel_ringing, SDP1}, ReqId),
                    timer:sleep(500),
                    nksip_request:reply(ok, ReqId);
                <<"pending1">> ->
                    ok = nksip_request:reply(ringing, ReqId), 
                    timer:sleep(100),
                    nksip_request:reply(ok, ReqId);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_update(Req, _Call) ->
    tests_util:send_ref(update, Req),
    Body = case nksip_request:body(Req) of
        {ok, #sdp{} = SDP} -> nksip_sdp:increment(SDP);
        {ok, _} -> <<>>
    end,        
    {reply, {answer, Body}}.


sip_dialog_update(Update, Dialog, _Call) ->
    tests_util:dialog_update(Update, Dialog),
    ok.


sip_session_update(Update, Dialog, _Call) ->
    tests_util:session_update(Update, Dialog),
    ok.

