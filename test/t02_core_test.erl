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

-module(t02_core_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).


core_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun cancel/0}, 
            {timeout, 60, fun auth/0}
        ]
    }.


all() ->
    start(),
    timer:sleep(1000),
    basic(),
    cancel(),
    auth(),
    stop().


start() ->
    tests_util:start_nksip(),
    {ok, _} = nksip:start_link(core_test_server, #{}),
    {ok, _} = nksip:start_link(core_test_client1, #{}),
    {ok, _} = nksip:start_link(core_test_client2, #{}),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(core_test_server),
    ok = nksip:stop(core_test_client1),
    ok = nksip:stop(core_test_client2).



basic() ->
    Ref = make_ref(),
    Pid = self(),
    ok =  nkserver:put(core_test_server, inline_test, {Ref, Pid}),
    ok =  nkserver:put(core_test_client1, inline_test, {Ref, Pid}),
    ok =  nkserver:put(core_test_client2, inline_test, {Ref, Pid}),
    nksip_registrar:clear(core_test_server),
    
    {ok, 200, []} = nksip_uac:register(core_test_client1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(core_test_client2, "sip:127.0.0.1", [contact]),
    ok = tests_util:wait(Ref, [{core_test_server, route}, {core_test_server, route}]),

    Fs1 = {get_meta, [<<"x-nk-id">>]},
    {ok, 200, Values1} = nksip_uac:options(core_test_client1, "sip:core_test_client2@nksip", [Fs1]),
    [{<<"x-nk-id">>, [<<"core_test_client2,core_test_server">>]}] = Values1,
    ok = tests_util:wait(Ref, [{core_test_server, route}, {core_test_client2, options}]),

    {ok, 480, []} = nksip_uac:options(core_test_client2, "sip:client3@nksip", []),
    ok = tests_util:wait(Ref, [{core_test_server, route}]),

    {ok, 200, [{dialog, Dlg2}]} = nksip_uac:invite(core_test_client2, "sip:core_test_client1@nksip", []),
    ok = nksip_uac:ack(Dlg2, []),
    ok = tests_util:wait(Ref, [
            {core_test_server, route}, {core_test_server, dialog_start}, {core_test_server, route},
            {core_test_client1, invite}, {core_test_client1, ack}, {core_test_client1, dialog_start},
            {core_test_client2, dialog_start}]),

    {ok, 200, []} = nksip_uac:info(Dlg2, []),
    ok = tests_util:wait(Ref, [{core_test_server, route}, {core_test_client1, info}]),

    SDP = nksip_sdp:new("core_test_client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Dlg1 = nksip_dialog_lib:remote_id(Dlg2, core_test_client1),
    {ok, 200, _} = nksip_uac:invite(Dlg1, [{body, SDP}]),
    ok = nksip_uac:ack(Dlg1, []),

    ok = tests_util:wait(Ref, [
            {core_test_server, route}, {core_test_server, route}, {core_test_server, session_start},
            {core_test_client1, session_start},
            {core_test_client2, reinvite}, {core_test_client2, ack}, {core_test_client2, session_start}]),

    {ok, 200, []} = nksip_uac:bye(Dlg1, []),
    ok = tests_util:wait(Ref, [
            {core_test_server, route}, {core_test_server, session_stop}, {core_test_server, dialog_stop},
            {core_test_client1, session_stop}, {core_test_client1, dialog_stop},
            {core_test_client2, bye}, {core_test_client2, session_stop}, {core_test_client2, dialog_stop}]),
    nkserver:del(core_test_server, inline_test),
    nkserver:del(core_test_client1, inline_test),
    nkserver:del(core_test_client2, inline_test),
    ok.


cancel() ->
    Ref = make_ref(),
    Pid = self(),
    ok =  nkserver:put(core_test_server, inline_test, {Ref, Pid}),
    ok =  nkserver:put(core_test_client1, inline_test, {Ref, Pid}),
    ok =  nkserver:put(core_test_client2, inline_test, {Ref, Pid}),

    {ok, 200, []} = nksip_uac:register(core_test_client2, "sip:127.0.0.1", [contact]),
    ok = tests_util:wait(Ref, [{core_test_server, route}]),

    Hds = {add, "x-nk-op", "wait"},
    CB = {callback, fun({resp, Code, _Req, _Call}) -> Pid ! {Ref, {ok, Code}} end},
    {async, ReqId} = nksip_uac:invite(core_test_client1, "sip:core_test_client2@nksip", [async, Hds, CB]),
    ok = nksip_uac:cancel(ReqId, []),
    receive {Ref, {ok, 180}} -> ok after 500 -> error(inline) end,
    receive {Ref, {ok, 487}} -> ok after 500 -> error(inline) end,

    ok = tests_util:wait(Ref, [
            {core_test_server, route},  {core_test_server, dialog_start}, {core_test_server, cancel},
            {core_test_server, dialog_stop},
            {core_test_client1, dialog_start}, {core_test_client1, dialog_stop},
            {core_test_client2, invite}, {core_test_client2, cancel},
            {core_test_client2, dialog_start}, {core_test_client2, dialog_stop}]),
    nkserver:del(core_test_server, inline_test),
    nkserver:del(core_test_client1, inline_test),
    nkserver:del(core_test_client2, inline_test),
    ok.


auth() ->
    SipS1 = "sip:127.0.0.1",
    nksip_registrar:clear(core_test_server),

    Hd = {add, "x-nk-auth", true},
    {ok, 407, []} = nksip_uac:options(core_test_client1, SipS1, [Hd]),
    {ok, 200, []} = nksip_uac:options(core_test_client1, SipS1, [Hd, {sip_pass, "1234"}]),

    {ok, 407, []} = nksip_uac:register(core_test_client1, SipS1, [Hd]),
    {ok, 200, []} = nksip_uac:register(core_test_client1, SipS1, [Hd, {sip_pass, "1234"}, contact]),

    {ok, 200, []} = nksip_uac:options(core_test_client1, SipS1, [Hd]),
    ok.






