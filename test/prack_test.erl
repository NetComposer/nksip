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

prack_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0,
            fun pending/0,
            fun media/0
        ]
    }.


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
    Supported = [{<<"100rel">>, []},{<<"path">>, []}],

    % No make_100rel in call to invite, neither in app config
    Hds1 = {headers, [{"Nk-Op", "prov-busy"}]},
    Fields1 = {fields, [parsed_supported, parsed_require]},
    {ok, 486, Values1} = nksip_uac:invite(C1, SipC2, [CB, get_request, Hds1, Fields1]),    [
        {parsed_supported, Supported},
        {parsed_require, []}
    ] = Values1,
    receive {Ref, {req, Req1}} -> 
        [Supported,[]] = 
            nksip_sipmsg:fields(Req1, [parsed_supported, parsed_require])
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 180, Values1a}} -> 
            [
                {dialog_id, _},
                {parsed_supported, Supported},
                {parsed_require,[]}
            ] = Values1a
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 183, Values1b}} -> 
            [
                {dialog_id, _},
                {parsed_supported,Supported},
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
        {parsed_supported, Supported},
        {parsed_require, []},
        {cseq_num, CSeq2},
        {rseq_num, undefined}
    ] = Values2,
    receive {Ref, {req, Req2}} -> 
        [Supported, [{<<"100rel">>,[]}]] = 
            nksip_sipmsg:fields(Req2, [parsed_supported, parsed_require])
    after 1000 -> 
        error(basic) 
    end,
    RSeq2a = receive 
        {Ref, {ok, 180, Values2a}} -> 
            [
                {dialog_id, _},
                {parsed_supported, Supported},
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
                {parsed_supported, Supported},
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


media() ->
    C1 = {prack, client1},
    C2 = {prack, client2},
    Ref = make_ref(),
    Self = self(),
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    % A session with media offer in INVITE, answer in reliable provisional 
    % and final responses.
    % Although it is not valid, in each one a new SDP is generated, so three 
    % session are received.
    % We don't receive callbacks from client1, since it has not stored the reply in 
    % its state
    Hds1 = [{"Nk-Op", "rel-prov-answer"}, RepHd],
    {ok, 200, [{dialog_id, DialogId1}]} = 
        nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070", [{headers, Hds1}, {body, SDP}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    receive {Ref, {client2, prack, _}} -> ok after 1000 -> error(media) end,
    receive {Ref, {client2, prack, _}} -> ok after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [{client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start},
                               {client2, sdp_update},
                               {client2, sdp_update}]),
    RemoteSDP1 = SDP#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"client2">>},
        vsn = SDP#sdp.vsn+2
    },
    % Hack to find remote dialog
    DialogId1B = nksip_dialog:field(C1, DialogId1, remote_id),
    {RemoteSDP1, SDP} = prack_endpoint:get_sessions(C2, DialogId1B),
    {ok, 200, _} = nksip_uac:bye(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with media offer in INVITE, answer in reliable provisional 
    % and new offer in PRACK (answer in respone to PRACk)
    Hds2 = [{"Nk-Op", "rel-prov-answer2"}, RepHd],
    CB = {prack, 
            fun(<<>>, #sipmsg{}) -> 
                Self ! {Ref, prack_sdp_ok},
                nksip_sdp:increment(SDP)
            end},
    {ok, 200, [{dialog_id, DialogId2}]} = 
        nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070", [{headers, Hds2}, {body, SDP}, CB]),
    ok = nksip_uac:ack(C1, DialogId2, []),
    receive {Ref, {client2, prack, _}} -> ok after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [prack_sdp_ok,
                               {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start},
                               {client2, sdp_update}]),
    LocalSDP2 = SDP#sdp{vsn = SDP#sdp.vsn+1},
    RemoteSDP2 = SDP#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"client2">>},
        vsn = SDP#sdp.vsn+1
    },
    DialogId2B = nksip_dialog:field(C1, DialogId2, remote_id),
    {RemoteSDP2, LocalSDP2} = prack_endpoint:get_sessions(C2, DialogId2B),
    {ok, 200, _} = nksip_uac:bye(C1, DialogId2, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with no media offer in INVITE, offer in reliable provisional 
    % and answer in PRACK
    Hds3 = [{"Nk-Op", "rel-prov-answer3"}, RepHd],
    CB3 = {prack, 
            fun(FunSDP, #sipmsg{}) -> 
                FunLocalSDP = FunSDP#sdp{
                    address={<<"IN">>, <<"IP4">>, <<"client1">>},            
                    connect={<<"IN">>, <<"IP4">>, <<"client1">>}
                },
                Self ! {Ref, {prack_sdp_ok, FunLocalSDP}},
                FunLocalSDP
            end},
    {ok, 200, [{dialog_id, DialogId3}]} = 
        nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070", [{headers, Hds3}, CB3]),
    ok = nksip_uac:ack(C1, DialogId3, []),
    receive {Ref, {client2, prack, _}} -> ok after 1000 -> error(media) end,
    LocalSDP3 = receive {Ref, {prack_sdp_ok, L3}} -> L3 after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [
                               {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),
    
    RemoteSDP3 = LocalSDP3#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"client2">>},
        connect = {<<"IN">>, <<"IP4">>, <<"client2">>}
    },
    DialogId3B = nksip_dialog:field(C1, DialogId3, remote_id),
    {RemoteSDP3, LocalSDP3} = prack_endpoint:get_sessions(C2, DialogId3B),
    {ok, 200, _} = nksip_uac:bye(C1, DialogId3, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 
    ok.



    




