%% -------------------------------------------------------------------
%%
%% event_test: Event Suite Test
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

-module(event_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

event_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        {inparallel, [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun refresh/0},
            {timeout, 60, fun dialog/0}
        ]}
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_endpoint:start({event, client1}, [
        {from, "sip:client1@nksip"},
        {fullname, "NkSIP Basic SUITE Test Client1"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}},
        {event, "myevent1,myevent2"},
        {event, "myevent3"}
    ]),
    
    ok = sipapp_endpoint:start({event, client2}, [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}},
        {event, "myevent4"}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({event, client1}),
    ok = sipapp_endpoint:stop({event, client2}).


basic() ->
    C1 = {event, client1},
    C2 = {event, client2},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    
    CB = {callback, fun(R) -> Self ! {Ref, R} end},
    {ok, 489, []} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent1;id=a"}, CB, get_request]),

    receive {Ref, {req, Req1}} -> 
        [[<<"myevent1;id=a">>],[<<"myevent1,myevent2,myevent3">>]] = 
            nksip_sipmsg:fields(Req1, [<<"Event">>, <<"Allow-Event">>])
    after 1000 -> 
        error(event) 
    end,

    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    {ok, 200, [{subscription_id, Subs1A}]} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4;id=4;o=2"}, {expires, 1},
                                        {headers, [RepHd]}]),

    Dialog1A = nksip_subscription:dialog_id(Subs1A),
    Dialog1B = nksip_dialog:field(C1, Dialog1A, remote_id),
    Subs1B = nksip_subscription:remote_id(C1, Subs1A),
    [
        {status, start},
        {event, <<"myevent4;id=4;o=2">>},
        {class, uac},
        {answered, undefined},
        {expires, 1}    % It will be something link round(0.99)
    ] = nksip_subscription:fields(C1, Subs1A, [status, event, class, answered, expires]),

    [
        {status, start},
        {parsed_event, {<<"myevent4">>, [{<<"id">>, <<"4">>}, {<<"o">>, <<"2">>}]}},
        {class, uas},
        {answered, undefined},
        {expires, 1} 
    ] = nksip_subscription:fields(C2, Subs1B, [status, parsed_event, class, answered, expires]),

    [
        {invite_status, undefined},
        {subscriptions, [Subs1A]}
    ] = nksip_dialog:fields(C1, Dialog1A, [invite_status, subscriptions]),
    [
        {invite_status, undefined},
        {subscriptions, [Subs1B]}
    ] = nksip_dialog:fields(C2, Dialog1B, [invite_status, subscriptions]),

    ok = tests_util:wait(Ref, [
            {subs, Subs1B, started}, 
            {subs, Subs1B, middle_timer},
            {subs, Subs1B, {terminated, timeout}}
    ]),
    timer:sleep(100),

    error = nksip_subscription:field(C1, Subs1A, status),
    error = nksip_subscription:field(C2, Subs1B, status),


    {ok, 200, [{subscription_id, Subs2A}]} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4;id=4;o=2"}, {expires, 2
            },
                                        {headers, [RepHd]}]),
 
    Subs2B = nksip_subscription:remote_id(C1, Subs2A),
    ok = tests_util:wait(Ref, [{subs, Subs2B, started}]),

    Dialog2A = nksip_subscription:dialog_id(Subs2A),
    sipapp_endpoint:start_events(C1, Ref, Self, Dialog2A),

    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, [{state, pending}, {body, <<"notify1">>}]),

    ok = tests_util:wait(Ref, [
        {subs, Subs2B, pending}, 
        {subs, Subs2A, pending},
        {client1, notify, <<"notify1">>},
        {subs, Subs2A, middle_timer},
        {subs, Subs2B, middle_timer}]),


    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, [{body, <<"notify2">>}]),

    ok = tests_util:wait(Ref, [
        {subs, Subs2B, active}, 
        {subs, Subs2A, active},
        {client1, notify, <<"notify2">>},
        {subs, Subs2A, middle_timer},         % C1 has re-scheduled timers 
        {subs, Subs2B, middle_timer}  
    ]),

    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, [{state, {terminated, giveup}}, {retry_after, 5}]),

ok = tests_util:wait(Ref, [
        {client1, notify, <<>>},
        {subs, Subs2B, {terminated, {giveup, 5}}}, 
        {subs, Subs2A, {terminated, {giveup, 5}}}
    ]),

    ok.


refresh() ->
    C1 = {event, client1},
    C2 = {event, client2},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    Hds = [
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
        {"Nk-Op", "expires-2"}
    ],
    {ok, 200, [{subscription_id, Subs1A}]} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, {expires, 5},
                                        {headers, [Hds]}]),
    Subs1B = nksip_subscription:remote_id(C1, Subs1A),
    {ok, 200, []} = nksip_uac:notify(C2, Subs1B, []),

    % 2xx response to subscribe has changed timeout to 2 secs
    2 = nksip_subscription:field(C1, Subs1A, expires),
    2 = nksip_subscription:field(C2, Subs1B, expires),
    ok = tests_util:wait(Ref, [
        {subs, Subs1B, started},
        {subs, Subs1B, active},
        {subs, Subs1B, middle_timer}
    ]),

    % We send a refresh, changing timeout to 20 secs
    {ok, 200, [{subscription_id, Subs1A}]} = 
        nksip_uac:subscribe(C1, Subs1A, [{expires, 20}]),
    20 = nksip_subscription:field(C1, Subs1A, expires),
    20 = nksip_subscription:field(C2, Subs1B, expires),
    
    % But we finish de dialog
    {ok, 200, []} = nksip_uac:notify(C2, Subs1B, [{state, {terminated, giveup}}]),
    ok = tests_util:wait(Ref, [{subs, Subs1B, {terminated, {giveup, undefined}}}]),
    ok.
    

    % % A new subscription
    % {ok, 200, [{subscription_id, Subs2A}]} = 
    %     nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, {expires, 5},
    %                                     {headers, [Hds]}]),
    % Subs2B = nksip_subscription:remote_id(C1, Subs2A),
    % {ok, 200, []} = nksip_uac:notify(C2, Subs2B, []),

    % % And a refresh to expire
    % {ok, 200, [{subscription_id, Subs2A}]} = 
    %     nksip_uac:subscribe(C1, Subs2A, [{expires, 0}]).


dialog() ->
    C1 = {event, client1},
    C2 = {event, client2},
    SipC2 = "sip:127.0.0.1:5070",
    _Ref = make_ref(),
    _Self = self(),
    
    % CB = {callback, fun(R) -> Self ! {Ref, R} end},
    {ok, 200, [{subscription_id, Subs1A}, {dialog_id, DialogA}]} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4;id=1"}, {expires, 2}, 
                                        {contact, "sip:a@127.0.0.1"}, 
                                        {fields, [dialog_id]}]),
    Subs1B = nksip_subscription:remote_id(C1, Subs1A),
    RS1 = {"Record-Route", "<sip:b1@127.0.0.1:5070;lr>,<sip:b@b>,<sip:a2@127.0.0.1;lr>"},

    % Now the remote party (the server) sends a NOTIFY, and updates the Route Set
    {ok, 200, []} = nksip_uac:notify(C2, Subs1B, [{headers, [RS1]}]),
    [
        {local_target, <<"<sip:a@127.0.0.1>">>},
        {remote_target, <<"<sip:127.0.0.1:5070>">>},
        {route_set, [<<"<sip:b1@127.0.0.1:5070;lr>">>,<<"<sip:b@b>">>,<<"<sip:a2@127.0.0.1;lr>">>]}
    ] = nksip_dialog:fields(C1, DialogA, [local_target, remote_target, route_set]),

    % It sends another NOTIFY, tries to update again the Route Set but it is not accepted.
    % The remote target is successfully updated
    RS2 = {"Record-Route", "<sip:b@b>"},
    {ok, 200, []} = nksip_uac:notify(C2, Subs1B, [{headers, [RS2]}, {contact, "sip:b@127.0.0.1:5070"}]),
    [
        {local_target, <<"<sip:a@127.0.0.1>">>},
        {remote_target, <<"<sip:b@127.0.0.1:5070>">>},
        {route_set, [<<"<sip:b1@127.0.0.1:5070;lr>">>,<<"<sip:b@b>">>,<<"<sip:a2@127.0.0.1;lr>">>]}
    ] = nksip_dialog:fields(C1, DialogA, [local_target, remote_target, route_set]),

    % We send another subscription request using the same dialog, but different Event Id
    % We update our local target
    {ok, 200, [{subscription_id, Subs2A}]} = 
        nksip_uac:subscribe(C1, DialogA, [{event, "myevent4;id=2"}, {expires, 2}, 
                                             {contact, "sip:a3@127.0.0.1"}]),
    Subs2B = nksip_subscription:remote_id(C1, Subs2A),
    DialogA = nksip_subscription:dialog_id(Subs2A),
    DialogB = nksip_dialog:field(C1, DialogA, remote_id),

    % Remote party updates remote target again
    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, [{contact, "sip:b2@127.0.0.1:5070"}]),
    [
        {local_target, <<"<sip:a3@127.0.0.1>">>},
        {remote_target, <<"<sip:b2@127.0.0.1:5070>">>},
        {route_set, [<<"<sip:b1@127.0.0.1:5070;lr>">>,<<"<sip:b@b>">>,<<"<sip:a2@127.0.0.1;lr>">>]}
    ] = nksip_dialog:fields(C1, DialogA, [local_target, remote_target, route_set]),
    [
        {local_target, <<"<sip:b2@127.0.0.1:5070>">>},
        {remote_target, <<"<sip:a3@127.0.0.1>">>},
        {route_set, [<<"<sip:a2@127.0.0.1;lr>">>, <<"<sip:b@b>">>, <<"<sip:b1@127.0.0.1:5070;lr>">>]}
    ] = nksip_dialog:fields(C2, DialogB, [local_target, remote_target, route_set]),

    % Now we have a dialog with 2 subscriptions
    [Subs1A, Subs2A] = nksip_dialog:field(C1, DialogA, subscriptions),

    {ok, 200, [{dialog_id, DialogB}]} = nksip_uac:invite(C2, DialogB, []),
    ok = nksip_uac:ack(C2, DialogB, []),

    % Now we have a dialog with 2 subscriptions and 

    {ok, 489, []} =
        nksip_uac:subscribe(C2, DialogB, [{event, "myevent4"}]),

    {ok, 200, [{subscription_id, Subs3B}]} = 
        nksip_uac:subscribe(C2, DialogB, [{event, "myevent1"}, {expires, 1}]),
    Subs3A = nksip_subscription:remote_id(C2, Subs3B),
    {ok, 200, []} = nksip_uac:notify(C1, Subs3A, []),

    % Now we have a dialog with 3 subscriptions and a INVITE
    [Subs1A, Subs2A, Subs3A] = nksip_dialog:field(C1, DialogA, subscriptions),
    [Subs1B, Subs2B, Subs3B] = nksip_dialog:field(C2, DialogB, subscriptions),
    confirmed = nksip_dialog:field(C1, DialogA, invite_status),
    confirmed = nksip_dialog:field(C2, DialogB, invite_status),

    timer:sleep(2000),

    % Now the subscriptions has timeout, we have only the INVITE
    [] = nksip_dialog:field(C1, DialogA, subscriptions),
    [] = nksip_dialog:field(C2, DialogB, subscriptions),
    confirmed = nksip_dialog:field(C1, DialogA, invite_status),
    confirmed = nksip_dialog:field(C2, DialogB, invite_status),

    {ok, 200, []} = nksip_uac:bye(C2, DialogB, []),
    error = nksip_dialog:field(C1, DialogA, invite_status),
    error = nksip_dialog:field(C2, DialogB, invite_status),
    ok.






