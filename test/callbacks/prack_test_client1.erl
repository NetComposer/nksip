%% -------------------------------------------------------------------
%%
%% prack_test: Reliable provisional responses test
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

-module(prack_test_client1).

-include_lib("nkserver/include/nkserver_module.hrl").
-include_lib("nksip/include/nksip.hrl").


-export([sip_invite/2, sip_ack/2, sip_prack/2, sip_dialog_update/3, sip_session_update/3]).

sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    {ok, SrvId} = nksip_request:pkg_id(Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            case Op of
                <<"prov-busy">> ->
                    ok = nksip_request:reply(ringing, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(session_progress, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(busy, ReqId);
                <<"rel-prov-busy">> ->
                    ok = nksip_request:reply(rel_ringing, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(rel_session_progress, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(busy, ReqId);
                <<"pending">> ->
                    spawn(
                        fun() -> 
                            ok = nksip_request:reply(rel_ringing, ReqId)
                        end),
                    spawn(
                        fun() -> 
                            {error, pending_prack} = 
                                nksip_request:reply(rel_session_progress, ReqId),
                            tests_util:send_ref(pending_prack_ok, Req)
                        end),
                    timer:sleep(100),
                    ok = nksip_request:reply(busy, ReqId);
                <<"rel-prov-answer">> ->
                    SDP = case nksip_request:body(Req) of
                        {ok, #sdp{} = RemoteSDP} ->
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nklib_util:to_binary(SrvId)}};
                        {ok, _} -> 
                            <<>>
                    end,
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    SDP1 = nksip_sdp:increment(SDP),
                    ok = nksip_request:reply({rel_session_progress, SDP1}, ReqId),
                    timer:sleep(100),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({answer, SDP2}, ReqId);
                <<"rel-prov-answer2">> ->
                    SDP = case nksip_request:body(Req) of
                        {ok, #sdp{} = RemoteSDP} ->
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nklib_util:to_binary(SrvId)}};
                        {ok, _} -> 
                            <<>>
                    end,
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    nksip_request:reply(ok, ReqId);
                <<"rel-prov-answer3">> ->
                    SDP = nksip_sdp:new(nklib_util:to_binary(SrvId),
                                        [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    nksip_request:reply(ok, ReqId);
                <<"retrans">> ->
                    spawn(
                        fun() ->
                            nksip_request:reply(ringing, ReqId),
                            timer:sleep(2000),
                            nksip_request:reply(busy, ReqId)
                        end);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_prack(Req, _Call) ->
    {ok, RAck} = nksip_request:get_meta(rack, Req),
    tests_util:send_ref({prack, RAck}, Req),
    Body = case nksip_request:body(Req) of
        {ok, #sdp{} = RemoteSDP} ->
            {ok, SrvId} = nksip_request:pkg_id(Req),
            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nklib_util:to_binary(SrvId)}};
        {ok, _} -> 
            <<>>
    end,        
    {reply, {answer, Body}}.


sip_dialog_update(Update, Dialog, _Call) ->
    tests_util:dialog_update(Update, Dialog),
    ok.


sip_session_update(Update, Dialog, _Call) ->
    tests_util:session_update(Update, Dialog),
    ok.


