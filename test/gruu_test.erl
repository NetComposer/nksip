%% -------------------------------------------------------------------
%%
%% gruu_test: Gruu (RFC5627) Test Suite
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

-module(gruu_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

gruu_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun register/0, 
            fun temp_gruu/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({gruu, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}
    ]),

    ok = sipapp_endpoint:start({gruu, ua1}, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}
    ]),

    ok = sipapp_endpoint:start({gruu, ua2}, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5080}},
        {transport, {tls, {0,0,0,0}, 5081}}
    ]),

    nksip_registrar:internal_clear(),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = sipapp_server:stop({gruu, server1}),
    ok = sipapp_endpoint:stop({gruu, ua1}),
    ok = sipapp_endpoint:stop({gruu, ua2}).



register() ->
    C1 = {gruu, ua1},
    C2 = {gruu, ua2},
    S1 = {gruu, server1},
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),


    {ok, 200, [{_, [PC1]}]} =
        nksip_uac:register(C1, "sip:127.0.0.1", 
                               [make_contact, {fields, [parsed_contacts]}]),
    #uri{
        user = <<"client1">>, 
        domain = <<"127.0.0.1">>,
        port = 5070,
        ext_opts = EOpts1
    } = PC1,
    Inst1 = list_to_binary(
                nksip_lib:unquote(nksip_lib:get_value(<<"+sip.instance">>, EOpts1))),
    [Pub1] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"pub-gruu">>, EOpts1))),
    [Tmp1] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"temp-gruu">>, EOpts1))),
    {ok, Inst1} = nksip_sipapp_srv:get_uuid(C1),
    #uri{user = <<"client1">>, domain = <<"nksip">>, port = 0} = Pub1,
    #uri{domain = <<"nksip">>, port=0} = Tmp1,

    Pub1 = nksip_sipapp_srv:get_gruu_pub(C1),
    Tmp1 = nksip_sipapp_srv:get_gruu_temp(C1),

    {ok, 200, [{_, [PC2, PC1]}]} =
        nksip_uac:register(C2, "sip:127.0.0.1", 
                               [make_contact, {fields, [parsed_contacts]}]),
    #uri{
        user = <<"client1">>, 
        domain = <<"127.0.0.1">>,
        port = 5080,
        ext_opts = EOpts2
    } = PC2,
    Inst2 = list_to_binary(
                nksip_lib:unquote(nksip_lib:get_value(<<"+sip.instance">>, EOpts2))),
    [Pub2] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"pub-gruu">>, EOpts2))),
    [Tmp2] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"temp-gruu">>, EOpts2))),
    {ok, Inst2} = nksip_sipapp_srv:get_uuid(C2),
    #uri{user = <<"client1">>, domain = <<"nksip">>, port = 0} = Pub2,
    #uri{domain = <<"nksip">>, port=0} = Tmp2,

    Pub2 = nksip_sipapp_srv:get_gruu_pub(C2),
    Tmp2 = nksip_sipapp_srv:get_gruu_temp(C2),


    % Now we have two contacts stored for this AOR
    [PC2a, PC1a] = nksip_registrar:find(S1, sip, <<"client1">>, <<"nksip">>),

    true = PC2#uri{ext_opts=[]} == PC2a#uri{headers=[]},
    true = PC1#uri{ext_opts=[]} == PC1a#uri{headers=[]},

    % But we use the Public or Private GRUUs, only one of each
    [PC1a] = nksip_registrar:find(S1, Pub1),
    [PC2a] = nksip_registrar:find(S1, Pub2),
    [PC1a] = nksip_registrar:find(S1, Tmp1),
    [PC2a] = nksip_registrar:find(S1, Tmp2),

    {ok, 403, []} = nksip_uac:register(C1, "sip:127.0.0.1", [{contact, Pub1}]),
    {ok, 403, []} = nksip_uac:register(C1, "sip:127.0.0.1", [{contact, Tmp1}]),
    ok.



temp_gruu() ->
    C1 = {gruu, ua1},
    S1 = {gruu, server1},
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    
    {ok, 200, [{_, CallId}, {_, CSeq}, {_, [#uri{ext_opts=EOpts1}]}]} =
        nksip_uac:register(C1, "sip:127.0.0.1", 
                               [make_contact, 
                                {fields, [call_id, cseq_num, parsed_contacts]}]),
    [Tmp1] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"temp-gruu">>, EOpts1))),

    % We send a new request with the same Call-ID, NkSIP generates a new valid 
    % and different temporary GRUU, both are valid
    {ok, 200, [{_, [#uri{ext_opts=EOpts2}]}]} =
        nksip_uac:register(C1, "sip:127.0.0.1", 
                               [make_contact, {call_id, CallId}, {cseq, CSeq+1}, 
                                {fields, [parsed_contacts]}]),
    [Tmp2] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"temp-gruu">>, EOpts2))),

    true = Tmp1 /= Tmp2,
    [#uri{port=5070}] = nksip_registrar:find(S1, Tmp1),
    [#uri{port=5070}] = nksip_registrar:find(S1, Tmp2),

    % Now we change the Call-ID, both are invalidated and only the new one is valid
    {ok, 200, [{_, [#uri{ext_opts=EOpts3}]}]} =
        nksip_uac:register(C1, "sip:127.0.0.1", 
                               [make_contact, {fields, [parsed_contacts]}]),
    [Tmp3] = nksip_parse:ruris(nksip_lib:unquote(
                            nksip_lib:get_value(<<"temp-gruu">>, EOpts3))),

    true = Tmp1 /= Tmp3 andalso Tmp2 /= Tmp3,
    [] = nksip_registrar:find(S1, Tmp1),
    [] = nksip_registrar:find(S1, Tmp2),
    [#uri{port=5070}] = nksip_registrar:find(S1, Tmp3),

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(S1, Tmp3),
    ok.







