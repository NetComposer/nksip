%% -------------------------------------------------------------------
%%
%% fork_test: Forking Proxy Suite Test
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

-module(fork_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

fork_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
        {timeout, 60, fun regs/0}, 
        {timeout, 60, fun basic/0}, 
        {timeout, 60, fun invite1/0}, 
        {timeout, 60, fun invite2/0}, 
        {timeout, 60, fun redirect/0}, 
        {timeout, 60, fun multiple_200/0}
      ]
  }.


start() ->
    tests_util:start_nksip(),
    
    % Clients to initiate connections

    ok = sipapp_endpoint:start({fork, client1}, [
        {from, "sip:client1@nksip"},
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5071}}]),

    % Server1 is stateless
    ok = sipapp_server:start({fork, server1}, [
        {from, "sip:server1@nksip"},
        no_100,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({fork, client2}, [
        {from, "sip:client2@nksip"},
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_server:start({fork, server2}, [
        {from, "sip:serverB@nksip"},
        no_100,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5062}}]),

    ok = sipapp_endpoint:start({fork, client3}, [
        {from, "sip:client3@nksip"},
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_server:start({fork, server3}, [
        {from, "sip:server3@nksip"},
        no_100,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5063}}]),


    % Registrar server

    ok = sipapp_server:start({fork, serverR}, [
        {from, "sip:serverR@nksip"},
        registrar,
        no_100,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}}]),


    % Clients to receive connections

    ok = sipapp_endpoint:start({fork, clientA1}, [
        {from, "sip:clientA1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientB1}, [
        {from, "sip:clientB1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientC1}, [
        {from, "sip:clientC1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientA2}, [
        {from, "sip:clientA2@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientB2}, [
        {from, "sip:clientB2@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}]),
    
    ok = sipapp_endpoint:start({fork, clientC3}, [
        {from, "sip:clientC3@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientD1}, []),
    ok = sipapp_endpoint:start({fork, clientD2}, []),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({fork, client1}),
    ok = sipapp_server:stop({fork, server1}),
    ok = sipapp_endpoint:stop({fork, client2}),
    ok = sipapp_server:stop({fork, server2}),
    ok = sipapp_endpoint:stop({fork, client3}),
    ok = sipapp_server:stop({fork, server3}),
    ok = sipapp_server:stop({fork, serverR}),
    ok = sipapp_endpoint:stop({fork, clientA1}),
    ok = sipapp_endpoint:stop({fork, clientB1}),
    ok = sipapp_endpoint:stop({fork, clientC1}),
    ok = sipapp_endpoint:stop({fork, clientA2}),
    ok = sipapp_endpoint:stop({fork, clientB2}),
    ok = sipapp_endpoint:stop({fork, clientC3}),
    ok = sipapp_endpoint:stop({fork, clientD1}),
    ok = sipapp_endpoint:stop({fork, clientD2}).


regs() ->
    % Q:
    % A1 = B1 = C1 = 0.1
    % A2 = B2 = 0.2
    % C3 = 0.3
    
    nksip_registrar:internal_clear(),
    Reg = "sip:nksip",
    Opts = [make_contact, {fields, [parsed_contacts]}],
    {ok, 200, Values1} = nksip_uac:register({fork, clientA1}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientA1">>}=CA1]}] = Values1,
    {ok, 200, []} = nksip_uac:register({fork, clientA1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values3} = nksip_uac:register({fork, clientB1}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientB1">>}=CB1]}] = Values3,
    {ok, 200, []} = nksip_uac:register({fork, clientB1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values5} = nksip_uac:register({fork, clientC1}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientC1">>}=CC1]}] = Values5,
    {ok, 200, []} = nksip_uac:register({fork, clientC1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CC1#uri{ext_opts=[{q, 0.1}]}}]),
    
    {ok, 200, Values7} = nksip_uac:register({fork, clientA2}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientA2">>}=CA2]}] = Values7,
    {ok, 200, []} = nksip_uac:register({fork, clientA2}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values9} = nksip_uac:register({fork, clientB2}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientB2">>}=CB2]}] = Values9,
    {ok, 200, []} = nksip_uac:register({fork, clientB2}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values11} = nksip_uac:register({fork, clientC3}, Reg, Opts),
    [{parsed_contacts, [#uri{user= <<"clientC3">>}=CC3]}] = Values11, 
    {ok, 200, []} = nksip_uac:register({fork, clientC3}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CC3#uri{ext_opts=[{q, 0.3}]}}]),    

    [
        [
            #uri{user = <<"clientC1">>}, 
            #uri{user = <<"clientB1">>},
            #uri{user = <<"clientA1">>}
        ],
        [
            #uri{user = <<"clientB2">>},
            #uri{user = <<"clientA2">>}
        ],
        [
            #uri{user = <<"clientC3">>}
        ]
    ] = 
        nksip_registrar:qfind({fork, serverR}, sip, <<"qtest">>, <<"nksip">>),
    ok.

basic() ->
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {headers, [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},

    % We have to complete the three iterations
    Body1 = {body, [{clientC3, 300}]},
    Fs = {fields, [<<"Nk-Id">>]},
    {ok, 300, Values1} = nksip_uac:invite({fork, client1}, QUri, [Body1, RepHd, Fs]),
    [{<<"Nk-Id">>, [<<"clientC3,serverR,server1">>]}] =Values1,
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 580},
                                {clientA2, 580}, {clientB2, 580},
                                {clientC3, 300}]),

    % The first 6xx response aborts everything at first iteration
    Body2 = {body, [{clientA1, 600}]},
    {ok, 600, Values2} = nksip_uac:invite({fork, client2}, QUri, [Body2, RepHd, Fs]),
    [{<<"Nk-Id">>, [<<"clientA1,serverR,server2">>]}] =Values2,
    ok = tests_util:wait(Ref, [{clientA1, 600}, {clientB1, 580}, {clientC1, 580}]),

    % Aborted in second iteration
    Body3 = {body, [{clientA1, 505}, {clientB2, 600}]},
    {ok, 600, Values3} = nksip_uac:invite({fork, client3}, QUri, [Body3, RepHd, Fs]),
    [{<<"Nk-Id">>, [<<"clientB2,serverR,server3">>]}] =Values3,
    ok = tests_util:wait(Ref, [{clientA1, 505}, {clientB1, 580}, {clientC1, 580},
                               {clientA2, 580}, {clientB2, 600}]),
    ok.


invite1() ->
    C1 = {fork, client1},
    SR = {fork, serverR},
    CB1 = {fork, clientC1},
    CC1 = {fork, clientB1},
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {headers, [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},
    Fun1 = {callback, fun({ok, Code, Vs}) -> Self ! {Ref, {code, Code, Vs}} end},

    % Test to CANCEL a forked request
    % Two 180 are received with different to_tag, so two different dialogs are
    % created at client1. 
    % After client1 sends CANCEL, the proxy cancels both of them, but only the first 
    % 487 response in sent back to client1, so it thinks the second dialog 
    % is still in proceeding_uac (until the 64*T1 timeout)
    
    Body1 = {body, [{clientB1, {488, 3000}}, {clientC1, {486, 3000}}]},
    {async, ReqId1} = nksip_uac:invite(C1, QUri, [async, Fun1, Body1, RepHd]),
    Dlg_C1_1 = receive
        {Ref, {code, 180, [{dialog_id, Dlg_1_1_tmp}]}} -> Dlg_1_1_tmp
        after 5000 -> error(invite)
    end,
    Dlg_C1_2 = receive
        {Ref, {code, 180, [{dialog_id, Dlg_2_1_tmp}]}} -> Dlg_2_1_tmp
        after 5000 -> error(invite)
    end,
    proceeding_uac = nksip_dialog:field(C1, Dlg_C1_1, invite_status),
    proceeding_uac = nksip_dialog:field(C1, Dlg_C1_2, invite_status),
    proceeding_uac = nksip_dialog:field(SR, Dlg_C1_1, invite_status),
    proceeding_uac = nksip_dialog:field(SR, Dlg_C1_2, invite_status),
    Dlg_CB1_1 = Dlg_CC1_1 = nksip_dialog:field(C1, Dlg_C1_1, remote_id),
    Dlg_CB1_2 = Dlg_CC1_2 = nksip_dialog:field(C1, Dlg_C1_2, remote_id),
    case nksip_dialog:field(CB1, Dlg_CB1_1, invite_status) of
        proceeding_uas ->   % B1 has "A" dialog
            error = nksip_dialog:field(CB1, Dlg_CB1_2, invite_status),
            proceeding_uas = nksip_dialog:field(CC1, Dlg_CC1_2, invite_status),
            error = nksip_dialog:field(CC1, Dlg_CC1_1, invite_status);
        error ->            % B1 has "B" dialog
            proceeding_uas = nksip_dialog:field(CB1, Dlg_CB1_2, invite_status),
            proceeding_uas = nksip_dialog:field(CC1, Dlg_CC1_1, invite_status),
            error = nksip_dialog:field(CC1, Dlg_CC1_2, invite_status)
    end,

    timer:sleep(500),
    ok = nksip_uac:cancel(C1, ReqId1),
    receive
        {Ref, {code, 487, _}} -> ok
        after 5000 -> error(invite)
    end,
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 488}, {clientC1, 486}]),
    % The second "zombie" dialog is still active at client1
    CallId1 = nksip_dialog:call_id(Dlg_C1_1),
    [Zombie] = nksip_dialog:get_all(C1, CallId1), 
    [] = nksip_dialog:get_all(SR, CallId1), 
    [] = nksip_dialog:get_all(CB1, CallId1), 
    [] = nksip_dialog:get_all(CC1, CallId1), 
    ok = nksip_dialog:stop(C1, Zombie),
    [] = nksip_dialog:get_all(C1, CallId1), 
    ok.

invite2() ->
    C2 = {fork, client2},
    S2 = {fork, server2},
    SR = {fork, serverR},
    CC3 = {fork, clientC3},
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {headers, [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},
    CB = {callback, fun({ok, Code, _RId}) -> Self ! {Ref, {code, Code}} end},
    Body2 = {body, [{clientB1, {503, 500}}, {clientC1, {415, 500}},
             {clientC3, {200, 1000}}]},

    % C1, B1 and C3 sends 180
    % clientC3 answers, the other two dialogs are deleted by the UAC sending ACK and BYE

    {ok, 200, [{dialog_id, Dlg_C2_1}]} = nksip_uac:invite(C2, QUri, [CB, Body2, RepHd]),
    ok = nksip_uac:ack(C2, Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 503}, {clientC1, 415},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 200},
                               {code, 180}, {code, 180}, {code, 180},
                               {clientC3, ack}]),

    confirmed = nksip_dialog:field(C2, Dlg_C2_1, invite_status),
    confirmed = nksip_dialog:field(S2, Dlg_C2_1, invite_status),
    Dlg_CC3_1 = nksip_dialog:field(C2, Dlg_C2_1, remote_id),
    confirmed = nksip_dialog:field(CC3, Dlg_CC3_1, invite_status),
    % ServerR receives the three 180 responses and creates three dialogs.
    % It then receives the 503 and 415 final responses for two of them, and deletes
    % two dialogs, but, as these responses are not sent back, server2 and client2 
    % have three dialogs, one confirmed and two in proceeding_uac
    % ServerR is not in Record-Route, it sees the 200 response but not the ACK, so
    % the winning dialog is not in confirmed state but accepted_uac
    % accepted_uac = nksip_dialog:field(SR, Dlg1, invite_status),

    All = nksip_dialog:get_all(),
    CallId = nksip_dialog:call_id(Dlg_C2_1),
    [Dlg_C2_2, Dlg_C2_3] = [D || {{fork, client2}, D} <- All, 
                         nksip_dialog:call_id(D)=:=CallId, D/=Dlg_C2_1],
    proceeding_uac = nksip_dialog:field(C2, Dlg_C2_2, invite_status),
    proceeding_uac = nksip_dialog:field(C2, Dlg_C2_3, invite_status),
    proceeding_uac = nksip_dialog:field(S2, Dlg_C2_2, invite_status),
    proceeding_uac = nksip_dialog:field(S2, Dlg_C2_3, invite_status),

    % Remove dialogs before waiting for timeout
    ok = nksip_dialog:stop(C2, Dlg_C2_2),
    ok = nksip_dialog:stop(C2, Dlg_C2_3),
    ok = nksip_dialog:stop(S2, Dlg_C2_2),
    ok = nksip_dialog:stop(S2, Dlg_C2_3),
    ok = nksip_dialog:stop(SR, Dlg_C2_1),

    % In-dialog OPTIONS
    Fs = {fields, [<<"Nk-Id">>]},
    {ok, 200, Values3} = nksip_uac:options(C2, Dlg_C2_1, [Fs]),
    [{<<"Nk-Id">>, [<<"clientC3,server2">>]}] = Values3,

    % Remote party in-dialog OPTIONS
    {ok, 200, Values4} = nksip_uac:options(CC3, Dlg_CC3_1, [Fs]),
    [{<<"Nk-Id">>, [<<"client2,server2">>]}] = Values4,
    
    % Dialog state at clientC1, clientC3 and server2
    [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ] = nksip_dialog:fields(C2, Dlg_C2_1, [invite_status, local_uri, remote_uri, 
                                          local_target, remote_target]),
    
    [
        {invite_status, confirmed}, 
        {local_uri, RUri}, 
        {remote_uri, LUri}, 
        {local_target, RTarget}, 
        {remote_target, LTarget}
    ] = nksip_dialog:fields(CC3, Dlg_CC3_1,[invite_status, local_uri, remote_uri, 
                                          local_target, remote_target]),

    [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ] = nksip_dialog:fields(S2, Dlg_C2_1, [invite_status, local_uri, remote_uri, 
                                          local_target, remote_target]),
                           
    {ok, 200, []} = nksip_uac:bye(C2, Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{clientC3, bye}]),

    error = nksip_dialog:field(C2, Dlg_C2_1, state),
    error = nksip_dialog:field(CC3, Dlg_CC3_1, state),
    error = nksip_dialog:field(S2, Dlg_C2_1, state),
    ok.


redirect() ->
    CA1 = {fork, clientA1},
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}],
    not_found = nksip:get_port(other, udp, ipv4),
    PortD1 = nksip:get_port({fork, clientD1}, udp, ipv4),
    PortD2 = nksip:get_port({fork, clientD2}, tcp, ipv4),
    Contacts = ["sip:127.0.0.1:"++integer_to_list(PortD1),
                #uri{domain= <<"127.0.0.1">>, port=PortD2, opts=[{transport, tcp}]}],

    Body1 = {body, [{clientC1, {redirect, Contacts}}, {clientD2, 570}]},
    Fs = {fields, [<<"Contact">>]},
    {ok, 300, Values1} = nksip_uac:invite(CA1, QUri, [Body1, {headers, [RepHd]}, Fs]),
    [{<<"Contact">>, [C1, C2]}] = Values1,
    {match, [LPortD1]} = re:run(C1, <<"^<sip:127.0.0.1:(\\d+)>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    {match, [LPortD2]} = re:run(C2, <<"^<sip:127.0.0.1:(\\d+);transport=tcp>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    LPortD2 = integer_to_list(PortD2),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580}]),
    
    {ok, 570, _} = nksip_uac:invite(CA1, QUri, 
                                     [Body1, {headers, [{"Nk-Redirect", true}, RepHd]}]), 
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580},
                               {clientD1, 580}, {clientD2, 570}]),
    ok.


multiple_200() ->
    C1 = {fork, client1},
    C3 = {fork, client3},
    SR = {fork, serverR},
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {headers, [{"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}]},
    
    % client1 requests are sent to server1, stateless and record-routing
    % client1, server1 and serverR will receive three 200 responses
    % client1 ACKs and BYEs second and third. They will not go to serverR, so
    % dialogs stay in accepted_uac state there.
    Body1 = {body, [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}]},
    {ok, 200, [{dialog_id, Dlg_C1_1}]} = nksip_uac:invite(C1, QUri, [Body1, RepHd]),
    CallId1 = nksip_dialog:call_id(Dlg_C1_1),
    ok = nksip_uac:ack(C1, Dlg_C1_1, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),

    [R1, R2, R3]= nksip_dialog:get_all(SR, CallId1),
    true = lists:member(Dlg_C1_1, [R1, R2, R3]),
    accepted_uac = nksip_dialog:field(SR, R1, invite_status),
    accepted_uac = nksip_dialog:field(SR, R2, invite_status),
    accepted_uac = nksip_dialog:field(SR, R3, invite_status),
    ok = nksip_dialog:stop(SR, R1),
    ok = nksip_dialog:stop(SR, R2),
    ok = nksip_dialog:stop(SR, R3),

    confirmed = nksip_dialog:field(C1, Dlg_C1_1, invite_status),
    Dlg_CA1_1 = Dlg_CB1_1 = Dlg_CC1_1 = nksip_dialog:field(C1, Dlg_C1_1, remote_id),
    [confirmed, error, error] = 
        lists:sort([
            nksip_dialog:field({fork, clientA1}, Dlg_CA1_1, invite_status),
            nksip_dialog:field({fork, clientB1}, Dlg_CB1_1, invite_status),
            nksip_dialog:field({fork, clientC1}, Dlg_CC1_1, invite_status)]),
    {ok, 200, []} = nksip_uac:bye(C1, Dlg_C1_1, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    [] = 
        nksip_dialog:get_all({fork, client1}, CallId1) ++
        nksip_dialog:get_all({fork, clientA1}, CallId1) ++
        nksip_dialog:get_all({fork, clientB1}, CallId1) ++
        nksip_dialog:get_all({fork, clientC1}, CallId1),


    % client3 requests are sent to server3, which is stateful and record-routing
    {ok, 200, [{dialog_id, Dlg_C3_2}]} = nksip_uac:invite(C3, QUri, [Body1, RepHd]),
    CallId2 = nksip_dialog:call_id(Dlg_C3_2),
    ok = nksip_uac:ack(C3, Dlg_C3_2, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),

    [R4, R5, R6] = nksip_dialog:get_all(SR, CallId2),
    ok = nksip_dialog:stop(SR, R4),
    ok = nksip_dialog:stop(SR, R5),
    ok = nksip_dialog:stop(SR, R6),

    confirmed = nksip_dialog:field(C3, Dlg_C3_2, invite_status),
    confirmed = nksip_dialog:field({fork, server3}, Dlg_C3_2, invite_status),
    Dlg_A1_2 = Dlg_B1_2 = Dlg_C1_2 = nksip_dialog:field(C3, Dlg_C3_2, remote_id),

    [confirmed, error, error] =         lists:sort([
            nksip_dialog:field({fork, clientA1}, Dlg_A1_2, invite_status),
            nksip_dialog:field({fork, clientB1}, Dlg_B1_2, invite_status),
            nksip_dialog:field({fork, clientC1}, Dlg_C1_2, invite_status)]),
    {ok, 200, []} = nksip_uac:bye(C3, Dlg_C3_2, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,

    [] = 
        nksip_dialog:get_all(C3, CallId2) ++
        nksip_dialog:get_all({fork, server3}, CallId2) ++
        nksip_dialog:get_all({fork, clientA1}, CallId2) ++
        nksip_dialog:get_all({fork, clientB1}, CallId2) ++
        nksip_dialog:get_all({fork, clientC1}, CallId2),


    % ServerR receives the 200 from clientB1 and CANCELs A1 y C1
    % Client1 make the dialog with B1, but can receive a 180 form A1 and/or C1
    Body3 = {body, [{clientA1, {200, 500}}, {clientB1, 200}, {clientC1, {200, 500}}]},
    {ok, 200, [{dialog_id, Dlg_C1_3}]} = nksip_uac:invite(C1, QUri, [Body3, RepHd]),
    CallId3 = nksip_dialog:call_id(Dlg_C1_3),
    ok = nksip_uac:ack(C1, Dlg_C1_3, []),
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientB1, ack}]),

    confirmed = nksip_dialog:field(C1, Dlg_C1_3, invite_status),
    Dlg_B1_3 = nksip_dialog:field(C1, Dlg_C1_3, remote_id),
    confirmed = nksip_dialog:field({fork, clientB1}, Dlg_B1_3, invite_status),

    % ServerR sends two CANCELs to A1 and C1, and receives each 487, so only 1
    % dialog stays in accepted_uac
    [Dlg_C1_3] = nksip_dialog:get_all(SR, CallId3),
    accepted_uac = nksip_dialog:field(SR, Dlg_C1_3, invite_status),
    ok = nksip_dialog:stop(SR, Dlg_C1_3),

    {ok, 200, []} = nksip_uac:bye(C1, Dlg_C1_3, []),
    ok = tests_util:wait(Ref, [{clientB1, bye}]),

    % Remove remaining dialogs in client1 from A1 and/or C1
    lists:foreach(
        fun(D) -> 
            proceeding_uac = nksip_dialog:field(C1, D, invite_status),
            ok = nksip_dialog:stop(C1, D)
        end,
        nksip_dialog:get_all(C1, CallId3)),

    ok.