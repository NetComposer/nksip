%% -------------------------------------------------------------------
%%
%% publish_test: PUBLISH Suite Test
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

-module(publish_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

event_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_endpoint:start({publish, client1}, [
        {from, "sip:client1@nksip"},
        {fullname, "NkSIP Basic SUITE Test Client1"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}
    ]),
    
    ok = sipapp_endpoint:start({publish, client2}, [
        {from, "sip:client2@nksip"},
        no_100,
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}},
        {event, "nkpublish"}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({publish, client1}),
    ok = sipapp_endpoint:stop({publish, client2}).


basic() ->
    C1 = {publish, client1},
    C2 = {publish, client2},
    SipC2 = "sip:user1@127.0.0.1:5070",

    {ok, 200, [{sip_etag, ETag1}, {expires, 5}]} = 
        nksip_uac:publish(C1, SipC2, 
            [{event, "nkpublish"}, {expires, 5}, {body, <<"data1">>}]),

    AOR = {sip, <<"user1">>, <<"127.0.0.1">>},
    {ok, #reg_publish{data = <<"data1">>}} = nksip_publish:find(C2, AOR, ETag1),

    % This ETag1 is not at the server
    {ok, 412, []} = nksip_uac:publish(C1, SipC2, 
            [{event, "nkpublish"}, {sip_etag, <<"other">>}]),

    {ok, 200, [{sip_etag, ETag1}, {expires, 0}]} = 
        nksip_uac:publish(C1, SipC2, 
            [{event, "nkpublish"}, {expires, 0}, {sip_etag, ETag1}]),

    {error, not_found} = nksip_publish:find(C2, AOR, ETag1),

    {ok, 200, [{sip_etag, ETag2}, {expires, 60}]} = 
        nksip_uac:publish(C1, SipC2, 
            [{event, "nkpublish"}, {expires, 60}, {body, <<"data2">>}]),

    {ok, #reg_publish{data = <<"data2">>}} = nksip_publish:find(C2, AOR, ETag2),

    {ok, 200, [{sip_etag, ETag2}, {expires, 1}]} = 
        nksip_uac:publish(C1, SipC2, 
            [{event, "nkpublish"}, {expires, 1}, {sip_etag, ETag2}, {body, <<"data3">>}]),

    {ok, #reg_publish{data = <<"data3">>}} = nksip_publish:find(C2, AOR, ETag2),
    ok.

