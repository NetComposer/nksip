%% -------------------------------------------------------------------
%%
%% timer_test: Timer (RFC4028) Tests
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

-module(timer_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

% timer_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             fun basic/0
%         ]
%     }.

% This configuration resembles the example in RFC3327
start() ->
    tests_util:start_nksip(),

    % ok = timer_server:start({timer, p1}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5060}},
    %     {transport, {tls, {0,0,0,0}, 5061}}]),

    % ok = timer_server:start({timer, p2}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5070}},
    %     {transport, {tls, {0,0,0,0}, 5071}}]),

    % ok = timer_server:start({timer, p3}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5080}},
    %     {transport, {tls, {0,0,0,0}, 5081}}]),

    ok = sipapp_endpoint:start({timer, ua1}, [
        {from, "sip:ua1@nksip"},
        % {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 0}},
        {transport, {tls, {0,0,0,0}, 0}}]),

    ok = sipapp_endpoint:start({timer, ua2}, [
        {route, "<sip:127.0.0.1:5090;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5090}}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    % ok = sipapp_server:stop({timer, p1}),
    % ok = sipapp_server:stop({timer, p2}),
    % ok = sipapp_server:stop({timer, p3}),
    ok = sipapp_endpoint:stop({timer, ua1}),
    ok = sipapp_endpoint:stop({timer, ua2}).


basic() ->
    C1 = {timer, ua1},
    C2 = {timer, ua2},

    % {error, invalid_session_expires} = 
    %     nksip_uac:invite(C1, "sip:any", [{session_expires, 1}]),

    {ok, 200, _} = nksip_uac:invite(C1, "sip:127.0.0.1:5090", 
        [auto_2xx_ack, {session_expires, 10}]),    

        ok.




