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

-module(t11_fork).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).

fork_gen() ->
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
    ?debugFmt("\n\nStarting ~p\n\n", [?MODULE]),
    tests_util:start_nksip(),
    
    % Registrar server

    {ok, _} = nksip:start_link(fork_test_serverR, #{
        sip_from => "sip:fork_test_serverR@nksip",
        sip_no_100 => true,
        sip_local_host => "localhost",
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060"
    }),


    % Clients to initiate connections

    {ok, _} = nksip:start_link(fork_test_client1, #{
        sip_from => "sip:fork_test_client1@nksip",
        sip_route => "<sip:127.0.0.1:5061;lr>",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all:5071"
    }),

    % Server1 is stateless
    {ok, _} = nksip:start_link(fork_test_server1, #{
        sip_from => "sip:fork_test_server1@nksip",
        sip_no_100 => true,
        sip_local_host => "localhost",
        sip_listen => "sip:all:5061"
    }),

    {ok, _} = nksip:start_link(fork_test_client2, #{
        sip_from => "sip:fork_test_client2@nksip",
        sip_route => "<sip:127.0.0.1:5062;lr;transport=tcp>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_server2, #{
        sip_from => "sip:serverB@nksip",
        sip_no_100 => true,
        sip_local_host => "localhost",
        sip_listen => "<sip:all:5062>"
    }),

    {ok, _} = nksip:start_link(fork_test_client3, #{
        sip_from => "sip:fork_test_client3@nksip",
        sip_route => "<sip:127.0.0.1:5063;lr>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_server3, #{
        sip_from => "sip:fork_test_server3@nksip",
        sip_no_100 => true,
        sip_local_host => "localhost",
        sip_listen => "<sip:all:5063>"
    }),


    % Clients to receive connections

    {ok, _} = nksip:start_link(fork_test_clientA1, #{
        sip_from => "sip:fork_test_clientA1@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5061;lr>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_clientB1, #{
        sip_from => "sip:fork_test_clientB1@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5062;lr;transport=tcp>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_clientC1, #{
        sip_from => "sip:fork_test_clientC1@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5063;lr>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_clientA2, #{
        sip_from => "sip:fork_test_clientA2@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5061;lr>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_clientB2, #{
        sip_from => "sip:fork_test_clientB2@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5062;lr;transport=tcp>",
        sip_local_host => "127.0.0.1"
    }),
    
    {ok, _} = nksip:start_link(fork_test_clientC3, #{
        sip_from => "sip:fork_test_clientC3@nksip",
        sip_no_100 => true,
        sip_route => "<sip:127.0.0.1:5063;lr>",
        sip_local_host => "127.0.0.1"
    }),

    {ok, _} = nksip:start_link(fork_test_clientD1, #{}),
    {ok, _} = nksip:start_link(fork_test_clientD2, #{}),

    timer:sleep(1000),
    ok.


stop() ->
    ok = nksip:stop(fork_test_client1),
    ok = nksip:stop(fork_test_server1),
    ok = nksip:stop(fork_test_client2),
    ok = nksip:stop(fork_test_server2),
    ok = nksip:stop(fork_test_client3),
    ok = nksip:stop(fork_test_server3),
    ok = nksip:stop(fork_test_serverR),
    ok = nksip:stop(fork_test_clientA1),
    ok = nksip:stop(fork_test_clientB1),
    ok = nksip:stop(fork_test_clientC1),
    ok = nksip:stop(fork_test_clientA2),
    ok = nksip:stop(fork_test_clientB2),
    ok = nksip:stop(fork_test_clientC3),
    ok = nksip:stop(fork_test_clientD1),
    ok = nksip:stop(fork_test_clientD2),
    ?debugFmt("Stopping ~p", [?MODULE]),
    timer:sleep(500),
    ok.


regs() ->
    % Q:
    % A1 = B1 = fork_test_client1 = 0.1
    % A2 = B2 = 0.2
    % fork_test_client3 = 0.3
    
    nksip_registrar_util:clear(),
    Reg = "sip:nksip",
    Opts = [contact, {get_meta, [contacts]}],
    {ok, 200, Values1} = nksip_uac:register(fork_test_clientA1, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientA1">>}=CA1]}] = Values1,
    {ok, 200, []} = nksip_uac:register(fork_test_clientA1, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CA1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values3} = nksip_uac:register(fork_test_clientB1, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientB1">>}=CB1]}] = Values3,
    {ok, 200, []} = nksip_uac:register(fork_test_clientB1, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CB1#uri{ext_opts=[{q, 0.1}]}}]),

    {ok, 200, Values5} = nksip_uac:register(fork_test_clientC1, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientC1">>}=CC1]}] = Values5,
    {ok, 200, []} = nksip_uac:register(fork_test_clientC1, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CC1#uri{ext_opts=[{q, 0.1}]}}]),
    
    {ok, 200, Values7} = nksip_uac:register(fork_test_clientA2, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientA2">>}=CA2]}] = Values7,
    {ok, 200, []} = nksip_uac:register(fork_test_clientA2, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CA2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values9} = nksip_uac:register(fork_test_clientB2, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientB2">>}=CB2]}] = Values9,
    {ok, 200, []} = nksip_uac:register(fork_test_clientB2, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CB2#uri{ext_opts=[{q, 0.2}]}}]),

    {ok, 200, Values11} = nksip_uac:register(fork_test_clientC3, Reg, Opts),
    [{contacts, [#uri{scheme=sip, user= <<"fork_test_clientC3">>}=CC3]}] = Values11,
    {ok, 200, []} = nksip_uac:register(fork_test_clientC3, Reg,
                [{from, "sip:qtest@nksip"}, {contact, CC3#uri{ext_opts=[{q, 0.3}]}}]),    

    [
        [
            #uri{user = <<"fork_test_clientC1">>},
            #uri{user = <<"fork_test_clientB1">>},
            #uri{user = <<"fork_test_clientA1">>}
        ],
        [
            #uri{user = <<"fork_test_clientB2">>},
            #uri{user = <<"fork_test_clientA2">>}
        ],
        [
            #uri{user = <<"fork_test_clientC3">>}
        ]
    ] = 
        nksip_registrar:qfind(fork_test_serverR, sip, <<"qtest">>, <<"nksip">>),
    ok.

basic() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),

    % We have to complete the three iterations
    Body1 = {body, [{fork_test_clientC3, 300}]},
    Fs = {get_meta, [<<"x-nk-id">>]},
    {ok, 300, Values1} = nksip_uac:invite(fork_test_client1, QUri, [Body1, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"fork_test_clientC3,fork_test_serverR,fork_test_server1">>]}] = Values1,
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 580}, {fork_test_clientB1, 580}, {fork_test_clientC1, 580},
                                {fork_test_clientA2, 580}, {fork_test_clientB2, 580},
                                {fork_test_clientC3, 300}]),

    % The first 6xx response aborts everything at first iteration
    Body2 = {body, [{fork_test_clientA1, 600}]},
    {ok, 600, Values2} = nksip_uac:invite(fork_test_client2, QUri, [Body2, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"fork_test_clientA1,fork_test_serverR,fork_test_server2">>]}] =Values2,
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 600}, {fork_test_clientB1, 580}, {fork_test_clientC1, 580}]),

    % Aborted in second iteration
    Body3 = {body, [{fork_test_clientA1, 505}, {fork_test_clientB2, 600}]},
    {ok, 600, Values3} = nksip_uac:invite(fork_test_client3, QUri, [Body3, RepHd, Fs]),
    [{<<"x-nk-id">>, [<<"fork_test_clientB2,fork_test_serverR,fork_test_server3">>]}] =Values3,
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 505}, {fork_test_clientB1, 580}, {fork_test_clientC1, 580},
                               {fork_test_clientA2, 580}, {fork_test_clientB2, 600}]),
    ok.


invite1() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    Fun1 = {callback, 
            fun({resp, Code, Resp, _Call}) -> Self ! {Ref, {resp, Code, Resp}} end},

    % Test to CANCEL a forked request
    % Two 180 are received with different to_tag, so two different dialogs are
    % created at fork_test_client1.
    % After fork_test_client1 sends CANCEL, the proxy cancels both of them, but only the first
    % 487 response in sent back to fork_test_client1, so it thinks the second dialog
    % is still in proceeding_uac (until the 64*T1 timeout)
    
    Body1 = {body, [{fork_test_clientB1, {488, 3000}}, {fork_test_clientC1, {486, 3000}}]},
    {async, ReqId1} = nksip_uac:invite(fork_test_client1, QUri, [async, Fun1, Body1, RepHd]),
    {ok, Dlg_C1_1} = receive
        {Ref, {resp, 180, Resp1_1}} -> nksip_dialog:get_handle(Resp1_1)
        after 5000 -> error(invite)
    end,
    {ok, Dlg_C1_2} = receive
        {Ref, {resp, 180, Resp2_1}} -> nksip_dialog:get_handle(Resp2_1)
        after 5000 -> error(invite)
    end,
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C1_1),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C1_2),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C1_1),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C1_2),
    Dlg_CB1_1 = nksip_dialog_lib:remote_id(Dlg_C1_1, fork_test_clientB1),
    Dlg_CC1_1 = nksip_dialog_lib:remote_id(Dlg_C1_1, fork_test_clientC1),
    Dlg_CB1_2 = nksip_dialog_lib:remote_id(Dlg_C1_2, fork_test_clientB1),
    Dlg_CC1_2 = nksip_dialog_lib:remote_id(Dlg_C1_2, fork_test_clientC1),
    case nksip_dialog:get_meta(invite_status, Dlg_CB1_1) of
        {ok, proceeding_uas} ->   % B1 has "A" dialog
            {error, _} = nksip_dialog:get_meta(invite_status, Dlg_CB1_2),
            {ok, proceeding_uas} = nksip_dialog:get_meta(invite_status, Dlg_CC1_2),
            {error, _} = nksip_dialog:get_meta(invite_status, Dlg_CC1_1);
        {error, _} ->            % B1 has "B" dialog
            {ok, proceeding_uas} = nksip_dialog:get_meta(invite_status, Dlg_CB1_2),
            {ok, proceeding_uas} = nksip_dialog:get_meta(invite_status, Dlg_CC1_1),
            {error, _} = nksip_dialog:get_meta(invite_status, Dlg_CC1_2)
    end,

    timer:sleep(500),
    ok = nksip_uac:cancel(ReqId1, []),
    receive
        {Ref, {resp, 487, _}} -> ok
        after 5000 -> error(invite)
    end,
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 580}, {fork_test_clientB1, 488}, {fork_test_clientC1, 486}]),
    % The second "zombie" dialog is still active at fork_test_client1
    {ok, CallId1} = nksip_dialog:call_id(Dlg_C1_1),
    [Zombie] = nksip_dialog:get_all(fork_test_client1, CallId1),
    [] = nksip_dialog:get_all(fork_test_serverR, CallId1),
    [] = nksip_dialog:get_all(fork_test_clientC1, CallId1),
    [] = nksip_dialog:get_all(fork_test_clientB1, CallId1),
    ok = nksip_dialog:stop(Zombie),
    [] = nksip_dialog:get_all(fork_test_client1, CallId1),
    ok.

invite2() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    CB = {callback, fun({resp, Code, _RId, _Call}) -> Self ! {Ref, {code, Code}} end},
   
    % fork_test_client1, B1 and fork_test_client3 sends 180
    % fork_test_clientC3 answers, the other two dialogs are deleted by the UAC sending ACK and BYE

    Body2 = {body, [{fork_test_clientB1, {503, 500}}, {fork_test_clientC1, {415, 500}},
                    {fork_test_clientC3, {200, 1000}}]},
    {ok, 200, [{dialog, Dlg_C2_1}]} = nksip_uac:invite(fork_test_client2, QUri,
                                            [CB, Body2, RepHd, {supported, ""}]),
    ok = nksip_uac:ack(Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 580}, {fork_test_clientB1, 503}, {fork_test_clientC1, 415},
                               {fork_test_clientA2, 580}, {fork_test_clientB2, 580}, {fork_test_clientC3, 200},
                               {code, 180}, {code, 180}, {code, 180},
                               {fork_test_clientC3, ack}]),

    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C2_1),
    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C2_1),
    Dlg_CC3_1 = nksip_dialog_lib:remote_id(Dlg_C2_1, fork_test_clientC3),
    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_CC3_1),

    % ServerR receives the three 180 responses and creates three dialogs.
    % It then receives the 503 and 415 final responses for two of them, and deletes
    % two dialogs, but, as these responses are not sent back, fork_test_server2 and fork_test_client2
    % have three dialogs, one confirmed and two in proceeding_uac
    % ServerR is not in Record-Route, it sees the 200 response but not the ACK, so
    % the winning dialog is not in confirmed state but accepted_uac
    % accepted_uac = nksip_dialog:meta(Dlg1, invite_status, fork_test_serverR),

    All = nksip_dialog:get_all(),

    {ok, CallId} = nksip_dialog:call_id(Dlg_C2_1),
    [Dlg_C2_2, Dlg_C2_3] =
        [
            D ||
            D <- All,
            element(2, nksip_dialog:srv_id(D))==fork_test_client2,
            element(2, nksip_dialog:call_id(D))=:=CallId, D/=Dlg_C2_1
        ],
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C2_2),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C2_3),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C2_2),
    {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, Dlg_C2_3),

    % Remove dialogs before waiting for timeout
    ok = nksip_dialog:stop(Dlg_C2_2),
    ok = nksip_dialog:stop(Dlg_C2_3),
    Dlg_C2_2_S2 = nksip_dialog_lib:change_app(Dlg_C2_2, fork_test_server2),
    Dlg_C2_3_S2 = nksip_dialog_lib:change_app(Dlg_C2_3, fork_test_server2),
    ok = nksip_dialog:stop(Dlg_C2_2_S2),
    ok = nksip_dialog:stop(Dlg_C2_3_S2),
    Dlg_C2_1_SR = nksip_dialog_lib:change_app(Dlg_C2_1, fork_test_serverR),
    ok = nksip_dialog:stop(Dlg_C2_1_SR),

    % In-dialog OPTIONS
    Fs = {get_meta, [<<"x-nk-id">>]},
    {ok, 200, Values3} = nksip_uac:options(Dlg_C2_1, [Fs]),
    [{<<"x-nk-id">>, [<<"fork_test_clientC3,fork_test_server2">>]}] = Values3,

    % Remote party in-dialog OPTIONS
    {ok, 200, Values4} = nksip_uac:options(Dlg_CC3_1, [Fs]),
    [{<<"x-nk-id">>, [<<"fork_test_client2,fork_test_server2">>]}] = Values4,
    
    % Dialog state at fork_test_clientC1, fork_test_clientC3 and fork_test_server2
    {ok, [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ]} = nksip_dialog:get_metas([invite_status, local_uri, remote_uri,
                             local_target, remote_target], Dlg_C2_1),
    
    {ok, [
        {invite_status, confirmed}, 
        {local_uri, RUri}, 
        {remote_uri, LUri}, 
        {local_target, RTarget}, 
        {remote_target, LTarget}
    ]} = nksip_dialog:get_metas([invite_status, local_uri, remote_uri,
                             local_target, remote_target], Dlg_CC3_1),

    {ok, [
        {invite_status, confirmed}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}
    ]} = nksip_dialog:get_metas([invite_status, local_uri, remote_uri,
                             local_target, remote_target], Dlg_C2_1),
                           
    {ok, 200, []} = nksip_uac:bye(Dlg_C2_1, []),
    ok = tests_util:wait(Ref, [{fork_test_clientC3, bye}]),

    {error, _} = nksip_dialog:get_meta(state, Dlg_C2_1),
    {error, _} = nksip_dialog:get_meta(state, Dlg_CC3_1),
    {error, _} = nksip_dialog:get_meta(state, Dlg_C2_1),
    ok.


redirect() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    
    not_found = get_port(other, udp),
    PortD1 = get_port(fork_test_clientD1, udp),
    PortD2 = get_port(fork_test_clientD2, tcp),
    Contacts = ["sip:127.0.0.1:"++integer_to_list(PortD1),
                #uri{scheme=sip, domain= <<"127.0.0.1">>, port=PortD2, opts=[{transport, tcp}]}],

    Body1 = {body, [{fork_test_clientC1, {redirect, Contacts}}, {fork_test_clientD2, 570}]},
    Fs = {get_meta, [<<"contact">>]},
    {ok, 300, Values1} = nksip_uac:invite(fork_test_clientA1, QUri, [Body1, RepHd, Fs]),
    [{<<"contact">>, [C1, C2]}] = Values1,
    {match, [LPortD1]} = re:run(C1, <<"^<sip:127.0.0.1:(\\d+)>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    {match, [LPortD2]} = re:run(C2, <<"^<sip:127.0.0.1:(\\d+);transport=tcp>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    LPortD2 = integer_to_list(PortD2),
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 580}, {fork_test_clientB1, 580}, {fork_test_clientC1, 300},
                               {fork_test_clientA2, 580}, {fork_test_clientB2, 580}, {fork_test_clientC3, 580}]),
    
    % io:format("BODY1: ~p\n", [Body1]),

    {ok, 570, _} = nksip_uac:invite(fork_test_clientA1, QUri,
                                     [Body1, {add, "x-nk-redirect", true}, RepHd]),
    ok = tests_util:wait(Ref, [{fork_test_clientA1, 580}, {fork_test_clientB1, 580}, {fork_test_clientC1, 300},
                               {fork_test_clientA2, 580}, {fork_test_clientB2, 580}, {fork_test_clientC3, 580},
                               {fork_test_clientD1, 580}, {fork_test_clientD2, 570}]),
    ok.


multiple_200() ->
    QUri = "sip:qtest@nksip",
    {Ref, RepHd} = tests_util:get_ref(),
    
    % fork_test_client1 requests are sent to fork_test_server1, stateless and record-routing
    % fork_test_client1, fork_test_server1 and fork_test_serverR will receive three 200 responses
    % fork_test_client1 ACKs and BYEs second and third. They will not go to fork_test_serverR, so
    % dialogs stay in accepted_uac state there.
    Body1 = {body, [{fork_test_clientA1, 200}, {fork_test_clientB1, 200}, {fork_test_clientC1, 200}]},
    {ok, 200, [{dialog, Dlg_C1_1}]} = nksip_uac:invite(fork_test_client1, QUri, [Body1, RepHd]),
    {ok, CallId1} = nksip_dialog:call_id(Dlg_C1_1),
    ok = nksip_uac:ack(Dlg_C1_1, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{fork_test_clientA1, 200}, {fork_test_clientB1, 200}, {fork_test_clientC1, 200},
                             {fork_test_clientA1, ack}, {fork_test_clientB1, ack}, {fork_test_clientC1, ack}]),

    [R1, R2, R3]= nksip_dialog:get_all(fork_test_serverR, CallId1),

    % lager:notice("R: ~p, ~p, ~p, ~p", [R1, R2, R3, Dlg_C1_1]),

    Dlg_C1_1_SR = nksip_dialog_lib:change_app(Dlg_C1_1, fork_test_serverR),
    true = lists:member(Dlg_C1_1_SR, [R1, R2, R3]),
    {ok, accepted_uac} = nksip_dialog:get_meta(invite_status, R1),
    {ok, accepted_uac} = nksip_dialog:get_meta(invite_status, R2),
    {ok, accepted_uac} = nksip_dialog:get_meta(invite_status, R3),
    ok = nksip_dialog:stop(R1),
    ok = nksip_dialog:stop(R2),
    ok = nksip_dialog:stop(R3),

    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C1_1),
    Dlg_CA1_1 = nksip_dialog_lib:remote_id(Dlg_C1_1, fork_test_clientA1),
    Dlg_CB1_1 = nksip_dialog_lib:remote_id(Dlg_C1_1, fork_test_clientB1),
    Dlg_CC1_1 = nksip_dialog_lib:remote_id(Dlg_C1_1, fork_test_clientC1),
    [{error, _}, {error, _}, {ok, confirmed}] = 
        lists:sort([
            nksip_dialog:get_meta(invite_status, Dlg_CA1_1),
            nksip_dialog:get_meta(invite_status, Dlg_CB1_1),
            nksip_dialog:get_meta(invite_status, Dlg_CC1_1)]),
    {ok, 200, []} = nksip_uac:bye(Dlg_C1_1, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    timer:sleep(100),
    [] =
        nksip_dialog:get_all(fork_test_client1, CallId1) ++
        nksip_dialog:get_all(fork_test_clientA1, CallId1) ++
        nksip_dialog:get_all(fork_test_clientB1, CallId1) ++
        nksip_dialog:get_all(fork_test_clientC1, CallId1),


    % fork_test_client3 requests are sent to fork_test_server3, which is stateful and record-routing
    {ok, 200, [{dialog, Dlg_C3_2}]} = nksip_uac:invite(fork_test_client3, QUri, [Body1, RepHd]),
    {ok, CallId2} = nksip_dialog:call_id(Dlg_C3_2),
    ok = nksip_uac:ack(Dlg_C3_2, []),

    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,
    ok = tests_util:wait(Ref, 
                            [{fork_test_clientA1, 200}, {fork_test_clientB1, 200}, {fork_test_clientC1, 200},
                             {fork_test_clientA1, ack}, {fork_test_clientB1, ack}, {fork_test_clientC1, ack}]),

    [R4, R5, R6] = nksip_dialog:get_all(fork_test_serverR, CallId2),
    ok = nksip_dialog:stop(R4),
    ok = nksip_dialog:stop(R5),
    ok = nksip_dialog:stop(R6),

    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C3_2),
    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C3_2),
    Dlg_A1_2 = nksip_dialog_lib:remote_id(Dlg_C3_2, fork_test_clientA1),
    Dlg_B1_2 = nksip_dialog_lib:remote_id(Dlg_C3_2, fork_test_clientB1),
    Dlg_C1_2 = nksip_dialog_lib:remote_id(Dlg_C3_2, fork_test_clientC1),

    [{error, _}, {error, _}, {ok, confirmed}] =  lists:sort([
            nksip_dialog:get_meta(invite_status, Dlg_A1_2),
            nksip_dialog:get_meta(invite_status, Dlg_B1_2),
            nksip_dialog:get_meta(invite_status, Dlg_C1_2)]),
    {ok, 200, []} = nksip_uac:bye(Dlg_C3_2, []),
    receive {Ref, {_, bye}} -> ok after 5000 -> error(multiple_200) end,

    [] = 
        nksip_dialog:get_all(fork_test_client3, CallId2) ++
        nksip_dialog:get_all(fork_test_server3, CallId2) ++
        nksip_dialog:get_all(fork_test_clientA1, CallId2) ++
        nksip_dialog:get_all(fork_test_clientB1, CallId2) ++
        nksip_dialog:get_all(fork_test_clientC1, CallId2),


    % ServerR receives the 200 from fork_test_clientB1 and CANCELs A1 y fork_test_client1
    % Client1 make the dialog with B1, but can receive a 180 form A1 and/or fork_test_client1
    Body3 = {body, [{fork_test_clientA1, {200, 500}}, {fork_test_clientB1, 200}, {fork_test_clientC1, {200, 500}}]},
    {ok, 200, [{dialog, Dlg_C1_3}]} = nksip_uac:invite(fork_test_client1, QUri, [Body3, RepHd]),
    {ok, CallId3} = nksip_dialog:call_id(Dlg_C1_3),
    ok = nksip_uac:ack(Dlg_C1_3, []),
    ok = tests_util:wait(Ref, 
                            [{fork_test_clientA1, 200}, {fork_test_clientB1, 200}, {fork_test_clientC1, 200},
                             {fork_test_clientB1, ack}]),

    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_C1_3),
    Dlg_B1_3 = nksip_dialog_lib:remote_id(Dlg_C1_3, fork_test_clientB1),
    {ok, confirmed} = nksip_dialog:get_meta(invite_status, Dlg_B1_3),

    % ServerR sends two CANCELs to A1 and fork_test_client1, and receives each 487, so only 1
    % dialog stays in accepted_uac
    [Dlg_C1_3_SR] = nksip_dialog:get_all(fork_test_serverR, CallId3),
    Dlg_C1_3 = nksip_dialog_lib:change_app(Dlg_C1_3_SR, fork_test_client1),

    {ok, accepted_uac} = nksip_dialog:get_meta(invite_status, Dlg_C1_3_SR),
    ok = nksip_dialog:stop(Dlg_C1_3_SR),

    {ok, 200, []} = nksip_uac:bye(Dlg_C1_3, []),
    ok = tests_util:wait(Ref, [{fork_test_clientB1, bye}]),

    % Remove remaining dialogs in client1 from A1 and/or client1
    lists:foreach(
        fun(D) -> 
            {ok, proceeding_uac} = nksip_dialog:get_meta(invite_status, D),
            ok = nksip_dialog:stop(D)
        end,
        nksip_dialog:get_all(client1, CallId3)),

    ok.



%%%%%

get_port(PkgId, Transp) ->
    case nkpacket:get_listening(nksip_protocol, Transp, #{class=>{nksip, PkgId}}) of
        [#nkport{listen_port=Port}|_] -> Port;
        _ -> not_found
    end.

