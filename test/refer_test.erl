%% -------------------------------------------------------------------
%%
%% refer_test: REFER Test
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

-module(refer_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

refer_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        {inparallel, [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun in_dialog/0}
        ]}
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_endpoint:start({refer, client1}, [
        {transport, {udp, {0,0,0,0}, 5060}}
    ]),
    
    ok = sipapp_endpoint:start({refer, client2}, [
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}
    ]),

    ok = sipapp_endpoint:start({refer, client3}, [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5080}},
        {transport, {tls, {0,0,0,0}, 5081}}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({refer, client1}),
    ok = sipapp_endpoint:stop({refer, client2}),
    ok = sipapp_endpoint:stop({refer, client3}).


basic() ->
    C1 = {refer, client1},
    C2 = {refer, client2},
    C3 = {refer, client3},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{subscription_id, Subs1A}]} = 
        nksip_uac:refer(C1, SipC2, [{refer_to, "sips:127.0.0.1:5081"}]),

    Dialog1A = nksip_subscription:dialog_id(Subs1A),
    % Prepare sipapp_endpoint to send us the received NOTIFYs
    sipapp_endpoint:start_events(C1, Ref, Self, Dialog1A),

    % C2 has sent the INVITE to C3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, notify, <<"SIP/2.0 180 Ringing">>}]),
    timer:sleep(100),

    [Subs1A] = nksip_dialog:field(C1, Dialog1A, subscriptions),
    [
        {status, active},
        {parsed_event, {<<"refer">>, _}},
        {expires, 180}
    ] = nksip_subscription:fields(C1, Subs1A, [status, parsed_event, expires]),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(C2, CallId),
    [Subs1B] = nksip_dialog:field(C2, Dialog1B, subscriptions),
    [
        {status, active},
        {parsed_event, {<<"refer">>, _}},
        {expires, 180}
    ] = nksip_subscription:fields(C2, Subs1B, [status, parsed_event, expires]),

    % Let's do a refresh
    {ok, 200, _} = nksip_uac:subscribe(C1, Subs1A, [{expires, 10}]),
    10 = nksip_subscription:field(C1, Subs1A, expires),
    10 = nksip_subscription:field(C2, Subs1B, expires),
    
    % Lets find the INVITE dialogs at C2 and C3
    % Call-ID of the INVITE is the same as the original plus "_inv" 
    % (see implementation of refer/4 in sipapp_endoint.erl)
    InvCallId = <<CallId/binary, "_inv">>,
    [Dialog2A] = nksip_dialog:get_all(C2, InvCallId),
    
    proceeding_uac = nksip_dialog:field(C2, Dialog2A, invite_status),
    Dialog2B = nksip_dialog:remote_id(C2, Dialog2A),
    proceeding_uas = nksip_dialog:field(C3, Dialog2B, invite_status),

    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, notify, <<"SIP/2.0 200 OK">>}]),
    timer:sleep(100),
    error = nksip_dialog:field(C1, Dialog1A, subscriptions),
    error = nksip_dialog:field(C2, Dialog1B, subscriptions),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(C2, Dialog2A, []),
    error = nksip_dialog:field(C2, Dialog2A, invite_status),
    error = nksip_dialog:field(C3, Dialog2B, invite_status),
    ok.

% A REFER inside a INVITE dialog
in_dialog() ->
    C1 = {refer, client1},
    C2 = {refer, client2},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{dialog_id, Dialog1A}]} = 
        nksip_uac:invite(C1, SipC2, [auto_2xx_ack]),

    {ok, 200, [{subscription_id, _}]} = 
        nksip_uac:refer(C1, Dialog1A, [{refer_to, "sips:127.0.0.1:5081"}]),

    sipapp_endpoint:start_events(C1, Ref, Self, Dialog1A),

    % C2 has sent the INVITE to C3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, notify, <<"SIP/2.0 180 Ringing">>}]),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(C2, CallId),
    
    % Lets find the INVITE dialogs at C2 and C3
    % Call-ID of the INVITE is the same as the original plus "_inv" 
    % (see implementation of refer/4 in sipapp_endoint.erl)
    InvCallId = <<CallId/binary, "_inv">>,
    [Dialog2A] = nksip_dialog:get_all(C2, InvCallId),
        
    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, notify, <<"SIP/2.0 200 OK">>}]),
    timer:sleep(100),
    [] = nksip_dialog:field(C1, Dialog1A, subscriptions),
    [] = nksip_dialog:field(C2, Dialog1B, subscriptions),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(C2, Dialog2A, []),
    error = nksip_dialog:field(C2, Dialog2A, invite_status),

    % Finish the original INVITE
    {ok, 200, []} = nksip_uac:bye(C1, Dialog1A, []),
    error = nksip_dialog:field(C1, Dialog1A, invite_status),
    ok.



