%% -------------------------------------------------------------------
%%
%% stateless_test: Stateless Proxy Suite Test
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

-module(proxy_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).

stateless_test_() ->
    {setup, spawn, 
        fun() -> 
            start(stateless),
            ?debugMsg("Starting proxy stateless")
        end,
        fun(_) -> 
            stop(stateless) 
        end,
        [
            fun() -> invalid(stateless) end,
            fun() -> opts(stateless) end,
            fun() -> transport(stateless) end, 
            fun() -> invite(stateless) end,
            fun() -> servers(stateless) end
        ]
    }.


stateful_test_() ->
    {setup, spawn, 
        fun() -> 
            start(stateful),
            ?debugMsg("Starting proxy stateful")
        end,
        fun(_) -> 
            stop(stateful) 
        end,
        [
            fun() -> invalid(stateful) end,
            fun() -> opts(stateful) end,
            fun() -> transport(stateful) end, 
            fun() -> invite(stateful) end,
            fun() -> servers(stateful) end,
            fun() -> dialog() end
        ]
    }.


start(Test) ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({Test, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = sipapp_server:start({Test, server2}, [
        {from, "sip:server2@nksip"},
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5080}},
        {transport, {tls, {0,0,0,0}, 5081}}]),

    ok = sipapp_endpoint:start({Test, client1}, [
        {from, "sip:client1@nksip"},
        {route, "sip:127.0.0.1;lr"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({Test, client2}, [
        {from, "sip:client2@nksip"},
        {route, "sip:127.0.0.1;lr"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 0}},
        {transport, {tls, {0,0,0,0}, 0}}]),

    tests_util:log(),
    nksip_registrar:clear({Test, server1}).


stop(Test) ->
    ok = sipapp_server:stop({Test, server1}),
    ok = sipapp_server:stop({Test, server2}),
    ok = sipapp_endpoint:stop({Test, client1}),
    ok = sipapp_endpoint:stop({Test, client2}).


invalid(Test) ->
    Client1 = {Test, client1},
    Client2 = {Test, client2},
    Server1 = {Test, client2},
    TC1 = nksip_transaction_uac:total(Client1),
    TC2 = nksip_transaction_uac:total(Client2),
    TS1 = nksip_transaction_uas:total(Server1),
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    TC1 = nksip_transaction_uac:total(Client1)-1,
    TS1 = nksip_transaction_uas:total(Server1), % The server has created no transaction

    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [make_contact]),
    TC2 = nksip_transaction_uac:total(Client2)-1,
    TS1 = nksip_transaction_uas:total(Server1),

    Opts1 = [{headers, [{"Proxy-Require", "a, b;c=1,d"}]}, full_response],
    {reply, Res1} = nksip_uac:options(Client1, "sip:client2@nksip", Opts1),
    420 = nksip_response:code(Res1),
    [<<"a,b,d">>] = nksip_response:header(Res1, <<"Unsupported">>),

    % Force Forwards=0 using REGISTER
    {ok, Req2} = nksip_uac_lib:make(Client1, 'REGISTER', "sip:any", []),
    {ok, 483} = nksip_uac:send_request(Req2#sipmsg{forwards=0}, []),

    % Force Forwards=0 using OPTIONS. Server will reply
    {ok, Req3} = nksip_uac_lib:make(Client1, 'OPTIONS', "sip:any", [full_response]),
    {reply, Res3} = nksip_uac:send_request(Req3#sipmsg{forwards=0}, [full_response]),
    200 = nksip_response:code(Res3),
    <<"Max Forwards">> = nksip_response:reason(Res3),

    % User not registered: Temporarily Unavailable
    {ok, 480} = nksip_uac:options(Client1, "sip:other@nksip", []),

    % Force Loop (a notice is going to be generated)
    tests_util:log(error),
    {ok, 482} = nksip_uac:options(Client1, "sip:any", 
                        [{route, "sip:127.0.0.1;lr, sip:127.0.0.1;lr"}]),
    tests_util:log(),
    
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    ok.


opts(Test) ->
    Client1 = {Test, client1},
    Client2 = {Test, client2},
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [make_contact]),
    
    % Route to client2@nksip using ServerOpts1 options at the server
    % Add headers at server
    ServerOpts1 = [{headers, [{"Nk", "server"}, {"Nk", Test}]}],
    Body1 = base64:encode(term_to_binary(ServerOpts1)),
    Opts1 = [{headers, [{"Nk", "opts2"}]}, {body, Body1}, full_response],
    {reply, Res1} = nksip_uac:options(Client1, "sip:client2_op@nksip", Opts1),
    200 = nksip_response:code(Res1),
    Res1Rep = list_to_binary(["server,",atom_to_list(Test),",opts2"]),
    [Res1Rep] = nksip_response:header(Res1, <<"Nk">>),

    % Remove headers at server
    ServerOpts2 = [{headers, [{"Nk", "server"}]}, remove_headers],
    Body2 = base64:encode(term_to_binary(ServerOpts2)),
    Opts2 = [{headers, [{"Nk", "opts2"}]}, {body, Body2}, full_response],
    {reply, Res2} = nksip_uac:options(Client1, "sip:client2_op@nksip", Opts2),
    200 = nksip_response:code(Res2),
    [<<"server">>] = nksip_response:header(Res2, <<"Nk">>),

    % Add a route at server
    ServerOpts3 = [{headers, [{"Nk", "server2"}]}, 
                    {route, "sip:127.0.0.1:5070;lr, sip:1.2.3.4;lr"}],
    Body3 = base64:encode(term_to_binary(ServerOpts3)),
    Opts3 = [{headers, [{"Nk", "opts2"}]}, {body, Body3}, full_response],
    {reply, Res3} = nksip_uac:options(Client1, "sip:client2_op@nksip", Opts3),
    200 = nksip_response:code(Res3),
    [<<"server2,opts2">>] = nksip_response:header(Res3, <<"Nk">>),
    [<<"<sip:1.2.3.4;lr>">>] = nksip_response:header(Res3, <<"Nk-R">>),

    % Add a route from client
    ServerOpts4 = [],
    Body4 = base64:encode(term_to_binary(ServerOpts4)),
    [Uri2] = nksip_registrar:find({Test, server1}, sip, <<"client2">>, <<"nksip">>),
    Opts4 = [{route, ["sip:127.0.0.1;lr", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
                {body, Body4}, full_response], 
    {reply, Res4} = nksip_uac:options(Client1, "sip:client2_op@nksip", Opts4),
    200 = nksip_response:code(Res4),
    [] = nksip_response:header(Res4, <<"Nk">>),
    [<<"<sip:aaa>">>] = nksip_response:header(Res4, <<"Nk-R">>),

    % Remove route from client at server
    ServerOpts5 = [remove_routes],
    Body5 = base64:encode(term_to_binary(ServerOpts5)),
    Opts5 = [{route, ["sip:127.0.0.1;lr", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
                {body, Body5}, full_response], 
    {reply, Res5} = nksip_uac:options(Client1, "sip:client2_op@nksip", Opts5),
    200 = nksip_response:code(Res5),
    [] = nksip_response:header(Res5, <<"Nk">>),
    [] = nksip_response:header(Res5, <<"Nk-R">>),

    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    ok.


transport(Test) ->
    Client1 = {Test, client1},
    Client2 = {Test, client2},
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),

    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [make_contact]),
    {reply, Res1} = nksip_uac:options(Client1, "sip:client2@nksip", [full_response]),
    200 = nksip_response:code(Res1),
    [<<"client2,server1">>] = nksip_response:header(Res1, <<"Nk-Id">>),
    {reply, Res2} = nksip_uac:options(Client2, "sip:client1@nksip", [full_response]),
    200 = nksip_response:code(Res2),
    [<<"client1,server1">>] = nksip_response:header(Res2, <<"Nk-Id">>),
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),

    % Register generating a TCP Contact
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", 
                        [{route, "sip:127.0.0.1;transport=tcp;lr"}, make_contact]),
    Ref = make_ref(),
    Self = self(),
    Fun4 = fun(Reply) ->
        case Reply of
            {request, Req} ->
                {tcp, {127,0,0,1}, L} = nksip_request:field(Req, local),
                Self ! {Ref, {fun4l, L}};
            {reply, Res} -> 
                {ok, 200} = nksip_response:code(Res),
                {ok, {tcp, {127,0,0,1}, 5060}} = nksip_response:field(Res, remote),
                Self ! {Ref, fun4ok}
        end
    end,
    nksip_uac:register(Client2, "sip:127.0.0.1",
                        [{route, "sip:127.0.0.1;transport=tcp;lr"}, make_contact,
                        async, {respfun, Fun4}, full_response, full_request]),
    LPort = receive {Ref, {fun4l, L}} -> L after 2000 -> error(transport) end,
    ok = tests_util:wait(Ref, [fun4ok]),

    % This request is sent using UDP, proxied using TCP
    {reply, Res5} = nksip_uac:options(Client1, "sip:client2@nksip", [full_response]),
    200 = nksip_response:code(Res5),
    {udp, {127,0,0,1}, 5060} = nksip_response:field(Res5, remote),
    [<<"client2,server1">>] = nksip_response:header(Res5, <<"Nk-Id">>),

    % This one is sent using TCP, proxied using TCP
    % Proxy will send response using same connection
    Fun6 = fun(Reply) ->
        case Reply of
            {request, Req} ->
                % Should reuse transport
                {tcp, {127,0,0,1}, LPort} = nksip_request:field(Req, local), 
                Self ! {Ref, fun6ok1};
            {reply, Res} -> 
                200 = nksip_response:code(Res),
                {ok, {tcp, {127,0,0,1}, 5060}} = nksip_response:field(Res, remote),
                {ok, [<<"client1,server1">>]} = nksip_response:header(Res, <<"Nk-Id">>),
                {ok, {tcp, {127,0,0,1}, LPort}} = nksip_response:field(Res, local),
                {ok, {tcp, {127,0,0,1}, 5060}} = nksip_response:field(Res, remote),
                Self ! {Ref, fun6ok2}
        end
    end,
    nksip_uac:options(Client2, "sip:client1@nksip", 
                                [{route, "sip:127.0.0.1;transport=tcp;lr"},
                                 async, {respfun, Fun6}, full_response, full_request]),
    ok = tests_util:wait(Ref, [fun6ok1, fun6ok2]),

    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    ok.


invite(Test) ->
    Client1 = {Test, client1},
    Client2 = {Test, client2},
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [make_contact]),    
    
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    RespFun = fun({ok, Code, Dialog}) -> 
        if 
            Code >= 200, Code < 300 -> ok = nksip_uac:ack(Dialog, []);
            true -> Self ! {Ref, Code} 
        end
    end,

    % Provisional 180 and Busy
    {ok, 486, _} = nksip_uac:invite(Client1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", busy}, {"Nk-Prov", true}]}, 
                                        {respfun, RespFun}]),
    ok = tests_util:wait(Ref, [180]),

    % Provisional 180 and 200
    {ok, 200, Dialog1} = nksip_uac:invite(Client1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", ok}, {"Nk-Prov", true},
                                                    {"Nk-Sleep", 100}, RepHd]},
                                         {respfun, RespFun}]),
    ok = nksip_uac:ack(Dialog1, []),
    ok = tests_util:wait(Ref, [180, {client2, ack}]),

    % Several in-dialog requests
    Dialog2 = nksip_dialog:remote_id(Client2, Dialog1),
    {reply, Res3} = nksip_uac:options(Dialog1, [full_response]),
    200 = nksip_response:code(Res3),
    [<<"client2">>] = nksip_response:header(Res3, <<"Nk-Id">>),
    {reply, Res4} = nksip_uac:options(Dialog2, [full_response]),
    200 = nksip_response:code(Res4),
    [<<"client1">>] = nksip_response:header(Res4, <<"Nk-Id">>),
    {reply, Res5} = nksip_uac:reinvite(Dialog1, 
                                        [{headers, [{"Nk-Op", ok}]}, full_response]),
    200 = nksip_response:code(Res5),
    [<<"client2">>] = nksip_response:header(Res5, <<"Nk-Id">>),
    ok = nksip_uac:ack(Res5, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),
    {reply, Res6} = nksip_uac:reinvite(Dialog2, 
                                        [{headers, [{"Nk-Op", ok}, RepHd]}, 
                                         full_response]),
    200 = nksip_response:code(Res6),
    [<<"client1">>] = nksip_response:header(Res6, <<"Nk-Id">>),
    ok = nksip_uac:ack(Res6, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200} = nksip_uac:bye(Dialog1, []),

    % Cancelled request
    {async, Req7} = nksip_uac:invite(Client1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", ok}, {"Nk-Prov", true},
                                                    {"Nk-Sleep", 100}, RepHd]},
                                         async, {respfun, RespFun}]),
    timer:sleep(50),
    {ok, 200} = nksip_uac:cancel(Req7, []),
    ok = tests_util:wait(Ref, [180, 487]),
    ok.

servers(Test) ->
    Client1 = {Test, client1},
    Client2 = {Test, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    Opts2 = [{route, "sips:127.0.0.1:5081;lr"}, {from, "sips:client2@nksip2"}],
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sips:127.0.0.1:5081", 
                                                                [unregister_all|Opts2]),
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sips:127.0.0.1:5081", 
                                                                [make_contact|Opts2]),
    
    % As the RURI is sips, it will be sent using sips, even if our Route is sip
    {reply, Res1} = nksip_uac:options(Client1, "sips:client2@nksip2", 
                                            [full_response]),
    200 = nksip_response:code(Res1),
    {tls, {127,0,0,1}, 5061} = nksip_response:field(Res1, remote),
    [<<"client2,server2,server1">>] = nksip_response:header(Res1, <<"Nk-Id">>),

    {reply, Res2} = nksip_uac:options(Client2, "sip:client1@nksip", 
                                            [full_response|Opts2]),
    200 = nksip_response:code(Res2),
    {tls, {127,0,0,1}, 5081} = nksip_response:field(Res2, remote),
    [<<"client1,server1,server2">>] = nksip_response:header(Res2, <<"Nk-Id">>),

    % Test a dialog through 2 proxies without Record-Route
    {reply, Res3} = nksip_uac:invite(Client1, "sips:client2@nksip2", 
                                            [{headers, [{"Nk-Op", ok}, RepHd]},
                                             full_response]),
    200 = nksip_response:code(Res3),
    [Client2Contact] = nksip_response:header(Res3, <<"Contact">>),
    [#uri{port=Client2Port}] = nksip_parse:uris(Client2Contact),
    [<<"client2,server2,server1">>] = nksip_response:header(Res3, <<"Nk-Id">>),

    % ACK is sent directly
    {ok, #sipmsg{ruri=#uri{scheme=sips, port=Client2Port}}} = 
        nksip_uac:ack(Res3, [full_request, {headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogId1 = nksip_dialog:id(Res3),
    DialogId2 = nksip_dialog:id(Res3#sipmsg{sipapp_id=Client2}),

    {reply, Res4} = nksip_uac:options(DialogId1, [full_response]),
    200 = nksip_response:code(Res4),
    {tls, {127,0,0,1}, Client2Port} = nksip_response:field(Res4, remote),
    [<<"client2">>] = nksip_response:header(Res4, <<"Nk-Id">>),

    {reply, Res5} = nksip_uac:options(DialogId2, [full_response]),
    200 = nksip_response:code(Res5),
    {tls, {127,0,0,1}, 5071} = nksip_response:field(Res5, remote),
    [<<"client1">>] = nksip_response:header(Res5, <<"Nk-Id">>),
    {ok, 200} = nksip_uac:bye(DialogId2, []),

    % Test a dialog through 2 proxies with Record-Route
    {reply, Res6} = nksip_uac:invite(Client1, "sips:client2@nksip2", 
                                            [{headers, [{"Nk-Op", ok}, {"Nk-Rr", true},
                                             RepHd]},
                                            full_response]),
    200 = nksip_response:code(Res6),
    [<<"client2,server2,server1">>] = nksip_response:header(Res6, <<"Nk-Id">>),
    [RR1, RR2] = nksip_response:header(Res6, <<"Record-Route">>),
    [#uri{port=5081, opts=[lr, {transport, <<"tls">>}]}] = nksip_parse:uris(RR1),
    [#uri{port=5061, opts=[lr, {transport, <<"tls">>}]}] = nksip_parse:uris(RR2),

    % Sends an options in the dialog before the ACK
    DialogId3 = nksip_dialog:id(Res6),
    DialogId4 = nksip_dialog:id(Res6#sipmsg{sipapp_id=Client2}),
    {reply, Res7} = nksip_uac:options(DialogId3, [full_response]),
    200 = nksip_response:code(Res7),
    {tls, _, 5061} = nksip_response:field(Res7, remote),
    [<<"client2,server2,server1">>] = nksip_response:header(Res7, <<"Nk-Id">>),

    Self = self(),
    ACKFun = fun({ok, R}) -> 
        {tls, _, 5061} = nksip_request:field(R, remote),
        [<<"<sip:NkS@localhost:5061;lr;transport=tls>">>,
         <<"<sip:NkS@localhost:5081;lr;transport=tls>">>] = 
            nksip_request:header(R, <<"Route">>),
        Self ! {Ref, ack_fun_ok} 
    end,
    async = nksip_uac:ack(Res6, [async, {respfun, ACKFun}, full_request]),
    ok = tests_util:wait(Ref, [ack_fun_ok, {client2, ack}]),

    {reply, Res8} = nksip_uac:options(DialogId4, [full_response]),
    200 = nksip_response:code(Res8),
    [<<"client1,server1,server2">>] = nksip_response:header(Res8, <<"Nk-Id">>),
    {ok, 200} = nksip_uac:bye(DialogId4, [{headers, [{"Nk-Rr", true}]}]),
    ok.


dialog() ->
    Client1 = {stateful, client1},
    Client2 = {stateful, client2},
    Server1 = {stateful, server1},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200} = nksip_uac:register(Client1, "sip:127.0.0.1", [make_contact]),
    {ok, 200} = nksip_uac:register(Client2, "sip:127.0.0.1", [make_contact]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, DialogC1} = nksip_uac:invite(Client1, "sip:client2@nksip",
                    [{headers, [{"Nk-Op", answer}, {"Nk-Rr", true}, RepHd]}, 
                     {body, SDP}]),
    ok = nksip_uac:ack(DialogC1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogC2 = nksip_dialog:remote_id(Client2, DialogC1),
    DialogS1 = nksip_dialog:remote_id(Server1, DialogC1),
    {ok, 200} = nksip_uac:options(DialogC2, []),

    [
        Client1, 
        confirmed, 
        LSeq, 
        RSeq, 
        #uri{user = <<"client1">>, domain = <<"nksip">>} = LUri, 
        #uri{user = <<"client2">>, domain = <<"nksip">>} = RUri, 
        #uri{user = <<"client1">>, domain = <<"127.0.0.1">>, port=5070} = LTarget, 
        #uri{user = <<"client2">>, domain = <<"127.0.0.1">>, port=_Port} = RTarget, 
        LSDP, 
        RSDP, 
        [#uri{domain = <<"localhost">>}]
    ] = 
        nksip_dialog:fields(DialogC1, [sipapp_id, state, local_seq, remote_seq, parsed_local_uri, 
                             parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                             local_sdp, remote_sdp, parsed_route_set]),

    [
        Client2,
        confirmed,
        RSeq,
        LSeq,
        RUri,
        LUri,
        RTarget,
        LTarget,
        RSDP,
        LSDP,
        [#uri{domain = <<"localhost">>}]
    ] = 
        nksip_dialog:fields(DialogC2, [sipapp_id, state, local_seq, remote_seq, parsed_local_uri, 
                             parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                             local_sdp, remote_sdp, parsed_route_set]),
    
    [
        Server1,
        confirmed,
        LUri,
        RUri,
        LTarget,
        RTarget,
        LSDP,
        RSDP,
        []          % The first route is deleted (it is itself)
    ] =
        nksip_dialog:fields(DialogS1, [sipapp_id, state, parsed_local_uri, parsed_remote_uri,
                             parsed_local_target, parsed_remote_target, local_sdp, 
                             remote_sdp, parsed_route_set]),

    {ok, 200} = nksip_uac:bye(DialogC2, [{headers, [{"Nk-Rr", true}]}]),
    error = nksip_dialog:field(DialogC1, state),
    error = nksip_dialog:field(DialogC2, state),
    error = nksip_dialog:field(DialogS1, state),
    ok.

