%% -------------------------------------------------------------------
%%
%% uas_test: Inline Test Suite
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

-module(inline_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


inline_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun cancel/0}, 
            {timeout, 60, fun auth/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_inline_server:start({inline, server1}, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server@nksip>"},
        registrar,
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = sipapp_inline_endpoint:start({inline, client1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {local_host, "127.0.0.1"},
        {route, "<sip:127.0.0.1;lr>"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_inline_endpoint:start({inline, client2}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"},
        {local_host, "127.0.0.1"},
        {route, "<sip:127.0.0.1;lr>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_server:stop({inline, server1}),
    ok = sipapp_endpoint:stop({inline, client1}),
    ok = sipapp_endpoint:stop({inline, client2}).


basic() ->
    C1 = {inline, client1},
    C2 = {inline, client2},
    S1 = {inline, server1},
    Ref = make_ref(),
    Pid = self(),
    nksip_config:put(inline_test, {Ref, Pid}),
    nksip_registrar:clear(S1),
    % tests_util:log(debug), 

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),
    ok = tests_util:wait(Ref, [{S1, route}, {S1, route}]),

    Fs1 = {fields, [<<"Nk-Id">>]},
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:client2@nksip", [Fs1]),
    [{<<"Nk-Id">>, [<<"server1,client2">>]}] = Values1,
    ok = tests_util:wait(Ref, [{S1, route}, {C2, options}]),

    {ok, 480, []} = nksip_uac:options(C2, "sip:client3@nksip", []),
    ok = tests_util:wait(Ref, [{S1, route}]),

    {ok, 200, [{dialog_id, Dlg2}]} = nksip_uac:invite(C2, "sip:client1@nksip", []),
    ok = nksip_uac:ack(C2, Dlg2, []),
    ok = tests_util:wait(Ref, [
            {S1, route}, {C1, invite}, {S1, route}, {C1, ack},
            {C1, dialog_start},{C2, dialog_start}]),

    {ok, 200, []} = nksip_uac:info(C2, Dlg2, []),
    ok = tests_util:wait(Ref, [{S1, route}, {C1, info}]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Dlg1 = nksip_dialog:field(C2, Dlg2, remote_id),
    {ok, 200, _} = nksip_uac:invite(C1, Dlg1, [{body, SDP}]),
    ok = nksip_uac:ack(C1, Dlg1, []),

    ok = tests_util:wait(Ref, [
            {S1, route}, {C2, reinvite}, {S1, route}, {C2, ack},
            {C1, session_start},{C2, session_start}]),

    {ok, 200, []} = nksip_uac:bye(C1, Dlg1, []),
    ok = tests_util:wait(Ref, [
            {S1, route}, {C2, bye}, 
            {C1, session_stop}, {C2, session_stop},
            {C1, dialog_stop}, {C2, dialog_stop}]),
    ok.


cancel() ->
    C1 = {inline, client1},
    C2 = {inline, client2},
    S1 = {inline, server1},
    Ref = make_ref(),
    Pid = self(),
    nksip_config:put(inline_test, {Ref, Pid}),
    Hds = {headers, [{<<"Nk-Op">>, <<"wait">>}]},
    CB = {callback, fun(Term) -> Pid ! {Ref, Term} end},
    {async, ReqId} = nksip_uac:invite(C1, "sip:client2@nksip", [async, Hds, CB]),
    ok = nksip_uac:cancel(C1, ReqId),
    receive {Ref, {ok, 180, _}} -> ok after 500 -> error(inline) end,
    receive {Ref, {ok, 487, _}} -> ok after 500 -> error(inline) end,

    ok = tests_util:wait(Ref, [
            {S1, route},  
            {C1, dialog_start}, {C1, dialog_stop},
            {C2, invite}, {C2, cancel},
            {C2, dialog_start}, {C2, dialog_stop}]),

    nksip_config:del(inline_test),
    ok.


auth() ->
    C1 = {inline, client1},
    S1 = "sip:127.0.0.1",
    nksip_registrar:clear({inline, server1}),

    Hd = {headers, [{<<"Nksip-Auth">>, <<"true">>}]},
    {ok, 407, []} = nksip_uac:options(C1, S1, [Hd]),
    {ok, 200, []} = nksip_uac:options(C1, S1, [Hd, {pass, "1234"}]),

    {ok, 407, []} = nksip_uac:register(C1, S1, [Hd]),
    {ok, 200, []} = nksip_uac:register(C1, S1, [Hd, {pass, "1234"}, make_contact]),

    {ok, 200, []} = nksip_uac:options(C1, S1, [Hd]),
    ok.





