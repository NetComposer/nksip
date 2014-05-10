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

    Dialog1A = nksip_dialog:get_id(Subs1A),
    % Prepare to send us the received NOTIFYs
    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),

    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 180 Ringing">>}}]),
    timer:sleep(100),

    [Subs1A] = nksip_dialog:meta(subscriptions, Dialog1A),
    [
        {status, active},
        {event, {<<"refer">>, [{<<"id">>, _}]}},
        {expires, 180}
    ] = nksip_subscription:meta([status, event, expires], Subs1A),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    [Subs1B] = nksip_dialog:meta(subscriptions, Dialog1B),
    [
        {status, active},
        {event, {<<"refer">>, [{<<"id">>, _}]}},
        {expires, 180}
    ] = nksip_subscription:meta([status, event, expires], Subs1B),

    % Let's do a refresh
    {ok, 200, _} = nksip_uac:subscribe(Subs1A, [{expires, 10}]),
    10 = nksip_subscription:meta(expires, Subs1A),
    10 = nksip_subscription:meta(expires, Subs1B),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original plus "_inv" 
    % (see implementation bellow in refer/2)
    InvCallId = <<CallId/binary, "_refer">>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
    
    proceeding_uac = nksip_dialog:meta(invite_status, Dialog2A),
    Dialog2B = nksip_dialog:remote_id(Dialog2A, client3),
    proceeding_uas = nksip_dialog:meta(invite_status, Dialog2B),

    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 200 OK">>}}]),
    timer:sleep(100),
    error = nksip_dialog:meta(subscriptions, Dialog1A),
    error = nksip_dialog:meta(subscriptions, Dialog1B),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    error = nksip_dialog:meta(invite_status, Dialog2A),
    error = nksip_dialog:meta(invite_status, Dialog2B),
    ok.


% A REFER inside a INVITE dialog
in_dialog() ->
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{dialog_id, Dialog1A}]} = nksip_uac:invite(client1, SipC2, [auto_2xx_ack]),

    {ok, 200, [{subscription_id, _}]} = nksip_uac:refer(Dialog1A, [{refer_to, "sips:127.0.0.1:5081"}]),

    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),

    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 180 Ringing">>}}]),

    CallId = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original plus "_refer" 
    % (see implementation bellow in refer/2)
    InvCallId = <<CallId/binary, "_refer">>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
        
    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [{client1, {notify, <<"SIP/2.0 200 OK">>}}]),
    timer:sleep(100),
    [] = nksip_dialog:meta(subscriptions, Dialog1A),
    [] = nksip_dialog:meta(subscriptions, Dialog1B),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    error = nksip_dialog:meta(invite_status, Dialog2A),

    % Finish the original INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog1A, []),
    error = nksip_dialog:meta(invite_status, Dialog1A),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.


sip_refer(Req, _Call) ->
    case nksip_request:header("refer-to", Req) of
        [ReferTo] ->
            AppId = nksip_request:app_id(Req),
            SubsId = nksip_subscription:get_id(Req), 
            CallId = nksip_request:call_id(Req),
            InvCallId = <<CallId/binary, "_refer">>,
            Opts = [async, auto_2xx_ack, {call_id, InvCallId}, 
                   {refer_subscription_id, SubsId}],
            spawn(fun() -> nksip_uac:invite(AppId, ReferTo, Opts) end),
            {reply, ok};
        O ->
            lager:warning("O: ~p", [O]),

            {reply, invalid_request}
    end.


sip_subscribe(_Req, _Call) ->
    {reply, ok}.


% resubscribe(_Req, _Call) ->
%     {reply, ok}.


sip_notify(Req, _Call) ->
    Body = nksip_request:body(Req),
    tests_util:send_ref({notify, Body}, Req),
    {reply, ok}.


sip_invite(Req, _Call) ->
    ReqId = nksip_request:get_id(Req),
    spawn(
        fun() ->
            nksip_request:reply(180, ReqId),
            timer:sleep(1000),
            nksip_request:reply(ok, ReqId)
        end),
    noreply.

