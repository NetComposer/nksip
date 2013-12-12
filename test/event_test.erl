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
            {timeout, 60, fun dialog/0},
            {timeout, 60, fun out_or_order/0},
            {timeout, 60, fun fork/0}
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
        {status, init},
        {event, <<"myevent4;id=4;o=2">>},
        {class, uac},
        {answered, undefined},
        {expires, 1}    % It will be something link round(0.99)
    ] = nksip_subscription:fields(C1, Subs1A, [status, event, class, answered, expires]),

    [
        {status, init},
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
            {subs, Subs1B, init}, 
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
    ok = tests_util:wait(Ref, [{subs, Subs2B, init}]),

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
        {subs, Subs1B, init},
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
    
    % A new subscription
    {ok, 200, [{subscription_id, Subs2A}]} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, {expires, 5},
                                        {headers, [Hds]}]),
    Subs2B = nksip_subscription:remote_id(C1, Subs2A),
    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, []),
    ok = tests_util:wait(Ref, [{subs, Subs2B, init}, {subs, Subs2B, active}
    ]),

    % And a refresh with expire=0, actually it is not removed until notify
    {ok, 200, [{subscription_id, Subs2A}]} = 
        nksip_uac:subscribe(C1, Subs2A, [{expires, 0}]),
    % Notify will use status:terminated;reason=timeout automatically
    {ok, 200, []} = nksip_uac:notify(C2, Subs2B, []),
    ok = tests_util:wait(Ref, [{subs, Subs2B, {terminated, timeout}}]),
    ok.


dialog() ->
    C1 = {event, client1},
    C2 = {event, client2},
    SipC2 = "sip:127.0.0.1:5070",

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


% Test reception of NOTIFY before SUBSCRIPTION's response
out_or_order() ->
    C1 = {event, client1},
    SipC2 = "sip:127.0.0.1:5070",
    Self = self(),
    Ref = make_ref(),
    Reply = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    CB = {callback, fun(R) -> Self ! {Ref, R} end},
    {async, _} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, CB, async, get_request,
                                        {headers, [Reply, {"Nk-Op", "wait"}]}, 
                                        {expires, 2}]),

    % Right after sending the SUBSCRIBE, and before replying with 200
    RecvReq1 = receive {Ref, {wait, Req1}} -> Req1
    after 1000 -> error(fork)
    end,

    % Generate a NOTIFY similar to what C2 would send after 200, simulating
    % coming to C1 before the 200 response to SUBSCRIBE
    Notify1 = make_notify(RecvReq1),
    {ok, 200, []} = nksip_call:send(Notify1, [no_dialog]),

    Subs1A = receive {Ref, {ok, 200, [{subscription_id, S1}]}} -> S1
    after 5000 -> error(fork)
    end,
    Subs1B = nksip_subscription:remote_id(C1, Subs1A),

    receive {Ref, {req, _}} -> ok after 1000 -> error(fork) end,

    % 'active' is not received, the remote party does not see the NOTIFY
    ok = tests_util:wait(Ref, [
        {subs, Subs1B, init},
        {subs, Subs1B, middle_timer},
        {subs, Subs1B, {terminated, timeout}}
    ]),

    % Another subscription
    {async, _} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, CB, async, get_request,
                                        {headers, [Reply, {"Nk-Op", "wait"}]}, 
                                        {expires, 2}]),
    RecvReq2 = receive {Ref, {wait, Req2}} -> Req2
    after 1000 -> error(fork)
    end,
    % If we use another FromTag, it is not accepted
    RecvReq3 = RecvReq2#sipmsg{
        from = (RecvReq2#sipmsg.from)#uri{ext_opts=[{<<"tag">>, <<"a">>}]},
        from_tag = <<"a">>
    },
    Notify3 = make_notify(RecvReq3),
    {ok, 481, []} = nksip_call:send(Notify3, [no_dialog]),
    ok.


fork() ->
    C1 = {event, client1},
    C2 = {event, client2},
    SipC2 = "sip:127.0.0.1:5070",
    Self = self(),
    Ref = make_ref(),
    Reply = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    CB = {callback, fun(R) -> Self ! {Ref, R} end},

    {async, _} = 
        nksip_uac:subscribe(C1, SipC2, [{event, "myevent4"}, CB, async, get_request,
                                        {headers, [Reply, {"Nk-Op", "wait"}]}, 
                                        {expires, 2}]),

    % Right after sending the SUBSCRIBE, and before replying with 200
    RecvReq1 = receive {Ref, {wait, Req1}} -> Req1
    after 1000 -> error(fork)
    end,
    #sipmsg{call_id=CallId} = RecvReq1,

    % Generate a NOTIFY similar to what C2 would send after 200, simulating
    % coming to C1 before the 200 response to SUBSCRIBE
    Notify1 = make_notify(RecvReq1#sipmsg{to_tag_candidate = <<"a">>}),
    {ok, 200, []} = nksip_call:send(Notify1, [no_dialog]),

    Notify2 = make_notify(RecvReq1#sipmsg{to_tag_candidate = <<"b">>}),
    {ok, 200, []} = nksip_call:send(Notify2, [no_dialog]),

    SubsA = receive {Ref, {ok, 200, [{subscription_id, S1}]}} -> S1
    after 5000 -> error(fork)
    end,

    receive {Ref, {req, _}} -> ok after 1000 -> error(fork) end,

    SubsB = nksip_subscription:remote_id(C1, SubsA),
    {ok, 200, []} = nksip_uac:notify(C2, SubsB, []),

    Notify4 = make_notify(RecvReq1#sipmsg{to_tag_candidate = <<"c">>}),
    {ok, 200, []} = nksip_call:send(Notify4, [no_dialog]),

    % We have created four dialogs, each one with one subscription
    [D1, D2, D3, D4] = nksip_dialog:get_all(C1, CallId),
    [_] = nksip_dialog:field(C1, D1, subscriptions),
    [_] = nksip_dialog:field(C1, D2, subscriptions),
    [_] = nksip_dialog:field(C1, D3, subscriptions),
    [_] = nksip_dialog:field(C1, D4, subscriptions),

    {ok, 200, []} = nksip_uac:notify(C2, SubsB, [{state, {terminated, giveup}}]),
    ok.


make_notify(#sipmsg{to_tag_candidate=ToTag}=Req) ->
    Req#sipmsg{
        id = nksip_sipmsg:make_id(req, Req#sipmsg.call_id),
        class = {req, 'NOTIFY'},
        ruri = hd(nksip_parse:uris("sip:127.0.0.1")),
        vias = [],
        from = (Req#sipmsg.to)#uri{ext_opts=[{<<"tag">>, ToTag}]},
        to = Req#sipmsg.from,
        cseq = Req#sipmsg.cseq+1,
        cseq_method = 'NOTIFY',
        routes = [],
        contacts = nksip_parse:uris("sip:127.0.0.1:5070"),
        expires = 0,
        headers = [{<<"Subscription-State">>, <<"active;expires=5">>}],
        from_tag = ToTag,
        to_tag = Req#sipmsg.from_tag,
        transport = undefined
    }.

