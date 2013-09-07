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
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).

fork_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
        {timeout, 60, fun regs/0}, 
        {timeout, 60, fun basic/0}, 
        {timeout, 60, fun invite/0}, 
        {timeout, 60, fun redirect/0}, 
        {timeout, 60, fun multiple_200/0}
      ]
  }.


start() ->
    tests_util:start_nksip(),
    
    % Clients to initiate connections

    ok = sipapp_endpoint:start({fork, client1}, [
        {from, "sip:client1@nksip"},
        {route, "sip:127.0.0.1:5061;lr"},
        {local_host, "127.0.0.1"}]),

    % Server1 is stateless
    ok = sipapp_server:start({fork, server1}, [
        {from, "sip:server1@nksip"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({fork, client2}, [
        {from, "sip:client2@nksip"},
        {route, "sip:127.0.0.1:5062;lr;transport=tcp"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_server:start({fork, server2}, [
        {from, "sip:serverB@nksip"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5062}}]),

    ok = sipapp_endpoint:start({fork, client3}, [
        {from, "sip:client3@nksip"},
        {route, "sip:127.0.0.1:5063;lr"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_server:start({fork, server3}, [
        {from, "sip:server3@nksip"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5063}}]),


    % Registrar server

    ok = sipapp_server:start({fork, serverR}, [
        {from, "sip:serverR@nksip"},
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}}]),


    % Clients to receive connections

    ok = sipapp_endpoint:start({fork, clientA1}, [
        {from, "sip:clientA1@nksip"},
        {route, "sip:127.0.0.1:5061;lr"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientB1}, [
        {from, "sip:clientB1@nksip"},
        {route, "sip:127.0.0.1:5062;lr;transport=tcp"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientC1}, [
        {from, "sip:clientC1@nksip"},
        {route, "sip:127.0.0.1:5063;lr"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientA2}, [
        {from, "sip:clientA2@nksip"},
        {route, "sip:127.0.0.1:5061;lr"},
        {local_host, "127.0.0.1"}]),

    ok = sipapp_endpoint:start({fork, clientB2}, [
        {from, "sip:clientB2@nksip"},
        {route, "sip:127.0.0.1:5062;lr;transport=tcp"},
        {local_host, "127.0.0.1"}]),
    
    ok = sipapp_endpoint:start({fork, clientC3}, [
        {from, "sip:clientC3@nksip"},
        {route, "sip:127.0.0.1:5063;lr"},
        {local_host, "127.0.0.1"}]),

        ok = sipapp_endpoint:start({fork, clientD1}, []),
    ok = sipapp_endpoint:start({fork, clientD2}, []),

    % Q:
    % A1 = B1 = C1 = 0.1
    % A2 = B2 = 0.2
    % C3 = 0.3
    
    nksip_registrar:clear(),
    Reg = "sip:nksip",
    Opts = [make_contact, full_response],
    {resp, Res1} = nksip_uac:register({fork, clientA1}, Reg, Opts),
    [200, [#uri{user= <<"clientA1">>}=CA1]] = 
        nksip_response:fields(Res1, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientA1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA1#uri{ext_opts=[{q, 0.1}]}}]),

    {resp, Res3} = nksip_uac:register({fork, clientB1}, Reg, Opts),
    [200, [#uri{user= <<"clientB1">>}=CB1]] = 
        nksip_response:fields(Res3, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientB1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB1#uri{ext_opts=[{q, 0.1}]}}]),

    {resp, Res5} = nksip_uac:register({fork, clientC1}, Reg, Opts),
    [200, [#uri{user= <<"clientC1">>}=CC1]] = 
        nksip_response:fields(Res5, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientC1}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CC1#uri{ext_opts=[{q, 0.1}]}}]),
    
    {resp, Res7} = nksip_uac:register({fork, clientA2}, Reg, Opts),
    [200, [#uri{user= <<"clientA2">>}=CA2]] = 
        nksip_response:fields(Res7, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientA2}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CA2#uri{ext_opts=[{q, 0.2}]}}]),

    {resp, Res9} = nksip_uac:register({fork, clientB2}, Reg, Opts),
    [200, [#uri{user= <<"clientB2">>}=CB2]] = 
        nksip_response:fields(Res9, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientB2}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CB2#uri{ext_opts=[{q, 0.2}]}}]),

    {resp, Res11} = nksip_uac:register({fork, clientC3}, Reg, Opts),
    [200, [#uri{user= <<"clientC3">>}=CC3]] = 
        nksip_response:fields(Res11, [code, parsed_contacts]),
    {ok, 200, _, _} = nksip_uac:register({fork, clientC3}, Reg, 
                [{from, "sip:qtest@nksip"}, {contact, CC3#uri{ext_opts=[{q, 0.3}]}}]),

    tests_util:log(),
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
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    % We have to complete the three iterations
    Opts1 = [{clientC3, 300}],
    {resp, Res1} = nksip_uac:invite({fork, client1}, QUri, 
                                          [{body, Opts1}, full_response, 
                                           {headers, [RepHd]}]),
    300 = nksip_response:code(Res1),
    [<<"clientC3,serverR,server1">>] = nksip_response:header(Res1, <<"Nk-Id">>),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 580},
                                {clientA2, 580}, {clientB2, 580},
                                {clientC3, 300}]),

    % The first 6xx response aborts everything at first iteration
    Opts2 = [{clientA1, 600}],
    {resp, Res2} = nksip_uac:invite({fork, client2}, QUri, 
                                      [{body, Opts2}, full_response, {headers, [RepHd]}]),
    600 = nksip_response:code(Res2),
    [<<"clientA1,serverR,server2">>] = nksip_response:header(Res2, <<"Nk-Id">>),
    ok = tests_util:wait(Ref, [{clientA1, 600}, {clientB1, 580}, {clientC1, 580}]),

    % Aborted in second iteration
    Opts3 = [{clientA1, 505}, {clientB2, 600}],
    {resp, Res3} = nksip_uac:invite({fork, client3}, QUri, 
                                      [{body, Opts3}, full_response, {headers, [RepHd]}]),
    600 = nksip_response:code(Res3),
    [<<"clientB2,serverR,server3">>] = nksip_response:header(Res3, <<"Nk-Id">>),
    ok = tests_util:wait(Ref, [{clientA1, 505}, {clientB1, 580}, {clientC1, 580},
                                {clientA2, 580}, {clientB2, 600}]),

    % Resonse from clientB1 will timeout timer_c. The lower response code will be 408
    nksip_config:put(timer_c, 1),
    Opts4 = [{clientB1, {490, 3000}}],
    Fun = fun({resp, Resp}) -> Self ! {Ref, {resp, Resp#sipmsg.response}} end,
    {resp, Res4} = nksip_uac:invite({fork, client1}, QUri, 
                                      [{body, Opts4}, {callback, Fun}, full_response,
                                       {headers, [RepHd]}]),
    408 = nksip_response:code(Res4),
    <<"Timer C Timeout">> = nksip_response:reason(Res4),
    [] = nksip_response:header(Res4, <<"Nk-Id">>),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientC1, 580}, {resp, 180},
                                {clientA2, 580}, {clientB2, 580}, {clientC3, 580}]),
    % {clientB1, 490} will be detected at the end not to wait here

    % Resonse from clientC1 will timeout proxy process. 
    % The lower response code will be 408.
    nksip_config:put(timer_c, 180),
    nksip_config:put(proxy_timeout, 1),
    nksip_trace:notice("Next notice about Proxy Timeout is expected"),
    Opts5 = [{clientC1, {490, 3000}}],
    {resp, Res5} = nksip_uac:invite({fork, client1}, QUri, 
                                      [{headers, [RepHd]}, {body, Opts5}, 
                                       {callback, Fun}, full_response]),
    408 = nksip_response:code(Res5),
    <<"Proxy Timeout">> = nksip_response:reason(Res5),
    [] = nksip_response:header(Res5, <<"Nk-Id">>),
    nksip_config:put(proxy_timeout, 180),
    % {clientB1, 490} comes from previous test
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {resp, 180},
                               {clientC1, 490}, {clientB1, 490}]),
    ok.


invite() ->
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    Fun = fun({ok, Code, _}) -> Self ! {Ref, {resp, Code}} end,

    % Test to CANCEL a forked request
    % Two 180 are received with different to_tag, so two different dialogs are
    % created. After Cancel, only one of them is cancelled (the proxy only sends the
    % first 487 response), the other is deleted by the UAC sending ACK and BYE
    
    nksip_trace:notice("Next notice about UAC stopping secondary dialog is expected"),
    Opts1 = [{clientB1, {488, 3000}}, {clientC1, {486, 3000}}],
    {async, CancelId} = nksip_uac:invite({fork, client1}, QUri, 
                                         [async, {callback, Fun}, {body, Opts1},
                                          {headers, [RepHd]}]),
    timer:sleep(500),
    {ok, 200, _, _} = nksip_uac:cancel(CancelId, []),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {resp, 180}, {resp, 180}, {resp, 487},
                               {clientB1, 488}, {clientC1, 486}]),

    % C1, B1 and C3 sends 180
    % clientC3 answers, the other two dialogs are deleted by the UAC sending ACK and BYE
    nksip_trace:notice("Next notices about UAC stopping two secondary dialogs are expected"),
    Opts2 = [{clientB1, {503, 500}}, {clientC1, {415, 500}},
             {clientC3, {200, 1000}}],
    {ok, 200, _, Dialog1} = nksip_uac:invite({fork, client2}, QUri, 
                                            [{callback, Fun}, {body, Opts2},
                                             {headers, [RepHd]}]),
    ok = nksip_uac:ack(Dialog1, []),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 503}, {clientC1, 415},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 200},
                               {resp, 180}, {resp, 180}, {resp, 180}, 
                               {clientC3, ack}]),

    % In-dialog OPTIONS
    {resp, Res3} = nksip_uac:options(Dialog1, [full_response]),
    200 = nksip_response:code(Res3),
    [<<"clientC3,server2">>] = nksip_response:header(Res3, <<"Nk-Id">>),

    % Remote party in-dialog OPTIONS
    Dialog2 = nksip_dialog:remote_id({fork, clientC3}, Dialog1),
    {resp, Res4} = nksip_uac:options(Dialog2, [full_response]),
    200 = nksip_response:code(Res4),
    [<<"client2,server2">>] = nksip_response:header(Res4, <<"Nk-Id">>),
    
    % Dialog state at clientC1, clientC3 and server2
    Dialog3 = nksip_dialog:remote_id({fork, server2}, Dialog1),
    [confirmed, LUri, RUri, LTarget, RTarget] = 
        nksip_dialog:fields(Dialog1, 
                            [state, local_uri, remote_uri, local_target, remote_target]),
    [confirmed, RUri, LUri, RTarget, LTarget] = 
        nksip_dialog:fields(Dialog2,
                            [state, local_uri, remote_uri, local_target, remote_target]),
    [confirmed, LUri, RUri, LTarget, RTarget] = 
        nksip_dialog:fields(Dialog3,
                            [state, local_uri, remote_uri, local_target, remote_target]),
                            
    
    {ok, 200, _, _} = nksip_uac:bye(Dialog1, []),
    timer:sleep(100),
    error = nksip_dialog:field(Dialog1, state),
    error = nksip_dialog:field(Dialog2, state),
    error = nksip_dialog:field(Dialog3, state),
    ok.


redirect() ->
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    not_found = nksip:get_port(other, udp),
    PortD1 = nksip:get_port({fork, clientD1}, udp),
    PortD2 = nksip:get_port({fork, clientD2}, tcp),
    Contacts = ["sip:127.0.0.1:"++integer_to_list(PortD1),
                #uri{domain= <<"127.0.0.1">>, port=PortD2, opts=[{transport, tcp}]}],

    Opts1 = [{clientC1, {redirect, Contacts}}, {clientD2, 570}],
    {resp, Res1} = nksip_uac:invite({fork, clientA1}, QUri, 
                                        [{body, Opts1}, full_response, 
                                         {headers, [RepHd]}]),
    300 = nksip_response:code(Res1),
    [C1, C2] = nksip_response:header(Res1, <<"Contact">>),
    {match, [LPortD1]} = re:run(C1, <<"^<sip:127.0.0.1:(\\d+)>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    {match, [LPortD2]} = re:run(C2, <<"^<sip:127.0.0.1:(\\d+);transport=tcp>">>, 
                                [{capture, all_but_first, list}]),
    LPortD1 = integer_to_list(PortD1),
    LPortD2 = integer_to_list(PortD2),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580}]),
    
    {ok, 570, _, _} = nksip_uac:invite({fork, clientA1}, QUri, 
                                     [{headers, [{"Nk-Redirect", true}, RepHd]}, 
                                      {body, Opts1}]),
    ok = tests_util:wait(Ref, [{clientA1, 580}, {clientB1, 580}, {clientC1, 300},
                               {clientA2, 580}, {clientB2, 580}, {clientC3, 580},
                               {clientD1, 580}, {clientD2, 570}]),
    ok.

multiple_200() ->
    QUri = "sip:qtest@nksip",
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    
    % client1 requests are sent to server1, stateless and not record-routing
    % client1 will receive three 200 responses and it will ACK and BYE 2nd and 3rd
    Opts = [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}],
    nksip_trace:info("Next two infos about UAC Trans receiving secondary response "
                     "are expected"),
    nksip_trace:info("Next two infos about UAC sending ACK and BYE to secondary response "
                     "are expected"),
    {ok, 200, Dialog1} = nksip_uac:invite({fork, client1}, QUri, [{body, Opts},
                                             {headers, [RepHd]}]),
    ok = nksip_uac:ack(Dialog1, []),
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),
    {ok, 200, _, _} = nksip_uac:bye(Dialog1, []),

    % client3 requests are sent to server3, which is stateful and record-routing
    nksip_trace:info("Next two infos about UAC Trans receiving secondary response "
                     "are expected"),
    nksip_trace:info("Next two infos about terminated proxy sending ACK and BYE "
                      "are expected"),
    {ok, 200, _, Dialog2} = nksip_uac:invite({fork, client3}, QUri, 
                                          [{body, Opts}, {headers, [RepHd]}]),
    ok = nksip_uac:ack(Dialog2, []),
    ok = tests_util:wait(Ref, 
                            [{clientA1, 200}, {clientB1, 200}, {clientC1, 200}, 
                             {clientA1, ack}, {clientB1, ack}, {clientC1, ack}]),

    % Remove the real dialog created at client3, server3 and the remote party
    {ok, 200, _, _} = nksip_uac:bye(Dialog2, []),

    % server3 returns the first 2xx response to client3 and stops (it does not know
    % the request has been forked by serverR). After that, two more 2xx are received. 
    % Proxy process is no longer alive, so it will ACK and BYE both of them.
    timer:sleep(2000),
    ok.







