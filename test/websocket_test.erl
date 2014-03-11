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

-module(websocket_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


% start_test() ->
%     ok = nksip:start(ws_a, nksip_sipapp, [], [
%         {transport, {ws, {0,0,0,0}, 8090, []}},
%         {transport, {wss, {0,0,0,0}, 8091, []}},
%         {transport, {ws, {0,0,0,0}, 0, [{dispatch, "/ws"}]}}
%     ]),
%     ok = nksip:start(ws_b, nksip_sipapp, [], [
%         {transport, {ws, {0,0,0,0}, 8090, []}},
%         {transport, {wss, {0,0,0,0}, 8092, [{dispatch, [{'_', ["/ws"]}]}]}}
%     ]),
   
%     [
%         {#transport{proto=ws, local_port=0, listen_port=_LP, 
%                     dispatch=[{'_', [], [{"/ws", [], _, _}]}]}, _},
%         {#transport{proto=ws, local_port=8090, listen_port=8090, 
%                     dispatch=[{'_', [], [{"/", [], _, _}]}]}, _},
%         {#transport{proto=wss, local_port=8091, listen_port=8091, 
%                     dispatch=[{'_', [], [{"/", [], _, _}]}]}, _}
%     ] = 
%         lists:sort(nksip_transport:get_all(ws_a)),

%     [
%         {#transport{proto=ws, local_port=8090, listen_port=8090, 
%                     dispatch=[{'_', [], [{"/", [], _, _}]}]}, _},
%         {#transport{proto=wss, local_port=8092, listen_port=8092, 
%                     dispatch=[{'_', [], [{"/ws", [], _, _}]}]}, _}
%     ] = 
%         lists:sort(nksip_transport:get_all(ws_b)),

%     [
%         {ws,{0,0,0,0},0},
%         {ws,{0,0,0,0},8090},
%         {wss,{0,0,0,0},8091},
%         {wss,{0,0,0,0},8092}
%     ] = 
%         lists:sort(nksip_webserver_sup:get_all()),

%     nksip:stop(ws_a),
%     timer:sleep(100),
%     [] = nksip_transport:get_all(ws_a),
%     [{ws,{0,0,0,0},8090},{wss,{0,0,0,0},8092}] = 
%         lists:sort(nksip_webserver_sup:get_all()),

%     nksip:stop(ws_b),
%     timer:sleep(100),
%     [] = nksip_transport:get_all(ws_b),
%     [] = lists:sort(nksip_webserver_sup:get_all()),
%     ok.


% basic_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             {timeout, 60, fun running/0}, 
%             {timeout, 60, fun transport/0}, 
%             {timeout, 60, fun cast_info/0}, 
%             {timeout, 60, fun stun/0}
%         ]
%     }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({ws, server1}, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        registrar,
        {listeners, 10},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}},
        {transport, {ws, {0,0,0,0}, 8080}},
        {transport, {wss, {0,0,0,0}, 8081, [{dispatch, "/wss"}]}}
    ]),

    ok = sipapp_endpoint:start({ws, ua1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {supported, []},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}
    ]),

    ok = sipapp_endpoint:start({ws, ua2}, [
        {supported, []},
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"},
        {transport, {ws, {0,0,0,0}, 0}},
        {transport, {wss, {0,0,0,0}, 8091}}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop_all(),
    error = sipapp_server:stop({ws, server1}),
    error = sipapp_endpoint:stop({ws, ua1}),
    error = sipapp_endpoint:stop({ws, ua2}),
    ok.


basic() ->
    {ok, 200, []} = nksip_uac:options({ws, ua2}, "<sip:localhost:8080/;transport=ws>", []).




