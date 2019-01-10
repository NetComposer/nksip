
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

-module(t01_basic_test).

-include_lib("nklib/include/nklib.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").
-include_lib("nksip/include/nksip_call.hrl").

-compile([export_all, nowarn_export_all]).


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

all() ->
    start(),
    lager:warning("Starting TEST ~p", [?MODULE]),
    timer:sleep(1000),
    running(),
    transport(),
    cast_info(),
    stun(),
    stop().


start() ->
    catch stop(),
    tests_util:start_nksip(),
    %tests_util:log(debug),

    nklib_store:update_timer(200),

    {ok, _} = nksip:start_link(basic_test_server, #{}),

    {ok, _} = nksip:start_link(basic_test_client1, #{
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:basic_test_client1@nksip>",
        sip_listen => "sip://all:5070, sips:all:5071"
        %sip_debug => [nkpacket, call, packet]
    }),

    {ok, _} = nksip:start_link(basic_test_client2, #{
        callback => ?MODULE,
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:basic_test_client2@nksip>"
        %sip_debug => [nkpacket, call, packet]
    }),

    ?debugFmt("Starting ~p", [?MODULE]),
ok.


stop() ->
    ok = nkserver_srv:stop_local_all(),
    timer:sleep(200),
    {error, not_started} = nksip:stop(basic_test_server),
    {error, not_started} = nksip:stop(basic_test_client1),
    {error, not_started} = nksip:stop(basic_test_client2),
    ok.


running() ->
    {error, {already_started, _}} = nksip:start_link(basic_test_server, #{}),
    {error, {already_started, _}} = nksip:start_link(basic_test_client1, #{}),
    {error, {already_started, _}} = nksip:start_link(basic_test_client2, #{}),
    [{basic_test_client1, _}, {basic_test_client2, _}, {basic_test_server, _}] =
        lists:sort(nkserver_srv:get_local_all(<<"Sip">>)),

    {error,{service_config_error,{name,{invalid_transport,<<"other">>}}}} =
        nksip:start_link(name, #{sip_listen => "<sip:all;transport=other>"}),
    {error, {service_config_error,{name, {syntax_error,<<"sip_registrar_min_time">>}}}} =
        nksip:start_link(name, #{plugins => [nksip_registrar], sip_registrar_min_time => -1}),
    {error, {plugin_unknown, invalid}} =
        nksip:start_link(name, #{plugins => [nksip_registrar, invalid]}),
    ok.



transport() ->
    Body = base64:encode(crypto:strong_rand_bytes(100)),
    Opts1 = [
        {add, "x-nksip", "test1"},
        {add, "x-nk-op", "reply-request"},
        {contact, "sip:aaa:123, sips:bbb:321"},
        {add, user_agent, "My SIP"},
        {body, Body},
        {get_meta, [body]}
    ],
    {ok, 200, [{body, RespBody}]} = nksip_uac:options(basic_test_client1, "<sip:127.0.0.1;transport=tcp>", Opts1),

    % Req1 is the request as received at the remote party
    Req1 = binary_to_term(base64:decode(RespBody)),
    [<<"My SIP">>] = nksip_sipmsg:header(<<"user-agent">>, Req1),
    [<<"<sip:aaa:123>">>,<<"<sips:bbb:321>">>] = nksip_sipmsg:header(<<"contact">>, Req1),
    Body = nksip_sipmsg:get_meta(body, Req1),

    % Remote has generated a valid Contact (OPTIONS generates a Contact by default)
    Fields2 = {get_meta, [contacts, remote]},
    {ok, 200, Values2} = nksip_uac:options(basic_test_client1, "<sip:127.0.0.1;transport=tcp>", [Fields2]),

    [
        {_, [#uri{scheme=sip, port=5060, opts=[{<<"transport">>, <<"tcp">>}]}]},
        {_, {tcp, {127,0,0,1}, 5060, <<>>}}
    ] = Values2,

    % Remote has generated a SIPS Contact
    {ok, 200, Values3} = nksip_uac:options(basic_test_client1, "sips:127.0.0.1", [Fields2]),
    [
        {_, [#uri{scheme=sips, port=5061}]},
        {_, {tls, {127,0,0,1}, 5061, <<>>}}
    ] = Values3,

    % Send a big body, switching to TCP
    BigBody = list_to_binary([[integer_to_list(L), 32] || L <- lists:seq(1, 5000)]),
    BigBodyHash = erlang:phash2(BigBody),
    Opts4 = [
        {add, "x-nk-op", "reply-request"},
        {content_type, "nksip/binary"},
        {body, BigBody},
        {get_meta, [body, remote]}
    ],
    {ok, 200, Values4} = nksip_uac:options(basic_test_client2, "sip:127.0.0.1", Opts4),
    [{body, RespBody4}, {remote, {tcp, _, _, _}}] = Values4,
    Req4 = binary_to_term(base64:decode(RespBody4)),
    BigBodyHash = erlang:phash2(nksip_sipmsg:get_meta(body, Req4)),

    % Check local_host is used to generate local Contact, Route headers are received
    Opts5 = [
        {add, "x-nk-op", "reply-request"},
        contact,
        {local_host, "mihost"},
        {route, [<<"<sip:127.0.0.1;lr>">>, "<sip:aaa;lr>, <sips:bbb:123;lr>"]},
        {get_meta, [body]}
    ],
    {ok, 200, Values5} = nksip_uac:options(basic_test_client1, "sip:127.0.0.1", Opts5),
    [{body, RespBody5}] = Values5,
    Req5 = binary_to_term(base64:decode(RespBody5)),
    [#uri{user=(<<"basic_test_client1">>), domain=(<<"mihost">>), port=5070}] =
        nksip_sipmsg:get_meta(contacts, Req5),
    [
        #uri{domain=(<<"127.0.0.1">>), port=0, opts=[<<"lr">>]},
        #uri{domain=(<<"aaa">>), port=0, opts=[<<"lr">>]},
        #uri{domain=(<<"bbb">>), port=123, opts=[<<"lr">>]}
    ] =
       nksip_sipmsg:get_meta(routes, Req5),

    {ok, 200, []} = nksip_uac:options(basic_test_client1, "sip:127.0.0.1",
                                [{add, "x-nk-op", "reply-stateless"}]),
    {ok, 200, []} = nksip_uac:options(basic_test_client1, "sip:127.0.0.1",
                                [{add, "x-nk-op", "reply-stateful"}]),

    % Cover ip resolution
    case nksip_uac:options(basic_test_client1, "<sip:sip2sip.info>", []) of
        {ok, 200, []} -> ok;
        {ok, Code, []} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Code]);
        {error, Error} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Error])
    end,
    ok.


cast_info() ->
    {ok, Domains} = gen_server:call(basic_test_server, get_domains),
    ok = gen_server:call(basic_test_server, {set_domains, [<<"test">>]}),
    {ok, [<<"test">>]} = gen_server:call(basic_test_server, get_domains),
    ok = gen_server:call(basic_test_server, {set_domains, Domains}),
    {ok, Domains} = gen_server:call(basic_test_server, get_domains),
    Ref = make_ref(),
    Self = self(),
    gen_server:cast(basic_test_server, {cast_test, Ref, Self}),
    basic_test_server ! {info_test, Ref, Self},
    ok = tests_util:wait(Ref, [{cast_test, basic_test_server}, {info_test, basic_test_server}]).


stun() ->
    {ok, {{0,0,0,0}, 5070}, {{127,0,0,1}, 5070}} = 
        nksip_uac:stun(basic_test_client1, "sip:127.0.0.1", []),
    {ok, {{0,0,0,0}, 5060}, {{127,0,0,1}, 5060}} = 
        nksip_uac:stun(basic_test_server, "sip:127.0.0.1:5070", []),
    ok.
















