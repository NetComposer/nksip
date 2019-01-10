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

-module(t16_publish_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").
-include_lib("nksip/include/nksip_event_compositor.hrl").

-compile([export_all, nowarn_export_all]).

publish_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(publish_test_client, #{
        sip_from => "sip:publish_test_client@nksip",
        sip_local_host => "localhost",
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),
    
    {ok, _} = nksip:start_link(publish_test_server, #{
        sip_from => "sip:publish_test_server@nksip",
        sip_no_100 => true,
        sip_events => "nkpublish",
        sip_local_host => "127.0.0.1",
        plugins => [nksip_event_compositor],
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(publish_test_client),
    ok = nksip:stop(publish_test_server).


all() ->
    start(),
    lager:warning("Starting TEST ~p normal", [?MODULE]),
    timer:sleep(1000),
    basic(),
    stop().


basic() ->
    SipC2 = "sip:user1@127.0.0.1:5070",

    {ok, 200, [{sip_etag, ETag1}, {expires, 5}]} = 
        nksip_uac:publish(publish_test_client, SipC2,
            [{event, "nkpublish"}, {expires, 5}, {body, <<"data1">>}]),

    AOR = {sip, <<"user1">>, <<"127.0.0.1">>},
    {ok, #reg_publish{data = <<"data1">>}} = nksip_event_compositor:find(publish_test_server, AOR, ETag1),

    % This ETag1 is not at the publish_test_server
    {ok, 412, []} = nksip_uac:publish(publish_test_client, SipC2,
            [{event, "nkpublish"}, {sip_if_match, <<"other">>}]),

    {ok, 200, [{sip_etag, ETag1}, {expires, 0}]} = 
        nksip_uac:publish(publish_test_client, SipC2,
            [{event, "nkpublish"}, {expires, 0}, {sip_if_match, ETag1}]),

    not_found = nksip_event_compositor:find(publish_test_server, AOR, ETag1),

    {ok, 200, [{sip_etag, ETag2}, {expires, 60}]} = 
        nksip_uac:publish(publish_test_client, SipC2,
            [{event, "nkpublish"}, {expires, 60}, {body, <<"data2">>}]),

    {ok, #reg_publish{data = <<"data2">>}} = nksip_event_compositor:find(publish_test_server, AOR, ETag2),

    {ok, 200, [{sip_etag, ETag2}, {expires, 1}]} = 
        nksip_uac:publish(publish_test_client, SipC2,
            [{event, "nkpublish"}, {expires, 1}, {sip_if_match, ETag2}, {body, <<"data3">>}]),

    {ok, #reg_publish{data = <<"data3">>}} = nksip_event_compositor:find(publish_test_server, AOR, ETag2),
    ok.





