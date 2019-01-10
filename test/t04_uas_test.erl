
%% -------------------------------------------------------------------
%%
%% uas_test: Basic Test Suite
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

-module(t04_uas_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).


uas_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uas/0}, 
            {timeout, 60, fun auto/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


all() ->
    start(),
    lager:warning("Starting TEST ~p", [?MODULE]),
    timer:sleep(1000),
    uas(),
    auto(),
    timeout(),
    stop().



start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(uas_test_server1, #{
        sip_from => "\"NkSIP Basic SUITE Test Server\" <sip:uas_test_server1@nksip>",
        sip_supported => "a;a_param, 100rel",
        sip_uac_auto_register_timer => 1,
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),

    {ok, _} = nksip:start_link(uas_test_client1, #{
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:uas_test_client1@nksip>",
        sip_uac_auto_register_timer => 1,
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>",
        plugins => [nksip_uac_auto_register]
    }),
            
    {ok, _} = nksip:start_link(uas_test_client2, #{
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:uas_test_client2@nksip>"
    }),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(uas_test_server1),
    ok = nksip:stop(uas_test_client1),
    ok = nksip:stop(uas_test_client2).


uas() ->
    % Test loop detection
    {ok, 200, Values1} = nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
                                {add, <<"x-nk-op">>, <<"reply-stateful">>},
                                {get_meta, [call_id, from, cseq_num]}]),
    [{call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}] = Values1,

    {ok, 482, [{reason_phrase, <<"Loop Detected">>}]} = 
        nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
                            {add, <<"x-nk-op">>, <<"reply-stateful">>},
                            {call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}, 
                            {get_meta, [reason_phrase]}]),

    % Stateless proxies do not detect loops
    {ok, 200, Values3} = nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
                            {add, "x-nk-op", "reply-stateless"},
                            {get_meta, [call_id, from, cseq_num]}]),

    [{_, CallId3}, {_, From3}, {_, CSeq3}] = Values3,
    {ok, 200, []} = nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
                        {add, "x-nk-op", "reply-stateless"},
                        {call_id, CallId3}, {from, From3}, {cseq_num, CSeq3}]),

    % Test bad extension endpoint and proxy
    {ok, 420, [{all_headers, Hds5}]} = nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
                                           {add, "require", "a,b;c,d"}, 
                                           {get_meta, [all_headers]}]),
    % 'a' is supported because of app config
    [<<"b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds5),
    
    {ok, 420, [{all_headers, Hds6}]} = nksip_uac:options(uas_test_client1, "sip:a@external.com", [
                                            {add, "proxy-require", "a,b;c,d"}, 
                                            {route, "<sip:127.0.0.1;lr>"},
                                            {get_meta, [all_headers]}]),
    [<<"a,b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds6),

    % Force invalid response
    lager:warning("Next warning about a invalid sipreply is expected"),
    {ok, 500,  [{reason_phrase, <<"Invalid Service Response">>}]} = 
        nksip_uac:options(uas_test_client1, "sip:127.0.0.1", [
            {add, "x-nk-op", "reply-invalid"}, {get_meta, [reason_phrase]}]),
    ok.


auto() ->
    {ok, _} = nksip:start_link(uas_test_server2, #{
        sip_registrar_min_time => 1,
        sip_uac_auto_register_timer => 1,
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5080"}),

    timer:sleep(200),
    {error, service_not_started} = nksip_uac_auto_register:start_ping(none, ping1, "sip:a", []),
    {error, invalid_uri} = nksip_uac_auto_register:start_ping(uas_test_client1, ping1, "sip::a", []),
    Ref = make_ref(),

    ok =  nkserver:put(uas_test_client1, callback, {Ref, self()}),

    {ok, true} = nksip_uac_auto_register:start_ping(uas_test_client1, ping1,
                                "<sip:127.0.0.1:5080;transport=tcp>", [{expires, 5}]),

    {error, service_not_started} = nksip_uac_auto_register:start_register(none, reg1, "sip::a", []),
    {error, invalid_uri} = nksip_uac_auto_register:start_register(uas_test_client1, reg1, "sip::a", []),
    {ok, true} = nksip_uac_auto_register:start_register(uas_test_client1, reg1,
                                "<sip:127.0.0.1:5080;transport=tcp>", [{expires, 1}]),

    [{ping1, true, _}] = nksip_uac_auto_register:get_pings(uas_test_client1),
    [{reg1, true, _}] = nksip_uac_auto_register:get_registers(uas_test_client1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    lager:notice("Next notices about connection error to port 9999 are expected"),
    {ok, false} = nksip_uac_auto_register:start_ping(uas_test_client1, ping2,
                                            "<sip:127.0.0.1:9999;transport=tcp>",
                                            [{expires, 1}]),
    {ok, false} = nksip_uac_auto_register:start_register(uas_test_client1, reg2,
                                            "<sip:127.0.0.1:9999;transport=tcp>",
                                            [{expires, 1}]),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] =
        lists:sort(nksip_uac_auto_register:get_pings(uas_test_client1)),
    [{reg1, true,_}, {reg2, false,_}] =
        lists:sort(nksip_uac_auto_register:get_registers(uas_test_client1)),

    ok = nksip_uac_auto_register:stop_ping(uas_test_client1, ping2),
    ok = nksip_uac_auto_register:stop_register(uas_test_client1, reg2),

    [{ping1, true, _}] = nksip_uac_auto_register:get_pings(uas_test_client1),
    [{reg1, true, _}] = nksip_uac_auto_register:get_registers(uas_test_client1),

    ok = nksip_uac_auto_register:stop_ping(uas_test_client1, ping1),
    ok = nksip_uac_auto_register:stop_register(uas_test_client1, reg1),
    ok = nksip:stop(uas_test_server2),
    timer:sleep(500),
    lager:notice("Next notice about connection error to port 5080 is expected"),
    {ok, false} = nksip_uac_auto_register:start_ping(uas_test_client1, ping3,
                                            "<sip:127.0.0.1:5080;transport=tcp>",
                                            [{expires, 1}]),
    ok = nksip_uac_auto_register:stop_ping(uas_test_client1, ping3),
    [] = nksip_uac_auto_register:get_pings(uas_test_client1),
    [] = nksip_uac_auto_register:get_registers(uas_test_client1),
    ok.


timeout() ->
    SipC1 = "<sip:127.0.0.1:5070;transport=tcp>",

    % ok = nksip:update(uas_test_client1, [{sipapp_timeout, 0.02}]),

    % % Client1 callback module has a 50msecs delay in route()
    % {ok, 500, [{reason_phrase, <<"No Server Response">>}]} = 
    %     nksip_uac:options(uas_test_client2, SipC1, [{get_meta,[reason_phrase]}]),

    ok = nksip:update(uas_test_client1, #{sip_timer_t1=>10, sip_timer_c=>1}),

    Hd1 = {add, "x-nk-sleep", 2000},
    {ok, 408, [{reason_phrase, <<"No-INVITE Timeout">>}]} = 
        nksip_uac:options(uas_test_client2, SipC1, [Hd1, {get_meta, [reason_phrase]}]),

    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-sleep", 2000}],
    {ok, 408, [{reason_phrase, <<"Timer C Timeout">>}]} = 
        nksip_uac:invite(uas_test_client2, SipC1, [{get_meta,[reason_phrase]}|Hds2]),
    ok.

