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

-module(t15_prack_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).
-ifdef(is_travis).
-define(TIMEOUT, 100000).
-else.
-define(TIMEOUT, 10000).
-endif.


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

    {ok, _} = nksip:start_link(prack_test_client1, #{
        sip_from => "sip:prack_test_client1@nksip",
        sip_local_host => "localhost",
        sip_timer_t1 => 100,
        sip_no_100 => true,
        plugins => [nksip_100rel],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),
    
    {ok, _} = nksip:start_link(prack_test_client2, #{
        sip_from => "sip:prack_test_client2@nksip",
        sip_no_100 => true,
        sip_local_host => "127.0.0.1",
        sip_timer_t1 => 100,
        plugins => [nksip_100rel],
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(prack_test_client1),
    ok = nksip:stop(prack_test_client2).


all() ->
    start(),
    timer:sleep(1000),
    basic(),
    pending(),
    media(),
    stop().


basic() ->
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    CB = {callback, 
        fun
            ({req, Req, _Call}) -> Self ! {Ref, {req, Req}};
            ({resp, Code, Resp, _Call}) -> Self ! {Ref, {resp, Code, Resp}}
        end},

    % No do100rel in call to invite, neither in app config
    Hd1 = {add, "x-nk-op", "prov-busy"},
    Fields1 = {get_meta, [supported, require]},
    {ok, 486, Values1} = nksip_uac:invite(prack_test_client1, SipC2, [CB, get_request, Hd1, Fields1]),
    [{supported,  Sup1}, {require, []}] = Values1,
    true = lists:member(<<"100rel">>, Sup1),

    receive {Ref, {req, Req1}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Req1)),
        [] = nksip_sipmsg:get_meta(require, Req1)
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {resp, 180, Resp1a}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Resp1a)),
            [] = nksip_sipmsg:get_meta(require, Resp1a)
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {resp, 183, Resp1b}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Resp1b)),
            [] = nksip_sipmsg:get_meta(require, Resp1b)
    after 1000 -> 
        error(basic) 
    end,


    % Ask for 100rel in UAS
    Hds2 = [
        {add, "x-nk-op", "rel-prov-busy"},
        {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))}
    ],
    Fields2 = {get_meta, [supported, require, cseq_num, rseq_num]},
    {ok, 486, Values2} = nksip_uac:invite(prack_test_client1, SipC2,
                            [CB, get_request, Fields2, {require, "100rel"}|Hds2]),
    [
        {supported, Sup2},
        {require, []},
        {cseq_num, CSeq2},
        {rseq_num, undefined}
    ] = Values2,
    true = lists:member(<<"100rel">>, Sup2),

    receive {Ref, {req, Req2}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Req2)),
        [<<"100rel">>] = nksip_sipmsg:get_meta(require, Req2)
    after 1000 -> 
        error(basic) 
    end,
    RSeq2a = receive 
        {Ref, {resp, 180, Resp2a}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Resp2a)),
            [<<"100rel">>] = nksip_sipmsg:get_meta(require, Resp2a),
            CSeq2 = nksip_sipmsg:get_meta(cseq_num, Resp2a),
            RSeq2a_0 = nksip_sipmsg:get_meta(rseq_num, Resp2a),
            RSeq2a_0
    after 1000 -> 
        error(basic) 
    end,
    RSeq2b = receive 
        {Ref, {resp, 183, Resp2b}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:get_meta(supported, Resp2b)),
            [<<"100rel">>] = nksip_sipmsg:get_meta(require, Resp2b),
            CSeq2 = nksip_sipmsg:get_meta(cseq_num, Resp2b),
            RSeq2b_0 = nksip_sipmsg:get_meta(rseq_num, Resp2b),
            RSeq2b_0
    after 1000 -> 
        error(basic) 
    end,
    receive
        {Ref, {prack_test_client2, {prack, {RSeq2a, CSeq2, 'INVITE'}}}} -> ok
    after 1000 ->
        error(basic)
    end,
    receive
        {Ref, {prack_test_client2, {prack, {RSeq2b, CSeq2, 'INVITE'}}}} -> ok
    after 1000 ->
        error(basic)
    end,
    RSeq2b = RSeq2a+1,
    ok.


pending() ->
    SipC2 = "sip:127.0.0.1:5070",
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [{add, "x-nk-op", "pending"}, RepHd],

    {ok, 486, _} = nksip_uac:invite(prack_test_client1, SipC2, Hds),
    receive
        {Ref, {_, pending_prack_ok}} -> ok
    after ?TIMEOUT ->
        error(pending)
    end.


media() ->
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    SDP = nksip_sdp:new("prack_test_client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),

    % A session with media offer in INVITE, answer in reliable provisional 
    % and final responses.
    % Although it is not valid, in each one a new SDP is generated, so three 
    % session are received.
    % We don't receive callbacks from prack_test_client1, since it has not stored the reply in
    % its state
    Hds1 = [{add, "x-nk-op", "rel-prov-answer"}, RepHd],
    {ok, 200, [{dialog, DialogId1}]} = 
        nksip_uac:invite(prack_test_client1, "sip:ok@127.0.0.1:5070", [{body, SDP}|Hds1]),
    ok = nksip_uac:ack(DialogId1, []),
    receive {Ref, {prack_test_client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    receive {Ref, {prack_test_client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [{prack_test_client2, ack},
                               {prack_test_client2, dialog_confirmed},
                               {prack_test_client2, sdp_start},
                               {prack_test_client2, sdp_update},
                               {prack_test_client2, sdp_update}]),
    RemoteSDP1 = SDP#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"prack_test_client2">>},
        vsn = SDP#sdp.vsn+2
    },
    % Hack to find remote dialog
    DialogId1B = nksip_dialog_lib:remote_id(DialogId1, prack_test_client2),
    {RemoteSDP1, SDP} = get_sessions(prack_test_client2, DialogId1B),
    {ok, 200, _} = nksip_uac:bye(DialogId1, []),
    ok = tests_util:wait(Ref, [{prack_test_client2, sdp_stop},
                               {prack_test_client2, {dialog_stop, caller_bye}}]),

    % A session with media offer in INVITE, answer in reliable provisional 
    % and new offer in PRACK (answer in respone to PRACK)
    Hds2 = [{add, "x-nk-op", "rel-prov-answer2"}, RepHd],
    CB = {prack_callback, 
            fun(<<>>, {resp, _Code, #sipmsg{}, _Call}) -> 
                Self ! {Ref, prack_sdp_ok},
                nksip_sdp:increment(SDP)
            end},
    {ok, 200, [{dialog, DialogId2}]} = 
        nksip_uac:invite(prack_test_client1, "sip:ok@127.0.0.1:5070", [{body, SDP}, CB|Hds2]),
    ok = nksip_uac:ack(DialogId2, []),
    receive {Ref, {prack_test_client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [prack_sdp_ok,
                               {prack_test_client2, ack},
                               {prack_test_client2, dialog_confirmed},
                               {prack_test_client2, sdp_start},
                               {prack_test_client2, sdp_update}]),
    LocalSDP2 = SDP#sdp{vsn = SDP#sdp.vsn+1},
    RemoteSDP2 = SDP#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"prack_test_client2">>},
        vsn = SDP#sdp.vsn+1
    },
    DialogId2B = nksip_dialog_lib:remote_id(DialogId2, prack_test_client2),
    {RemoteSDP2, LocalSDP2} = get_sessions(prack_test_client2, DialogId2B),
    {ok, 200, _} = nksip_uac:bye(DialogId2, []),
    ok = tests_util:wait(Ref, [{prack_test_client2, sdp_stop},
                               {prack_test_client2, {dialog_stop, caller_bye}}]),

    % A session with no media offer in INVITE, offer in reliable provisional 
    % and answer in PRACK
    Hds3 = [{add, "x-nk-op", "rel-prov-answer3"}, RepHd],
    CB3 = {prack_callback, 
            fun(FunSDP, {resp, _Code, #sipmsg{}, _Call}) -> 
                FunLocalSDP = FunSDP#sdp{
                    address={<<"IN">>, <<"IP4">>, <<"prack_test_client1">>},
                    connect={<<"IN">>, <<"IP4">>, <<"prack_test_client1">>}
                },
                Self ! {Ref, {prack_sdp_ok, FunLocalSDP}},
                FunLocalSDP
            end},
    {ok, 200, [{dialog, DialogId3}]} = 
        nksip_uac:invite(prack_test_client1, "sip:ok@127.0.0.1:5070", [CB3|Hds3]),
    ok = nksip_uac:ack(DialogId3, []),
    receive {Ref, {prack_test_client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    LocalSDP3 = receive {Ref, {prack_sdp_ok, L3}} -> L3 after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [
                               {prack_test_client2, ack},
                               {prack_test_client2, dialog_confirmed},
                               {prack_test_client2, sdp_start}]),
    
    RemoteSDP3 = LocalSDP3#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"prack_test_client2">>},
        connect = {<<"IN">>, <<"IP4">>, <<"prack_test_client2">>}
    },
    DialogId3B = nksip_dialog_lib:remote_id(DialogId3, prack_test_client2),
    {RemoteSDP3, LocalSDP3} = get_sessions(prack_test_client2, DialogId3B),
    {ok, 200, _} = nksip_uac:bye(DialogId3, []),
    ok = tests_util:wait(Ref, [{prack_test_client2, sdp_stop},
                               {prack_test_client2, {dialog_stop, caller_bye}}]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(SrvId, DialogId) ->
    Sessions = nkserver:get(SrvId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.






