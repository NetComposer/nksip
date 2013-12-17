%% -------------------------------------------------------------------
%%
%% register_test: Register Test Suite
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

-module(register_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

register_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun register1/0, 
            fun register2/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({basic, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = sipapp_endpoint:start({basic, client1}, [
        {from, "sip:client1@nksip"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({basic, client2}, [
        {from, "sip:client2@nksip"}]),

    nksip_config:put(registrar_min_time, 60),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = sipapp_server:stop({basic, server1}),
    ok = sipapp_endpoint:stop({basic, client1}),
    ok = sipapp_endpoint:stop({basic, client2}).


register1() ->
    Min = nksip_config:get(registrar_min_time),
    MinB = nksip_lib:to_binary(Min),
    Max = nksip_config:get(registrar_max_time),
    MaxB = nksip_lib:to_binary(Max),
    Def = nksip_config:get(registrar_default_time),
    DefB = nksip_lib:to_binary(Def),
    Client1 = {basic, client1},
    Client2 = {basic, client2},
    Server1 = {basic, server1},

    % Method not allowed
    {ok, 405, []} = nksip_uac:register(Client2, "sip:127.0.0.1:5070", []),

    {ok, 200, Values1} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                        [unregister_all, {fields, [<<"Contact">>]}]),
    [{<<"Contact">>, []}] = Values1,
    [] = nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),
    
    Ref = make_ref(),
    Self = self(),
    RespFun = fun(Reply) -> Self ! {Ref, Reply} end,
    {async, _} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                [async, {callback, RespFun}, make_contact, get_request,
                                 {fields, [<<"Contact">>]}]),
    [CallId, CSeq] = receive 
        {Ref, {req, Req2}} -> nksip_sipmsg:fields(Req2, [call_id, cseq_num])
        after 2000 -> error(register1)
    end,
    Contact2 = receive 
        {Ref, {ok, 200, [{<<"Contact">>, [C2]}]}} -> C2
        after 2000 -> error(register1) 
    end,

    Name = <<"client1">>,
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{<<"expires">>, DefB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),
    MakeContact = fun(Exp) ->
        list_to_binary([
            "<sip:", Name, "@", Domain, ":", nksip_lib:to_binary(Port),
            ">;expires=", Exp])
    end,
    Contact2 = MakeContact(DefB),

    {ok, 400, Values3} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq}, make_contact,
                                     {fields, [reason_phrase]}]),
    [{reason_phrase, <<"Rejected Old CSeq">>}] = Values3,

    {ok, 200, []} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq+1}, make_contact]),

    {ok, 400, []} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq+1}, 
                                     unregister_all]),
    Opts3 = [{expires, Min-1}, make_contact, {fields, [<<"Min-Expires">>]}],
    {ok, 423, Values4} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts3),
    [{_, [MinB]}] = Values4,
    
    Opts4 = [{expires, Max+1}, make_contact, {fields, [<<"Contact">>]}],
    {ok, 200, Values5} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts4),
    [{_, [Contact5]}] = Values5,
    Contact5 = MakeContact(MaxB),
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{<<"expires">>, MaxB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),

    Opts5 = [{expires, Min}, make_contact, {fields, [<<"Contact">>]}],
    ExpB = nksip_lib:to_binary(Min),
    {ok, 200, Values6} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts5),
    [{_, [Contact6]}] = Values6,
    Contact6 = MakeContact(ExpB),
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{<<"expires">>, ExpB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),

    Reg1 = {{sip,<<"client1">>,<<"nksip">>},
        [{Server1, #uri{user = <<"client1">>, domain=Domain, port=Port, 
        ext_opts=[{<<"expires">>, ExpB}]}, Min, 1.0}]},
    true = lists:member(Reg1, nksip_registrar:internal_get_all()),

    % Simulate a request coming at the server from 127.0.0.1:Port, 
    % From is sip:client1@nksip,
    Request1 = #sipmsg{
                app_id = Server1, 
                from = #uri{scheme=sip, user= <<"client1">>, domain= <<"nksip">>},
                transport = #transport{
                                proto = udp, 
                                remote_ip = {127,0,0,1}, 
                                remote_port=Port}},

    true = nksip_registrar:is_registered(Request1),

    {ok, Ip} = nksip_lib:to_ip(Domain),
    
    % Now coming from the Contact's registered address
    Request2 = Request1#sipmsg{transport=(Request1#sipmsg.transport)
                                                #transport{remote_ip=Ip}},
    true = nksip_registrar:is_registered(Request2),

    ok = nksip_registrar:delete(Server1, sip, <<"client1">>, <<"nksip">>),
    not_found  = nksip_registrar:delete(Server1, sip, <<"client1">>, <<"nksip">>),
    ok.


register2() ->
    Opts1 = [make_contact, {expires, 300}],
    FromS = {from, <<"sips:client1@nksip">>},
    Opts2 = [FromS|Opts1],
    Client1 = {basic, client1},
    Client2 = {basic, client2}, 
    Server1 = {basic, server1},

    {ok, 200, Values1} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                            [unregister_all, {fields, [<<"Contact">>]}]),
    [{<<"Contact">>, []}] = Values1,
    [] = nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),

    {ok, 200, Values2} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                            [FromS, unregister_all, 
                                             {fields, [<<"Contact">>]}]),
    [{<<"Contact">>, []}] = Values2,
    [] = nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(Client1, 
                                            "<sip:127.0.0.1;transport=tcp>", Opts1),
    {ok, 200, []} = nksip_uac:register(Client1, 
                                            "<sip:127.0.0.1;transport=tls>", Opts1),
    {ok, 200, []} = nksip_uac:register(Client1, "sips:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                    [{contact, "tel:123456"}, {expires, 300}]),

    {ok, 200, Values3} = nksip_uac:register(Client1, "sips:127.0.0.1", 
                        [{contact, <<"<sips:client1@127.0.0.1:5071>">>},
                         {fields, [<<"Contact">>]}
                            | Opts2--[make_contact]]),
    [{<<"Contact">>, Contact3}] = Values3,
    Contact3Uris = nksip_parse:uris(Contact3),

    {ok, 200, Values4} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                            [{fields, [parsed_contacts]}]),
    [{parsed_contacts, Contacts4}] = Values4, 
    [
        #uri{scheme=sip, port=5070, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5070, opts=[{<<"transport">>, <<"tcp">>}], 
             ext_opts=[{<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5071, opts=[{<<"transport">>, <<"tls">>}], 
             ext_opts=[{<<"expires">>, <<"300">>}]},
        #uri{scheme=sips, port=5071, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]},
        #uri{scheme=tel, domain=(<<"123456">>), opts=[], 
             ext_opts=[{<<"expires">>, <<"300">>}]}
    ]  = lists:sort(Contacts4),

    [#uri{scheme=sips, port=5071, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]}] = 
        Contact3Uris,
    [#uri{scheme=sips, user = <<"client1">>, domain=_Domain, port = 5071}] =
        nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    Contact = <<"<sips:client1@127.0.0.1:5071>;expires=0">>,
    {ok, 200, []} = nksip_uac:register(Client1, "sips:127.0.0.1", 
                                        [{contact, Contact}|Opts2--[make_contact]]),
    [] = nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(Client2, 
                                        "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(Server1, sip, <<"client2">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{local_host, "aaa"}, make_contact]),
    {ok, 200, []} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{contact, "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3"}]),
    {ok, 200, []} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{contact, <<"<sip:ddd:444;transport=tcp>;q=2.1">>}]),
    [
        [
            #uri{user = <<"client2">>, domain = <<"aaa">>, opts = [],
            ext_opts = [{<<"expires">>,<<"3600">>}]}
        ],
        [
            #uri{user= <<>>, domain = <<"ddd">>,port = 444,
                opts = [{<<"transport">>,<<"tcp">>}],
               ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"3600">>}]},
             #uri{user = <<>>, domain = <<"bbb">>, port = 0,
                opts = [], ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"180">>}]}
        ],
        [
            #uri{user = <<>>, domain = <<"ccc">>, port = 0, 
                opts = [], ext_opts = [{<<"q">>,<<"3">>},{<<"expires">>,<<"3600">>}]}
        ]
    ] = nksip_registrar:qfind(Server1, sip, <<"client2">>, <<"nksip">>),
    {ok, 200, []} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    ok.
