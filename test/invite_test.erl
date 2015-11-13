%% -------------------------------------------------------------------
%%
%% invite_test: Invite Suite Test
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

-module(invite_test).
-include_lib("nklib/include/nklib.hrl").

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

invite_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        {inparallel, [
            {timeout, 60, fun cancel/0},
            {timeout, 60, fun dialog/0},
            {timeout, 60, fun rr_contact/0},
            {timeout, 60, fun multiple_uac/0},
            {timeout, 60, fun multiple_uas/0}
        ]}
    }.


start() ->
    tests_util:start_nksip(),

    ok = tests_util:start(client1, ?MODULE, [
        {sip_from, "sip:client1@nksip"},
        {sip_local_host, "localhost"},
        {sip_supported, []},
        {transports, "sip:all:5060, <sip:all:5061;transport=tls>"}
    ]),
    
    ok = tests_util:start(client2, ?MODULE, [
        {sip_from, "sip:client2@nksip"},
        {sip_no_100, true},
        {sip_local_host, "127.0.0.1"},
        {sip_supported, []},
        {transports, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).



cancel() ->
    Ref = make_ref(),
    Self = self(),
    RepHd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Fun = fun({resp, Code, _, _}) -> Self ! {Ref, Code} end,

    % Receive generated busy
    Hds1 = [{add, "x-nk-sleep", 300}, {add, "x-nk-op", busy}, RepHd],
    {ok, 486, _} = nksip_uac:invite(client1, "sip:any@127.0.0.1:5070", 
                                    [{callback, Fun} | Hds1]),
    
    % Test manual CANCEL
    Hds2 = [{add, "x-nk-sleep", 3000}, {add, "x-nk-op", ok}, 
            {add, "x-nk-prov", "true"}, RepHd],
    {async, Req3Id} = nksip_uac:invite(client1, "sip:any@127.0.0.1:5070", 
                                        [{callback, Fun}, async | Hds2]),
    timer:sleep(100),
    ok = nksip_uac:cancel(Req3Id, []),
    
    % Test invite expire, UAC must send CANCEL
    Remote = "sip:any@127.0.0.1:5070",
    {ok, 487, _} = nksip_uac:invite(client1, Remote, 
                              [{callback, Fun}, {expires, 1} | Hds2]),

    % Test invite expire, UAC will ignore and UAS must CANCEL
    {ok, 487, _} = nksip_uac:invite(client1, "sip:any@127.0.0.1:5070", 
                                        [{callback, Fun}, {expires, 1}, no_auto_expire
                                          | Hds2]),
    
    ok = tests_util:wait(Ref, [180, 487, 180, 180,
                               {client2, {dialog_stop, cancelled}},
                               {client2, {dialog_stop, cancelled}},
                               {client2, {dialog_stop, cancelled}}]),
    ok.


dialog() ->
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [{add, "x-nk-op", "answer"}, RepHd],
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),

    {ok, 200, [{dialog, DialogIdA}]} = 
        nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", [{body, SDP}|Hds]),
    ok = nksip_uac:ack(DialogIdA, []),
    % We don't receive callbacks from client1, since it has not stored the reply in 
    % its state
    ok = tests_util:wait(Ref, [{client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),
    
    {ok, [
        {invite_status, confirmed},
        {created, Created}, 
        {updated, Updated}, 
        {invite_answered, Answered}, 
        {local_target, #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {raw_remote_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {route_set, []},
        {early, false},
        {secure, false},
        {local_seq, CSeq},
        {remote_seq, 0},
        {invite_local_sdp, #sdp{
            id = LocalSDPId,
            vsn = LocalSDPId,
            address = {<<"IN">>, <<"IP4">>, <<"client1">>},
            session = <<"nksip">>,
            connect = {<<"IN">>, <<"IP4">>, <<"client1">>},
            time = [{0, 0, []}],
            medias = [
                #sdp_m{
                    media = <<"test">>,
                    port = 1234,
                    fmt = [<<"0">>],
                    attributes = [{<<"rtpmap">>, [<<"0">>,<<"codec1">>]}]
                }]
        } = LocalSDP},
        {invite_remote_sdp, #sdp{
            id = RemoteSDPId,
            vsn = RemoteSDPId,
            address = {<<"IN">>, <<"IP4">>, <<"client2">>},
            session = <<"nksip">>,
            connect = {<<"IN">>, <<"IP4">>, <<"client2">>},
            time = [{0, 0, []}],
            medias = [
                #sdp_m{
                    media = <<"test">>,
                    port = 4321,
                    fmt = [<<"0">>],
                    attributes = [{<<"rtpmap">>, [<<"0">>,<<"codec1">>]}]
                }]      
        } = RemoteSDP},
        {call_id, CallId}
    ]} = nksip_dialog:metas([
            invite_status, created, updated, invite_answered, 
            local_target, raw_remote_target, route_set, early,
            secure, local_seq, remote_seq, invite_local_sdp, 
            invite_remote_sdp, call_id],
            DialogIdA),

    
    Now = nklib_util:timestamp(),
    true = (Now - Created) < 2,
    true = (Now - Updated) < 2,
    true = (Now - Answered) < 2,
    true = (Now - LocalSDPId) < 2,
    true = (Now - RemoteSDPId) < 2,

    % Hack to find remote dialog
    DialogIdB = nksip_dialog_lib:remote_id(DialogIdA, client2),
    {ok, [
        {invite_status, confirmed},
        {created, Created2},
        {updated, Updated2},
        {invite_answered, Answered2},
        {raw_local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {remote_target, 
                    #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {route_set, []},
        {early, false},
        {secure, false},
        {local_seq, 0},
        {remote_seq, CSeq},
        {invite_local_sdp, RemoteSDP},
        {invite_remote_sdp, LocalSDP},
        {call_id, CallId}
    ]} = nksip_dialog:metas([
            invite_status, created, updated, invite_answered, 
            raw_local_target, remote_target, route_set, early,
            secure, local_seq, remote_seq, invite_local_sdp, 
            invite_remote_sdp, call_id],
            DialogIdB),
    true = (Now - Created2) < 2,
    true = (Now - Updated2) < 2,
    true = (Now - Answered2) < 2,

    {RemoteSDP, LocalSDP} = get_sessions(client2, DialogIdB),


    % Sends an in-dialog OPTIONS. Local CSeq should be incremented
    {ok, 200, [{cseq_num, CSeq1}]} = nksip_uac:options(DialogIdA, [{meta, [cseq_num]}]),
    CSeq = CSeq1 - 1,
    {ok, 0} = nksip_dialog:meta(remote_seq, DialogIdA),
    {ok, 0} = nksip_dialog:meta(local_seq, DialogIdB),
    CSeq = element(2, nksip_dialog:meta(remote_seq, DialogIdB)) - 1,

    % Sends now from the remote party to us, forcing initial CSeq
    {ok, 200, []} = nksip_uac:options(DialogIdB, [{cseq_num, 9999}]),
    CSeq = element(2, nksip_dialog:meta(local_seq, DialogIdA)) -1,
    {ok, 9999} = nksip_dialog:meta(remote_seq, DialogIdA),
    {ok, 9999} = nksip_dialog:meta(local_seq, DialogIdB),
    CSeq = element(2, nksip_dialog:meta(remote_seq, DialogIdB)) -1,

    % Force invalid CSeq
    {ok, 500, [{reason_phrase, <<"Old CSeq in Dialog">>}]} = 
        nksip_uac:options(DialogIdB, [{cseq_num, 9998}, {meta, [reason_phrase]}]),

    [DialogIdA] = nksip_dialog:get_all(client1, CallId),
    [DialogIdB] = nksip_dialog:get_all(client2, CallId),
    
    % Send the dialog de opposite way
    {ok, 200, [{dialog, DialogIdB}]} = nksip_uac:invite(DialogIdB, Hds),
    ok = nksip_uac:ack(DialogIdB, []),

    % Now we receive callbacks from both
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),

    {ok, 200, []} = nksip_uac:bye(DialogIdA, []),
    ok = tests_util:wait(Ref, [{client2, {dialog_stop, caller_bye}}, 
                               {client1, {dialog_stop, caller_bye}},
                               {client1, sdp_stop},
                               {client2, sdp_stop},
                               {client2, bye}]),
    ok.


rr_contact() ->
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}, sendrecv]}]),
    RR = [<<"<sip:127.0.0.1:5070;lr>">>, <<"<sips:abc:123>">>, <<"<sip:127.0.0.1;lr>">>],
    Hds1 = [
        {add, "x-nk-op", "answer"}, RepHd,
        {add, "record-route", nklib_util:bjoin(lists:reverse(RR), <<", ">>)}],

    {ok, 200, [{dialog, DialogIdA}, {<<"record-route">>, RRH}]} = 
            nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", 
                                    [{contact, "sip:abc"},
                                     {meta, [<<"record-route">>]}|Hds1]),

    % Test Record-Route is replied
    RR = lists:reverse(RRH),
    FunAck = fun({req, ACKReq1, _Call}) -> 
        % Test body in ACK, and Route and Contact generated in ACK
        RR = nksip_sipmsg:header(<<"route">>, ACKReq1),
        [<<"<sip:abc>">>] = nksip_sipmsg:header(<<"contact">>, ACKReq1),
        Self ! {Ref, fun_ack_ok}
    end,
    async = nksip_uac:ack(DialogIdA, 
                          [{body, SDP}, async, get_request, {callback, FunAck}]),
    ok = tests_util:wait(Ref, [fun_ack_ok, {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),

    % Test generated dialog values: local and remote targets, record route, SDPs.
    {ok, [
        {raw_local_target, <<"<sip:abc>">>},
        {raw_remote_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {raw_route_set, RR},
        {invite_local_sdp, 
            #sdp{vsn=LVsn1, connect={_, _, <<"client1">>}, medias=[LMed1]} = LocalSDP},
        {invite_remote_sdp, 
            #sdp{vsn=RVsn1, connect={_, _, <<"client2">>}} = RemoteSDP}
    ]} = nksip_dialog:metas([raw_local_target, raw_remote_target, raw_route_set, 
                            invite_local_sdp, invite_remote_sdp], DialogIdA),

    DialogIdB = nksip_dialog_lib:remote_id(DialogIdA, client2),
    {ok, [
        {raw_local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {raw_remote_target, <<"<sip:abc>">>},
        {raw_route_set, RR1},
        {invite_local_sdp, RemoteSDP}, 
        {invite_remote_sdp, LocalSDP}
    ]} = nksip_dialog:metas([raw_local_target, raw_remote_target, raw_route_set, 
                            invite_local_sdp, invite_remote_sdp], DialogIdB),
    true = lists:member({<<"sendrecv">>, []}, LMed1#sdp_m.attributes),
    RR1 = lists:reverse(RR),

    {RemoteSDP, LocalSDP} = get_sessions(client2, DialogIdB),

    Fun = fun(R) ->
        case R of
            {req, Req, _Call} ->
                RR = nksip_sipmsg:header(<<"route">>, Req),
                [#uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}] = 
                    nksip_sipmsg:header(<<"contact">>, Req, uris),
                Self ! {Ref, req_ok};
            {resp, Code, _Req, _Call} ->
                if 
                    Code < 200 -> ok;
                    Code < 300 -> Self ! {Ref, Code}
                end
        end
    end,
    
    % Reinvite updating SDP
    SDP2 = nksip_sdp:update(SDP, sendonly), 
    Hds2 = [{add, "x-nk-op", increment}, {add, "record-route", "<sip:ddd>"}, RepHd],
    {async, _} = nksip_uac:invite(DialogIdA, [
        {body, SDP2}, contact, async, {callback, Fun}, get_request | Hds2]),

    % Test Route Set cannot change now, it is already answered
    receive {Ref, 200} -> 
        FunAck2 = fun({req, ACKReq2, _Call}) ->
            RR = nksip_sipmsg:header(<<"route">>, ACKReq2),
            [#uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}] = 
                nksip_sipmsg:header(<<"contact">>, ACKReq2, uris),
            Self ! {Ref, ack_2_ok}
        end,
        ok = nksip_uac:ack(DialogIdA, [{callback, FunAck2}, get_request]),
        ok = tests_util:wait(Ref, [req_ok, ack_2_ok,
                                   {client2, ack}, 
                                   {client2, sdp_update},
                                   {client2, target_update},
                                   {client2, dialog_confirmed}])
    after 5000 -> 
        error(dialog2) 
    end,
    
    % Test SDP version has been incremented
    LVsn2 = LVsn1+1, 
    RVsn2 = RVsn1+1,
    {ok, [
        {invite_local_sdp, 
            #sdp{vsn=LVsn2, connect={_, _, <<"client1">>}, medias=[LMed2]}=LocalSDP2},
        {invite_remote_sdp, 
            #sdp{vsn=RVsn2, connect={_, _, <<"client2">>}} = RemoteSDP2},
        {local_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {raw_remote_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ]} = nksip_dialog:metas([invite_local_sdp, invite_remote_sdp, local_target,
                            raw_remote_target], DialogIdA),

    {ok, [
        {invite_local_sdp, RemoteSDP2},
        {invite_remote_sdp, LocalSDP2},
        {remote_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {raw_local_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ]} = nksip_dialog:metas([invite_local_sdp, invite_remote_sdp, remote_target,
                            raw_local_target], DialogIdB),
    true = lists:member({<<"sendonly">>, []}, LMed2#sdp_m.attributes),

    {RemoteSDP2, LocalSDP2} = get_sessions(client2, DialogIdB),


    % reINVITE from the other party
    Hds3 = [{add, "x-nk-op", increment}, RepHd],
    {ok, 200, [{dialog, DialogIdB}]} = nksip_uac:refresh(DialogIdB, Hds3),
    ok = nksip_uac:ack(DialogIdB, []),
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client1, sdp_update},
                               {client2, dialog_confirmed},
                               {client2, sdp_update}]),

    LVsn3 = LVsn2+1, RVsn3 = RVsn2+1,
    {ok, [
        {invite_local_sdp, #sdp{vsn=LVsn3, connect={_, _, <<"client1">>}} = LocalSDP3},
        {invite_remote_sdp, #sdp{vsn=RVsn3, connect={_, _, <<"client2">>}} = RemoteSDP3}
    ]} = nksip_dialog:metas([invite_local_sdp, invite_remote_sdp], DialogIdA),
    
    {ok, [
        {invite_local_sdp, RemoteSDP3},
        {invite_remote_sdp, LocalSDP3}
    ]} = nksip_dialog:metas([invite_local_sdp, invite_remote_sdp], DialogIdB),

    %% Test Contact is not modified
    {ok, 200, []} = nksip_uac:options(DialogIdA, [{contact, <<"sip:aaa">>}]),
    {ok, [
        {invite_local_sdp, #sdp{vsn=LVsn3}},
        {invite_remote_sdp, #sdp{vsn=RVsn3}},
        {local_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {raw_remote_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ]} = nksip_dialog:metas([invite_local_sdp, invite_remote_sdp, 
                            local_target, raw_remote_target], DialogIdA),
    
    {ok, [
        {remote_target,  
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {raw_local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {invite_local_sdp, #sdp{vsn=RVsn3}}
    ]} = nksip_dialog:metas([remote_target, raw_local_target, invite_local_sdp],
                           DialogIdB), 
   
    {LocalSDP3, RemoteSDP3} = get_sessions(client1, DialogIdA),
    {RemoteSDP3, LocalSDP3} = get_sessions(client2, DialogIdB),

    ByeFun = fun(Reply) ->
        case Reply of
            {req, ByeReq, _Call} ->
                RevRR = nksip_sipmsg:header(<<"route">>, ByeReq),
                RR = lists:reverse(RevRR),
                [<<"<sip:ok@127.0.0.1:5070>">>] = 
                    nksip_sipmsg:header(<<"contact">>, ByeReq),
                Self ! {Ref, bye_ok1};
            {resp, 200, _Req, _Call} ->
                Self ! {Ref, bye_ok2}
        end
    end,

    {async, _} = nksip_uac:bye(DialogIdB, [async, {callback, ByeFun}, get_request]),
    ok = tests_util:wait(Ref, [bye_ok1, bye_ok2, 
                               {client1, {dialog_stop, callee_bye}}, 
                               {client1, sdp_stop},
                               {client2, {dialog_stop, callee_bye}},
                               {client2, sdp_stop},
                               {client1, bye}]),
    ok.


multiple_uac() ->
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    OpAnswer = {add, "x-nk-op", "answer"},
    % Stablish a dialog between client1 and client2, but do not send the ACK 
    % yet, it will stay in accepted_uac state
    {ok, 200, [{dialog, DialogIdA}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", 
                         [RepHd, OpAnswer]),
    {ok, [{local_seq, _CSeq}, {invite_status, accepted_uac}]} = 
        nksip_dialog:metas([local_seq, invite_status], DialogIdA),
    
    {error, request_pending} = nksip_uac:invite(DialogIdA, []), 
    ok = nksip_uac:ack(DialogIdA, []),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    Fun = fun({resp, 200, _Req, _Call}) -> Self ! {Ref, ok1} end,
    DialogIdB = nksip_dialog_lib:remote_id(DialogIdA, client2),
    {async, _} = nksip_uac:invite(DialogIdB, [async, {callback, Fun}, OpAnswer]),
    ok = tests_util:wait(Ref, [ok1]),
    % % CSeq uses next NkSIP's cseq. The next for dialog is CSeq+1, the first 
    % % dialog's reverse CSeq is next+1000
    {ok, 200, []} = nksip_uac:bye(DialogIdA, []),
    ok = tests_util:wait(Ref, [{client2, bye}, {client2, {dialog_stop, caller_bye}}]),
    ok.


multiple_uas() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [{add, "x-nk-op", ok}, RepHd],

    % Set a new dialog between client1 and client2
    {ok, 200, [{dialog, DialogId1A}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", Hds),
    ok = nksip_uac:ack(DialogId1A, [RepHd]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    {ok, confirmed} = nksip_dialog:meta(invite_status, DialogId1A),
    DialogId1B = nksip_dialog_lib:remote_id(DialogId1A, client2),
    {ok, confirmed} = nksip_dialog:meta(invite_status, DialogId1B),

    MakeFun = fun() ->
        fun(Reply) ->
            case Reply of
                {req, _Req, _Call} -> 
                    Self ! {Ref, request};
                {resp, Code, _Resp, _Call} when Code < 200 -> 
                    Self ! {Ref, provisional};
                {resp, Code, Resp, _Call} when Code < 300 -> 
                    {ok, FDlgId} = nksip_dialog:get_handle(Resp),
                    spawn(fun() -> nksip_uac:ack(FDlgId, [RepHd]) end)
            end
        end
    end,

    % Send a new reinvite, it will spend 300msecs before answering
    {async, _} = nksip_uac:invite(DialogId1A,  
                                    [async, {callback, MakeFun()}, get_request,
                                    {add, "x-nk-sleep", 300}|Hds]),
    ok = tests_util:wait(Ref, [request]),   % Wait to be sent

    % Before the previous invite has been answered, we send a new one
    % {error, request_pending} = 
    % UAS replies with 500
    {ok, 500, [{reason_phrase, <<"Processing Previous INVITE">>}]} = 
        nksip_uac:invite(DialogId1A, 
                           [no_dialog, {meta, [reason_phrase]}|Hds]),

    % % Previous invite will reply 200, and Fun will send ACK
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]), 
    
    {ok, confirmed} = nksip_dialog:meta(invite_status, DialogId1A),
    {ok, confirmed} = nksip_dialog:meta(invite_status, DialogId1B),
    {ok, 200, []} = nksip_uac:bye(DialogId1A, []),
    ok = tests_util:wait(Ref, [{client2, {dialog_stop, caller_bye}}, {client2, bye}]),

    % Set a new dialog
    {ok, 200, [{dialog, DialogId2A}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", Hds),
    ok = nksip_uac:ack(DialogId2A, [RepHd]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    {ok, [{invite_status, confirmed}, {local_seq, LSeq}, {remote_seq, RSeq}]} = 
        nksip_dialog:metas([invite_status, local_seq, remote_seq], DialogId2A),
    DialogId2B = nksip_dialog_lib:remote_id(DialogId2A, client2),
    {ok, [{invite_status, confirmed}, {local_seq, RSeq}, {remote_seq, LSeq}]} = 
        nksip_dialog:metas([invite_status, local_seq, remote_seq], DialogId2B),

    % The remote party (client2) will send a reinvite to the local (client1),
    % but the response will be delayed 300msecs
    Hds2 = [{add, "x-nk", 1}, {add, "x-nk-prov", "true"}, {add, "x-nk-sleep", 300}|Hds],
    {async, _} = nksip_uac:invite(DialogId2B, [async, {callback, MakeFun()}, 
                                               get_request | Hds2]),
    ok = tests_util:wait(Ref, [request, provisional]),   
    % Before answering, the local party sends a new reinvite. The remote party
    % replies a 491
    % {error, request_pending} = 
    {ok, 491, _} = nksip_uac:invite(DialogId2A, [no_dialog, {add, "x-nk", 2}]),
    % The previous invite will be answered, and Fun will send the ACK
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),
    {ok, 200, [{cseq_num, BCSeq}]} = nksip_uac:bye(DialogId2A, [{meta,[cseq_num]}]),
    BCSeq = LSeq+2,
    ok = tests_util:wait(Ref, [{client1, {dialog_stop, caller_bye}},
                               {client2, {dialog_stop, caller_bye}},
                               {client2, bye}]),
    ok.




%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


sip_invite(Req, Call) ->
    tests_util:save_ref(Req),
    {ok, Values} = nksip_request:header(<<"x-nk">>, Req),
    Hds = case Values of [] -> []; _ -> [{add, "x-nk", nklib_util:bjoin(Values)}] end,
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    Sleep = case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> nklib_util:to_integer(Sleep0);
        {ok, _} -> 0
    end,
    Prov = case nksip_request:header(<<"x-nk-prov">>, Req) of
        {ok, [<<"true">>]} -> true;
        {ok, _} -> false
    end,
    {ok, ReqId} = nksip_request:get_handle(Req),
    {ok, SDP1} = case nksip_dialog:get_dialog(Req, Call) of
        {ok, Dialog} -> nksip_dialog:meta(invite_local_sdp, Dialog);
        {error, _} -> {ok, undefined}
    end,
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(ringing, ReqId); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip_request:reply({ok, Hds}, ReqId);
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip_request:reply({ok, [{body, SDP}|Hds]}, ReqId);
                <<"busy">> ->
                    nksip_request:reply(busy, ReqId);
                <<"increment">> ->
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({ok, [{body, SDP2}|Hds]}, ReqId);
                _ ->
                    nksip:reply(decline, ReqId)
            end
        end),
    noreply.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_options(Req, _Call) ->
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, App} = nksip_request:srv_name(Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([App|Ids])}],
    {reply, {ok, [contact|Hds]}}.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.


sip_dialog_update(Update, Dialog, _Call) ->
    tests_util:dialog_update(Update, Dialog),
    ok.


sip_session_update(Update, Dialog, _Call) ->
    tests_util:session_update(Update, Dialog),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(SrvId, DialogId) ->
    Sessions = nkservice:get(SrvId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.

