%% -------------------------------------------------------------------
%%
%% websocket_test: Websocket Test Suite
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

-module(a_websocket_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


ws1_test_() ->
    {setup, spawn, 
        fun() -> start1() end,
        fun(_) -> stop1() end,
        [
            fun webserver/0
        ]
    }.


start1() ->
    ok = nksip:start(ws_a, nksip_sipapp, [], [
        {transport, {ws, {0,0,0,0}, 8090, []}},
        {transport, {wss, {0,0,0,0}, 8091, []}},
        {transport, {ws, {0,0,0,0}, 0, [{dispatch, "/ws"}]}}
    ]),

    ok = nksip:start(ws_b, nksip_sipapp, [], [
        {transport, {ws, {0,0,0,0}, 8090, []}},
        {transport, {wss, {0,0,0,0}, 8092, [{dispatch, [{'_', ["/ws"]}]}]}}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

webserver() ->
    [
        {#transport{proto=ws, local_port=0, listen_port=_LP}, _},
        {#transport{proto=ws, local_port=8090, listen_port=8090}, _},
        {#transport{proto=wss, local_port=8091, listen_port=8091}, _}
    ] = 
        lists:sort(nksip_transport:get_all(ws_a)),

    [
        {#transport{proto=ws, local_port=8090, listen_port=8090}, _},
        {#transport{proto=wss, local_port=8092, listen_port=8092}, _}
    ] = 
        lists:sort(nksip_transport:get_all(ws_b)),

    [
        {ws,{0,0,0,0},0},
        {ws,{0,0,0,0},8090},
        {wss,{0,0,0,0},8091},
        {wss,{0,0,0,0},8092}
    ] = 
        lists:sort(nksip_webserver_sup:get_all()),

    nksip:stop(ws_a),
    timer:sleep(100),
    [] = nksip_transport:get_all(ws_a),
    [{ws,{0,0,0,0},8090},{wss,{0,0,0,0},8092}] = 
        lists:sort(nksip_webserver_sup:get_all()),

    nksip:stop(ws_b),
    timer:sleep(100),
    [] = nksip_transport:get_all(ws_b),
    [] = lists:sort(nksip_webserver_sup:get_all()),
    ok.

stop1() ->
    ok.


ws2_test_() ->
    {setup, spawn, 
        fun() -> start2() end,
        fun(_) -> stop2() end,
        [
            fun basic/0, 
            fun sharing/0,
            fun proxy/0
        ]
    }.


start2() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({ws, server1}, [
        {from, "\"NkSIP Server\" <sip:server1@nksip>"},
        registrar,
        {listeners, 10},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}},
        {transport, {ws, {0,0,0,0}, 8080, []}},
        {transport, {wss, {0,0,0,0}, 8081, [{dispatch, "/wss"}]}}
    ]),

    ok = sipapp_endpoint:start({ws, ua1}, [
        {from, "\"NkSIP Client\" <sip:client1@nksip>"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}
    ]),

    ok = sipapp_endpoint:start({ws, ua2}, [
        {from, "<sip:client2@nksip>"},
        {local_host, "localhost"},
        {transport, {ws, {0,0,0,0}, 0}},
        {transport, {wss, {0,0,0,0}, 8091}}
    ]),

    ok = sipapp_endpoint:start({ws, ua3}, [
        {from, "<sip:client3@nksip>"},
        {local_host, "invalid.invalid"},
        {transport, {ws, {0,0,0,0}, 8080, [{dispatch, "/client3"}]}}
    ]),

    tests_util:log().


stop2() ->
    ok = sipapp_server:stop({ws, server1}),
    ok = sipapp_endpoint:stop({ws, ua1}),
    ok = sipapp_endpoint:stop({ws, ua2}),
    ok = sipapp_endpoint:stop({ws, ua3}),
    ok.


basic() ->
    S1 = {ws, server1},
    C2 = {ws, ua2},

    [] = nksip_transport:get_all_connected(S1),
    [] = nksip_transport:get_all_connected(C2),

    {ok, 200, Values1} = nksip_uac:options(C2, 
                         "<sip:localhost:8080/;transport=ws>", 
                         [{fields, [parsed_vias, local, remote]}]),

    [
        {_, [#via{proto=ws, domain = <<"localhost">>, port=Port1}]},
        {_, {ws, {127,0,0,1}, Port2, <<"/">>}},
        {_, {ws, {127,0,0,1}, 8080, <<"/">>}}
    ] = Values1,

    [
        {#transport{
            proto = ws,
            local_ip = {127,0,0,1},
            local_port = Port2,
            remote_ip = {127,0,0,1},
            remote_port = 8080,
            listen_ip = {0,0,0,0},
            listen_port = Port1
        }, Pid1}
    ] = nksip_transport:get_all_connected(C2),

    [
        {#transport{
            proto = ws,
            local_ip = {0,0,0,0},
            local_port = 8080,
            remote_ip = {127,0,0,1},
            remote_port = Port2,
            listen_ip = {0,0,0,0},
            listen_port = 8080
        }, Pid2}
    ] = nksip_transport:get_all_connected(S1),

    % If we send another request, it is going to use the same transport
    {ok, 200, []} = nksip_uac:options({ws, ua2}, "<sip:localhost:8080/;transport=ws>", []),
    [{_, Pid1}] = nksip_transport:get_all_connected(C2),
    [{_, Pid2}] = nksip_transport:get_all_connected(S1),

    % Now with SSL, but the path is incorrect
    {error, service_unavailable} =  nksip_uac:options(C2, 
                                            "<sips:localhost:8081/;transport=ws>", []),

    {ok, 200, Values2} = nksip_uac:options(C2, 
                         "<sips:localhost:8081/wss;transport=ws>", 
                         [{fields, [parsed_vias, local, remote]}]),

    [
        {_, [#via{proto=wss, domain = <<"localhost">>, port=8091}]},
        {_, {wss, {127,0,0,1}, Port3, <<"/wss">>}},
        {_, {wss, {127,0,0,1}, 8081, <<"/wss">>}}
    ] = Values2,

    [
        {_, Pid1},
        {#transport{
            proto = wss,
            local_ip = {127,0,0,1},
            local_port = Port3,
            remote_ip = {127,0,0,1},
            remote_port = 8081,
            listen_ip = {0,0,0,0},
            listen_port = 8091
        }, Pid3}
    ] = lists:sort(nksip_transport:get_all_connected(C2)),

    [
        {_, Pid2},
        {#transport{
            proto = wss,
            local_ip = {0,0,0,0},
            local_port = 8081,
            remote_ip = {127,0,0,1},
            remote_port = Port3,
            listen_ip = {0,0,0,0},
            listen_port = 8081
        }, Pid4}
    ] = lists:sort(nksip_transport:get_all_connected(S1)),

    [nksip_connection:stop(Pid, normal) || Pid <- [Pid1,Pid2,Pid3,Pid4]],
    ok.


sharing() ->
    % Server1 must answer
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options({ws, ua2}, "<sip:localhost:8080/;transport=ws>", 
                                      [{fields, [parsed_contacts]}]),
    #uri{domain = <<"localhost">>, port=8080} = S1C,

    {error, service_unavailable} = nksip_uac:options({ws, ua2}, 
                                    "<sip:localhost:8080/other;transport=ws>", []),

    % Client3 must answer
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options({ws, ua2}, 
                                            "<sip:localhost:8080/client3;transport=ws>", 
                                            [{fields, [parsed_contacts]}]),
    #uri{domain = <<"invalid.invalid">>, port=8080} = C3C,
    
    % Client2 must unswer
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options({ws, server1},
                                            "<sips:localhost:8091/;transport=ws>", 
                                            [{fields, [parsed_contacts]}]),
    #uri{domain = <<"localhost">>, port=8091} = C2C,
    ok.

proxy() ->

    {ok, 200, []} = 
        nksip_uac:register({ws,ua2}, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [unregister_all]),
    {ok, 200, []} = 
        nksip_uac:register({ws,ua3}, "<sip:127.0.0.1:8080;transport=ws>", 
                           [unregister_all]),

    
    % UA2 registers with the registrar, using WSS
    {ok, 200, []} = 
        nksip_uac:register({ws,ua2}, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [make_contact]),

    % Using or public GRUU, UA1 (without websocket support) is able to reach us
    C2Pub = nksip_sipapp_srv:get_gruu_pub({ws,ua2}),
    {ok, 200, [{_, [<<"ua2">>]}]} = 
        nksip_uac:options({ws,ua1}, C2Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}, {fields, [<<"Nk-Id">>]}]),

    % The same with our private GRUU
    C2Priv = nksip_sipapp_srv:get_gruu_temp({ws,ua2}),
    {ok, 200, [{_, [<<"ua2">>]}]} = 
        nksip_uac:options({ws,ua1}, C2Priv, 
                          [{route, "<sip:127.0.0.1;lr>"}, {fields, [<<"Nk-Id">>]}]),


    % UA3 registers. Its contact is not routable
    {ok, 200, [{_, [C3Contact]}]} = 
        nksip_uac:register({ws,ua3}, "<sip:127.0.0.1:8080;transport=ws>", 
                           [make_contact, {fields, [parsed_contacts]}]),
    #uri{domain = <<"invalid.invalid">>} = C3Contact,
    
    C3Pub = nksip_sipapp_srv:get_gruu_pub({ws,ua3}),
    {ok, 200, [{_, [<<"ua3">>]}]} = 
        nksip_uac:options({ws,ua1}, C3Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}, {fields, [<<"Nk-Id">>]}]),

    C3Priv = nksip_sipapp_srv:get_gruu_temp({ws,ua3}),
    {ok, 200, [{_, [<<"ua3">>]}]} = 
        nksip_uac:options({ws,ua1}, C3Priv, 
                          [{route, "<sip:127.0.0.1;lr>"}, {fields, [<<"Nk-Id">>]}]),


    % Let's stop the transports
    [nksip_connection:stop(Pid, normal) || 
        {_, Pid} <- nksip_transport:get_all_connected({ws,server1})],
    timer:sleep(100),

    {ok, 430, []} = nksip_uac:options({ws,ua1}, C2Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),

    {ok, 430, []} = nksip_uac:options({ws,ua1}, C3Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),
    ok.