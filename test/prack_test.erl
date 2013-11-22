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

-module(prack_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

% invite_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             fun basic/0
%             fun pending/0
%         ]
%     }.


start() ->
    tests_util:start_nksip(),

    ok = nksip:start({prack, client1}, prack_endpoint, [client1], [
        {from, "sip:client1@nksip"},
        {fullname, "NkSIP Basic SUITE Test Client1"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}},
        no_100
    ]),
    
    ok = nksip:start({prack, client2}, prack_endpoint, [client2], [
        {from, "sip:client2@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}},
        no_100,
        make_100rel
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop({prack, client1}),
    ok = nksip:stop({prack, client2}).



basic() ->
    C1 = {prack, client1},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun(Reply) -> Self ! {Ref, Reply} end},

    % No make_100rel in call to invite, neither in app config
    Hds1 = {headers, [{"Nk-Op", "prov-busy"}]},
    Fields1 = {fields, [parsed_supported, parsed_require]},
    {ok, 486, Values1} = nksip_uac:invite(C1, SipC2, [CB, get_request, Hds1, Fields1]),    [
        {dialog_id, _},
        {parsed_supported, [{<<"100rel">>, []}]},
        {parsed_require, []}
    ] = Values1,
    receive {Ref, {req, Req1}} -> 
        [[{<<"100rel">>,[]}],[]] = 
            nksip_sipmsg:fields(Req1, [parsed_supported, parsed_require])
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 180, Values1a}} -> 
            [
                {dialog_id, _},
                {parsed_supported,[{<<"100rel">>,[]}]},
                {parsed_require,[]}
            ] = Values1a
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 183, Values1b}} -> 
            [
                {dialog_id, _},
                {parsed_supported,[{<<"100rel">>,[]}]},
                {parsed_require,[]}
            ] = Values1b
    after 1000 -> 
        error(basic) 
    end,


    % Ask for 100rel in UAS
    Hds2 = {headers, [
        {"Nk-Op", "rel-prov-busy"},
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},

    Fields2 = {fields, [parsed_supported, parsed_require, cseq_num, rseq_num]},
    {ok, 486, Values2} = nksip_uac:invite(C1, SipC2, [CB, get_request, Hds2, Fields2, require_100rel]),
    [
        {dialog_id, _},
        {parsed_supported, [{<<"100rel">>, []}]},
        {parsed_require, []},
        {cseq_num, CSeq2},
        {rseq_num, undefined}
    ] = Values2,
    receive {Ref, {req, Req2}} -> 
        [[{<<"100rel">>,[]}], [{<<"100rel">>,[]}]] = 
            nksip_sipmsg:fields(Req2, [parsed_supported, parsed_require])
    after 1000 -> 
        error(basic) 
    end,
    RSeq2a = receive 
        {Ref, {ok, 180, Values2a}} -> 
            [
                {dialog_id, _},
                {parsed_supported, [{<<"100rel">>,[]}]},
                {parsed_require, [{<<"100rel">>,[]}]},
                {cseq_num, CSeq2},
                {rseq_num, RSeq2a_0}
            ] = Values2a,
            RSeq2a_0
    after 1000 -> 
        error(basic) 
    end,
    RSeq2b = receive 
        {Ref, {ok, 183, Values2b}} -> 
            [
                {dialog_id, _},
                {parsed_supported, [{<<"100rel">>,[]}]},
                {parsed_require, [{<<"100rel">>,[]}]},
                {cseq_num, CSeq2},
                {rseq_num, RSeq2b_0}
            ] = Values2b,
            RSeq2b_0
    after 1000 -> 
        error(basic) 
    end,
    receive
        {Ref, {client2, prack, {RSeq2a, CSeq2, 'INVITE'}}} -> ok
    after 1000 ->
        error(basic)
    end,
    receive
        {Ref, {client2, prack, {RSeq2b, CSeq2, 'INVITE'}}} -> ok
    after 1000 ->
        error(basic)
    end,
    RSeq2b = RSeq2a+1,
    ok.


pending() ->
    C1 = {prack, client1},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    Hds = {headers, [
        {"Nk-Op", "pending"},
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},

    {ok, 486, _} = nksip_uac:invite(C1, SipC2, [Hds]),
    receive
        {Ref, pending_prack_ok} -> ok
    after 1000 ->
        error(pending)
    end.




