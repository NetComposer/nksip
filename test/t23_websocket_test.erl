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

-module(t23_websocket_test).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).


ws_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic1/0, 
            fun basic2/0, 
            fun sharing/0,
            fun proxy/0
        ]
    }.


all() ->
    start(),
    lager:warning("Starting TEST ~p normal", [?MODULE]),
    timer:sleep(1000),
    basic1(),
    basic2(),
    sharing(),
    proxy(),
    stop().




start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(websocket_test_ws_a, #{
        sip_listen => "
            <sip:all:8880;transport=ws>,
            <sips:all:8881;transport=wss>,
            <sip:all/ws;transport=ws>"
    }),

    {ok, _} = nksip:start_link(websocket_test_ws_b, #{
        sip_listen => "
            sip:all:8092/ws;transport=wss,
            sip:all:8093;transport=ws"
    }),

    {ok, _} = nksip:start_link(websocket_test_server, #{
        sip_from => "\"NkSIP Server\" <sip:websocket_test_server@nksip>",
        sip_local_host => "localhost",
        plugins => [nksip_registrar, nksip_gruu, nksip_outbound],
        sip_listen => "
            sip:all:5060,
            <sip:all:5061;transport=tls>,
            <sip:all:8180;transport=ws>;listeners=10,
            <sip:all:8181/wss;transport=wss>"
    }),

    {ok, _} = nksip:start_link(websocket_test_ua1, #{
        sip_from => "\"NkSIP Client\" <sip:client1@nksip>",
        sip_local_host => "localhost",
        plugins => [nksip_gruu, nksip_outbound],
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    {ok, _} = nksip:start_link(websocket_test_ua2, #{
        sip_from => "<sip:client2@nksip>",
        sip_local_host => "localhost",
        plugins => [nksip_gruu, nksip_outbound],
        sip_listen => "sip:all;transport=ws, sip:all:8881/websocket_test_ua2;transport=wss"
    }),

    {ok, _} = nksip:start_link(websocket_test_ua3, #{
        sip_from => "<sip:client3@nksip>",
        sip_local_host => "invalid.invalid",
        plugins => [nksip_gruu, nksip_outbound],
        sip_listen => "sip:all:8180/client3;transport=ws"
    }),

    tests_util:log().


stop() ->
    ok = nksip:stop(websocket_test_server),
    ok = nksip:stop(websocket_test_ua1),
    ok = nksip:stop(websocket_test_ua2),
    ok = nksip:stop(websocket_test_ua3),
    ok.


basic1() ->
    WsA = websocket_test_ws_a,
    WsB = websocket_test_ws_b,
    
    [
        #nkport{transp=ws, local_port=8880, listen_port=8880,
                 opts=#{ws_proto:=<<"sip">>}},
        #nkport{transp=ws, local_port=_LP1, listen_port=_LP1,
                 opts=#{path:=<<"/ws">>, ws_proto:=<<"sip">>}}
    ] 
        = all_listeners(ws, WsA),

    [
        #nkport{transp=wss, local_port=8881, listen_port=8881,
                opts=#{ws_proto:=<<"sip">>}}
    ]
        = all_listeners(wss, WsA),

    [
        #nkport{transp=ws, local_port=8093, listen_port=8093,
                 opts=#{ws_proto:=<<"sip">>}}
    ] 
        = L3 = all_listeners(ws, WsB),

    [
        #nkport{transp=wss, local_port=8092, listen_port=8092, 
                opts=#{path:=<<"/ws">>, ws_proto:=<<"sip">>}}
    ]
        = L4 = all_listeners(wss, WsB),

    nksip:stop(WsA),
    timer:sleep(100),
    [] = all_listeners(ws, WsA),
    [] = all_listeners(wss, WsA),
    L3 = all_listeners(ws, WsB),
    L4 = all_listeners(wss, WsB),

    nksip:stop(WsB),
    timer:sleep(100),
    [] = all_listeners(ws, WsB),
    [] = all_listeners(wss, WsB),
    ok.


basic2() ->
    UA2 = websocket_test_ua2,
    S1 = websocket_test_server,

    [] = all_connected(S1),
    [] = all_connected(UA2),

    {ok, 200, Values1} = nksip_uac:options(websocket_test_ua2,
                         "<sip:localhost:8180/s1;transport=ws>", 
                         [{get_meta, [vias, local, remote]}]),

    [
        {vias, [#via{transp=ws, domain = <<"localhost">>, port=Port1}]},
        {local, {ws, {127,0,0,1}, Port2, <<"/s1">>}},
        {remote, {ws, {127,0,0,1}, 8180, <<"/s1">>}}
    ] = Values1,

    [
        #nkport{
            transp = ws,
            local_ip = {127,0,0,1},
            local_port = Port2,
            remote_ip = {127,0,0,1},
            remote_port = 8180,
            listen_ip = {0,0,0,0},
            listen_port = Port1,
            pid = Pid1,
            opts = #{path:=<<"/s1">>, host:=<<"localhost">>, ws_proto:=<<"sip">>}
        }
    ] = all_connected(UA2),

    [
        #nkport{
            transp = ws,
            local_ip = {0,0,0,0},
            local_port = 8180,
            remote_ip = {127,0,0,1},
            remote_port = Port2,
            listen_ip = {0,0,0,0},
            listen_port = 8180,
            pid = Pid2,
            opts = #{ws_proto:=<<"sip">>}
        }
    ] = all_connected(S1),

    % If we send another request, it is going to use the same transport
    {ok, 200, []} = nksip_uac:options(websocket_test_ua2, "<sip:localhost:8180/s1;transport=ws>", []),
    [#nkport{pid=Pid1}] = all_connected(UA2),
    [#nkport{pid=Pid2}] = all_connected(S1),

    % Now with SSL, but the path is incorrect
    {error, service_unavailable} =  nksip_uac:options(websocket_test_ua2,
                                            "<sips:localhost:8181/;transport=ws>", []),

    {ok, 200, Values2} = nksip_uac:options(websocket_test_ua2,
                         "<sips:localhost:8181/wss;transport=ws>", 
                         [{get_meta, [vias, local, remote]}]),

    [
        {_, [#via{transp=wss, domain = <<"localhost">>, port=8881}]},
        {_, {wss, {127,0,0,1}, Port3, <<"/wss">>}},
        {_, {wss, {127,0,0,1}, 8181, <<"/wss">>}}
    ] = Values2,

    [
        #nkport{pid=Pid1},
        #nkport{
            transp = wss,
            local_ip = {127,0,0,1},
            local_port = Port3,
            remote_ip = {127,0,0,1},
            remote_port = 8181,
            listen_ip = {0,0,0,0},
            listen_port = 8881,
            pid = Pid3
        }
    ] = all_connected(UA2),

    [
        #nkport{pid=Pid2},
        #nkport{
            transp = wss,
            local_ip = {0,0,0,0},
            local_port = 8181,
            remote_ip = {127,0,0,1},
            remote_port = Port3,
            listen_ip = {0,0,0,0},
            listen_port = 8181,
            pid = Pid4
        }
    ] = all_connected(S1),

    [nkpacket_connection:stop(Pid, normal) || Pid <- [Pid1,Pid2,Pid3,Pid4]],
    ok.


sharing() ->
    % Server1 must answer
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(websocket_test_ua2, "<sip:localhost:8180/s1;transport=ws>",
                                      [{get_meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8180} = S1C,
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(websocket_test_ua2, "<sip:localhost:"
                                                     "8180/s1/other/more;transport=ws>", 
                                      [{get_meta, [contacts]}]),

    %% Server is also listening on anything above /
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(websocket_test_ua2,
                                    "<sip:localhost:8180/other;transport=ws>", 
                                    [{get_meta, [contacts]}]),

    % Client3 must answer (it takes more priority than /)
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options(websocket_test_ua2,
                                            "<sip:localhost:8180/client3;transport=ws>", 
                                            [{get_meta, [contacts]}]),
    #uri{domain = <<"invalid.invalid">>, port=8180} = C3C,
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options(websocket_test_ua2,
                                            "<sip:localhost:8180/client3/more;transport=ws>", 
                                            [{get_meta, [contacts]}]),
    
    % Client2 must answer
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options(websocket_test_server,
                                            "<sips:localhost:8881/websocket_test_ua2;transport=ws>",
                                            [{get_meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8881} = C2C,
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options(websocket_test_server,
                                            "<sips:localhost:8881/websocket_test_ua2/any/thing;transport=ws>",
                                            [{get_meta, [contacts]}]),

    % But not now
    {error, service_unavailable} = nksip_uac:options(websocket_test_server,
                                            "<sips:localhost:8881/;transport=ws>", []),
    ok.


proxy() ->
    {ok, 200, []} = 
        nksip_uac:register(websocket_test_ua2, "<sip:127.0.0.1:8181/wss;transport=wss>",
                           [unregister_all]),
    {ok, 200, []} = 
        nksip_uac:register(websocket_test_ua3, "<sip:127.0.0.1:8180/s1;transport=ws>",
                           [unregister_all]),

    
    % UA2 registers with the registrar, using WSS
    {ok, 200, []} = 
        nksip_uac:register(websocket_test_ua2, "<sip:127.0.0.1:8181/wss;transport=wss>",
                           [contact]),

    % Using our public GRUU, UA1 (without websocket support) is able to reach us
    {ok, C2Pub} = nksip_gruu:get_gruu_pub(websocket_test_ua2),
    {ok, 200, [{_, [<<"websocket_test_ua2">>]}]} =
        nksip_uac:options(websocket_test_ua1, C2Pub,
                          [{route, "<sip:127.0.0.1;lr>"}, {get_meta, [<<"x-nk-id">>]}]),

    % The same with our private GRUU
    {ok, C2Priv} = nksip_gruu:get_gruu_temp(websocket_test_ua2),
    {ok, 200, [{_, [<<"websocket_test_ua2">>]}]} =
        nksip_uac:options(websocket_test_ua1, C2Priv,
                          [{route, "<sip:127.0.0.1;lr>"}, {get_meta, [<<"x-nk-id">>]}]),


    % UA3 registers. Its contact is not routable
    {ok, 200, [{_, [C3Contact]}]} = 
        nksip_uac:register(websocket_test_ua3, "<sip:127.0.0.1:8180/s1;transport=ws>",
                           [contact, {get_meta, [contacts]}]),
    #uri{domain = <<"invalid.invalid">>} = C3Contact,
    
    {ok, C3Pub} = nksip_gruu:get_gruu_pub(websocket_test_ua3),
    {ok, 200, [{_, [<<"websocket_test_ua3">>]}]} =
        nksip_uac:options(websocket_test_ua1, C3Pub,
                          [{route, "<sip:127.0.0.1;lr>"}, {get_meta, [<<"x-nk-id">>]}]),

    {ok, C3Priv} = nksip_gruu:get_gruu_temp(websocket_test_ua3),
    {ok, 200, [{_, [<<"websocket_test_ua3">>]}]} =
        nksip_uac:options(websocket_test_ua1, C3Priv,
                          [{route, "<sip:127.0.0.1;lr>"}, {get_meta, [<<"x-nk-id">>]}]),


    % Let's stop the transports
    S1 = websocket_test_server,
    [nkpacket_connection:stop(Pid, normal) || #nkport{pid=Pid} <- all_connected(S1)],
    timer:sleep(100),

    {ok, 430, []} = nksip_uac:options(websocket_test_ua1, C2Pub,
                          [{route, "<sip:127.0.0.1;lr>"}]),

    {ok, 430, []} = nksip_uac:options(websocket_test_ua1, C3Pub,
                          [{route, "<sip:127.0.0.1;lr>"}]),
    ok.



all_listeners(Transp, SrvId) ->
    lists:sort(
        nkpacket:get_listening(nksip_protocol, Transp, #{class=>{nksip, SrvId}})).

all_connected(SrvId) ->
    All = lists:sort([Pid || {_, Pid} <- nkpacket_connection:get_all_class({nksip, SrvId})]),
    [element(2, nkpacket:get_nkport(Pid)) || Pid <- All].

