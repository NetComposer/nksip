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

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {transports, [{udp, all, 5060}]}
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    {ok, _} = nksip:start(client3, ?MODULE, client3, [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2),
    ok = nksip:stop(client3).


basic() ->
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{subscription_id, Subs1A}]} = 
        nksip_uac:refer(client1, SipC2, [{refer_to, "sips:127.0.0.1:5081"}]),

    Dialog1A = nksip_subscription:dialog_id(Subs1A),
    % Prepare to send us the received NOTIFYs
    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),

    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 180 Ringing">>}}]),
    timer:sleep(100),

    [Subs1A] = nksip_dialog:field(Dialog1A, subscriptions),
    [
        {status, active},
        {parsed_event, {<<"refer">>, _}},
        {expires, 180}
    ] = nksip_subscription:fields(client1, Subs1A, [status, parsed_event, expires]),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    [Subs1B] = nksip_dialog:field(Dialog1B, subscriptions),
    [
        {status, active},
        {parsed_event, {<<"refer">>, _}},
        {expires, 180}
    ] = nksip_subscription:fields(client2, Subs1B, [status, parsed_event, expires]),

    % Let's do a refresh
    {ok, 200, _} = nksip_uac:subscribe(client1, Subs1A, [{expires, 10}]),
    10 = nksip_subscription:field(client1, Subs1A, expires),
    10 = nksip_subscription:field(client2, Subs1B, expires),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original plus "_inv" 
    % (see implementation of refer/4 in sipapp_endoint.erl)
    InvCallId = <<CallId/binary, "_inv">>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
    
    proceeding_uac = nksip_dialog:field(Dialog2A, invite_status),
    Dialog2B = nksip_dialog:remote_id(Dialog2A, client1),
    proceeding_uas = nksip_dialog:field(client3, Dialog2B, invite_status),

    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 200 OK">>}}]),
    timer:sleep(100),
    error = nksip_dialog:field(Dialog1A, subscriptions),
    error = nksip_dialog:field(Dialog1B, subscriptions),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    error = nksip_dialog:field(Dialog2A, invite_status),
    error = nksip_dialog:field(client3, Dialog2B, invite_status),
    ok.

% A REFER inside a INVITE dialog
in_dialog() ->
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{dialog_id, Dialog1A}]} = 
        nksip_uac:invite(client1, SipC2, [auto_2xx_ack]),

    {ok, 200, [{subscription_id, _}]} = 
        nksip_uac:refer(client1, Dialog1A, [{refer_to, "sips:127.0.0.1:5081"}]),

    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),


    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 180 Ringing">>}}]),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original plus "_inv" 
    % (see implementation of refer/4 in sipapp_endoint.erl)
    InvCallId = <<CallId/binary, "_inv">>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
        
    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 200 OK">>}}]),
    timer:sleep(100),
    [] = nksip_dialog:field(Dialog1A, subscriptions),
    [] = nksip_dialog:field(Dialog1B, subscriptions),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    error = nksip_dialog:field(Dialog2A, invite_status),

    % Finish the original INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog1A, []),
    error = nksip_dialog:field(Dialog1A, invite_status),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.


refer(ReqId, Meta, _From,AppId=State) ->
    ReferTo = nksip_lib:get_value(refer_to, Meta),
    SubsId = nksip_lib:get_value(subscription_id, Meta),
    CallId = nksip_request:call_id(ReqId),
    InvCallId = <<CallId/binary, "_inv">>,
    Opts = [async, auto_2xx_ack, {call_id, InvCallId}, {refer_subscription_id, SubsId}],
    spawn(fun() -> nksip_uac:invite(AppId, ReferTo, Opts) end),
    {reply, ok, State}.


notify(_ReqId, Meta, _From, AppId=State) ->
    Body = nksip_lib:get_value(body, Meta),
    tests_util:send_ref(AppId, Meta, {notify, Body}),
    {reply, ok, State}.


invite(ReqId, _Meta, From, AppId=State) ->
    spawn(
        fun() ->
            nksip_request:reply(ReqId, 180),
            timer:sleep(1000),
            nksip:reply(From, ok)
        end),
    {noreply, State}.

