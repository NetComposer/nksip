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
-include_lib("nklib/include/nklib.hrl").

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

    {ok, _} = nksip:start(server1, [
        {callback, ?MODULE},
        {from, "sip:server1@nksip"},
        {plugins, [nksip_registrar, nksip_gruu]},
        {local_host, "localhost"},
        {transports, "sip:all:5060, <sip:all:5061;transport=tls>"}
    ]),

    {ok, _} = nksip:start(ua1, [
        {callback, ?MODULE},
        {from, "sip:client1@nksip"},
        {plugins, [nksip_gruu]},
        {local_host, "127.0.0.1"},
        {transports, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]}
    ]),

    {ok, _} = nksip:start(ua2, [
        {callback, ?MODULE},
        {from, "sip:client1@nksip"},
        {plugins, [nksip_gruu]},
        {local_host, "127.0.0.1"},
        {transports, "<sip:all:5080>,<sip:all:5081;transport=tls>"}
    ]),

    nksip_registrar_util:clear(),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2).



register() ->
    {ok, 200, []} = nksip_uac:register(ua1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, [{_, [PC1]}]} =
        nksip_uac:register(ua1, "sip:127.0.0.1", [contact, {meta, [contacts]}]),

    #uri{
        user = <<"client1">>, 
        domain = <<"127.0.0.1">>,
        port = 5070,
        ext_opts = EOpts1
    } = PC1,
    Inst1 = list_to_binary(
                nklib_util:unquote(nklib_util:get_value(<<"+sip.instance">>, EOpts1))),
    [Pub1] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"pub-gruu">>, EOpts1))),
    [Tmp1] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"temp-gruu">>, EOpts1))),
    Inst1 = nksip:get_uuid(ua1),
    #uri{user = <<"client1">>, domain = <<"nksip">>, port = 0} = Pub1,
    #uri{domain = <<"nksip">>, port=0} = Tmp1,
    {ok, Pub1} = nksip_gruu:get_gruu_pub(ua1),
    {ok, Tmp1} = nksip_gruu:get_gruu_temp(ua1),

    % Now we register a second UA with the same AOR
    {ok, 200, [{_, [PC2, PC1]}]} =
        nksip_uac:register(ua2, "sip:127.0.0.1", [contact, {meta, [contacts]}]),
    #uri{
        user = <<"client1">>, 
        domain = <<"127.0.0.1">>,
        port = 5080,
        ext_opts = EOpts2
    } = PC2,

    Inst2 = list_to_binary(
                nklib_util:unquote(nklib_util:get_value(<<"+sip.instance">>, EOpts2))),
    [Pub2] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"pub-gruu">>, EOpts2))),
    [Tmp2] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"temp-gruu">>, EOpts2))),
    Inst2 = nksip:get_uuid(ua2),
    #uri{user = <<"client1">>, domain = <<"nksip">>, port = 0} = Pub2,
    #uri{domain = <<"nksip">>, port=0} = Tmp2,
    {ok, Pub2} = nksip_gruu:get_gruu_pub(ua2),
    {ok, Tmp2} = nksip_gruu:get_gruu_temp(ua2),


    % Now we have two contacts stored for this AOR
    [PC2, PC1] = nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    % true = PC2#uri{ext_opts=[]} == PC2a#uri{headers=[]},
    % true = PC1#uri{ext_opts=[]} == PC1a#uri{headers=[]},

    % But we use the Public or Private GRUUs, only one of each
    [PC1a] = nksip_gruu:registrar_find(server1, Pub1),
    [PC2a] = nksip_gruu:registrar_find(server1, Pub2),
    [PC1a] = nksip_gruu:registrar_find(server1, Tmp1),
    [PC2a] = nksip_gruu:registrar_find(server1, Tmp2),

    {ok, 403, []} = nksip_uac:register(ua1, "sip:127.0.0.1", [{contact, Pub1}]),
    {ok, 403, []} = nksip_uac:register(ua1, "sip:127.0.0.1", [{contact, Tmp1}]),
    ok.


temp_gruu() ->   
    {ok, 200, []} = nksip_uac:register(ua1, "sip:127.0.0.1", [unregister_all]),
    
    {ok, 200, [{_, CallId}, {_, CSeq}, {_, [#uri{ext_opts=EOpts1}]}]} =
        nksip_uac:register(ua1, "sip:127.0.0.1", 
                           [contact, {meta, [call_id, cseq_num, contacts]}]),
    [Tmp1] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"temp-gruu">>, EOpts1))),

    % We send a new request with the same Call-ID, NkSIP generates a new valid 
    % and different temporary GRUU, both are valid
    {ok, 200, [{_, [#uri{ext_opts=EOpts2}]}]} =
        nksip_uac:register(ua1, "sip:127.0.0.1", 
                               [contact, {call_id, CallId}, {cseq_num, CSeq+1}, 
                                {meta, [contacts]}]),
    [Tmp2] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"temp-gruu">>, EOpts2))),

    true = Tmp1 /= Tmp2,
    [#uri{port=5070}] = nksip_gruu:registrar_find(server1, Tmp1),
    [#uri{port=5070}] = nksip_gruu:registrar_find(server1, Tmp2),

    % Now we change the Call-ID, both are invalidated and only the new one is valid
    {ok, 200, [{_, [#uri{ext_opts=EOpts3}]}]} =
        nksip_uac:register(ua1, "sip:127.0.0.1", [contact, {meta, [contacts]}]),
    [Tmp3] = nksip_parse:ruris(nklib_util:unquote(
                               nklib_util:get_value(<<"temp-gruu">>, EOpts3))),

    true = Tmp1 /= Tmp3 andalso Tmp2 /= Tmp3,
    [] = nksip_gruu:registrar_find(server1, Tmp1),
    [] = nksip_gruu:registrar_find(server1, Tmp2),
    [#uri{port=5070}] = nksip_gruu:registrar_find(server1, Tmp3),

    {ok, 200, []} = nksip_uac:register(ua1, "sip:127.0.0.1", [unregister_all]),
    [] = nksip_gruu:registrar_find(server1, Tmp3),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%

%% (not necessary, using all defaults in nksip_sipapp)

