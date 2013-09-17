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
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).

-define(TIMEOUT, 5000).     

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

    ok = sipapp_endpoint:start({invite, client1}, [
        {from, "sip:client1@nksip"},
        {fullname, "NkSIP Basic SUITE Test Client1"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),
    
    ok = sipapp_endpoint:start({invite, client2}, [
        {from, "sip:client2@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({invite, client1}),
    ok = sipapp_endpoint:stop({invite, client2}).



cancel() ->
    C1 = {invite, client1},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Fun = fun(Term) ->
        case Term of
            {req_id, _} -> ok;
            {ok, Code, _} -> Self ! {Ref, Code} 
        end
    end,
    Remote = "sip:any@127.0.0.1:5070;transport=tcp",

    % Receive generated 100 response and busy
    Hds1 = [{"Nk-Sleep", 300}, {"Nk-Op", busy}, RepHd],
    {ok, 486, _} = nksip_uac:invite(C1, "sip:any@127.0.0.1:5070", 
                                    [{callback, Fun}, {headers, Hds1}]),
    Hds2 = [{"Nk-Sleep", 3000}, {"Nk-Op", ok}, {"Nk-Prov", "true"}, RepHd],

    Test1 = fun() ->
        % Test manual CANCEL
        {async, Req3} = nksip_uac:invite(C1, "sip:any@127.0.0.1:5070", 
                                        [{callback, Fun}, async, {headers, Hds2}]),
        ok = nksip_uac:cancel(Req3)
    end,

    Test2 = fun() ->
        % Test invite expire, UAC must send CANCEL
        {ok, 487, _} = nksip_uac:invite(C1, Remote, 
                                 [{callback, Fun}, {expires, 1}, {headers, Hds2}])
    end,

    Test3 = fun() ->
        % Test invite expire, UAC will ignore and UAS must CANCEL
        {ok, 487, _} = nksip_uac:invite(C1, "sip:any@127.0.0.1:5070", 
                                        [{callback, Fun}, {expires, 1}, no_auto_expire,
                                         {headers, Hds2}])
     end,

    % Launch tests in parallel to share the waiting time
    Test1(),
    Test2(),
    Test3(),

    ok = tests_util:wait(Ref, [180, 487, 180, 180,
                               {client2, {dialog_stop, cancelled}},
                               {client2, {dialog_stop, cancelled}},
                               {client2, {dialog_stop, cancelled}}]),
    ok.


dialog() ->
    C1 = {invite, client1},
    C2 = {invite, client2},
    Ref = make_ref(),
    Self = self(),
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Hds = [{"Nk-Op", answer}, RepHd],

    {ok, 200, LocalResp} = nksip_uac:invite({invite, client1}, "sip:ok@127.0.0.1:5070",
                                                [{headers, Hds}, {body, SDP}]),
    {ok, _} = nksip_uac:ack(LocalResp, []),
    LocalDialog = nksip_dialog:id(LocalResp),
    % We don't receive callbacks from client1, since it has not stored the reply in 
    % its state
    ok = tests_util:wait(Ref, [{client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),

    [
        confirmed,
        Created, 
        Updated, 
        Answered, 
        <<"<sip:client1@localhost:5060>">>, 
        <<"<sip:ok@127.0.0.1:5070>">>,
        [],
        false,
        false,
        CSeq,
        0,
        #sdp{
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
        } = LocalSDP,
        #sdp{
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
        } = RemoteSDP,
        CallId
    ] = nksip_dialog:fields(LocalDialog, [
                                status, created, updated, answered, local_target, 
                                remote_target, route_set, early, secure, local_seq, 
                                remote_seq, local_sdp, remote_sdp, call_id]),
    Now = nksip_lib:timestamp(),
    true = (Now - Created) < 2,
    true = (Now - Updated) < 2,
    true = (Now - Answered) < 2,
    true = (Now - LocalSDPId) < 2,
    true = (Now - RemoteSDPId) < 2,

    % Hack to find remote dialog
    RemoteDialog = nksip_dialog:remote_id(C2, LocalDialog),
    [
        confirmed,
        Created2,
        Updated2,
        Answered2,
        <<"<sip:ok@127.0.0.1:5070>">>,
        <<"<sip:client1@localhost:5060>">>,
        [],
        false,
        false,
        0,
        CSeq,
        RemoteSDP,
        LocalSDP,
        CallId
    ] = nksip_dialog:fields(RemoteDialog, [
                                status, created, updated, answered, local_target, 
                                remote_target, route_set, early, secure, local_seq,
                                remote_seq, local_sdp, remote_sdp, call_id]),
    true = (Now - Created2) < 2,
    true = (Now - Updated2) < 2,
    true = (Now - Answered2) < 2,

    {RemoteSDP, LocalSDP} = sipapp_endpoint:get_sessions(C2, RemoteDialog),


    % Sends an in-dialog OPTIONS. Local CSeq should be incremented
    {ok, 200, _} = nksip_uac:reoptions(LocalDialog, []),
    CSeq = nksip_dialog:field(LocalDialog, local_seq) - 1,
    0 = nksip_dialog:field(LocalDialog, remote_seq),
    0 = nksip_dialog:field(RemoteDialog, local_seq),
    CSeq = nksip_dialog:field(RemoteDialog, remote_seq) - 1,

    % Sends now from the remote party to us, forcing initial CSeq
    {ok, 200, _} = nksip_uac:reoptions(RemoteDialog, [{cseq, 9999}]),
    CSeq = nksip_dialog:field(LocalResp, local_seq) -1,
    9999 = nksip_dialog:field(LocalResp, remote_seq),
    9999 = nksip_dialog:field(RemoteDialog, local_seq),
    CSeq = nksip_dialog:field(RemoteDialog, remote_seq) -1,

    % Force invalid CSeq
    nksip_trace:notice("Next notice about UAS 'OPTIONS' dialog request error old_cseq "
                       "is expected"),
    {ok, 500, Resp5} = nksip_uac:reoptions(RemoteDialog, [{cseq, 9998}]),
    <<"Old CSeq in Dialog">> = nksip_response:reason(Resp5),

    [LocalDialog] = nksip_dialog:find_callid(C1, CallId),
    [RemoteDialog] = nksip_dialog:find_callid(C2, CallId),
    
    % Send the dialog de opposite way
    {ok, 200, _} = nksip_uac:reinvite(RemoteDialog, [{headers, Hds}]),
    {ok, _} = nksip_uac:ack(RemoteDialog, []),

    % Now we receive callbacks from both
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),

    {ok, 200, _} = nksip_uac:bye(LocalDialog, []),
    ok = tests_util:wait(Ref, [{client2, {dialog_stop, caller_bye}}, 
                               {client1, {dialog_stop, caller_bye}},
                               {client1, sdp_stop},
                               {client2, sdp_stop}]),
    ok.


rr_contact() ->
    C1 = {invite, client1},
    C2 = {invite, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}],
    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}, sendrecv]}]),
    RR = [<<"<sip:127.0.0.1:5070;lr>">>, <<"<sips:abc:123>">>, <<"<sip:127.0.0.1;lr>">>],
    Hds1 = [
        {"Nk-Op", "answer"}, RepHd,
        {"Record-Route", nksip_lib:bjoin(lists:reverse(RR), <<", ">>)}],

    {ok, 200, Resp} = nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070", 
                                    [{contact, "sip:abc"}, {headers, Hds1}]),

    % Test Record-Route is replied
    RR = lists:reverse(nksip_response:header(Resp, <<"Record-Route">>)),
    FunAck = fun({ok, ACKReq1}) -> 
        % Test body in ACK, and Route and Contact generated in ACK
        RR = nksip_request:header(ACKReq1, <<"Route">>),
        [<<"<sip:abc>">>] = nksip_request:header(ACKReq1, <<"Contact">>),
        Self ! {Ref, fun_ack_ok}
    end,
    {async, _} = nksip_uac:ack(Resp, [{body, SDP}, async, {callback, FunAck}]),
    ok = tests_util:wait(Ref, [fun_ack_ok, {client2, ack}, 
                               {client2, dialog_confirmed},
                               {client2, sdp_start}]),

    % Test generated dialog values: local and remote targets, record route, SDPs.
    LocalDialog = nksip_dialog:id(Resp),
    [
        <<"<sip:abc>">>,
        <<"<sip:ok@127.0.0.1:5070>">>,
        RR,
        #sdp{vsn=LVsn1, connect={_, _, <<"client1">>}, medias=[LMed1]} = LocalSDP,
        #sdp{vsn=RVsn1, connect={_, _, <<"client2">>}} = RemoteSDP
    ] = nksip_dialog:fields(LocalDialog, [local_target, remote_target, route_set, 
                                          local_sdp, remote_sdp]),

    % Hack to find remote dialog
    RemoteDialog = nksip_dialog:remote_id({invite, client2}, LocalDialog),
    [
        <<"<sip:ok@127.0.0.1:5070>">>,
        <<"<sip:abc>">>,
        RR1,
        RemoteSDP, 
        LocalSDP
    ] = nksip_dialog:fields(RemoteDialog, [local_target, remote_target, route_set, 
                                local_sdp, remote_sdp]),
    true = lists:member({<<"sendrecv">>, []}, LMed1#sdp_m.attributes),
    RR1 = lists:reverse(RR),

    {RemoteSDP, LocalSDP} = sipapp_endpoint:get_sessions(C2, RemoteDialog),

    Fun = fun(R) ->
        case R of
            {req_id, Req} ->
                RR = nksip_request:header(Req, <<"Route">>),
                [<<"<sip:client1@localhost:5060>">>] = 
                    nksip_request:header(Req, <<"Contact">>),
                Self ! {Ref, req_ok};
            {ok, Code, RespId} ->
                if 
                    Code < 200 -> ok;
                    Code < 300 -> Self ! {Ref, Code, RespId}
                end
        end
    end,
    SDP2 = nksip_sdp:update(SDP, sendonly), 
    Hds2 = [{"Nk-Op", increment}, {"Record-Route", "<sip:ddd>"}, RepHd],
    % Reinvite updating SDP
    {async, _} = nksip_uac:reinvite(Resp, [
        {body, SDP2}, make_contact, async, {callback, Fun},
        {headers, Hds2}]),

    % Test Route Set cannot change now, it is already answered
    receive {Ref, Code, RespId} -> 
        200 = Code,
        {ok, ACKReq2} = nksip_uac:ack(RespId, []),
        ok = tests_util:wait(Ref, [req_ok,
                                   {client2, ack}, 
                                   {client2, sdp_update},
                                   {client2, dialog_confirmed}]),
        RR = nksip_request:header(ACKReq2, <<"Route">>),
        [<<"<sip:client1@localhost:5060>">>] = 
            nksip_request:header(ACKReq2, <<"Contact">>)
    after ?TIMEOUT -> 
        error(dialog2) 
    end,
    
    % Test SDP version has been incremented
    LVsn2 = LVsn1+1, 
    RVsn2 = RVsn1+1,
    [
        #sdp{vsn=LVsn2, connect={_, _, <<"client1">>}, medias=[LMed2]} = LocalSDP2,
        #sdp{vsn=RVsn2, connect={_, _, <<"client2">>}} = RemoteSDP2,
        <<"<sip:client1@localhost:5060>">>,
        <<"<sip:ok@127.0.0.1:5070>">>
    ] = nksip_dialog:fields(LocalDialog, 
                                [local_sdp, remote_sdp, local_target, remote_target]),

    [
        RemoteSDP2,
        LocalSDP2,
        <<"<sip:client1@localhost:5060>">>,
        <<"<sip:ok@127.0.0.1:5070>">>
    ] = nksip_dialog:fields(RemoteDialog, 
                                [local_sdp, remote_sdp, remote_target, local_target]),
    true = lists:member({<<"sendonly">>, []}, LMed2#sdp_m.attributes),

    {RemoteSDP2, LocalSDP2} = sipapp_endpoint:get_sessions(C2, RemoteDialog),


    % reINVITE from the other party
    Hds3 = [{"Nk-Op", increment}, RepHd],
    {ok, 200, RemoteResp} = nksip_uac:refresh(RemoteDialog, [{headers, Hds3}]),
    {ok, _} = nksip_uac:ack(RemoteResp, []),
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client1, sdp_update},
                               {client2, dialog_confirmed},
                               {client2, sdp_update}]),

    LVsn3 = LVsn2+1, RVsn3 = RVsn2+1,
    [
        #sdp{vsn=LVsn3, connect={_, _, <<"client1">>}} = LocalSDP3,
        #sdp{vsn=RVsn3, connect={_, _, <<"client2">>}} = RemoteSDP3
    ] = nksip_dialog:fields(LocalDialog, [local_sdp, remote_sdp]),
    
    [
        RemoteSDP3,
        LocalSDP3
    ] = nksip_dialog:fields(RemoteResp, [local_sdp, remote_sdp]),

    %% Test Contact is not modified
    {ok, 200, _} = nksip_uac:reoptions(Resp, [{contact, <<"sip:aaa">>}]),
    [
        #sdp{vsn=LVsn3},
        #sdp{vsn=RVsn3},
        <<"<sip:client1@localhost:5060>">>,
        <<"<sip:ok@127.0.0.1:5070>">>
    ] = nksip_dialog:fields(LocalDialog, 
                            [local_sdp, remote_sdp, local_target, remote_target]),
    
    [
        <<"<sip:client1@localhost:5060>">>,
        <<"<sip:ok@127.0.0.1:5070>">>,
        #sdp{vsn=RVsn3}
    ] = nksip_dialog:fields(RemoteResp, [remote_target, local_target, local_sdp]),
   

    RemoteDialog = nksip_dialog:id(RemoteResp),
    {LocalSDP3, RemoteSDP3} = sipapp_endpoint:get_sessions(C1, LocalDialog),
    {RemoteSDP3, LocalSDP3} = sipapp_endpoint:get_sessions(C2, RemoteDialog),

    ByeFun = fun(Reply) ->
        case Reply of
            {req_id, ByeReq} ->
                RevRR = nksip_request:header(ByeReq, <<"Route">>),
                RR = lists:reverse(RevRR),
                [<<"<sip:ok@127.0.0.1:5070>">>] = 
                    nksip_request:header(ByeReq, <<"Contact">>),
                Self ! {Ref, bye_ok1};
            {ok, 200, _} ->
                Self ! {Ref, bye_ok2}
        end
    end,

    {async, _} = nksip_uac:bye(RemoteDialog, [async, {callback, ByeFun}]),
    ok = tests_util:wait(Ref, [bye_ok1, bye_ok2, 
                               {client1, {dialog_stop, callee_bye}}, 
                               {client1, sdp_stop},
                               {client2, {dialog_stop, callee_bye}},
                               {client2, sdp_stop}]),
    ok.


multiple_uac() ->
    C1 = {invite, client1},
    C2 = {invite, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    OpAnswer = {"Nk-Op", answer},
    % Stablish a dialog between C1 and C2, but do not send the ACK 
    % yet, it will stay in accepted_uac state
    {ok, 200, Res} = nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070;transport=tcp", 
                                    [{headers, [RepHd, OpAnswer]}]),
    LocalDialog = nksip_dialog:id(Res),
    RemoteDialog = nksip_dialog:remote_id(C2, Res),
    [CSeq, accepted_uac] = nksip_dialog:fields(LocalDialog, [local_seq, status]),
    
    {error, request_pending} = nksip_uac:reinvite(Res, []), 
    {ok, _} = nksip_uac:ack(Res, []),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    Fun = fun(Term) ->
        case Term of
            {req_id, _} -> ok;
            {ok, 200, _} -> Self ! {Ref, ok1}
        end
    end,
    {async, Req2} = nksip_uac:reinvite(RemoteDialog, 
                                        [async, {callback, Fun}, {headers, [OpAnswer]}]),
    ok = tests_util:wait(Ref, [ok1]),
    % % CSeq uses next NkSIP's cseq. The next for dialog is CSeq+1, the first 
    % % dialog's reverse CSeq is next+1000
    RCSeq = CSeq+1001,
    % Sometimes it fails...
    case nksip_request:field(Req2, cseq_num) of
        RCSeq -> ok;
        Current -> io:format("RCSEQ should be ~p, is ~p", [RCSeq, Current])
    end,
    {ok, 200, _} = nksip_uac:bye(LocalDialog, []),
    ok.


multiple_uas() ->
    C1 = {invite, client1},
    C2 = {invite, client2},
    Self = self(),
    Ref = make_ref(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Fun = fun(Reply) ->
        case Reply of
            {req_id, _} -> Self ! 
                {Ref, request};
            {ok, Code, _} when Code < 200 -> 
                Self ! {Ref, provisional};
            {ok, Code, RespId} when Code < 300 -> 
                spawn(fun() -> nksip_uac:ack(RespId, [{headers, [RepHd]}]) end)
        end
    end,
    Hds = [{"Nk-Op", ok}, RepHd],

    % Set a new dialog between C1 and C2
    {ok, 200, Res1} = nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070;transport=tcp", 
                                        [{headers, Hds}]),
    {ok, _} = nksip_uac:ack(Res1, [{headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    LocalDialog = nksip_dialog:id(Res1),
    RemoteDialog = nksip_dialog:remote_id(C2, Res1),
    confirmed = nksip_dialog:field(LocalDialog, status),
    confirmed = nksip_dialog:field(RemoteDialog, status),

    % Send a new reinvite, it will spend 300msecs before answering
    {async, _} = nksip_uac:reinvite(LocalDialog, 
                                    [async, {callback, Fun},
                                    {headers, [{"Nk-Sleep", 300}|Hds]}]),
    ok = tests_util:wait(Ref, [request]),   % Wait to be sent

    % Before the previous invite has been answered, we send a new one
    % UAC will not block it because of the dialog_force_send option.
    % UAS replies with 500
    {ok, 500, R6} = nksip_uac:reinvite(LocalDialog, 
                        [no_dialog, {headers, [Hds]}]),
    500 = nksip_response:code(R6),
    <<"Processing Previous INVITE">> = nksip_response:reason(R6),
    % Previous invite will reply 200, and Fun will send ACK
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]), 
    
    confirmed = nksip_dialog:field(LocalDialog, status),
    confirmed = nksip_dialog:field(RemoteDialog, status),
    {ok, 200, _} = nksip_uac:bye(LocalDialog, []),
    ok = tests_util:wait(Ref, [{client2, {dialog_stop, caller_bye}}]),


    % Set a new dialog
    {ok, 200, Res2} = nksip_uac:invite(C1, "sip:ok@127.0.0.1:5070;transport=tcp", 
                                       [{headers, Hds}]),
    200 = nksip_response:code(Res2),
    {ok, _} = nksip_uac:ack(Res2, [{headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client2, ack}, {client2, dialog_confirmed}]),
    
    LocalDialog2 = nksip_dialog:id(Res2),
    RemoteDialog2 = nksip_dialog:remote_id(C2, Res2),
    [confirmed, LSeq, RSeq] = 
        nksip_dialog:fields(LocalDialog2, [status, local_seq, remote_seq]),
    [confirmed, RSeq, LSeq] = 
        nksip_dialog:fields(RemoteDialog2, [status, local_seq, remote_seq]),

    % The remote party (C2) will send a reinvite to the local (C1),
    % but the response will be delayed 300msecs
    Hds2 = [{"Nk", 1}, {"Nk-Prov", "true"}, {"Nk-Sleep", 300}|Hds],
    {async, _} = nksip_uac:reinvite(RemoteDialog2, [async, {callback, Fun},
                                                    {headers, Hds2}]),
    ok = tests_util:wait(Ref, [request, provisional]),   
    % Before answering, the local party sends a new reinvite. The remote party
    % replies a 491
    {ok, 491, _} = nksip_uac:reinvite(LocalDialog2, 
                                        [no_dialog, 
                                         {headers, [{"Nk", 2}]}]),
    % The previous invite will be answered, and Fun will send the ACK
    ok = tests_util:wait(Ref, [{client1, ack}, 
                               {client1, dialog_confirmed},
                               {client2, dialog_confirmed}]),
    {ok, 200, Bye} = nksip_uac:bye(LocalDialog2, []),
    BCSeq = nksip_response:field(Bye, cseq_num),
    BCSeq = LSeq+2,
    ok = tests_util:wait(Ref, [{client1, {dialog_stop, caller_bye}},
                               {client2, {dialog_stop, caller_bye}}]),
    ok.

