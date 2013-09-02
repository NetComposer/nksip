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
-include_lib("nksip/include/nksip.hrl").

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
    {ok, 405} = nksip_uac:register(Client2, "sip:127.0.0.1:5070", []),

    {ok, 400} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                        [{from, "sip:one"}, {to, "sip:two"}]),

    {reply, Resp1} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                                [unregister_all, full_response]),
    200 = nksip_response:code(Resp1),
    [] = nksip_response:header(Resp1, <<"Contact">>),
    [] = nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),
    
    Ref = make_ref(),
    Self = self(),
    RespFun = fun(Reply) -> Self ! {Ref, Reply} end,
    async = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [async, {respfun, RespFun}, make_contact, 
                                     full_request, full_response]),
    [CallId, CSeq] = receive 
        {ok, {Ref, {request, Req2}}} -> nksip_request:fields(Req2, [call_id, cseq_num])
        after 2000 -> error(register1)
    end,

    receive {Ref, {reply, Resp2}} -> ok after 2000 -> Resp2 = error(register1) end,

    Name = <<"client1">>,
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{expires, DefB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),
    MakeContact = fun(Exp) ->
        list_to_binary([
            "<sip:", Name, "@", Domain, ":", nksip_lib:to_binary(Port),
            ">;expires=", Exp])
    end,
    Contact2 = MakeContact(DefB),
    [Contact2] = nksip_response:header(Resp2, <<"Contact">>),

    {reply, Resp2b} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq}, make_contact,
                                     full_response]),
    400 = nksip_response:code(Resp2b),
    <<"Rejected Old CSeq">> = nksip_response:reason(Resp2b),

    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq+1}, make_contact]),

    {ok, 400} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq, CSeq+1}, 
                                     unregister_all]),

    Opts3 = [{expires, Min-1}, make_contact, full_response],
    {reply, Resp3} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts3),
    423 = nksip_response:code(Resp3),
    [MinB] = nksip_response:header(Resp3, <<"Min-Expires">>),

    Opts4 = [{expires, Max+1}, make_contact, full_response],
    {reply, Resp4} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts4),
    200 = nksip_response:code(Resp4),
    Contact4 = MakeContact(MaxB),
    [Contact4] = nksip_response:header(Resp4, <<"Contact">>),
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{expires, MaxB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),

    Opts5 = [{expires, Min}, make_contact, full_response],
    ExpB = nksip_lib:to_binary(Min),
    {reply, Resp5} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts5),
    200 = nksip_response:code(Resp5),
    Contact5 = MakeContact(ExpB),
    [Contact5] = nksip_response:header(Resp5, <<"Contact">>),
    [#uri{user=Name, domain=Domain, port=Port, ext_opts=[{expires, ExpB}]}] = 
        nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),

    Reg1 = {{sip,<<"client1">>,<<"nksip">>},
        [{#uri{user = <<"client1">>, domain=Domain, port=Port, 
        ext_opts=[{expires, ExpB}]}, Min, 1.0}]},
    true = lists:member(Reg1, nksip_registrar:get_all()),

    % Simulate a request coming at the server from 127.0.0.1:Port, 
    % From is sip:client1@nksip,
    Request1 = #sipmsg{
                sipapp_id = Server1, 
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


    {reply, Resp1} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                            [unregister_all, full_response]),
    200 = nksip_response:code(Resp1),

    [] = nksip_response:header(Resp1, <<"Contact">>),
    [] = nksip_registrar:find(Server1, sip, <<"client1">>, <<"nksip">>),
    {reply, Resp2} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                                            [FromS, unregister_all, full_response]),
    200 = nksip_response:code(Resp2),
    [] = nksip_response:headers(Resp2, <<"Contact">>),
    [] = nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts1),
    {ok, 200} = nksip_uac:register(Client1, 
                                            "sip:127.0.0.1;transport=tcp", Opts1),
    {ok, 200} = nksip_uac:register(Client1, 
                                            "sip:127.0.0.1;transport=tls", Opts1),
    {ok, 200} = nksip_uac:register(Client1, "sips:127.0.0.1", Opts1),

    {ok, 400} = nksip_uac:register(Client1, "sip:127.0.0.1", Opts2),
    {reply, Resp4} = nksip_uac:register(Client1, "sips:127.0.0.1", 
                        [{contact, <<"<sips:client1@127.0.0.1:5071>">>}, 
                            full_response| Opts2--[make_contact]]),
    200 = nksip_response:code(Resp4),

    {reply, Resp3} = nksip_uac:register(Client1, "sip:127.0.0.1", [full_response]),
    200 = nksip_response:code(Resp3),
    [
        #uri{scheme=sip, port=5070, opts=[], ext_opts=[{expires, <<"300">>}]},
        #uri{scheme=sip, port=5070, opts=[{transport, <<"tcp">>}], 
                                                ext_opts=[{expires, <<"300">>}]},
        #uri{scheme=sips, port=5071, opts=[], ext_opts=[{expires, <<"300">>}]}
    ] = 
        lists:sort(nksip_response:field(Resp3, parsed_contacts)),

    [#uri{scheme=sips, port=5071, opts=[], ext_opts=[{expires, <<"300">>}]}] = 
        lists:sort(nksip_parse:uris(nksip_response:header(Resp4, <<"Contact">>))),
    [#uri{scheme=sips, user = <<"client1">>, domain=_Domain, port = 5071}] =
        nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    Contact = <<"<sips:client1@127.0.0.1:5071>;expires=0">>,
    {ok, 200} = nksip_uac:register(Client1, "sips:127.0.0.1", 
                                        [{contact, Contact}|Opts2--[make_contact]]),
    [] = nksip_registrar:find(Server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200} = nksip_uac:register(Client2, 
                                        "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(Server1, sip, <<"client2">>, <<"nksip">>),

    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{local_host, "aaa"}, make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{contact, "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3"}]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", 
                                [{contact, <<"<sip:ddd:444;transport=tcp>;q=2.1">>}]),
    [
        [
            #uri{user = <<"client2">>, domain = <<"aaa">>, opts = [],
            ext_opts = [{expires,<<"3600">>}]}
        ],
        [
            #uri{user= <<>>, domain = <<"ddd">>,port = 444,
                opts = [{transport,<<"tcp">>}],
               ext_opts = [{q,<<"2.1">>},{expires,<<"3600">>}]},
             #uri{user = <<>>, domain = <<"bbb">>, port = 0,
                opts = [], ext_opts = [{q,<<"2.1">>},{expires,<<"180">>}]}
        ],
        [
            #uri{user = <<>>, domain = <<"ccc">>, port = 0, 
                opts = [], ext_opts = [{q,<<"3">>},{expires,<<"3600">>}]}
        ]
    ] = nksip_registrar:qfind(Server1, sip, <<"client2">>, <<"nksip">>),
    {ok, 200} = nksip_uac:register(Client2, 
                                            "sip:127.0.0.1", [unregister_all]),
    ok.
