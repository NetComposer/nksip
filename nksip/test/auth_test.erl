%% -------------------------------------------------------------------
%%
%% auth_SUITE: Authentication Tests
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
-include_lib("nksip/include/nksip.hrl").

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

    {ok, 401, _} = nksip_uac:options(C1, SipC2, []),
    {ok, 200, _} = nksip_uac:options(C1, SipC2, [{pass, "1234"}]),
    {ok, 403, _} = nksip_uac:options(C1, SipC2, [{pass, "12345"}]),
    {ok, 200, _} = nksip_uac:options(C1, SipC2, [{pass, {"1234", "client2"}}]),
    {ok, 403, _} = nksip_uac:options(C1, SipC2, [{pass, {"1234", "other"}}]),

    HA1 = nksip_auth:make_ha1("client1", "1234", "client2"),
    {ok, 200, _} = nksip_uac:options(C1, SipC2, [{pass, HA1}]),
    
    % Pass is invalid, but there is a valid one in SipApp's options
    {ok, 200, _} = nksip_uac:options(C2, SipC1, []),
    {ok, 200, _} = nksip_uac:options(C2, SipC1, [{pass, "kk"}]),
    {ok, 403, _} = nksip_uac:options(C2, SipC1, [{pass, {"kk", "client1"}}]),

    Self = self(),
    Ref = make_ref(),
    Fun = fun(Term) ->
        case Term of
            {req_id, _} -> ok;
            {ok, 200, _} -> Self ! {Ref, digest_ok} 
        end
    end,
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
    % ACKHeaders = [{"Nk-Pid", base64:encode(term_to_binary({Ref, self()}))}],
    {ok, 401, Res1} = nksip_uac:invite(C1, SipC3, []),
    CSeq = nksip_response:field(Res1, cseq_num),
    {ok, 200, Res2} = nksip_uac:invite(C1, SipC3, 
                                            [{pass, "abcd"}, {headers, [RepHd]}]),
    Dialog = nksip_dialog:id(Res2),
    {ok, _} = nksip_uac:ack(Res2, []),
    ok = tests_util:wait(Ref, [{client3, ack}]),
    {ok, 401, _} = nksip_uac:reoptions(Res2, []),
    {ok, 200, _} = nksip_uac:reoptions(Dialog, [{pass, "abcd"}]),

    {ok, 401, _} = nksip_uac:reinvite(Res2, []),

    {ok, 200, Res3} = nksip_uac:reinvite(Res2, [{pass, "abcd"}]),
    Dialog = nksip_dialog:id(Res3),
    {ok, ACK3} = nksip_uac:ack(Res3, []),
    CSeq = nksip_request:field(ACK3, cseq_num) - 8,
    ok = tests_util:wait(Ref, [{client3, ack}]),

    % client1 does support dialog's authentication
    DialogB = nksip_dialog:remote_id(C3, Res3),
    DialogB = nksip_dialog:remote_id(C3, Dialog),
    {ok, 200, Res4} = nksip_uac:reoptions(DialogB, []),
    CSeq2 = nksip_response:field(Res4, cseq_num),
    {ok, 200, Res5} = nksip_uac:reinvite(DialogB, [{headers, [RepHd]}]),
    DialogB = nksip_dialog:id(Res5),
    {ok, _} = nksip_uac:ack(DialogB, [{headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, Res6} = nksip_uac:bye(DialogB, []),
    CSeq3 = nksip_response:field(Res6, cseq_num),
    CSeq3 = CSeq2 + 2,
    ok.


dialog() ->
    C1 = {auth, client1},
    C2 = {auth, client2},
    SipC2 = "sip:127.0.0.1:5071",
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
    {ok, 200, RespA} = nksip_uac:invite(C1, SipC2, 
                                            [{pass, "1234"}, {headers, [RepHd]}]),
    {ok, _} = nksip_uac:ack(RespA, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogA = nksip_dialog:id(RespA),
    DialogB = nksip_dialog:remote_id(C2, DialogA),
    [{udp, {127,0,0,1}, 5071}] = nksip_call_router:get_authorized_list(DialogA),
    [{udp, {127,0,0,1}, 5070}] = nksip_call_router:get_authorized_list(DialogB),

    {ok, 200, _} = nksip_uac:reoptions(DialogA, []),
    {ok, 200, _} = nksip_uac:reoptions(DialogB, []),

    ok = nksip_call_router:clear_authorized_list(DialogB),
    {ok, 401, _} = nksip_uac:reoptions(DialogA, []),
    {ok, 200, _} = nksip_uac:reoptions(DialogA, [{pass, "1234"}]),
    {ok, 200, _} = nksip_uac:reoptions(DialogA, []),

    ok = nksip_call_router:clear_authorized_list(DialogA),
    [] = nksip_call_router:get_authorized_list(DialogA),

    % Force an invalid password, because the SipApp config has a valid one
    {ok, 403, _} = nksip_uac:reoptions(DialogB, [{pass, {"invalid", "client1"}}]),
    {ok, 200, _} = nksip_uac:reoptions(DialogB, []),
    {ok, 200, _} = nksip_uac:reoptions(DialogB, [{pass, {"invalid", "client1"}}]),

    {ok, 200, _} = nksip_uac:bye(DialogA, []),
    ok.


proxy() ->
    C1 = {auth, client1},
    C2 = {auth, client2},
    S1 = "sip:127.0.0.1",
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},

    {ok, 407, _} = nksip_uac:register(C1, S1, []),
    {ok, 200, _} = nksip_uac:register(C1, S1, [{pass, "1234"}, unregister_all]),
    
    {ok, 200, _} = nksip_uac:register(C2, S1, [{pass, "4321"}, unregister_all]),
    
    % Users are not registered and no digest
    {ok, 407, _} = nksip_uac:options(C1, S1, []),
    % C2's SipApp has a password, but it is invalid
    {ok, 403, _} = nksip_uac:options(C2, S1, []),

    {ok, 200, _} = nksip_uac:register(C1, S1, [{pass, "1234"}, make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, S1, [{pass, "4321"}, make_contact]),

    % Authorized because of previous registration
    {ok, 200, _} = nksip_uac:options(C1, S1, []),
    {ok, 200, _} = nksip_uac:options(C2, S1, []),
    
    % The request is authorized at server1 (registered) but not server server2
    % (server1 will proxy to server2)
    Route = {route, "sip:127.0.0.1;lr"},
    {ok, 407, Res1} = nksip_uac:invite(C1, "sip:client2@nksip", [Route]),
    [<<"server2">>] = nksip_auth:realms(Res1),

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
    {ok, 200, RespId} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                            [Route, {pass, {"1234", "server2"}},
                                            {pass, {"1234", "client2"}},
                                            {headers, [RepHd]}]),
    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    {ok, _} = nksip_uac:ack(RespId, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % Server2 and C2 accepts the request because of dialog authentication
    {ok, 200, _} = nksip_uac:reoptions(RespId, []),
    Dialog2 = nksip_dialog:remote_id(C2, RespId),
    % The same for C1
    {ok, 200, _} = nksip_uac:reoptions(Dialog2, []),
    {ok, 200, _} = nksip_uac:bye(Dialog2, []),
    ok.

