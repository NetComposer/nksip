%% -------------------------------------------------------------------
%%
%% basic_test: Basic Test Suite
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

-module(basic_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).


basic_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun running/0}, 
            {timeout, 60, fun transport/0}, 
            {timeout, 60, fun cast_info/0}, 
            {timeout, 60, fun uas/0}, 
            {timeout, 60, fun auto/0}, 
            {timeout, 60, fun stun/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),
    nksip_config:put(nksip_store_timer, 200),
    nksip_config:put(nksip_sipapp_timer, 10000),

    ok = sipapp_server:start({basic, server1}, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        registrar,
        {listeners, 10},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({basic, client1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({basic, client2}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop_all(),
    error = sipapp_server:stop({basic, server1}),
    error = sipapp_endpoint:stop({basic, client1}),
    error = sipapp_endpoint:stop({basic, client2}),
    ok.


running() ->
    {error, already_started} = sipapp_server:start({basic, server1}, []),
    {error, already_started} = sipapp_endpoint:start({basic, client1}, []),
    {error, already_started} = sipapp_endpoint:start({basic, client2}, []),
    [{basic, client1}, {basic, client2}, {basic, server1}] = 
        lists:sort(nksip:get_all()),

    {error, error1} = 
        sipapp_endpoint:start(error1, [{transport, {udp, {0,0,0,0}, 5090}}]),
    timer:sleep(100),
    {ok, P1} = gen_udp:open(5090, [{reuseaddr, true}, {ip, {0,0,0,0}}]),
    ok = gen_udp:close(P1),
    
    {error, invalid_transport} = 
                    sipapp_endpoint:start(name, [{transport, {other, {0,0,0,0}, 0}}]),
    {error, invalid_transport} = 
                    sipapp_endpoint:start(name, [{transport, {udp, {1,2,3}, 0}}]),
    {error, invalid_register} = sipapp_endpoint:start(name, [{register, "sip::a"}]),

    ok.
    

uac() ->
    C1 = {basic, client1},
    SipC2 = "sip:127.0.0.1:5070",

    {error, invalid_uri} = nksip_uac:options(C1, "sip::a", []),
    {error, invalid_from} = nksip_uac:options(C1, SipC2, [{from, "<>"}]),
    {error, invalid_to} = nksip_uac:options(C1, SipC2, [{to, "<>"}]),
    {error, invalid_route} = nksip_uac:options(C1, SipC2, [{route, "<>"}]),
    {error, invalid_contact} = nksip_uac:options(C1, SipC2, [{contact, "<>"}]),
    {error, invalid_cseq} = nksip_uac:options(C1, SipC2, [{cseq, -1}]),
    nksip_trace:error("Next error about 'unknown_siapp' is expected"),
    {error, unknown_sipapp} = nksip_uac:options(none, SipC2, []),
    nksip_trace:error("Next error about 'too_many_calls' is expected"),
    nksip_counters:incr(nksip_calls, 1000000000),
    {error, too_many_calls} = nksip_uac:options(C1, SipC2, []),
    nksip_counters:incr(nksip_calls, -1000000000),

    Self = self(),
    Ref = make_ref(),
    Fun = fun(Reply) -> Self ! {Ref, Reply} end,
    CB = {callback, Fun},
    Hds = {headers, [{"Nk-Op", busy}, {"Nk-Prov", "true"}]},

    nksip_trace:info("Next two infos about connection error to port 50600 are expected"),
    {ok, 503, _, _} =
        nksip_uac:options(C1, "sip:127.0.0.1:50600;transport=tcp", []),
    % Async, error
    {async, ReqId11} = nksip_uac:options(C1, "sip:127.0.0.1:50600;transport=tcp", 
                                        [async, CB]),
    receive 
        {Ref, {req_id, ReqId11}} -> ok 
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {ok, 503, _, _}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync
    {ok, 200, ReqId1, DlgId1} = nksip_uac:options(C1, SipC2, []),
    200 = nksip_response:code(ReqId1),
    error = nksip_dialog:field(DlgId1, status),
    {error, unknown_dialog} = nksip_uac:reoptions(DlgId1, []),

    % Sync, full_response
    {resp, #sipmsg{class=resp}} = nksip_uac:options(C1, SipC2, [full_response]),

    % Sync, callback for request
    {ok, 200, RespId3, _} = nksip_uac:options(C1, SipC2, [CB]),
    CallId3 = nksip_response:field(RespId3, call_id),
    receive 
        {Ref, {req_id, ReqId3}} -> CallId3 = nksip_request:field(ReqId3, call_id)
        after 500 -> error(uac) 
    end,

    % Sync, callback for request and provisional response
    {ok, 486, RespId4, DlgId4} = nksip_uac:invite(C1, SipC2, [Hds, CB]),
    CallId4 = nksip_response:field(RespId4, call_id),
    receive 
        {Ref, {req_id, ReqId4}} -> 
            CallId4 = nksip_request:field(ReqId4, call_id)
        after 500 -> 
            error(uac) 
    end,
    receive 
        {Ref, {ok, 180, RespId4_180, DlgId4}} -> 
            CallId4 = nksip_response:field(RespId4_180, call_id)
        after 500 -> 
            error(uac) 
    end,

    % Sync, callback for request and provisional response, full request, full_response
    {resp, #sipmsg{class=resp, response=486, call_id=CallId5}=Resp5} = 
        nksip_uac:invite(C1, SipC2, [Hds, CB, full_request, full_response]),
    DialogId5 = nksip_dialog:id(Resp5),
    receive 
        {Ref, {req, #sipmsg{class=req, call_id=CallId5}}} -> ok
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {resp, #sipmsg{class=resp, response=180, call_id=CallId5}=Resp5_180}} ->
            DialogId5 = nksip_dialog:id(Resp5_180)
        after 500 -> 
            error(uac) 
    end,


    % Async
    {async, ReqId10} = nksip_uac:invite(C1, SipC2, [async, CB, Hds]),
    CallId10 = nksip_request:field(ReqId10, call_id),
    receive 
        {Ref, {req_id, ReqId10}} -> CallId10 = nksip_request:field(ReqId10, call_id)
        after 500 -> error(uac) 
    end,
    Dlg10 = receive 
        {Ref, {ok, 180, RespId10_180, D10_180}} -> 
            [180, CallId10] = nksip_response:fields(RespId10_180, [code, call_id]),
            D10_180
        after 500 -> 
            error(uac) 
    end,
    Dlg10 = receive 
        {Ref, {ok, 486, RespId10_486, D10_486}} -> 
            [486, CallId10] = nksip_response:fields(RespId10_486, [code, call_id]),
            D10_486
        after 500 -> 
            error(uac) 
    end,

    ok.



transport() ->
    C1 = {basic, client1},
    C2 = {basic, client2},
    Body = base64:encode(crypto:rand_bytes(100)),
    Opts1 = [
        {headers, [{<<"Nksip">>, <<"test1">>}, {<<"Nksip-Op">>, <<"reply-request">>}]}, 
        {contact, "sip:aaa:123, sips:bbb:321"},
        {user_agent, "My SIP"},
        {body, Body},
        full_response
    ],
    {resp, Resp1} = nksip_uac:options(C1, "sip:127.0.0.1", Opts1),
    200 = nksip_response:code(Resp1),
    % Req1 is the request as received at the remote party

    Req1 = binary_to_term(base64:decode(nksip_response:body(Resp1))),
    [<<"My SIP">>] = nksip_request:header(Req1, <<"User-Agent">>),
    [<<"<sip:aaa:123>">>,<<"<sips:bbb:321>">>] = 
        nksip_request:header(Req1,  <<"Contact">>),
    Body = nksip_request:body(Req1),

    {resp, #sipmsg{}=Resp2} = 
        nksip_uac:options(C1, "sip:127.0.0.1;transport=tcp", [full_response]),
    200 = nksip_response:code(Resp2),

    % Remote has generated a valid Contact (OPTIONS generates a Contact by default)
    [
        [#uri{scheme=sip, port=5060, opts=[{transport, <<"tcp">>}]}],
        {tcp, {127,0,0,1}, 5060}
    ] = nksip_response:fields(Resp2, [parsed_contacts, remote]),

    % Remote has generated a SIPS Contact   
    {resp, Resp3} = nksip_uac:options(C1, "sips:127.0.0.1", [full_response]),
    200 = nksip_response:code(Resp3),
    [
        [#uri{scheme=sips, port=5061}],
        {tls, {127,0,0,1}, 5061}
    ] = nksip_response:fields(Resp3, [parsed_contacts, remote]),

    % Send a big body, switching to TCP
    BigBody = base64:encode(crypto:rand_bytes(1000)),
    BigBodyHash = erlang:phash2(BigBody),
    Opts4 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-request">>}]},
        {content_type, <<"nksip/binary">>},
        {body, BigBody},
        full_response
    ],
    {resp, Resp4} = nksip_uac:options(C2, "sip:127.0.0.1", Opts4),
    200 = nksip_response:code(Resp4),
    Req4 = binary_to_term(base64:decode(nksip_response:body(Resp4))),
    BigBodyHash = erlang:phash2(nksip_request:body(Req4)),

    % Check local_host is used to generare local Contact, Route headers are received
    Opts5 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-request">>}]},
        make_contact,
        {local_host, "mihost"},
        {route, [<<"sip:127.0.0.1;lr">>, "sip:aaa;lr, sips:bbb:123;lr"]},
        full_response
    ],
    {resp, Resp5} = nksip_uac:options(C1, "sip:127.0.0.1", Opts5),
    200 = nksip_response:code(Resp5),
    Req5 = binary_to_term(base64:decode(nksip_response:body(Resp5))),
    [
        [#uri{user=(<<"client1">>), domain=(<<"mihost">>), port=5070}],
        [
            #uri{domain=(<<"aaa">>), port=0, opts=[lr]},
            #uri{domain=(<<"bbb">>), port=123, opts=[lr]}
        ]
    ] = nksip_request:fields(Req5, [parsed_contacts, parsed_routes]),

    {ok, 200, _,  _} = nksip_uac:options(C1, "sip:127.0.0.1", 
                                [{headers, [{<<"Nksip-Op">>, <<"reply-stateless">>}]}]),
    {ok, 200, _, _} = nksip_uac:options(C1, "sip:127.0.0.1", 
                                [{headers, [{<<"Nksip-Op">>, <<"reply-stateful">>}]}]),

    % Cover ip resolution
    case nksip_uac:options(C1, "sip:sip2sip.info;transport=tcp", []) of
        {ok, 200, _,  _} -> ok;
        {ok, Code, _,  _} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Code]);
        {error, Error} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Error])
    end,
    ok.


cast_info() ->
    % Direct calls to SipApp's core process
    Server1 = {basic, server1},
    Pid = nksip:get_pid(Server1),
    true = is_pid(Pid),
    not_found = nksip:get_pid(other),

    {ok, Server1, Domains} = sipapp_server:get_domains(Server1),
    {ok, Server1} = sipapp_server:set_domains(Server1, [<<"test">>]),
    {ok, Server1, [<<"test">>]} = sipapp_server:get_domains(Server1),
    {ok, Server1} = sipapp_server:set_domains(Server1, Domains),
    {ok, Server1, Domains} = sipapp_server:get_domains(Server1),
    Ref = make_ref(),
    Self = self(),
    nksip:cast(Server1, {cast_test, Ref, Self}),
    Pid ! {info_test, Ref, Self},
    ok = tests_util:wait(Ref, [{cast_test, Server1}, {info_test, Server1}]).


uas() ->
    C1 = {basic, client1},
    
    % Test loop detection
    Opts1 = [{headers, [{<<"Nksip-Op">>, <<"reply-stateful">>}]}, full_response],
    {resp, Resp1} = nksip_uac:options(C1, "sip:127.0.0.1", Opts1),
    200 = nksip_response:code(Resp1),
    [CallId1, From1, CSeq1] = nksip_response:fields(Resp1, [call_id, from, cseq_num]),
    ForceLoopOpts1 = [{call_id, CallId1}, {from, From1}, {cseq, CSeq1} | Opts1],
    {resp, Resp2} = nksip_uac:options(C1, "sip:127.0.0.1", ForceLoopOpts1),
    482 = nksip_response:code(Resp2),
    <<"Loop Detected">> = nksip_response:reason(Resp2),

    % Stateless proxies do not detect loops
    Opts3 = [{headers, [{<<"Nksip-Op">>, <<"reply-stateless">>}]}, full_response],
    {resp, Resp3} = nksip_uac:options(C1, "sip:127.0.0.1", Opts3),
    200 = nksip_response:code(Resp3),
    [CallId3, From3, CSeq3] = nksip_response:fields(Resp3, [call_id, from, cseq_num]),
    ForceLoopOpts4 = [{call_id, CallId3}, {from, From3}, {cseq, CSeq3} | Opts3],
    {resp, Resp4} = nksip_uac:options(C1, "sip:127.0.0.1", ForceLoopOpts4),
    200 = nksip_response:code(Resp4),

    % Test bad extension endpoint and proxy
    Opts5 = [{headers, [{"Require", "a,b;c,d"}]}, full_response],
    {resp, Resp5} = nksip_uac:options(C1, "sip:127.0.0.1", Opts5),
    420 = nksip_response:code(Resp5),
    [<<"a,b,d">>] = nksip_response:header(Resp5, <<"Unsupported">>),
    Opts6 = [
        {headers, [{"Proxy-Require", "a,b;c,d"}]}, 
        {route, "<sip:127.0.0.1;lr>"},
        full_response
    ],
    {resp, Resp6} = nksip_uac:options(C1, "sip:a@external.com", Opts6),
    420 = nksip_response:code(Resp6),
    [<<"a,b,d">>] = nksip_response:header(Resp6, <<"Unsupported">>),

    % Force invalid response
    Opts7 = [{headers, [{"Nksip-Op", "reply-invalid"}]}, full_response],
    tests_util:log(error),
    {resp, Resp7} = nksip_uac:options(C1, "sip:127.0.0.1", Opts7),
    tests_util:log(),
    500 = nksip_response:code(Resp7),
    <<"Invalid Response">> = nksip_response:reason(Resp7),
    ok.


auto() ->
    C1 = {basic, client1},
    % Start a new server to test ping and register options
    sipapp_server:stop({basic, server2}),
    ok = sipapp_server:start({basic, server2}, 
                                [registrar, {transport, {udp, {0,0,0,0}, 5080}}]),
    timer:sleep(200),
    Old = nksip_config:get(registrar_min_time),
    nksip_config:put(registrar_min_time, 1),
    {error, invalid_uri} = nksip_sipapp_auto:start_ping(n, ping1, "sip::a", 1, []),
    Ref = make_ref(),
    ok = sipapp_endpoint:add_callback(C1, Ref),
    {ok, true} = nksip_sipapp_auto:start_ping(C1, ping1, 
                                "sip:127.0.0.1:5080;transport=tcp", 5, []),

    {error, invalid_uri} = nksip_sipapp_auto:start_register(name, reg1, "sip::a", 1, []),
    {ok, true} = nksip_sipapp_auto:start_register(C1, reg1, 
                                "sip:127.0.0.1:5080;transport=tcp", 1, []),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    nksip_trace:info("Next infos about connection error to port 9999 are expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping2, 
                                            "sip:127.0.0.1:9999;transport=tcp", 1, []),
    {ok, false} = nksip_sipapp_auto:start_register(C1, reg2, 
                                            "sip:127.0.0.1:9999;transport=tcp", 1, []),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_pings(C1)),
    [{reg1, true,_}, {reg2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C1)),
    
    ok = nksip_sipapp_auto:stop_ping(C1, ping2),
    ok = nksip_sipapp_auto:stop_register(C1, reg2),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(C1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(C1),

    ok = sipapp_server:stop({basic, server2}),
    nksip_trace:info("Next info about connection error to port 5080 is expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(C1, ping3, 
                                            "sip:127.0.0.1:5080;transport=tcp", 1, []),
    ok = nksip_sipapp_auto:stop_ping(C1, ping1),
    ok = nksip_sipapp_auto:stop_ping(C1, ping3),
    ok = nksip_sipapp_auto:stop_register(C1, reg1),
    [] = nksip_sipapp_auto:get_pings(C1),
    [] = nksip_sipapp_auto:get_registers(C1),
    nksip_config:put(registrar_min_time, Old),
    ok.


stun() ->
    {ok, {{0,0,0,0}, 5070}, {{127,0,0,1}, 5070}} = 
        nksip_uac:stun({basic, client1}, "sip:127.0.0.1", []),
    {ok, {{0,0,0,0}, 5060}, {{127,0,0,1}, 5060}} = 
        nksip_uac:stun({basic, server1}, "sip:127.0.0.1:5070", []),
    ok.








