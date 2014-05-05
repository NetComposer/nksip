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

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {from, "sip:client1@nksip"},
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {supported, "100rel"},
        no_100
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        {from, "sip:client2@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        no_100,
        {supported, "100rel"}
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
    CB = {callback, fun(Reply) -> Self ! {Ref, Reply} end},

    % No do100rel in call to invite, neither in app config
    Hd1 = {add, "x-nk-op", "prov-busy"},
    Fields1 = {meta, [parsed_supported, parsed_require]},
    {ok, 486, Values1} = nksip_uac:invite(client1, SipC2, [CB, get_request, Hd1, Fields1]),    [
        {parsed_supported,  [<<"100rel">>]},
        {parsed_require, []}
    ] = Values1,
    receive {Ref, {req, Req1}} -> 
        [[<<"100rel">>],[]] = nksip_sipmsg:metas([supported, require], Req1)
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 180, Values1a}} -> 
            [
                {dialog_id, _},
                {parsed_supported,  [<<"100rel">>]},
                {parsed_require,[]}
            ] = Values1a
    after 1000 -> 
        error(basic) 
    end,
    receive 
        {Ref, {ok, 183, Values1b}} -> 
            [
                {dialog_id, _},
                {parsed_supported, [<<"100rel">>]},
                {parsed_require,[]}
            ] = Values1b
    after 1000 -> 
        error(basic) 
    end,


    % Ask for 100rel in UAS
    Hds2 = [
        {add, "x-nk-op", "rel-prov-busy"},
        {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))}
    ],
    Fields2 = {meta, [parsed_supported, parsed_require, cseq_num, rseq_num]},
    {ok, 486, Values2} = nksip_uac:invite(client1, SipC2, [CB, get_request, Fields2, {require, "100rel"}|Hds2]),
    [
        {parsed_supported, [<<"100rel">>]},
        {parsed_require, []},
        {cseq_num, CSeq2},
        {rseq_num, undefined}
    ] = Values2,
    receive {Ref, {req, Req2}} -> 
        [[<<"100rel">>], [<<"100rel">>]] = 
            nksip_sipmsg:metas([supported, require], Req2)
    after 1000 -> 
        error(basic) 
    end,
    RSeq2a = receive 
        {Ref, {ok, 180, Values2a}} -> 
            [
                {dialog_id, _},
                {parsed_supported, [<<"100rel">>]},
                {parsed_require, [<<"100rel">>]},
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
                {parsed_supported, [<<"100rel">>]},
                {parsed_require, [<<"100rel">>]},
                {cseq_num, CSeq2},
                {rseq_num, RSeq2b_0}
            ] = Values2b,
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
    {ok, 200, [{dialog_id, DialogId1}]} = 
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
    DialogId1B = nksip_dialog:remote_id(DialogId1, client2),
    {RemoteSDP1, SDP} = get_sessions(client2, DialogId1B),
    {ok, 200, _} = nksip_uac:bye(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with media offer in INVITE, answer in reliable provisional 
    % and new offer in PRACK (answer in respone to PRACK)
    Hds2 = [{add, "x-nk-op", "rel-prov-answer2"}, RepHd],
    CB = {prack_callback, 
            fun(<<>>, #sipmsg{}) -> 
                Self ! {Ref, prack_sdp_ok},
                nksip_sdp:increment(SDP)
            end},
    {ok, 200, [{dialog_id, DialogId2}]} = 
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
    DialogId2B = nksip_dialog:remote_id(DialogId2, client2),
    {RemoteSDP2, LocalSDP2} = get_sessions(client2, DialogId2B),
    {ok, 200, _} = nksip_uac:bye(DialogId2, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 

    % A session with no media offer in INVITE, offer in reliable provisional 
    % and answer in PRACK
    Hds3 = [{add, "x-nk-op", "rel-prov-answer3"}, RepHd],
    CB3 = {prack_callback, 
            fun(FunSDP, #sipmsg{}) -> 
                FunLocalSDP = FunSDP#sdp{
                    address={<<"IN">>, <<"IP4">>, <<"client1">>},            
                    connect={<<"IN">>, <<"IP4">>, <<"client1">>}
                },
                Self ! {Ref, {prack_sdp_ok, FunLocalSDP}},
                FunLocalSDP
            end},
    {ok, 200, [{dialog_id, DialogId3}]} = 
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
    DialogId3B = nksip_dialog:remote_id(DialogId3, client2),
    {RemoteSDP3, LocalSDP3} = get_sessions(client2, DialogId3B),
    {ok, 200, _} = nksip_uac:bye(DialogId3, []),
    ok = tests_util:wait(Ref, [{client2, sdp_stop},
                               {client2, {dialog_stop, caller_bye}}]), 
    ok.



    %%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.

invite(ReqId, Meta, From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Op = case nksip_request:header(<<"x-nk-op">>, ReqId) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    proc_lib:spawn(
        fun() ->
            case Op of
                <<"prov-busy">> ->
                    ok = nksip_request:reply(ringing, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(session_progress, ReqId),
                    timer:sleep(100),
                    nksip:reply(From, busy);
                <<"rel-prov-busy">> ->
                    ok = nksip_request:reply(rel_ringing, ReqId),
                    timer:sleep(100),
                    ok = nksip_request:reply(rel_session_progress, ReqId),
                    timer:sleep(100),
                    nksip:reply(From, busy);
                <<"pending">> ->
                    spawn(
                        fun() -> 
                            ok = nksip_request:reply(rel_ringing, ReqId)
                        end),
                    spawn(
                        fun() -> 
                            {error, pending_prack} = 
                                nksip_request:reply(rel_session_progress, ReqId),
                            tests_util:send_ref(AppId, Meta, pending_prack_ok)
                        end),
                    timer:sleep(100),
                    nksip:reply(From, busy);
                <<"rel-prov-answer">> ->
                    SDP = case nksip_lib:get_value(body, Meta) of
                        #sdp{} = RemoteSDP ->
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(AppId)}};
                        _ -> 
                            <<>>
                    end,
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    SDP1 = nksip_sdp:increment(SDP),
                    ok = nksip_request:reply({rel_session_progress, SDP1}, ReqId),
                    timer:sleep(100),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {answer, SDP2});
                <<"rel-prov-answer2">> ->
                    SDP = case nksip_lib:get_value(body, Meta) of
                        #sdp{} = RemoteSDP ->
                            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(AppId)}};
                        _ -> 
                            <<>>
                    end,
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    nksip:reply(From, ok);
                <<"rel-prov-answer3">> ->
                    SDP = nksip_sdp:new(nksip_lib:to_binary(AppId), [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
                    ok = nksip_request:reply({rel_ringing, SDP}, ReqId),
                    timer:sleep(100),
                    nksip:reply(From, ok);
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State}.


reinvite(ReqId, Meta, From, State) ->
    invite(ReqId, Meta, From, State).


ack(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, ack),
    {reply, ok, State}.


prack(ReqId, Meta, _From, AppId=State) ->
    RAck = nksip_request:field(ReqId, parsed_rack),
    tests_util:send_ref(AppId, Meta, {prack, RAck}),
    Body = case nksip_lib:get_value(body, Meta) of
        #sdp{} = RemoteSDP ->
            RemoteSDP#sdp{address={<<"IN">>, <<"IP4">>, nksip_lib:to_binary(AppId)}};
        _ -> 
            <<>>
    end,        
    {reply, {answer, Body}, State}.


dialog_update(DialogId, Update, State) ->
    tests_util:dialog_update(DialogId, Update, State),
    {noreply, State}.


session_update(DialogId, Update, State) ->
    tests_util:session_update(DialogId, Update, State),
    {noreply, State}.



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(AppId, DialogId) ->
    {ok, Sessions} = nksip:get(AppId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.






