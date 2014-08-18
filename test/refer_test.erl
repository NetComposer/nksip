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

    {ok, _} = nksip:start(client1, ?MODULE, [], [
        {transports, [{udp, all, 5060}]},
        {event_expires_offset, 0},
        {plugins, [nksip_refer]}
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, [], [
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        {event_expires_offset, 0},
        {plugins, [nksip_refer]}
    ]),

    {ok, _} = nksip:start(client3, ?MODULE, [], [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]},
        {event_expires_offset, 0},
        {plugins, [nksip_refer]}
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
    
    {ok, 200, [{subscription, Subs1A}]} = 
        nksip_uac:refer(client1, SipC2, [{refer_to, "sips:127.0.0.1:5081"}]),

    {ok, Dialog1A} = nksip_dialog:get_handle(Subs1A),
    % Prepare to send us the received NOTIFYs
    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),

    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [
        % {client1, Subs1A, init},  % It does not arrive, ref is not yet stored
        {client1, Subs1A, active},
        {client1, Subs1A, {notify, <<"SIP/2.0 180 Ringing">>}}
    ]),
    timer:sleep(100),

    {ok, [Subs1A]} = nksip_dialog:meta(subscriptions, Dialog1A),
    {ok, [
        {status, active},
        {event, {<<"refer">>, [{<<"id">>, _}]}},
        {expires, 180}
    ]} = nksip_subscription:metas([status, event, expires], Subs1A),

    {ok, CallId} = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    {ok, [Subs1B]} = nksip_dialog:meta(subscriptions, Dialog1B),
    {ok, [
        {status, active},
        {event, {<<"refer">>, [{<<"id">>, _}]}},
        {expires, 180}
    ]} = nksip_subscription:metas([status, event, expires], Subs1B),

    % Let's do a refresh
    {ok, 200, _} = nksip_uac:subscribe(Subs1A, [{expires, 10}]),
    {ok, 10} = nksip_subscription:meta(expires, Subs1A),
    {ok, 10} = nksip_subscription:meta(expires, Subs1B),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original starting with  "nksip_refer"
    % (see implementation bellow in refer/2)
    InvCallId = <<"nksip_refer_", CallId/binary>>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
    
    {ok, proceeding_uac} = nksip_dialog:meta(invite_status, Dialog2A),
    Dialog2B = nksip_dialog_lib:remote_id(Dialog2A, client3),
    {ok, proceeding_uas} = nksip_dialog:meta(invite_status, Dialog2B),

    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [
        {client1, Subs1A, {notify, <<"SIP/2.0 200 OK">>}},
        {client1, Subs1A, terminated}
    ]),
    timer:sleep(100),
    {error, _} = nksip_dialog:meta(subscriptions, Dialog1A),
    {error, _} = nksip_dialog:meta(subscriptions, Dialog1B),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    {error, _} = nksip_dialog:meta(invite_status, Dialog2A),
    {error, _} = nksip_dialog:meta(invite_status, Dialog2B),
    ok.


% A REFER inside a INVITE dialog
in_dialog() ->
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    {ok, 200, [{dialog, Dialog1A}]} = nksip_uac:invite(client1, SipC2, [auto_2xx_ack]),

    {ok, 200, [{subscription, Subs1}]} = 
        nksip_uac:refer(Dialog1A, [{refer_to, "sips:127.0.0.1:5081"}]),

    {ok, Dialogs} = nksip:get(client1, dialogs, []),
    ok = nksip:put(client1, dialogs, [{Dialog1A, Ref, Self}|Dialogs]),

    % client2 has sent the INVITE to client3, and it has replied 180
    ok = tests_util:wait(Ref, [
        {client1, Subs1, active},
        {client1, Subs1, {notify, <<"SIP/2.0 180 Ringing">>}}
    ]),

    {ok, CallId} = nksip_dialog:call_id(Dialog1A),
    [Dialog1B] = nksip_dialog:get_all(client2, CallId),
    
    % Lets find the INVITE dialogs at client2 and client3
    % Call-ID of the INVITE is the same as the original plus "_refer" 
    % (see implementation bellow in refer/2)
    InvCallId = <<"nksip_refer_", CallId/binary>>,
    [Dialog2A] = nksip_dialog:get_all(client2, InvCallId),
        
    % Final response received. Subscription is stopped.
    ok = tests_util:wait(Ref, [
        {client1, Subs1, {notify, <<"SIP/2.0 200 OK">>}},
        {client1, Subs1, terminated}
    ]),
    timer:sleep(100),
    {ok, []} = nksip_dialog:meta(subscriptions, Dialog1A),
    {ok, []} = nksip_dialog:meta(subscriptions, Dialog1B),

    % Finish the started INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog2A, []),
    {error, _} = nksip_dialog:meta(invite_status, Dialog2A),

    % Finish the original INVITE
    {ok, 200, []} = nksip_uac:bye(Dialog1A, []),
    {error, _} = nksip_dialog:meta(invite_status, Dialog1A),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%



sip_refer(_ReferTo, _Req, _Call) ->
    true.

sip_refer_update(SubsHandle, Status, Call) ->
    {ok, DialogId} = nksip_dialog:get_handle(SubsHandle),
    AppId = nksip_call:app_id(Call),
    {ok, Dialogs} = nksip:get(AppId, dialogs, []),
    case lists:keyfind(DialogId, 1, Dialogs) of
        {DialogId, Ref, Pid}=_D -> 
            Pid ! {Ref, {AppId:name(), SubsHandle, Status}};
        false ->
            ok
    end.


sip_invite(Req, _Call) ->
    {ok, ReqId} = nksip_request:get_handle(Req),
    spawn(
        fun() ->
            nksip_request:reply(180, ReqId),
            timer:sleep(1000),
            nksip_request:reply(ok, ReqId)
        end),
    noreply.

