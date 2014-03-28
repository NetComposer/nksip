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

    ok = nksip:start(client1, ?MODULE, client1, [
        {from, "sip:client1@nksip"},
        {local_host, "localhost"},
        {supported, []},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ]),
    
    ok = nksip:start(client2, ?MODULE, client2, [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {supported, []},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).



cancel() ->
    client1 = client1,
    Ref = make_ref(),
    Self = self(),
    RepHd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Fun = fun({ok, Code, _}) -> Self ! {Ref, Code} end,

    % Receive generated busy
    Hds1 = [{add, "x-nk-sleep", 300}, {add, "x-nk-op", busy}, RepHd],
    {ok, 486, _} = nksip_uac:invite(client1, "sip:any@127.0.0.1:5070", 
                                    [{callback, Fun} | Hds1]),

    Hds2 = [{add, "x-nk-sleep", 3000}, {add, "x-nk-op", ok}, {add, "x-nk-prov", "true"}, RepHd],
    Remote = "sip:any@127.0.0.1:5070",

    % Test manual CANCEL
    {async, Req3Id} = nksip_uac:invite(client1, "sip:any@127.0.0.1:5070", 
                                        [{callback, Fun}, async | Hds2]),
    timer:sleep(100),
    ok = nksip_uac:cancel(client1, Req3Id),
    
    % Test invite expire, UAC must send CANCEL
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

    {ok, 200, [{dialog_id, DialogIdA}]} = 
        nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", [{body, SDP}|Hds]),
    ok = nksip_uac:ack(client1, DialogIdA, []),
    % We don't receive callbacks from client1, since it has not stored the reply in 
    % its state
    ok = tests_util:wait(Ref, [{client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),
    
    [
        {invite_status, confirmed},
        {created, Created}, 
        {updated, Updated}, 
        {invite_answered, Answered}, 
        {parsed_local_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {remote_target, <<"<sip:ok@127.0.0.1:5070>">>},
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
    ] = nksip_dialog:fields(client1, DialogIdA, [
                                invite_status, created, updated, invite_answered, 
                                parsed_local_target, remote_target, route_set, early,
                                secure, local_seq, remote_seq, invite_local_sdp, 
                                invite_remote_sdp, call_id]),
    

    Now = nksip_lib:timestamp(),
    true = (Now - Created) < 2,
    true = (Now - Updated) < 2,
    true = (Now - Answered) < 2,
    true = (Now - LocalSDPId) < 2,
    true = (Now - RemoteSDPId) < 2,

    % Hack to find remote dialog
    DialogIdB = nksip_dialog:field(client1, DialogIdA, remote_id),
    [
        {invite_status, confirmed},
        {created, Created2},
        {updated, Updated2},
        {invite_answered, Answered2},
        {local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {parsed_remote_target, 
                    #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {route_set, []},
        {early, false},
        {secure, false},
        {local_seq, 0},
        {remote_seq, CSeq},
        {invite_local_sdp, RemoteSDP},
        {invite_remote_sdp, LocalSDP},
        {call_id, CallId}
    ] = nksip_dialog:fields(client2, DialogIdB, [
                                invite_status, created, updated, invite_answered, 
                                local_target, parsed_remote_target, route_set, early,
                                secure, local_seq, remote_seq, invite_local_sdp, 
                                invite_remote_sdp, call_id]),
    true = (Now - Created2) < 2,
    true = (Now - Updated2) < 2,
    true = (Now - Answered2) < 2,

    {RemoteSDP, LocalSDP} = get_sessions(client2, DialogIdB),


    % Sends an in-dialog OPTIONS. Local CSeq should be incremented
    {ok, 200, [{cseq_num, CSeq1}]} = 
        nksip_uac:options(client1, DialogIdA, [{meta, [cseq_num]}]),
    CSeq = CSeq1 - 1,
    0 = nksip_dialog:field(client1, DialogIdA, remote_seq),
    0 = nksip_dialog:field(client2, DialogIdB, local_seq),
    CSeq = nksip_dialog:field(client2, DialogIdB, remote_seq) - 1,

    % Sends now from the remote party to us, forcing initial CSeq
    {ok, 200, []} = nksip_uac:options(client2, DialogIdB, [{cseq_num, 9999}]),
    CSeq = nksip_dialog:field(client1, DialogIdA, local_seq) -1,
    9999 = nksip_dialog:field(client1, DialogIdA, remote_seq),
    9999 = nksip_dialog:field(client2, DialogIdB, local_seq),
    CSeq = nksip_dialog:field(client2, DialogIdB, remote_seq) -1,

    % Force invalid CSeq
    {ok, 500, [{reason_phrase, <<"Old CSeq in Dialog">>}]} = 
        nksip_uac:options(client2, DialogIdB, [{cseq_num, 9998}, {meta, [reason_phrase]}]),

    [DialogIdA] = nksip_dialog:get_all(client1, CallId),
    [DialogIdB] = nksip_dialog:get_all(client2, CallId),
    
    % Send the dialog de opposite way
    {ok, 200, [{dialog_id, DialogIdB}]} = nksip_uac:invite(client2, DialogIdB, Hds),
    ok = nksip_uac:ack(client2, DialogIdB, []),

    % Now we receive callbacks from both
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),

    {ok, 200, []} = nksip_uac:bye(client1, DialogIdA, []),
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
        {add, "record-route", nksip_lib:bjoin(lists:reverse(RR), <<", ">>)}],

    {ok, 200, [{dialog_id, DialogIdA}, {<<"record-route">>, RRH}]} = 
            nksip_uac:invite(client1, "sip:ok@127.0.0.1:5070", 
                                    [{contact, "sip:abc"},
                                     {meta, [<<"record-route">>]}|Hds1]),

    % Test Record-Route is replied
    RR = lists:reverse(RRH),
    FunAck = fun({req, ACKReq1}) -> 
        % Test body in ACK, and Route and Contact generated in ACK
        RR = nksip_sipmsg:header(ACKReq1, <<"route">>),
        [<<"<sip:abc>">>] = nksip_sipmsg:header(ACKReq1, <<"contact">>),
        Self ! {Ref, fun_ack_ok}
    end,
    async = nksip_uac:ack(client1, DialogIdA, 
                          [{body, SDP}, async, get_request, {callback, FunAck}]),
    ok = tests_util:wait(Ref, [fun_ack_ok, {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),

    % Test generated dialog values: local and remote targets, record route, SDPs.
    [
        {local_target, <<"<sip:abc>">>},
        {remote_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {route_set, RR},
        {invite_local_sdp, 
            #sdp{vsn=LVsn1, connect={_, _, <<"client1">>}, medias=[LMed1]} = LocalSDP},
        {invite_remote_sdp, 
            #sdp{vsn=RVsn1, connect={_, _, <<"client2">>}} = RemoteSDP}
    ] = nksip_dialog:fields(client1, DialogIdA, [local_target, remote_target, route_set, 
                                              invite_local_sdp, invite_remote_sdp]),

    DialogIdB = nksip_dialog:field(client1, DialogIdA, remote_id),
    [
        {local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {remote_target, <<"<sip:abc>">>},
        {route_set, RR1},
        {invite_local_sdp, RemoteSDP}, 
        {invite_remote_sdp, LocalSDP}
    ] = nksip_dialog:fields(client2, DialogIdB, [local_target, remote_target, route_set, 
                                invite_local_sdp, invite_remote_sdp]),
    true = lists:member({<<"sendrecv">>, []}, LMed1#sdp_m.attributes),
    RR1 = lists:reverse(RR),

    {RemoteSDP, LocalSDP} = get_sessions(client2, DialogIdB),

    Fun = fun(R) ->
        case R of
            {req, Req} ->
                RR = nksip_sipmsg:header(Req, <<"route">>),
                [#uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}] = 
                    nksip_sipmsg:header(Req, <<"contact">>, uris),
                Self ! {Ref, req_ok};
            {ok, Code, [{dialog_id, _}]} ->
                if 
                    Code < 200 -> ok;
                    Code < 300 -> Self ! {Ref, Code}
                end
        end
    end,
    
    % Reinvite updating SDP
    SDP2 = nksip_sdp:update(SDP, sendonly), 
    Hds2 = [{add, "x-nk-op", increment}, {add, "record-route", "<sip:ddd>"}, RepHd],
    {async, _} = nksip_uac:invite(client1, DialogIdA, [
        {body, SDP2}, contact, async, {callback, Fun}, get_request | Hds2]),

    % Test Route Set cannot change now, it is already answered
    receive {Ref, 200} -> 
        {req, ACKReq2} = nksip_uac:ack(client1, DialogIdA, [get_request]),
        RR = nksip_sipmsg:header(ACKReq2, <<"route">>),
        [#uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}] = 
            nksip_sipmsg:header(ACKReq2, <<"contact">>, uris),
        ok = tests_util:wait(Ref, [req_ok,
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
    [
        {invite_local_sdp, 
            #sdp{vsn=LVsn2, connect={_, _, <<"client1">>}, medias=[LMed2]}=LocalSDP2},
        {invite_remote_sdp, 
            #sdp{vsn=RVsn2, connect={_, _, <<"client2">>}} = RemoteSDP2},
        {parsed_local_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {remote_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ] = nksip_dialog:fields(client1, DialogIdA, 
                    [invite_local_sdp, invite_remote_sdp, parsed_local_target,
                     remote_target]),

    [
        {invite_local_sdp, RemoteSDP2},
        {invite_remote_sdp, LocalSDP2},
        {parsed_remote_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {local_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ] = nksip_dialog:fields(client2, DialogIdB, 
                    [invite_local_sdp, invite_remote_sdp, parsed_remote_target,
                     local_target]),
    true = lists:member({<<"sendonly">>, []}, LMed2#sdp_m.attributes),

    {RemoteSDP2, LocalSDP2} = get_sessions(client2, DialogIdB),


    % reINVITE from the other party
    Hds3 = [{add, "x-nk-op", increment}, RepHd],
    {ok, 200, [{dialog_id, DialogIdB}]} = 
        nksip_uac:refresh(client2, DialogIdB, Hds3),
    ok = nksip_uac:ack(client2, DialogIdB, []),
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client1, sdp_update},
                               {client2, dialog_confirmed},
                               {client2, sdp_update}]),

    LVsn3 = LVsn2+1, RVsn3 = RVsn2+1,
    [
        {invite_local_sdp, #sdp{vsn=LVsn3, connect={_, _, <<"client1">>}} = LocalSDP3},
        {invite_remote_sdp, #sdp{vsn=RVsn3, connect={_, _, <<"client2">>}} = RemoteSDP3}
    ] = nksip_dialog:fields(client1, DialogIdA, [invite_local_sdp, invite_remote_sdp]),
    
    [
        {invite_local_sdp, RemoteSDP3},
        {invite_remote_sdp, LocalSDP3}
    ] = nksip_dialog:fields(client2, DialogIdB, [invite_local_sdp, invite_remote_sdp]),

    %% Test Contact is not modified
    {ok, 200, []} = nksip_uac:options(client1, DialogIdA, [{contact, <<"sip:aaa">>}]),
    [
        {invite_local_sdp, #sdp{vsn=LVsn3}},
        {invite_remote_sdp, #sdp{vsn=RVsn3}},
        {parsed_local_target, 
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {remote_target, <<"<sip:ok@127.0.0.1:5070>">>}
    ] = nksip_dialog:fields(client1, DialogIdA, 
                            [invite_local_sdp, invite_remote_sdp, parsed_local_target, remote_target]),
    
    [
        {parsed_remote_target,  
            #uri{user = <<"client1">>, domain = <<"localhost">>, port=5060}}, 
        {local_target, <<"<sip:ok@127.0.0.1:5070>">>},
        {invite_local_sdp, #sdp{vsn=RVsn3}}
    ] = nksip_dialog:fields(client2, DialogIdB, 
                            [parsed_remote_target, local_target, invite_local_sdp]),
   

    {LocalSDP3, RemoteSDP3} = get_sessions(client1, DialogIdA),
    {RemoteSDP3, LocalSDP3} = get_sessions(client2, DialogIdB),

    ByeFun = fun(Reply) ->
        case Reply of
            {req, ByeReq} ->
                RevRR = nksip_sipmsg:header(ByeReq, <<"route">>),
                RR = lists:reverse(RevRR),
                [<<"<sip:ok@127.0.0.1:5070>">>] = 
                    nksip_sipmsg:header(ByeReq, <<"contact">>),
                Self ! {Ref, bye_ok1};
            {ok, 200, []} ->
                Self ! {Ref, bye_ok2}
        end
    end,

    {async, _} = nksip_uac:bye(client2, DialogIdB, [async, {callback, ByeFun}, get_request]),
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
    {ok, 200, [{dialog_id, DialogIdA}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", 
                         [RepHd, OpAnswer]),
    [{local_seq, _CSeq}, {invite_status, accepted_uac}] = 
        nksip_dialog:fields(client1, DialogIdA, [local_seq, invite_status]),
    
    {error, request_pending} = nksip_uac:invite(client1, DialogIdA, []), 
    ok = nksip_uac:ack(client1, DialogIdA, []),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    Fun = fun({ok, 200, [{dialog_id, _}]}) -> Self ! {Ref, ok1} end,
    DialogIdB = nksip_dialog:field(client1, DialogIdA, remote_id),
    {async, _} = nksip_uac:invite(client2, DialogIdB, 
                                        [async, {callback, Fun}, OpAnswer]),
    ok = tests_util:wait(Ref, [ok1]),
    % % CSeq uses next NkSIP's cseq. The next for dialog is CSeq+1, the first 
    % % dialog's reverse CSeq is next+1000
    {ok, 200, []} = nksip_uac:bye(client1, DialogIdA, []),
    ok = tests_util:wait(Ref, [{client2, bye}, {client2, {dialog_stop, caller_bye}}]),
    ok.


multiple_uas() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [{add, "x-nk-op", ok}, RepHd],

    % Set a new dialog between client1 and client2
    {ok, 200, [{dialog_id, DialogId1A}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", Hds),
    ok = nksip_uac:ack(client1, DialogId1A, [RepHd]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    confirmed = nksip_dialog:field(client1, DialogId1A, invite_status),
    DialogId1B = nksip_dialog:field(client1, DialogId1A, remote_id),
    confirmed = nksip_dialog:field(client2, DialogId1B, invite_status),

    MakeFun = fun(AppId) ->
        fun(Reply) ->
            case Reply of
                {req, _} -> Self ! 
                    {Ref, request};
                {ok, Code, _} when Code < 200 -> 
                    Self ! {Ref, provisional};
                {ok, Code, [{dialog_id, FDlgId}]} when Code < 300 -> 
                    spawn(
                        fun() -> 
                            nksip_uac:ack(AppId, FDlgId, [RepHd]) 
                        end)
            end
        end
    end,

    % Send a new reinvite, it will spend 300msecs before answering
    {async, _} = nksip_uac:invite(client1, DialogId1A,  
                                    [async, {callback, MakeFun(client1)}, get_request,
                                    {add, "x-nk-sleep", 300}|Hds]),
    ok = tests_util:wait(Ref, [request]),   % Wait to be sent

    % Before the previous invite has been answered, we send a new one
    % {error, request_pending} = 
    % UAS replies with 500
    {ok, 500, [{reason_phrase, <<"Processing Previous INVITE">>}]} = 
        nksip_uac:invite(client1, DialogId1A, 
                           [no_dialog, {meta, [reason_phrase]}|Hds]),

    % % Previous invite will reply 200, and Fun will send ACK
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]), 
    
    confirmed = nksip_dialog:field(client1, DialogId1A, invite_status),
    confirmed = nksip_dialog:field(client2, DialogId1B, invite_status),
    {ok, 200, []} = nksip_uac:bye(client1, DialogId1A, []),
    ok = tests_util:wait(Ref, [{client2, {dialog_stop, caller_bye}}, {client2, bye}]),

    % Set a new dialog
    {ok, 200, [{dialog_id, DialogId2A}]} = 
        nksip_uac:invite(client1, "<sip:ok@127.0.0.1:5070;transport=tcp>", Hds),
    ok = nksip_uac:ack(client1, DialogId2A, [RepHd]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    [{invite_status, confirmed}, {local_seq, LSeq}, {remote_seq, RSeq}] = 
        nksip_dialog:fields(client1, DialogId2A, [invite_status, local_seq, remote_seq]),
    DialogId2B = nksip_dialog:field(client1, DialogId2A, remote_id),
    [{invite_status, confirmed}, {local_seq, RSeq}, {remote_seq, LSeq}] = 
        nksip_dialog:fields(client2, DialogId2B, [invite_status, local_seq, remote_seq]),

    % The remote party (client2) will send a reinvite to the local (client1),
    % but the response will be delayed 300msecs
    Hds2 = [{add, "x-nk", 1}, {add, "x-nk-prov", "true"}, {add, "x-nk-sleep", 300}|Hds],
    {async, _} = nksip_uac:invite(client2, DialogId2B, [async, {callback, MakeFun(client2)}, 
                                                  get_request | Hds2]),
    ok = tests_util:wait(Ref, [request, provisional]),   
    % Before answering, the local party sends a new reinvite. The remote party
    % replies a 491
    % {error, request_pending} = 
    {ok, 491, _} = 
        nksip_uac:invite(client1, DialogId2A, [no_dialog, {add, "x-nk", 2}]),
    % The previous invite will be answered, and Fun will send the ACK
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),
    {ok, 200, [{cseq_num, BCSeq}]} = nksip_uac:bye(client1, DialogId2A, [{meta,[cseq_num]}]),
    BCSeq = LSeq+2,
    ok = tests_util:wait(Ref, [{client1, {dialog_stop, caller_bye}},
                               {client2, {dialog_stop, caller_bye}},
                               {client2, bye}]),
    ok.




%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.

invite(ReqId, Meta, From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Values = nksip_request:header(AppId, ReqId, <<"x-nk">>),
    Hds = case Values of [] -> []; _ -> [{add, "x-nk", nksip_lib:bjoin(Values)}] end,
    Op = case nksip_request:header(AppId, ReqId, <<"x-nk-op">>) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    Sleep = case nksip_request:header(AppId, ReqId, <<"x-nk-sleep">>) of
        [Sleep0] -> nksip_lib:to_integer(Sleep0);
        _ -> 0
    end,
    Prov = case nksip_request:header(AppId, ReqId, <<"x-nk-prov">>) of
        [<<"true">>] -> true;
        _ -> false
    end,
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(AppId, ReqId, ringing); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip:reply(From, {ok, Hds});
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip:reply(From, {ok, [{body, SDP}|Hds]});
                <<"busy">> ->
                    nksip:reply(From, busy);
                <<"increment">> ->
                    DialogId = nksip_lib:get_value(dialog_id, Meta),
                    SDP1 = nksip_dialog:field(AppId, DialogId, invite_local_sdp),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {ok, [{body, SDP2}|Hds]});
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


options(ReqId, _Meta, _From, AppId=State) ->
    Ids = nksip_request:header(AppId, ReqId, <<"x-nk-id">>),
    Hds = [{add, "x-nk-id", nksip_lib:bjoin([AppId|Ids])}],
    {reply, {ok, [contact|Hds]}, State}.


bye(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, bye),
    {reply, ok, State}.


dialog_update(DialogId, Update, AppId=State) ->
    tests_util:dialog_update(DialogId, Update, AppId),
    {noreply, State}.


session_update(DialogId, Update, AppId=State) ->
    tests_util:session_update(DialogId, Update, AppId),
    {noreply, State}.



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(AppId, DialogId) ->
    {ok, Sessions} = nksip:get(AppId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.

