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

-module(uas_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


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


start() ->
    tests_util:start_nksip(),
    nksip_config:put(nksip_store_timer, 200),
    nksip_config:put(nksip_sipapp_timer, 10000),

    ok = sipapp_server:start({uas, server1}, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        {supported, "a;a_param, 100rel"},
        registrar,
        {listeners, 10},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({uas, client1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({uas, client2}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_server:stop({uas, server1}),
    ok = sipapp_endpoint:stop({uas, client1}),
    ok = sipapp_endpoint:stop({uas, client2}).


uas() ->
    C1 = {uas, client1},
    
    % Test loop detection
    Opts1 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-stateful">>}]},
        {fields, [call_id, from, cseq_num]}
    ],
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:127.0.0.1", Opts1),
    [{call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}] = Values1,
    ForceLoopOpts1 = [{call_id, CallId1}, {from, From1}, {cseq, CSeq1}, 
                      {fields, [reason_phrase]} | Opts1],
    {ok, 482, [{reason_phrase, <<"Loop Detected">>}]} = 
        nksip_uac:options(C1, "sip:127.0.0.1", ForceLoopOpts1),

    % Stateless proxies do not detect loops
    Opts3 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-stateless">>}]},
        {fields, [call_id, from, cseq_num]}
    ],
    {ok, 200, Values3} = nksip_uac:options(C1, "sip:127.0.0.1", Opts3),
    [{_, CallId3}, {_, From3}, {_, CSeq3}] = Values3,
    ForceLoopOpts4 = [{call_id, CallId3}, {from, From3}, {cseq, CSeq3},
                     {fields, []} | Opts3],
    {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", ForceLoopOpts4),

    % Test bad extension endpoint and proxy
    Opts5 = [{headers, [{"Require", "a,b;c,d"}]}, {fields, [all_headers]}],
    {ok, 420, [{all_headers, Hds5}]} = nksip_uac:options(C1, "sip:127.0.0.1", Opts5),
    % 'a' is supported because of app config
    [<<"b,d">>] = proplists:get_all_values(<<"Unsupported">>, Hds5),
    
    Opts6 = [
        {headers, [{"Proxy-Require", "a,b;c,d"}]}, 
        {route, "<sip:127.0.0.1;lr>"},
        {fields, [all_headers]}
    ],
    {ok, 420, [{all_headers, Hds6}]} = nksip_uac:options(C1, "sip:a@external.com", Opts6),
    [<<"a,b,d">>] = proplists:get_all_values(<<"Unsupported">>, Hds6),

    % Force invalid response
    Opts7 = [{headers, [{"Nksip-Op", "reply-invalid"}]}, {fields, [reason_phrase]}],
    nksip_trace:warning("Next warning about a invalid sipreply is expected"),
    {ok, 500,  [{reason_phrase, <<"Invalid SipApp Response">>}]} = 
        nksip_uac:options(C1, "sip:127.0.0.1", Opts7),
    ok.


auto() ->
    C1 = {uas, client1},
    % Start a new server to test ping and register options
    sipapp_server:stop({uas, server2}),
    ok = sipapp_server:start({uas, server2}, 
                                [registrar, {transport, {udp, {0,0,0,0}, 5080}}]),
    timer:sleep(200),
    Old = nksip_config:get(registrar_min_time),
    nksip_config:put(registrar_min_time, 1),
    {error, invalid_uri} = nksip_sipapp_auto:start_ping(n, ping1, "sip::a", 1, []),
    Ref = make_ref(),
    ok = sipapp_endpoint:add_callback(C1, Ref),
    {ok, true} = nksip_sipapp_auto:start_ping(C1, ping1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 5, []),

    {error, invalid_uri} = nksip_sipapp_auto:start_register(name, reg1, "sip::a", 1, []),
    {ok, true} = nksip_sipapp_auto:start_register(C1, reg1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 1, []),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    nksip_trace:info("Next infos about connection error to port 9999 are expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    {ok, false} = nksip_sipapp_auto:start_register(C1, reg2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_pings(C1)),
    [{reg1, true,_}, {reg2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C1)),
    
    ok = nksip_sipapp_auto:stop_ping(C1, ping2),
    ok = nksip_sipapp_auto:stop_register(C1, reg2),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = sipapp_server:stop({uas, server2}),
    nksip_trace:info("Next info about connection error to port 5080 is expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping3, 
                                            "<sip:127.0.0.1:5080;transport=tcp>", 1, []),
    ok = nksip_sipapp_auto:stop_ping(C1, ping1),
    ok = nksip_sipapp_auto:stop_ping(C1, ping3),
    ok = nksip_sipapp_auto:stop_register(C1, reg1),
    [] = nksip_sipapp_auto:get_pings(C1),
    [] = nksip_sipapp_auto:get_registers(C1),
    nksip_config:put(registrar_min_time, Old),
    ok.

timeout() ->
    C1 = {uas, client1},
    C2 = {uas, client2},
    SipC1 = "<sip:127.0.0.1:5070;transport=tcp>",

    {ok, _Module, Opts, _Pid} = nksip_sipapp_srv:get_opts(C1),
    Opts1 = [{sipapp_timeout, 20}|Opts],
    ok = nksip_sipapp_srv:put_opts(C1, Opts1),

    % Client1 callback module has a 50msecs delay in route()
    {ok, 500, [{reason_phrase, <<"No SipApp Response">>}]} = 
        nksip_uac:options(C2, SipC1, [{fields, [reason_phrase]}]),

    Opts2 = [{timer_t1, 10}, {timer_c, 500}|Opts] -- [{sipapp_timeout, 50}],
    ok = nksip_sipapp_srv:put_opts(C1, Opts2),

    Hds1 = {headers, [{<<"Nk-Sleep">>, 2000}]},
    {ok, 408, [{reason_phrase, <<"No-INVITE Timeout">>}]} = 
        nksip_uac:options(C2, SipC1, [Hds1, {fields, [reason_phrase]}]),

    Hds2 = {headers, [{"Nk-Op", busy}, {"Nk-Sleep", 2000}]},
    {ok, 408, [{reason_phrase, <<"Timer C Timeout">>}]} = 
        nksip_uac:invite(C2, SipC1, [Hds2, {fields, [reason_phrase]}]),
    ok.






