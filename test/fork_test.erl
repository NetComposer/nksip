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

    {ok, _} = do_start(client1, [
        {from, "sip:client1@nksip"},
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5071}]}
    ]),

    % Server1 is stateless
    {ok, _} = do_start(server1, [
        {from, "sip:server1@nksip"},
        no_100,
        {local_host, "localhost"},
        {transports, [{udp, all, 5061}]}
    ]),

    {ok, _} = do_start(client2, [
        {from, "sip:client2@nksip"},
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(server2, [
        {from, "sip:serverB@nksip"},
        no_100,
        {local_host, "localhost"},
        {transports, [{udp, all, 5062}]}
    ]),

    {ok, _} = do_start(client3, [
        {from, "sip:client3@nksip"},
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(server3, [
        {from, "sip:server3@nksip"},
        no_100,
        {local_host, "localhost"},
        {transports, [{udp, all, 5063}]}
    ]),


    % Registrar server

    {ok, _} = do_start(serverR, [
        {from, "sip:serverR@nksip"},
        registrar,
        no_100,
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}]}
    ]),


    % Clients to receive connections

    {ok, _} = do_start(clientA1, [
        {from, "sip:clientA1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(clientB1, [
        {from, "sip:clientB1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(clientC1, [
        {from, "sip:clientC1@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(clientA2, [
        {from, "sip:clientA2@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5061;lr>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(clientB2, [
        {from, "sip:clientB2@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5062;lr;transport=tcp>"},
        {local_host, "127.0.0.1"}
    ]),
    
    {ok, _} = do_start(clientC3, [
        {from, "sip:clientC3@nksip"},
        no_100,
        {route, "<sip:127.0.0.1:5063;lr>"},
        {local_host, "127.0.0.1"}
    ]),

    {ok, _} = do_start(clientD1, []),
    {ok, _} = do_start(clientD2, []),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


do_start(AppId, Opts) ->
    nksip:start(AppId, ?MODULE, AppId, Opts).



stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(server1),
    ok = nksip:stop(client2),
    ok = nksip:stop(server2),
    ok = nksip:stop(client3),
    ok = nksip:stop(server3),
    ok = nksip:stop(serverR),
    ok = nksip:stop(clientA1),
    ok = nksip:stop(clientB1),
    ok = nksip:stop(clientC1),
    ok = nksip:stop(clientA2),
    ok = nksip:stop(clientB2),
    ok = nksip:stop(clientC3),
    ok = nksip:stop(clientD1),
    ok = nksip:stop(clientD2).


regs() ->
    % Q:
    % A1 = B1 = client1 = 0.1
    % A2 = B2 = 0.2
    % client3 = 0.3
    
    nksip_registrar_util:clear(),
    Reg = "sip:nksip",
    Opts = [contact, {meta, [contacts]}],
    {ok, 200, Values1} = nksip_uac:register(clientA1, Reg, Opts),
    [{contacts, [#uri{user= <<"clientA1">>}=CA1]}] = Values1,
    {ok, 200, []} = nksip_uac:register(clientA1, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values3} = nksip_uac:register(clientB1, Reg, Opts),
    [{contacts, [#uri{user= <<"clientB1">>}=CB1]}] = Values3,
    {ok, 200, []} = nksip_uac:register(clientB1, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values5} = nksip_uac:register(clientC1, Reg, Opts),
    [{contacts, [#uri{user= <<"clientC1">>}=CC1]}] = Values5,
    {ok, 200, []} = nksip_uac:register(clientC1, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CC1#uri{ext_opts=[{q, 0.1}]}}]),
    
    {ok, 200, Values7} = nksip_uac:register(clientA2, Reg, Opts),
    [{contacts, [#uri{user= <<"clientA2">>}=CA2]}] = Values7,
    {ok, 200, []} = nksip_uac:register(clientA2, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values9} = nksip_uac:register(clientB2, Reg, Opts),
    [{contacts, [#uri{user= <<"clientB2">>}=CB2]}] = Values9,
    {ok, 200, []} = nksip_uac:register(clientB2, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values11} = nksip_uac:register(clientC3, Reg, Opts),
    [{contacts, [#uri{user= <<"clientC3">>}=CC3]}] = Values11, 
    {ok, 200, []} = nksip_uac:register(clientC3, Reg, 
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
        nksip_registrar:qfind(serverR, sip, <<"qtest">>, <<"nksip">>),
    ok.

basic() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),

    % We have to complete the three iterations
    Body1 = {body, [{clientC3, 300}]},
    Fs = {meta, [<<"x-nk-id">>]},
    {ok, 300, Values1} = nksip_uac:invite(client1, QUri, [Body1, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"clientC3,serverR,server1">>]}] = Values1,
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 580},
                                {clientA2, 580}, {clientB2, 580},
                                {clientC3, 300}]),

    % The first 6xx response aborts everything at first iteration
    Body2 = {body, [{clientA1, 600}]},
    {ok, 600, Values2} = nksip_uac:invite(client2, QUri, [Body2, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"clientA1,serverR,server2">>]}] =Values2,
    ok = tests_util:wait(Ref, [{clientA1, 600}, {clientB1, 580}, {clientC1, 580}]),

    % Aborted in second iteration
    Body3 = {body, [{clientA1, 505}, {clientB2, 600}]},
    {ok, 600, Values3} = nksip_uac:invite(client3, QUri, [Body3, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"clientB2,serverR,server3">>]}] =Values3,
    ok = tests_util:wait(Ref, [{clientA1, 505}, {clientB1, 580}, {clientC1, 580},
                               {clientA2, 580}, {clientB2, 600}]),
    ok.


invite1() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    Fun1 = {callback, 
            fun({resp, Code, Resp, _Call}) -> Self ! {Ref, {resp, Code, Resp}} end},

    % Test to CANCEL a forked request
    % Two 180 are received with different to_tag, so two different dialogs are
    % created at client1. 
    % After client1 sends CANCEL, the proxy cancels both of them, but only the first 
    % 487 response in sent back to client1, so it thinks the second dialog 
    % is still in proceeding_uac (until the 64*T1 timeout)
    
    Body1 = {body, [{clientB1, {488, 3000}}, {clientC1, {486, 3000}}]},
    {async, ReqId1} = nksip_uac:invite(client1, QUri, [async, Fun1, Body1, RepHd]),
    Dlg_C1_1 = receive
        {Ref, {resp, 180, Resp1_1}} -> nksip_dialog:get_id(Resp1_1)
        after 5000 -> error(invite)
    end,
    Dlg_C1_2 = receive
        {Ref, {resp, 180, Resp2_1}} -> nksip_dialog:get_id(Resp2_1)
        after 5000 -> error(invite)
    end,
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C1_1),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C1_2),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C1_1),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C1_2),
    Dlg_CB1_1 = nksip_dialog:remote_id(Dlg_C1_1, clientB1),
    Dlg_CC1_1 = nksip_dialog:remote_id(Dlg_C1_1, clientC1),
    Dlg_CB1_2 = nksip_dialog:remote_id(Dlg_C1_2, clientB1),
    Dlg_CC1_2 = nksip_dialog:remote_id(Dlg_C1_2, clientC1),
    case nksip_dialog:meta(invite_status, Dlg_CB1_1) of
        proceeding_uas ->   % B1 has "A" dialog
            error = nksip_dialog:meta(invite_status, Dlg_CB1_2),
            proceeding_uas = nksip_dialog:meta(invite_status, Dlg_CC1_2),
            error = nksip_dialog:meta(invite_status, Dlg_CC1_1);
        error ->            % B1 has "B" dialog
            proceeding_uas = nksip_dialog:meta(invite_status, Dlg_CB1_2),
            proceeding_uas = nksip_dialog:meta(invite_status, Dlg_CC1_1),
            error = nksip_dialog:meta(invite_status, Dlg_CC1_2)
    end,

    timer:sleep(500),
    ok = nksip_uac:cancel(ReqId1),
    receive
        {Ref, {resp, 487, _}} -> ok
        after 5000 -> error(invite)
    end,
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 488}, {clientC1, 486}]),
    % The second "zombie" dialog is still active at client1
    CallId1 = nksip_dialog:call_id(Dlg_C1_1),
    [Zombie] = nksip_dialog:get_all(client1, CallId1), 
    [] = nksip_dialog:get_all(serverR, CallId1), 
    [] = nksip_dialog:get_all(clientC1, CallId1), 
    [] = nksip_dialog:get_all(clientB1, CallId1), 
    ok = nksip_dialog:stop(Zombie),
    [] = nksip_dialog:get_all(client1, CallId1), 
    ok.

invite2() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    CB = {callback, fun({resp, Code, _RId, _Call}) -> Self ! {Ref, {code, Code}} end},
   
    % client1, B1 and client3 sends 180
    % clientC3 answers, the other two dialogs are deleted by the UAC sending ACK and BYE

    Body2 = {body, [{clientB1, {503, 500}}, {clientC1, {415, 500}},
                    {clientC3, {200, 1000}}]},
    {ok, 200, [{dialog_id, Dlg_C2_1}]} = nksip_uac:invite(client2, QUri, 
                                            [CB, Body2, RepHd, {supported, ""}]),
    ok = nksip_uac:ack(Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 503}, {clientC1, 415},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 200},
                               {code, 180}, {code, 180}, {code, 180},
                               {clientC3, ack}]),

    confirmed = nksip_dialog:meta(invite_status, Dlg_C2_1),
    confirmed = nksip_dialog:meta(invite_status, Dlg_C2_1),
    Dlg_CC3_1 = nksip_dialog:remote_id(Dlg_C2_1, clientC3),
    confirmed = nksip_dialog:meta(invite_status, Dlg_CC3_1),

    % ServerR receives the three 180 responses and creates three dialogs.
    % It then receives the 503 and 415 final responses for two of them, and deletes
    % two dialogs, but, as these responses are not sent back, server2 and client2 
    % have three dialogs, one confirmed and two in proceeding_uac
    % ServerR is not in Record-Route, it sees the 200 response but not the ACK, so
    % the winning dialog is not in confirmed state but accepted_uac
    % accepted_uac = nksip_dialog:meta(Dlg1, invite_status, serverR),

    All = nksip_dialog:get_all(),

    % lager:notice("A")


    {ok, C2Id} = nksip:find_app(client2),
    CallId = nksip_dialog:call_id(Dlg_C2_1),
    [Dlg_C2_2, Dlg_C2_3] = [D || D <- All, nksip_dialog:app_id(D)==C2Id,
                            nksip_dialog:call_id(D)=:=CallId, D/=Dlg_C2_1],
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C2_2),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C2_3),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C2_2),
    proceeding_uac = nksip_dialog:meta(invite_status, Dlg_C2_3),

    % Remove dialogs before waiting for timeout
    ok = nksip_dialog:stop(Dlg_C2_2),
    ok = nksip_dialog:stop(Dlg_C2_3),
    Dlg_C2_2_S2 = nksip_dialog:change_app(Dlg_C2_2, server2),
    Dlg_C2_3_S2 = nksip_dialog:change_app(Dlg_C2_3, server2),
    ok = nksip_dialog:stop(Dlg_C2_2_S2),
    ok = nksip_dialog:stop(Dlg_C2_3_S2),
    Dlg_C2_1_SR = nksip_dialog:change_app(Dlg_C2_1, serverR),
    ok = nksip_dialog:stop(Dlg_C2_1_SR),

    % In-dialog OPTIONS
    Fs = {meta, [<<"x-nk-id">>]},
    {ok, 200, Values3} = nksip_uac:options(Dlg_C2_1, [Fs]),
    [{<<"x-nk-id">>, [<<"clientC3,server2">>]}] = Values3,

    % Remote party in-dialog OPTIONS
    {ok, 200, Values4} = nksip_uac:options(Dlg_CC3_1, [Fs]),
    [{<<"x-nk-id">>, [<<"client2,server2">>]}] = Values4,
    
    % Dialog state at clientC1, clientC3 and server2
    [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ] = nksip_dialog:meta([invite_status, local_uri, remote_uri, 
                             local_target, remote_target], Dlg_C2_1),
    
    [
        {invite_status, confirmed}, 
        {local_uri, RUri}, 
        {remote_uri, LUri}, 
        {local_target, RTarget}, 
        {remote_target, LTarget}
    ] = nksip_dialog:meta([invite_status, local_uri, remote_uri, 
                             local_target, remote_target], Dlg_CC3_1),

    [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ] = nksip_dialog:meta([invite_status, local_uri, remote_uri, 
                             local_target, remote_target], Dlg_C2_1),
                           
    {ok, 200, []} = nksip_uac:bye(Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{clientC3, bye}]),

    error = nksip_dialog:meta(state, Dlg_C2_1),
    error = nksip_dialog:meta(state, Dlg_CC3_1),
    error = nksip_dialog:meta(state, Dlg_C2_1),
    ok.


redirect() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    
    not_found = get_port(other, udp, ipv4),
    PortD1 = get_port(clientD1, udp, ipv4),
    PortD2 = get_port(clientD2, tcp, ipv4),
    Contacts = ["sip:127.0.0.1:"++integer_to_list(PortD1),
                #uri{domain= <<"127.0.0.1">>, port=PortD2, opts=[{transport, tcp}]}],

    Body1 = {body, [{clientC1, {redirect, Contacts}}, {clientD2, 570}]},
    Fs = {meta, [<<"contact">>]},
    {ok, 300, Values1} = nksip_uac:invite(clientA1, QUri, [Body1, RepHd, Fs]),
    [{<<"contact">>, [C1, C2]}] = Values1,
    {match, [LPortD1]} = re:run(C1, <<"^<sip:127.0.0.1:(\\d+)>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    {match, [LPortD2]} = re:run(C2, <<"^<sip:127.0.0.1:(\\d+);transport=tcp>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    LPortD2 = integer_to_list(PortD2),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580}]),
    
    {ok, 570, _} = nksip_uac:invite(clientA1, QUri, 
                                     [Body1, {add, "x-nk-redirect", true}, RepHd]), 
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580},
                               {clientD1, 580}, {clientD2, 570}]),
    ok.


multiple_200() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    
    % client1 requests are sent to server1, stateless and record-routing
    % client1, server1 and serverR will receive three 200 responses
    % client1 ACKs and BYEs second and third. They will not go to serverR, so
    % dialogs stay in accepted_uac state there.
    Body1 = {body, [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}]},
    {ok, 200, [{dialog_id, Dlg_C1_1}]} = nksip_uac:invite(client1, QUri, [Body1, RepHd]),
    CallId1 = nksip_dialog:call_id(Dlg_C1_1),
    ok = nksip_uac:ack(Dlg_C1_1, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),

    [R1, R2, R3]= nksip_dialog:get_all(serverR, CallId1),

    lager:notice("R: ~p, ~p, ~p, ~p", [R1, R2, R3, Dlg_C1_1]),



    Dlg_C1_1_SR = nksip_dialog:change_app(Dlg_C1_1, serverR),
    true = lists:member(Dlg_C1_1_SR, [R1, R2, R3]),
    accepted_uac = nksip_dialog:meta(invite_status, R1),
    accepted_uac = nksip_dialog:meta(invite_status, R2),
    accepted_uac = nksip_dialog:meta(invite_status, R3),
    ok = nksip_dialog:stop(R1),
    ok = nksip_dialog:stop(R2),
    ok = nksip_dialog:stop(R3),

    confirmed = nksip_dialog:meta(invite_status, Dlg_C1_1),
    Dlg_CA1_1 = nksip_dialog:remote_id(Dlg_C1_1, clientA1),
    Dlg_CB1_1 = nksip_dialog:remote_id(Dlg_C1_1, clientB1),
    Dlg_CC1_1 = nksip_dialog:remote_id(Dlg_C1_1, clientC1),
    [confirmed, error, error] = 
        lists:sort([
            nksip_dialog:meta(invite_status, Dlg_CA1_1),
            nksip_dialog:meta(invite_status, Dlg_CB1_1),
            nksip_dialog:meta(invite_status, Dlg_CC1_1)]),
    {ok, 200, []} = nksip_uac:bye(Dlg_C1_1, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    [] = 
        nksip_dialog:get_all(client1, CallId1) ++
        nksip_dialog:get_all(clientA1, CallId1) ++
        nksip_dialog:get_all(clientB1, CallId1) ++
        nksip_dialog:get_all(clientC1, CallId1),


    % client3 requests are sent to server3, which is stateful and record-routing
    {ok, 200, [{dialog_id, Dlg_C3_2}]} = nksip_uac:invite(client3, QUri, [Body1, RepHd]),
    CallId2 = nksip_dialog:call_id(Dlg_C3_2),
    ok = nksip_uac:ack(Dlg_C3_2, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),

    [R4, R5, R6] = nksip_dialog:get_all(serverR, CallId2),
    ok = nksip_dialog:stop(R4),
    ok = nksip_dialog:stop(R5),
    ok = nksip_dialog:stop(R6),

    confirmed = nksip_dialog:meta(invite_status, Dlg_C3_2),
    confirmed = nksip_dialog:meta(invite_status, Dlg_C3_2),
    Dlg_A1_2 = nksip_dialog:remote_id(Dlg_C3_2, clientA1),
    Dlg_B1_2 = nksip_dialog:remote_id(Dlg_C3_2, clientB1),
    Dlg_C1_2 = nksip_dialog:remote_id(Dlg_C3_2, clientC1),

    [confirmed, error, error] =  lists:sort([
            nksip_dialog:meta(invite_status, Dlg_A1_2),
            nksip_dialog:meta(invite_status, Dlg_B1_2),
            nksip_dialog:meta(invite_status, Dlg_C1_2)]),
    {ok, 200, []} = nksip_uac:bye(Dlg_C3_2, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,

    [] = 
        nksip_dialog:get_all(client3, CallId2) ++
        nksip_dialog:get_all(server3, CallId2) ++
        nksip_dialog:get_all(clientA1, CallId2) ++
        nksip_dialog:get_all(clientB1, CallId2) ++
        nksip_dialog:get_all(clientC1, CallId2),


    % ServerR receives the 200 from clientB1 and CANCELs A1 y client1
    % Client1 make the dialog with B1, but can receive a 180 form A1 and/or client1
    Body3 = {body, [{clientA1, {200, 500}}, {clientB1, 200}, {clientC1, {200, 500}}]},
    {ok, 200, [{dialog_id, Dlg_C1_3}]} = nksip_uac:invite(client1, QUri, [Body3, RepHd]),
    CallId3 = nksip_dialog:call_id(Dlg_C1_3),
    ok = nksip_uac:ack(Dlg_C1_3, []),
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientB1, ack}]),

    confirmed = nksip_dialog:meta(invite_status, Dlg_C1_3),
    Dlg_B1_3 = nksip_dialog:remote_id(Dlg_C1_3, clientB1),
    confirmed = nksip_dialog:meta(invite_status, Dlg_B1_3),

    % ServerR sends two CANCELs to A1 and client1, and receives each 487, so only 1
    % dialog stays in accepted_uac
    [Dlg_C1_3_SR] = nksip_dialog:get_all(serverR, CallId3),
    Dlg_C1_3 = nksip_dialog:change_app(Dlg_C1_3_SR, client1),
    accepted_uac = nksip_dialog:meta(invite_status, Dlg_C1_3_SR),
    ok = nksip_dialog:stop(Dlg_C1_3_SR),

    {ok, 200, []} = nksip_uac:bye(Dlg_C1_3, []),
    ok = tests_util:wait(Ref, [{clientB1, bye}]),

    % Remove remaining dialogs in client1 from A1 and/or client1
    lists:foreach(
        fun(D) -> 
            proceeding_uac = nksip_dialog:meta(invite_status, D),
            ok = nksip_dialog:stop(D)
        end,
        nksip_dialog:get_all(client1, CallId3)),

    ok.


%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    ok = nksip:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, []}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:app_name(Req) of
        serverR ->
            % Route for serverR in fork test
            % Adds x-nk-id header, and Record-Route if Nk-Rr is true
            % If nk-redirect will follow redirects
            Opts = lists:flatten([
                {insert, "x-nk-id", serverR},
                case nksip_request:header(<<"x-nk-rr">>, Req) of
                    [<<"true">>] -> record_route;
                    _ -> []
                end,
                case nksip_request:header(<<"x-nk-redirect">>, Req) of
                    [<<"true">>] -> follow_redirects;
                    _ -> []
                end
            ]),
            {ok, Domains} = nksip:get(serverR, domains),
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    process;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:qfind(serverR, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy, UriList, Opts}
                    end;
                true ->
                    {proxy, ruri, Opts};
                false ->
                    {reply, forbidden}
            end;
        App when App==server1; App==server2; App==server3 ->
            % Route for the rest of servers in fork test
            % Adds x-nk-id header. serverA is stateless, rest are stateful
            % Always Record-Route
            % If domain is "nksip" routes to serverR
            Opts = [record_route, {insert, "x-nk-id", App}],
            {ok, Domains} = nksip:get(App, domains),
            case lists:member(Domain, Domains) of
                true when Domain==<<"nksip">>, App==server1 ->
                    {proxy_stateless, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]};
                true when Domain==<<"nksip">> ->
                    {proxy, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]};
                true when App==server1->
                    {proxy_stateless, ruri, Opts};
                true ->
                    {proxy, ruri, Opts};
                false ->
                    {reply, forbidden}
            end;
        _ ->
            process
    end.


% Adds x-nk-id header
% Gets operation from body
sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Ids = nksip_request:header(<<"x-nk-id">>, Req),
    App = nksip_request:app_name(Req),
    Hds = [{add, "x-nk-id", nksip_lib:bjoin([App|Ids])}],
    case nksip_request:body(Req) of
        Ops when is_list(Ops) ->
            ReqId = nksip_request:get_id(Req),
            proc_lib:spawn(
                fun() ->
                    case nksip_lib:get_value(App, Ops) of
                        {redirect, Contacts} ->
                            Code = 300,
                            nksip_request:reply({redirect, Contacts}, ReqId);
                        Code when is_integer(Code) -> 
                            case Code of
                                200 -> nksip_request:reply({ok, Hds}, ReqId);
                                _ -> nksip_request:reply({Code, Hds}, ReqId)
                            end;
                        {Code, Wait} when is_integer(Code), is_integer(Wait) ->
                            nksip_request:reply(ringing, ReqId),
                            timer:sleep(Wait),
                            case Code of
                                200 -> nksip_request:reply({ok, Hds}, ReqId);
                                _ -> nksip_request:reply({Code, Hds}, ReqId)
                            end;
                        _ -> 
                            Code = 580,
                            nksip_request:reply({580, Hds}, ReqId)
                    end,
                    tests_util:send_ref(Code, Req)
                end),
            noreply;
        _ ->
            {reply, {500, Hds}}
    end.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_options(Req, _Call) ->
    Ids = nksip_request:header(<<"x-nk-id">>, Req),
    App = nksip_request:app_name(Req),
    Hds = [{add, "x-nk-id", nksip_lib:bjoin([App|Ids])}],
    {reply, {ok, [contact|Hds]}}.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.



%%%%%

get_port(App, Proto, Class) ->
    case nksip:find_app(App) of
        {ok, AppId} -> 
            case nksip_transport:get_listening(AppId, Proto, Class) of
                [{#transport{listen_port=Port}, _Pid}|_] -> Port;
                _ -> not_found
            end;
        not_found ->
            not_found
    end.

