%% -------------------------------------------------------------------
%%
%% auth_test: Authentication Tests
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

-module(auth_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

auth_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
          fun digest/0, 
          fun invite/0, 
          fun dialog/0, 
          fun proxy/0
      ]
  }.


start() ->
    tests_util:start_nksip(),
    ok = sipapp_server:start({auth, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}}]),

    ok = sipapp_server:start({auth, server2}, [
        {from, "sip:server2@nksip"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({auth, client1}, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}}]),
    
    ok = sipapp_endpoint:start({auth, client2}, [
        {from, "sip:client2@nksip"},
        {pass, "jj"},
        {pass, {"4321", "client1"}},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({auth, client3}, [
        {from, "sip:client3@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5072}}]),
    
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_server:stop({auth, server1}),
    ok = sipapp_server:stop({auth, server2}),
    ok = sipapp_endpoint:stop({auth, client1}),
    ok = sipapp_endpoint:stop({auth, client2}),
    ok = sipapp_endpoint:stop({auth, client3}).


digest() ->
    C1 = {auth, client1},
    C2 = {auth, client2},
    SipC1 = "sip:127.0.0.1:5070",
    SipC2 = "sip:127.0.0.1:5071",

    {ok, 401, []} = nksip_uac:options(C1, SipC2, []),
    {ok, 200, []} = nksip_uac:options(C1, SipC2, [{pass, "1234"}]),
    {ok, 403, []} = nksip_uac:options(C1, SipC2, [{pass, "12345"}]),
    {ok, 200, []} = nksip_uac:options(C1, SipC2, [{pass, {"1234", "client2"}}]),
    {ok, 403, []} = nksip_uac:options(C1, SipC2, [{pass, {"1234", "other"}}]),

    HA1 = nksip_auth:make_ha1("client1", "1234", "client2"),
    {ok, 200, []} = nksip_uac:options(C1, SipC2, [{pass, HA1}]),
    
    % Pass is invalid, but there is a valid one in SipApp's options
    {ok, 200, []} = nksip_uac:options(C2, SipC1, []),
    {ok, 200, []} = nksip_uac:options(C2, SipC1, [{pass, "kk"}]),
    {ok, 403, []} = nksip_uac:options(C2, SipC1, [{pass, {"kk", "client1"}}]),

    Self = self(),
    Ref = make_ref(),
    Fun = fun({ok, 200, []}) -> Self ! {Ref, digest_ok} end,
    {async, _} = nksip_uac:options(C1, SipC2, [async, {callback, Fun}, {pass, HA1}]),
    ok = tests_util:wait(Ref, [digest_ok]),
    ok.



invite() ->
    C1 = {auth, client1},
    C3 = {auth, client3},
    SipC3 = "sip:127.0.0.1:5072",
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},

    % client3 does not support dialog's authentication, only digest is used
    {ok, 401, [{cseq_num, CSeq}]} = 
        nksip_uac:invite(C1, SipC3, [{fields, [cseq_num]}]),
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(C1, SipC3, 
                                             [{pass, "abcd"}, {headers, [RepHd]}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client3, ack}]),
    {ok, 401, []} = nksip_uac:options(C1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(C1, DialogId1, [{pass, "abcd"}]),

    {ok, 401, _} = nksip_uac:invite(C1, DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(C1, DialogId1, [{pass, "abcd"}]),
    {req, ACK3} = nksip_uac:ack(C1, DialogId1, [get_request]),
    CSeq = nksip_sipmsg:field(ACK3, cseq_num) - 8,
    ok = tests_util:wait(Ref, [{client3, ack}]),

    % client1 does support dialog's authentication
    DialogId3 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, [{cseq_num, CSeq2}]} = 
        nksip_uac:options(C3, DialogId3, [{fields, [cseq_num]}]),
    {ok, 200, [{dialog_id, DialogId3}]} = 
        nksip_uac:invite(C3, DialogId3, [{headers, [RepHd]}]),
    ok = nksip_uac:ack(C3, DialogId3, [{headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, [{_, CSeq3}]} = nksip_uac:bye(C3, DialogId3, [{fields, [cseq_num]}]),
    ok = tests_util:wait(Ref, [{client1, bye}]),
    CSeq3 = CSeq2 + 2,
    ok.


dialog() ->
    C1 = {auth, client1},
    C2 = {auth, client2},
    SipC2 = "sip:127.0.0.1:5071",
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(C1, SipC2, 
                                            [{pass, "1234"}, {headers, [RepHd]}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    [{udp, {127,0,0,1}, 5071}] = nksip_call:get_authorized_list(C1, DialogId1),
    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    [{udp, {127,0,0,1}, 5070}] = nksip_call:get_authorized_list(C2, DialogId2),

    {ok, 200, []} = nksip_uac:options(C1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),

    ok = nksip_call:clear_authorized_list(C2, DialogId2),
    {ok, 401, []} = nksip_uac:options(C1, DialogId1, []),
    {ok, 200, []} = nksip_uac:options(C1, DialogId1, [{pass, "1234"}]),
    {ok, 200, []} = nksip_uac:options(C1, DialogId1, []),

    ok = nksip_call:clear_authorized_list(C1, DialogId1),
    [] = nksip_call:get_authorized_list(C1, DialogId1),

    % Force an invalid password, because the SipApp config has a valid one
    {ok, 403, []} = nksip_uac:options(C2, DialogId2, [{pass, {"invalid", "client1"}}]),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, [{pass, {"invalid", "client1"}}]),

    {ok, 200, []} = nksip_uac:bye(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, bye}]),
    ok.


proxy() ->
    C1 = {auth, client1},
    C2 = {auth, client2},
    S1 = "sip:127.0.0.1",
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},

    {ok, 407, []} = nksip_uac:register(C1, S1, []),
    {ok, 200, []} = nksip_uac:register(C1, S1, [{pass, "1234"}, unregister_all]),
    
    {ok, 200, []} = nksip_uac:register(C2, S1, [{pass, "4321"}, unregister_all]),
    
    % Users are not registered and no digest
    {ok, 407, []} = nksip_uac:options(C1, S1, []),
    % C2's SipApp has a password, but it is invalid
    {ok, 403, []} = nksip_uac:options(C2, S1, []),

    {ok, 200, []} = nksip_uac:register(C1, S1, [{pass, "1234"}, make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, S1, [{pass, "4321"}, make_contact]),

    % Authorized because of previous registration
    {ok, 200, []} = nksip_uac:options(C1, S1, []),
    {ok, 200, []} = nksip_uac:options(C2, S1, []),
    
    % The request is authorized at server1 (registered) but not server server2
    % (server1 will proxy to server2)
    Route = {route, "<sip:127.0.0.1;lr>"},
    {ok, 407, [{realms, [<<"server2">>]}]} = 
        nksip_uac:invite(C1, "sip:client2@nksip", [Route, {fields, [realms]}]),

    % Now the request reaches client2, and it is not authorized there. 
    % C2 replies with 401, but we generate a new request with the SipApp's invalid
    % password
    {ok, 403, _} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                      [Route, {pass, {"1234", "server2"}}, 
                                       {headers, [RepHd]}]),

    % Server1 accepts because of previous registration
    % Server2 replies with 407, and we generate a new request
    % Server2 now accepts and sends to C2
    % C2 replies with 401, and we generate a new request
    % Server2 and C2 accepts their digests
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                            [Route, {pass, {"1234", "server2"}},
                                            {pass, {"1234", "client2"}},
                                            {headers, [RepHd]}]),
    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % Server2 and C2 accepts the request because of dialog authentication
    {ok, 200, []} = nksip_uac:options(C1, DialogId1, []),
    % The same for C1
    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(C2, DialogId2, []),
    ok.

