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
-include("../include/nksip.hrl").

-compile([export_all]).


basic_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun running/0}, 
            {timeout, 60, fun transport/0}, 
            {timeout, 60, fun cast_info/0}, 
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
    

transport() ->
    C1 = {basic, client1},
    C2 = {basic, client2},
    Body = base64:encode(crypto:rand_bytes(100)),
    Opts1 = [
        {headers, [{<<"Nksip">>, <<"test1">>}, {<<"Nksip-Op">>, <<"reply-request">>}]}, 
        {contact, "sip:aaa:123, sips:bbb:321"},
        {user_agent, "My SIP"},
        {body, Body},
        {fields, [body]}
    ],
    {ok, 200, [{body, RespBody}]} = nksip_uac:options(C1, "sip:127.0.0.1", Opts1),

    % Req1 is the request as received at the remote party
    Req1 = binary_to_term(base64:decode(RespBody)),
    [<<"My SIP">>] = nksip_sipmsg:header(Req1, <<"User-Agent">>),
    [<<"<sip:aaa:123>">>,<<"<sips:bbb:321>">>] = 
        nksip_sipmsg:header(Req1, <<"Contact">>),
    Body = nksip_sipmsg:field(Req1, body),

    Fields2 = {fields, [parsed_contacts, remote]},
    {ok, 200, Values2} = nksip_uac:options(C1, "<sip:127.0.0.1;transport=tcp>", [Fields2]),

    % Remote has generated a valid Contact (OPTIONS generates a Contact by default)
    [
        {_, [#uri{scheme=sip, port=5060, opts=[{<<"transport">>, <<"tcp">>}]}]},
        {_, {tcp, {127,0,0,1}, 5060}}
    ] = Values2,

    % Remote has generated a SIPS Contact   
    {ok, 200, Values3} = nksip_uac:options(C1, "sips:127.0.0.1", [Fields2]),
    [
        {_, [#uri{scheme=sips, port=5061}]},
        {_, {tls, {127,0,0,1}, 5061}}
    ] = Values3,

    % Send a big body, switching to TCP
    BigBody = base64:encode(crypto:rand_bytes(1000)),
    BigBodyHash = erlang:phash2(BigBody),
    Opts4 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-request">>}]},
        {content_type, <<"nksip/binary">>},
        {body, BigBody},
        {fields, [body]}
    ],
    {ok, 200, Values4} = nksip_uac:options(C2, "sip:127.0.0.1", Opts4),
    [{body, RespBody4}] = Values4,
    Req4 = binary_to_term(base64:decode(RespBody4)),
    BigBodyHash = erlang:phash2(nksip_sipmsg:field(Req4, body)),

    % Check local_host is used to generare local Contact, Route headers are received
    Opts5 = [
        {headers, [{<<"Nksip-Op">>, <<"reply-request">>}]},
        make_contact,
        {local_host, "mihost"},
        {route, [<<"<sip:127.0.0.1;lr>">>, "<sip:aaa;lr>, <sips:bbb:123;lr>"]},
        {fields, [body]}
    ],
    {ok, 200, Values5} = nksip_uac:options(C1, "sip:127.0.0.1", Opts5),
    [{body, RespBody5}] = Values5,
    Req5 = binary_to_term(base64:decode(RespBody5)),
    [
        [#uri{user=(<<"client1">>), domain=(<<"mihost">>), port=5070}],
        [
            #uri{domain=(<<"aaa">>), port=0, opts=[<<"lr">>]},
            #uri{domain=(<<"bbb">>), port=123, opts=[<<"lr">>]}
        ]
    ] = nksip_sipmsg:fields(Req5, [parsed_contacts, parsed_routes]),

    {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", 
                                [{headers, [{<<"Nksip-Op">>, <<"reply-stateless">>}]}]),
    {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", 
                                [{headers, [{<<"Nksip-Op">>, <<"reply-stateful">>}]}]),

    % Cover ip resolution
    case nksip_uac:options(C1, "<sip:sip2sip.info>", []) of
        {ok, 200, []} -> ok;
        {ok, Code, []} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Code]);
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


stun() ->
    {ok, {{0,0,0,0}, 5070}, {{127,0,0,1}, 5070}} = 
        nksip_uac:stun({basic, client1}, "sip:127.0.0.1", []),
    {ok, {{0,0,0,0}, 5060}, {{127,0,0,1}, 5060}} = 
        nksip_uac:stun({basic, server1}, "sip:127.0.0.1:5070", []),
    ok.








