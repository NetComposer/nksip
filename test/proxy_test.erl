%% -------------------------------------------------------------------
%%
%% proxy_test: Stateless and Stateful Proxy Tests
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
-include("../include/nksip.hrl").

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
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = sipapp_endpoint:start({Test, client2}, [
        {from, "sip:client2@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
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
    {ok, 200, [{call_id, CallId1}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1", [make_contact, {fields, [call_id]}]),
    % The UAC has generated a transaction
    [{uac, _}] = nksip_call_router:get_all_transactions(C1, CallId1),
    case Test of
        stateless -> 
            [] = nksip_call_router:get_all_transactions(S1, CallId1);
        stateful -> 
            [{uas, _}] = 
                nksip_call_router:get_all_transactions(S1, CallId1)
    end,

    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),

    % client@nksip is registered by C2, but it will fail because of Proxy-Require
    Opts3 = [
        {headers, [{"Proxy-Require", "a, b;c=1,d"}]},
        {fields, [call_id, <<"Unsupported">>]}
    ],
    {ok, 420, [{call_id, CallId3}, {<<"Unsupported">>, [<<"a,b,d">>]}]} = 
        nksip_uac:options(C1, "sip:client2@nksip", Opts3),
    
    % The 420 response is always stateless
    [] = nksip_call_router:get_all_transactions(S1, CallId3),

    % Force Forwards=0 using REGISTER
    CallId4 = nksip_lib:luid(),
    Work4 = {make, 'REGISTER', "sip:any", []},
    {ok, Req4, Opts4} = nksip_call_router:send_work_sync(C1, CallId4, Work4),
    {ok, 483, _} = nksip_call:send(Req4#sipmsg{forwards=0}, Opts4),

    % Force Forwards=0 using OPTIONS. Server will reply
    CallId5 = nksip_lib:luid(),
    Work5 = {make, 'OPTIONS', "sip:any", []},
    {ok, Req5, Opts5} = nksip_call_router:send_work_sync(C1, CallId5, Work5),
    {ok, 200, [{reason_phrase, <<"Max Forwards">>}]} = 
        nksip_call:send(Req5#sipmsg{forwards=0}, [{fields, [reason_phrase]}|Opts5]),

    % User not registered: Temporarily Unavailable
    {ok, 480, []} = nksip_uac:options(C1, "sip:other@nksip", []),

    % Force Loop
    nksip_trace:notice("Next message about a loop detection is expected"),
    {ok, 482, []} = nksip_uac:options(C1, "sip:any", 
                        [{route, "<sip:127.0.0.1;lr>, <sip:127.0.0.1;lr>"}]),
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


opts(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),
    
    % Server1 proxies the request to client2@nksip using ServerOpts1 options:
    % two "Nk" headers are added
    ServerOpts1 = [{headers, [{"Nk", "server"}, {"Nk", Test}]}],
    Body1 = base64:encode(term_to_binary(ServerOpts1)),
    Opts1 = [{headers, [{"Nk", "opts2"}]}, {body, Body1}, {fields, [<<"Nk">>]}],
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts1),
    Res1Rep = list_to_binary(["server,",atom_to_list(Test),",opts2"]),
    [{<<"Nk">>, [Res1Rep]}] = Values1,

    % Remove headers at server
    ServerOpts2 = [{headers, [{"Nk", "server"}]}, remove_headers],
    Body2 = base64:encode(term_to_binary(ServerOpts2)),
    Opts2 = [{headers, [{"Nk", "opts2"}]}, {body, Body2}, {fields, [<<"Nk">>]}],
    {ok, 200, Values2} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts2),
    [{<<"Nk">>, [<<"server">>]}] = Values2,
    % Add a route at server
    ServerOpts3 = [{headers, [{"Nk", "server2"}]}, 
                    {route, "<sip:127.0.0.1:5070;lr>, <sip:1.2.3.4;lr>"}],
    Body3 = base64:encode(term_to_binary(ServerOpts3)),
    Opts3 = [{headers, [{"Nk", "opts2"}]}, {body, Body3},
             {fields, [<<"Nk">>, <<"Nk-R">>]}],
    {ok, 200, Values3} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts3),
    [
        {<<"Nk">>, [<<"server2,opts2">>]}, 
        {<<"Nk-R">>, [<<"<sip:1.2.3.4;lr>">>]}
    ] = Values3,

    % Add a route from client
    ServerOpts4 = [],
    Body4 = base64:encode(term_to_binary(ServerOpts4)),
    [Uri2] = nksip_registrar:find({Test, server1}, sip, <<"client2">>, <<"nksip">>),
    Opts4 = [{route, ["<sip:127.0.0.1;lr>", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
             {body, Body4},
             {fields, [<<"Nk">>, <<"Nk-R">>]}],
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts4),
    [
        {<<"Nk">>, []}, 
        {<<"Nk-R">>, [<<"<sip:aaa>">>]}
    ] = Values4,

    % Remove route from client at server
    ServerOpts5 = [remove_routes],
    Body5 = base64:encode(term_to_binary(ServerOpts5)),
    Opts5 = [{route, ["<sip:127.0.0.1;lr>", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
             {body, Body5}, 
             {fields, [<<"Nk">>, <<"Nk-R">>]}],
    {ok, 200, Values5} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts5),
    [
        {<<"Nk">>, []}, 
        {<<"Nk-R">>, []}
    ] = Values5,

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


transport(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),
    {ok, 200, [{<<"Nk-Id">>, [<<"client2,server1">>]}]} = 
        nksip_uac:options(C1, "sip:client2@nksip", [{fields, [<<"Nk-Id">>]}]),
    {ok, 200, [{<<"Nk-Id">>, [<<"client1,server1">>]}]} = 
        nksip_uac:options(C2, "sip:client1@nksip", [{fields, [<<"Nk-Id">>]}]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    % Register generating a TCP Contact
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", 
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, make_contact]),
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun(Term) -> Self ! {Ref, Term} end},
    
    nksip_uac:register(C2, "sip:127.0.0.1",
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, make_contact,
                        async, CB, get_request, {fields, [remote]}]),
    LPort = receive 
        {Ref, {req, Req3}} -> 
            {tcp, {127,0,0,1}, LP} = nksip_sipmsg:field(Req3, local),
            LP
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, [{remote, {tcp, {127,0,0,1}, 5060}}]}} -> ok
        after 1000 -> error(transport)
    end,

    % This request is sent using UDP, proxied using TCP
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:client2@nksip", 
        [{fields, [remote, <<"Nk-Id">>]}]),
    [
        {remote, {udp, {127,0,0,1}, 5060}},
        {<<"Nk-Id">>, [<<"client2,server1">>]}
    ] = Values4,

    nksip_uac:options(C2, "sip:client1@nksip", 
                                [{route, "<sip:127.0.0.1;transport=tcp;lr>"},
                                 async, CB, get_request,
                                 {fields, [local, remote, <<"Nk-Id">>]}]),
    receive 
        {Ref, {req, ReqId5}} -> 
            % Should reuse transport
            {tcp, {127,0,0,1}, LPort} = nksip_sipmsg:field(ReqId5, local)
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, Values5}} -> 
            [
                {local, {tcp, {127,0,0,1}, LPort}},
                {remote, {tcp, {127,0,0,1}, 5060}},
                {<<"Nk-Id">>, [<<"client1,server1">>]}
            ] = Values5
        after 1000 ->
            error(transport)
    end,

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


invite(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),    
    
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    RespFun = fun({ok, Code, _}) -> Self ! {Ref, Code} end,

    % Provisional 180 and Busy
    {ok, 486, []} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                     [{headers, [{"Nk-Op", busy}, {"Nk-Prov", true}]},
                                      {callback, RespFun}]),
    ok = tests_util:wait(Ref, [180]),

    % Provisional 180 and 200
    {ok, 200, [{dialog_id, DialogId1}]} = 
        nksip_uac:invite(C1, "sip:client2@nksip", 
                                [{headers, [{"Nk-Op", ok}, {"Nk-Prov", true},
                                            {"Nk-Sleep", 100}, RepHd]},
                                 {callback, RespFun}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [180, {client2, ack}]),

    % Several in-dialog requests
    {ok, 200, [{<<"Nk-Id">>, [<<"client2">>]}]} = 
        nksip_uac:options(C1, DialogId1, [{fields, [<<"Nk-Id">>]}]),
    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, [{<<"Nk-Id">>, [<<"client1">>]}]} = 
        nksip_uac:options(C2, DialogId2, [{fields, [<<"Nk-Id">>]}]),
    {ok, 200, [{dialog_id, DialogId1}, {<<"Nk-Id">>, [<<"client2">>]}]} = 
        nksip_uac:invite(C1, DialogId1, [{headers, [{"Nk-Op", ok}]},
                                         {fields, [<<"Nk-Id">>]}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, [{dialog_id, DialogId2}, {<<"Nk-Id">>, [<<"client1">>]}]} = 
        nksip_uac:invite(C2, DialogId2, [{headers, [{"Nk-Op", ok}, RepHd]},     
                                         {fields, [<<"Nk-Id">>]}]),
    ok = nksip_uac:ack(C2, DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, []} = nksip_uac:bye(C1, DialogId1, []),

    % Cancelled request
    {async, ReqId7} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                        [{headers, [{"Nk-Op", ok}, 
                                                    {"Nk-Sleep", 5000}, RepHd]},
                                         async, {callback, RespFun}]),
    ok = nksip_uac:cancel(C1, ReqId7),
    ok = tests_util:wait(Ref, [487, {client2, bye}]),
    ok.

servers(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    Opts2 = [{route, "<sips:127.0.0.1:5081;lr>"}, {from, "sips:client2@nksip2"}],
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                                                [unregister_all|Opts2]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                                                [make_contact|Opts2]),
    
    % As the RURI is sips, it will be sent using sips, even if our Route is sip
    % server1 detects nksip2 is a domain for server2, and routes to there
    % client2 answers
    Fs1 = {fields, [remote, <<"Nk-Id">>]},
    {ok, 200, Values1} = nksip_uac:options(C1, "sips:client2@nksip2", [Fs1]),
    [
        {remote, {tls, {127,0,0,1}, 5061}},
        {_, [<<"client2,server2,server1">>]}
    ] = Values1,

    % Sent to server2 using sips because of Opts2
    {ok, 200, Values2} = nksip_uac:options(C2, "sip:client1@nksip", [Fs1|Opts2]),
    [
        {remote, {tls, {127,0,0,1}, 5081}},
        {_, [<<"client1,server1,server2">>]}
    ] = Values2,


    % Test a dialog through 2 proxies without Record-Route
    Fs3 = {fields, [<<"Contact">>, <<"Nk-Id">>]},
    {ok, 200, Values3} = nksip_uac:invite(C1, "sips:client2@nksip2", 
                                            [Fs3, {headers, [{"Nk-Op", ok}, RepHd]}]),
    [
        {dialog_id, DialogIdA1},
        {<<"Contact">>, [C2Contact]},
        {<<"Nk-Id">>, [<<"client2,server2,server1">>]}
    ] = Values3,
    [#uri{port=C2Port}] = nksip_parse:uris(C2Contact),

    % ACK is sent directly
    {req, #sipmsg{ruri=#uri{scheme=sips, port=C2Port}}} = 
        nksip_uac:ack(C1, DialogIdA1, [get_request, {headers, [RepHd]}]),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % OPTIONS is also sent directly
    Fs4 = {fields, [remote, <<"Nk-Id">>]},
    {ok, 200, Values4} = nksip_uac:options(C1, DialogIdA1, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, _}},
        {<<"Nk-Id">>, [<<"client2">>]}
    ] = Values4,

    DialogIdA2 = nksip_dialog:field(C1, DialogIdA1, remote_id),
    {ok, 200, Values5} = nksip_uac:options(C2, DialogIdA2, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, 5071}},
        {<<"Nk-Id">>, [<<"client1">>]}
    ] = Values5,

    {ok, 200, []} = nksip_uac:bye(C1, DialogIdA1, []),
    ok = tests_util:wait(Ref, [{client2, bye}]),

    % Test a dialog through 2 proxies with Record-Route
    Hds6 = {headers, [{"Nk-Op", ok}, {"Nk-Rr", true}, RepHd]},
    Fs6 = {fields, [<<"Record-Route">>, <<"Nk-Id">>]},
    {ok, 200, Values6} = nksip_uac:invite(C1, "sips:client2@nksip2", [Hds6, Fs6]),
    [
        {dialog_id, DialogIdB1},
        {<<"Record-Route">>, [RR1, RR2]},
        {<<"Nk-Id">>, [<<"client2,server2,server1">>]}
    ] = Values6,
    [#uri{port=5081, opts=[<<"lr">>, {<<"transport">>, <<"tls">>}]}] = nksip_parse:uris(RR1),
    [#uri{port=5061, opts=[<<"lr">>, {<<"transport">>, <<"tls">>}]}] = nksip_parse:uris(RR2),

    % Sends an options in the dialog before the ACK
    {ok, 200, Values7} = nksip_uac:options(C1, DialogIdB1, [Fs4]),
    [
        {remote, {tls, _, 5061}},
        {<<"Nk-Id">>, [<<"client2,server2,server1">>]}
    ] = Values7,

    {req, AckReq} = nksip_uac:ack(C1, DialogIdB1, [get_request]),
    {tls, _, 5061} = nksip_sipmsg:field(AckReq, remote),
    [
        <<"<sip:NkS@localhost:5061;lr;transport=tls>">>,
        <<"<sip:NkS@localhost:5081;lr;transport=tls>">>
    ] = nksip_sipmsg:header(AckReq, <<"Route">>),
    ok = tests_util:wait(Ref, [{client2, ack}]),
 
    DialogIdB2 = nksip_dialog:field(C1, DialogIdB1, remote_id),
    Fs8 = {fields, [<<"Nk-Id">>]},
    {ok, 200, Values8} = nksip_uac:options(C2, DialogIdB2, [Fs8]),
    [{<<"Nk-Id">>, [<<"client1,server1,server2">>]}] = Values8,
    {ok, 200, []} = nksip_uac:bye(C2, DialogIdB2, [{headers, [{"Nk-Rr", true}]}]),
    ok.




dialog() ->
    C1 = {stateful, client1},
    C2 = {stateful, client2},
    S1 = {stateful, server1},
    Ref = make_ref(),
    Self = self(),
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [make_contact]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, Values1} = nksip_uac:invite(C1, "sip:client2@nksip",
                                [{headers, [{"Nk-Op", answer}, {"Nk-Rr", true}, RepHd]}, 
                                 {body, SDP}]),
    [{dialog_id, DialogId1}] = Values1,
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),

    [
        {app_id, C1}, 
        {invite_status, confirmed}, 
        {local_seq, LSeq}, 
        {remote_seq, RSeq}, 
        {parsed_local_uri, LUri}, 
        {parsed_remote_uri, RUri}, 
        {parsed_local_target, LTarget}, 
        {parsed_remote_target, RTarget}, 
        {invite_local_sdp, LSDP}, 
        {invite_remote_sdp, RSDP}, 
        {parsed_route_set, [#uri{domain = <<"localhost">>}]}
    ] = 
        nksip_dialog:fields(C1, DialogId1, 
                [app_id, invite_status, local_seq, remote_seq, parsed_local_uri, 
                 parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                 invite_local_sdp, invite_remote_sdp, parsed_route_set]),

    #uri{user = <<"client1">>, domain = <<"nksip">>} = LUri, 
    #uri{user = <<"client2">>, domain = <<"nksip">>} = RUri, 
    #uri{user = <<"client1">>, domain = <<"127.0.0.1">>, port=5070} = LTarget, 
    #uri{user = <<"client2">>, domain = <<"127.0.0.1">>, port=_Port} = RTarget, 

    [
        {app_id, C2},
        {invite_status, confirmed},
        {local_seq, RSeq},
        {remote_seq, LSeq},
        {parsed_local_uri, RUri},
        {parsed_remote_uri, LUri},
        {parsed_local_target, RTarget},
        {parsed_remote_target, LTarget},
        {invite_local_sdp, RSDP},
        {invite_remote_sdp, LSDP},
        {parsed_route_set, [#uri{domain = <<"localhost">>}]}
    ] = 
        nksip_dialog:fields(C2, DialogId2,
                [app_id, invite_status, local_seq, remote_seq, parsed_local_uri, 
                 parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                 invite_local_sdp, invite_remote_sdp, parsed_route_set]),
    
    [
        {app_id, S1},
        {invite_status, confirmed},
        {parsed_local_uri, LUri},
        {parsed_remote_uri, RUri},
        {parsed_local_target, LTarget},
        {parsed_remote_target, RTarget},
        {invite_local_sdp, LSDP},
        {invite_remote_sdp, RSDP},
        {parsed_route_set, []}          % The first route is deleted (it is itself)
    ] =
        nksip_dialog:fields(S1, DialogId1, 
            [app_id, invite_status, parsed_local_uri, parsed_remote_uri,
             parsed_local_target, parsed_remote_target, invite_local_sdp, 
             invite_remote_sdp, parsed_route_set]),

    {ok, 200, []} = nksip_uac:bye(C2, DialogId2, [{headers, [{"Nk-Rr", true}]}]),
    error = nksip_dialog:field(C1, DialogId1, status),
    error = nksip_dialog:field(C2, DialogId2, status),
    error = nksip_dialog:field(S1, DialogId1, status),
    ok.

