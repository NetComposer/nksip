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

% stateless_test_() ->
%     {setup, spawn, 
%         fun() -> 
%             start(stateless),
%             ?debugMsg("Starting proxy stateless")
%         end,
%         fun(_) -> 
%             stop(stateless) 
%         end,
%         [
%             fun() -> invalid(stateless) end,
%             fun() -> opts(stateless) end,
%             fun() -> transport(stateless) end, 
%             fun() -> invite(stateless) end,
%             fun() -> servers(stateless) end
%         ]
%     }.


% stateful_test_() ->
%     {setup, spawn, 
%         fun() -> 
%             start(stateful),
%             ?debugMsg("Starting proxy stateful")
%         end,
%         fun(_) -> 
%             stop(stateful) 
%         end,
%         [
%             fun() -> invalid(stateful) end,
%             fun() -> opts(stateful) end,
%             fun() -> transport(stateful) end, 
%             fun() -> invite(stateful) end,
%             fun() -> servers(stateful) end,
%             fun() -> dialog() end
%         ]
%     }.


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
    ok.


stop(Test) ->
    ok = sipapp_server:stop({Test, server1}),
    ok = sipapp_server:stop({Test, server2}),
    ok = sipapp_endpoint:stop({Test, client1}),
    ok = sipapp_endpoint:stop({Test, client2}).


invalid(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    S1 = {Test, server1},

    % Request arrives at server1; it has no user, and domain belongs to it,
    % so it orders to process it (statelessly or statefully depending on Test)
    {ok, 200, Resp1} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    CallId1 = nksip_response:call_id(Resp1),
    % The UAC has generated a transaction
    [{uac, C1, CallId1, _}] = nksip_call_router:get_all_transactions(C1, CallId1),
    case Test of
        stateless -> 
            [] = nksip_call_router:get_all_transactions(S1, CallId1);
        stateful -> 
            [{uas, S1, CallId1, _}] = 
                nksip_call_router:get_all_transactions(S1, CallId1)
    end,

    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),

    % client@nksip is registered by C2, but it will fail because of Proxy-Require
    Opts3 = [{headers, [{"Proxy-Require", "a, b;c=1,d"}]}],
    {ok, 420, Resp3} = nksip_uac:options(C1, "sip:client2@nksip", Opts3),
    [<<"a,b,d">>] = nksip_response:header(Resp3, <<"Unsupported">>),
    
    % The 420 response is allways stateless
    CallId3 = nksip_response:call_id(Resp3),
    [] = nksip_call_router:get_all_transactions(S1, CallId3),

    % Force Forwards=0 using REGISTER
    CallId4 = nksip_lib:luid(),
    Work4 = {make, 'REGISTER', "sip:any", []},
    {ok, Req4, Opts4} = nksip_call_router:send_work_sync(C1, CallId4, Work4),
    {ok, 483, _} = nksip_call_router:send(Req4#sipmsg{forwards=0}, Opts4),

    % Force Forwards=0 using OPTIONS. Server will reply
    CallId5 = nksip_lib:luid(),
    Work5 = {make, 'OPTIONS', "sip:any", []},
    {ok, Req5, Opts5} = nksip_call_router:send_work_sync(C1, CallId5, Work5),
    {ok, 200, Resp5} = nksip_call_router:send(Req5#sipmsg{forwards=0}, Opts5),
    <<"Max Forwards">> = nksip_response:reason(Resp5),

    % User not registered: Temporarily Unavailable
    {ok, 480, _} = nksip_uac:options(C1, "sip:other@nksip", []),

    % Force Loop
    nksip_trace:notice("Next message about a loop detection is expected"),
    {ok, 482, _} = nksip_uac:options(C1, "sip:any", 
                        [{route, "sip:127.0.0.1;lr, sip:127.0.0.1;lr"}]),
    
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


opts(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),
    
    % Server1 proxies the request to client2@nksip using ServerOpts1 options:
    % two "Nk" headers are added
    ServerOpts1 = [{headers, [{"Nk", "server"}, {"Nk", Test}]}],
    Body1 = base64:encode(term_to_binary(ServerOpts1)),
    Opts1 = [{headers, [{"Nk", "opts2"}]}, {body, Body1}],
    {ok, 200, Res1} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts1),
    Res1Rep = list_to_binary(["server,",atom_to_list(Test),",opts2"]),
    [Res1Rep] = nksip_response:header(Res1, <<"Nk">>),

    % Remove headers at server
    ServerOpts2 = [{headers, [{"Nk", "server"}]}, remove_headers],
    Body2 = base64:encode(term_to_binary(ServerOpts2)),
    Opts2 = [{headers, [{"Nk", "opts2"}]}, {body, Body2}],
    {ok, 200, Res2} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts2),
    [<<"server">>] = nksip_response:header(Res2, <<"Nk">>),

    % Add a route at server
    ServerOpts3 = [{headers, [{"Nk", "server2"}]}, 
                    {route, "sip:127.0.0.1:5070;lr, sip:1.2.3.4;lr"}],
    Body3 = base64:encode(term_to_binary(ServerOpts3)),
    Opts3 = [{headers, [{"Nk", "opts2"}]}, {body, Body3}],
    {ok, 200, Res3} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts3),
    [<<"server2,opts2">>] = nksip_response:header(Res3, <<"Nk">>),
    [<<"<sip:1.2.3.4;lr>">>] = nksip_response:header(Res3, <<"Nk-R">>),

    % Add a route from client
    ServerOpts4 = [],
    Body4 = base64:encode(term_to_binary(ServerOpts4)),
    [Uri2] = nksip_registrar:find({Test, server1}, sip, <<"client2">>, <<"nksip">>),
    Opts4 = [{route, ["sip:127.0.0.1;lr", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
                {body, Body4}], 
    {ok, 200, Res4} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts4),
    [] = nksip_response:header(Res4, <<"Nk">>),
    [<<"<sip:aaa>">>] = nksip_response:header(Res4, <<"Nk-R">>),

    % Remove route from client at server
    ServerOpts5 = [remove_routes],
    Body5 = base64:encode(term_to_binary(ServerOpts5)),
    Opts5 = [{route, ["sip:127.0.0.1;lr", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
                {body, Body5}], 
    {ok, 200, Res5} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts5),
    [] = nksip_response:header(Res5, <<"Nk">>),
    [] = nksip_response:header(Res5, <<"Nk-R">>),

    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


transport(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),
    {ok, 200, Res1} = nksip_uac:options(C1, "sip:client2@nksip", []),
    [<<"client2,server1">>] = nksip_response:header(Res1, <<"Nk-Id">>),
    {ok, 200, Res2} = nksip_uac:options(C2, "sip:client1@nksip", []),
    [<<"client1,server1">>] = nksip_response:header(Res2, <<"Nk-Id">>),
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    % Register generating a TCP Contact
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", 
                        [{route, "sip:127.0.0.1;transport=tcp;lr"}, make_contact]),
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun(Term) -> Self ! {Ref, Term} end},
    
    nksip_uac:register(C2, "sip:127.0.0.1",
                        [{route, "sip:127.0.0.1;transport=tcp;lr"}, make_contact,
                        async, CB]),
    LPort = receive 
        {Ref, {req_id, ReqId3}} -> 
            {tcp, {127,0,0,1}, LP} = nksip_request:field(ReqId3, local),
            LP
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, Res3}} -> 
            {tcp, {127,0,0,1}, 5060} = nksip_response:field(Res3, remote)
        after 1000 ->
            error(transport)
    end,

    % This request is sent using UDP, proxied using TCP
    {ok, 200, Res4} = nksip_uac:options(C1, "sip:client2@nksip", []),
    {udp, {127,0,0,1}, 5060} = nksip_response:field(Res4, remote),
    [<<"client2,server1">>] = nksip_response:header(Res4, <<"Nk-Id">>),

    nksip_uac:options(C2, "sip:client1@nksip", 
                                [{route, "sip:127.0.0.1;transport=tcp;lr"},
                                 async, CB]),
    receive 
        {Ref, {req_id, ReqId5}} -> 
            % Should reuse transport
            {tcp, {127,0,0,1}, LPort} = nksip_request:field(ReqId5, local)
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, Res5}} -> 
            {tcp, {127,0,0,1}, 5060} = nksip_response:field(Res5, remote),
            [<<"client1,server1">>] = nksip_response:header(Res5, <<"Nk-Id">>),
            {tcp, {127,0,0,1}, LPort} = nksip_response:field(Res5, local),
            {tcp, {127,0,0,1}, 5060} = nksip_response:field(Res5, remote)
        after 1000 ->
            error(transport)
    end,

    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


invite(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),    
    
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    RespFun = fun(Term) ->
        case Term of
            {req_id, _} -> ok;
            {ok, Code, _} -> Self ! {Ref, Code} 
        end
    end,

    % Provisional 180 and Busy
    {ok, 486, _} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                         [{headers, [{"Nk-Op", busy}, {"Nk-Prov", true}]},
                                          {callback, RespFun}]),
    ok = tests_util:wait(Ref, [180]),

    % Provisional 180 and 200
    {ok, 200, Res1} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", ok}, {"Nk-Prov", true},
                                                    {"Nk-Sleep", 100}, RepHd]},
                                         {callback, RespFun}]),
    {ok, _} = nksip_uac:ack(Res1, []),
    ok = tests_util:wait(Ref, [180, {client2, ack}]),

    % Several in-dialog requests
    {ok, 200, Res3} = nksip_uac:reoptions(Res1, []),
    [<<"client2">>] = nksip_response:header(Res3, <<"Nk-Id">>),
    Dialog2 = nksip_dialog:remote_id(C2, Res1),
    {ok, 200, Res4} = nksip_uac:reoptions(Dialog2, []),
    [<<"client1">>] = nksip_response:header(Res4, <<"Nk-Id">>),
    {ok, 200, Res5} = nksip_uac:reinvite(Res1, [{headers, [{"Nk-Op", ok}]}]),
    [<<"client2">>] = nksip_response:header(Res5, <<"Nk-Id">>),
    {ok, _} = nksip_uac:ack(Res5, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, Res6} = nksip_uac:reinvite(Dialog2, 
                                        [{headers, [{"Nk-Op", ok}, RepHd]}]),
    [<<"client1">>] = nksip_response:header(Res6, <<"Nk-Id">>),
    {ok, _} = nksip_uac:ack(Res6, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, _} = nksip_uac:bye(Res1, []),

    % Cancelled request
    {async, Req7} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", ok}, 
                                                    {"Nk-Sleep", 5000}, RepHd]},
                                         async, {callback, RespFun}]),
    ok = nksip_uac:cancel(Req7),
    ok = tests_util:wait(Ref, [487]),
    ok.

servers(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    Opts2 = [{route, "sips:127.0.0.1:5081;lr"}, {from, "sips:client2@nksip2"}],
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                                                [unregister_all|Opts2]),
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                                                [make_contact|Opts2]),
    
    % As the RURI is sips, it will be sent using sips, even if our Route is sip
    {ok, 200, Res1} = nksip_uac:options(C1, "sips:client2@nksip2", []),
    {tls, {127,0,0,1}, 5061} = nksip_response:field(Res1, remote),
    [<<"client2,server2,server1">>] = nksip_response:header(Res1, <<"Nk-Id">>),

    {ok, 200, Res2} = nksip_uac:options(C2, "sip:client1@nksip", Opts2),
    {tls, {127,0,0,1}, 5081} = nksip_response:field(Res2, remote),
    [<<"client1,server1,server2">>] = nksip_response:header(Res2, <<"Nk-Id">>),

    % Test a dialog through 2 proxies without Record-Route
    {ok, 200, Res3} = nksip_uac:invite(C1, "sips:client2@nksip2", 
                                            [{headers, [{"Nk-Op", ok}, RepHd]}]),
    [C2Contact] = nksip_response:header(Res3, <<"Contact">>),
    [#uri{port=C2Port}] = nksip_parse:uris(C2Contact),
    [<<"client2,server2,server1">>] = nksip_response:header(Res3, <<"Nk-Id">>),

    % ACK is sent directly
    {req, #sipmsg{ruri=#uri{scheme=sips, port=C2Port}}} = 
        nksip_uac:ack(Res3, [full_request, {headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogId1 = nksip_dialog:id(Res3),
    DialogId2 = nksip_dialog:remote_id(C2, Res3),

    {ok, 200, Res4} = nksip_uac:reoptions(DialogId1, []),
    {tls, {127,0,0,1}, C2Port} = nksip_response:field(Res4, remote),
    [<<"client2">>] = nksip_response:header(Res4, <<"Nk-Id">>),

    {ok, 200, Res5} = nksip_uac:reoptions(DialogId2, []),
    {tls, {127,0,0,1}, 5071} = nksip_response:field(Res5, remote),
    [<<"client1">>] = nksip_response:header(Res5, <<"Nk-Id">>),
    {ok, 200, _} = nksip_uac:bye(DialogId2, []),

    % Test a dialog through 2 proxies with Record-Route
    {ok, 200, Res6} = nksip_uac:invite(C1, "sips:client2@nksip2", 
                                            [{headers, [
                                                {"Nk-Op", ok}, 
                                                {"Nk-Rr", true},
                                                RepHd
                                            ]}]),
    [<<"client2,server2,server1">>] = nksip_response:header(Res6, <<"Nk-Id">>),
    [RR1, RR2] = nksip_response:header(Res6, <<"Record-Route">>),
    [#uri{port=5081, opts=[lr, {transport, <<"tls">>}]}] = nksip_parse:uris(RR1),
    [#uri{port=5061, opts=[lr, {transport, <<"tls">>}]}] = nksip_parse:uris(RR2),

    % Sends an options in the dialog before the ACK
    DialogId3 = nksip_dialog:id(Res6),
    DialogId4 = nksip_dialog:remote_id(C2, Res6),
    {ok, 200, Res7} = nksip_uac:reoptions(DialogId3, []),
    {tls, _, 5061} = nksip_response:field(Res7, remote),
    [<<"client2,server2,server1">>] = nksip_response:header(Res7, <<"Nk-Id">>),

    {ok, AckReq} = nksip_uac:ack(Res6, []),
    {tls, _, 5061} = nksip_request:field(AckReq, remote),
    [
        <<"<sip:NkS@localhost:5061;lr;transport=tls>">>,
        <<"<sip:NkS@localhost:5081;lr;transport=tls>">>
    ] = nksip_request:header(AckReq, <<"Route">>),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, Res8} = nksip_uac:reoptions(DialogId4, []),
    [<<"client1,server1,server2">>] = nksip_response:header(Res8, <<"Nk-Id">>),
    {ok, 200, _} = nksip_uac:bye(DialogId4, [{headers, [{"Nk-Rr", true}]}]),
    ok.


dialog() ->
    C1 = {stateful, client1},
    C2 = {stateful, client2},
    S1 = {stateful, server1},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, _} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, _} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, RespC1} = nksip_uac:invite(C1, "sip:client2@nksip",
                    [{headers, [{"Nk-Op", answer}, {"Nk-Rr", true}, RepHd]}, 
                     {body, SDP}]),
    {ok, _} = nksip_uac:ack(RespC1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogC2 = nksip_dialog:remote_id(C2, RespC1),
    DialogS1 = nksip_dialog:remote_id(S1, RespC1),
    {ok, 200, _} = nksip_uac:options(DialogC2, []),

    [
        C1, 
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
        nksip_dialog:fields(RespC1, [sipapp_id, state, local_seq, remote_seq, parsed_local_uri, 
                             parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                             local_sdp, remote_sdp, parsed_route_set]),

    [
        C2,
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
        S1,
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

    {ok, 200, _} = nksip_uac:bye(DialogC2, [{headers, [{"Nk-Rr", true}]}]),
    error = nksip_dialog:field(RespC1, state),
    error = nksip_dialog:field(DialogC2, state),
    error = nksip_dialog:field(DialogS1, state),
    ok.

