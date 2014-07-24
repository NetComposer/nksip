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

    {ok, _} = nksip:start(client1, ?MODULE, [], [
        {from, "sip:client1@nksip"},
        {plugins, [nksip_100rel]},
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {timer_t1, 100},
        no_100
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, [], [
        {from, "sip:client2@nksip"},
        {plugins, [nksip_100rel]},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        {timer_t1, 100},
        no_100
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).



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
    Fields1 = {meta, [supported, require]},
    {ok, 486, Values1} = nksip_uac:invite(client1, SipC2, [CB, get_request, Hd1, Fields1]), 
    [{supported,  Sup1}, {require, []}] = Values1,
    true = lists:member(<<"100rel">>, Sup1),

    receive {Ref, {req, Req1}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Req1)),
        [] = nksip_sipmsg:meta(require, Req1)
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {resp, 180, Resp1a}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Resp1a)),
            [] = nksip_sipmsg:meta(require, Resp1a)
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {resp, 183, Resp1b}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Resp1b)),
            [] = nksip_sipmsg:meta(require, Resp1b)
    after 1000 -> 
        error(basic) 
    end,


    % Ask for 100rel in UAS
    Hds2 = [
        {add, "x-nk-op", "rel-prov-busy"},
        {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))}
    ],
    Fields2 = {meta, [supported, require, cseq_num, rseq_num]},
    {ok, 486, Values2} = nksip_uac:invite(client1, SipC2, 
                            [CB, get_request, Fields2, {require, "100rel"}|Hds2]),
    [
        {supported, Sup2},
        {require, []},
        {cseq_num, CSeq2},
        {rseq_num, undefined}
    ] = Values2,
    true = lists:member(<<"100rel">>, Sup2),

    receive {Ref, {req, Req2}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Req2)),
        [<<"100rel">>] = nksip_sipmsg:meta(require, Req2)
    after 1000 -> 
        error(basic) 
    end,
    RSeq2a = receive 
        {Ref, {resp, 180, Resp2a}} -> 
            true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Resp2a)),
            [<<"100rel">>] = nksip_sipmsg:meta(require, Resp2a),
            CSeq2 = nksip_sipmsg:meta(cseq_num, Resp2a),
            RSeq2a_0 = nksip_sipmsg:meta(rseq_num, Resp2a),
            RSeq2a_0
    after 1000 -> 
        error(basic) 
    end,
    RSeq2b = receive 
        {Ref, {resp, 183, Resp2b}} -> 
        true = lists:member(<<"100rel">>, nksip_sipmsg:meta(supported, Resp2b)),
            [<<"100rel">>] = nksip_sipmsg:meta(require, Resp2b),
            CSeq2 = nksip_sipmsg:meta(cseq_num, Resp2b),
            RSeq2b_0 = nksip_sipmsg:meta(rseq_num, Resp2b),
            RSeq2b_0
    after 1000 -> 
        error(basic) 
    end,
    receive
        {Ref, {client2, {prack, {RSeq2a, CSeq2, 'INVITE'}}}} -> ok
    after 1000 ->
        error(basic)
    end,
    receive
        {Ref, {client2, {prack, {RSeq2b, CSeq2, 'INVITE'}}}} -> ok
    after 1000 ->
        error(basic)
    end,
    RSeq2b = RSeq2a+1,
    ok.


pending() ->
    SipC2 = "sip:127.0.0.1:5070",
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [{add, "x-nk-op", "pending"}, RepHd],

    {ok, 486, _} = nksip_uac:invite(client1, SipC2, Hds),
    receive
        {Ref, {_, pending_prack_ok}} -> ok
    after 1000 ->
        error(pending)
    end.


media() ->
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),

    % A session with media offer in INVITE, answer in reliable provisional 
    % and final responses.
    % Although it is not valid, in each one a new SDP is generated, so three 
    % session are received.
    % We don't receive callbacks from client1, since it has not stored the reply in 
    % its state
    Hds1 = [{add, "x-nk-op", "rel-prov-answer"}, RepHd],
    {ok, 200, [{dialog, DialogId1}]} = 
        nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", [{body, SDP}|Hds1]),
    ok = nksip_uac:ack(DialogId1, []),
    receive {Ref, {client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    receive {Ref, {client2, {prack, _}}} -> ok after 1000 -> error(media) end,
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
    DialogId1B = nksip_dialog_lib:remote_id(DialogId1, client2),
    {RemoteSDP1, SDP} = get_sessions(client2, DialogId1B),
    {ok, 200, _} = nksip_uac:bye(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with media offer in INVITE, answer in reliable provisional 
    % and new offer in PRACK (answer in respone to PRACK)
    Hds2 = [{add, "x-nk-op", "rel-prov-answer2"}, RepHd],
    CB = {prack_callback, 
            fun(<<>>, {resp, _Code, #sipmsg{}, _Call}) -> 
                Self ! {Ref, prack_sdp_ok},
                nksip_sdp:increment(SDP)
            end},
    {ok, 200, [{dialog, DialogId2}]} = 
        nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", [{body, SDP}, CB|Hds2]),
    ok = nksip_uac:ack(DialogId2, []),
    receive {Ref, {client2, {prack, _}}} -> ok after 1000 -> error(media) end,
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
    DialogId2B = nksip_dialog_lib:remote_id(DialogId2, client2),
    {RemoteSDP2, LocalSDP2} = get_sessions(client2, DialogId2B),
    {ok, 200, _} = nksip_uac:bye(DialogId2, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with no media offer in INVITE, offer in reliable provisional 
    % and answer in PRACK
    Hds3 = [{add, "x-nk-op", "rel-prov-answer3"}, RepHd],
    CB3 = {prack_callback, 
            fun(FunSDP, {resp, _Code, #sipmsg{}, _Call}) -> 
                FunLocalSDP = FunSDP#sdp{
                    address={<<"IN">>, <<"IP4">>, <<"client1">>},            
                    connect={<<"IN">>, <<"IP4">>, <<"client1">>}
                },
                Self ! {Ref, {prack_sdp_ok, FunLocalSDP}},
                FunLocalSDP
            end},
    {ok, 200, [{dialog, DialogId3}]} = 
        nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", [CB3|Hds3]),
    ok = nksip_uac:ack(DialogId3, []),
    receive {Ref, {client2, {prack, _}}} -> ok after 1000 -> error(media) end,
    LocalSDP3 = receive {Ref, {prack_sdp_ok, L3}} -> L3 after 1000 -> error(media) end,
    ok = tests_util:wait(Ref, [
                               {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),
    
    RemoteSDP3 = LocalSDP3#sdp{
        address = {<<"IN">>, <<"IP4">>, <<"client2">>},
        connect = {<<"IN">>, <<"IP4">>, <<"client2">>}
    },
    DialogId3B = nksip_dialog_lib:remote_id(DialogId3, client2),
    {RemoteSDP3, LocalSDP3} = get_sessions(client2, DialogId3B),
    {ok, 200, _} = nksip_uac:bye(DialogId3, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 
    ok.
   


%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    {ok, App} = nksip_request:app_name(Req),
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
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(App)}};
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
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(App)}};
                        {ok, _} -> 
                            <<>>
                    end,
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    nksip_request:reply(ok, ReqId);
                <<"rel-prov-answer3">> ->
                    SDP = nksip_sdp:new(nksip_lib:to_binary(App), 
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
    {ok, RAck} = nksip_request:meta(rack, Req),
    tests_util:send_ref({prack, RAck}, Req),
    Body = case nksip_request:body(Req) of
        {ok, #sdp{} = RemoteSDP} ->
            {ok, App} = nksip_request:app_name(Req),
            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(App)}};
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



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(AppId, DialogId) ->
    {ok, Sessions} = nksip:get(AppId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.






