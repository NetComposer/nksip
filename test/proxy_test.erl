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
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    ok = sipapp_server:start({Test, server2}, [
        {from, "sip:server2@nksip"},
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    ok = sipapp_endpoint:start({Test, client1}, [
        {from, "sip:client1@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    ok = sipapp_endpoint:start({Test, client2}, [
        {from, "sip:client2@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, any}, {tls, all, any}]}
    ]),

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
        nksip_uac:register(C1, "sip:127.0.0.1", [contact, {meta, [call_id]}]),
    % The UAC has generated a transaction
    [{uac, _}] = nksip_call_router:get_all_transactions(C1, CallId1),
    case Test of
        stateless -> 
            [] = nksip_call_router:get_all_transactions(S1, CallId1);
        stateful -> 
            [{uas, _}] = 
                nksip_call_router:get_all_transactions(S1, CallId1)
    end,

    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),

    % client@nksip is registered by C2, but it will fail because of Proxy-Require
    Opts3 = [
        {add, "proxy-require", "a, b;c=1,d"},
        {meta, [call_id, <<"unsupported">>]}
    ],
    {ok, 420, [{call_id, CallId3}, {<<"unsupported">>, [<<"a,b,d">>]}]} = 
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
        nksip_call:send(Req5#sipmsg{forwards=0}, [{meta,[reason_phrase]}|Opts5]),

    % User not registered: Temporarily Unavailable
    {ok, 480, []} = nksip_uac:options(C1, "sip:other@nksip", []),


    % Now all headers pointing us are removed...
    % % Force Loop
    % nksip_trace:notice("Next message about a loop detection is expected"),
    % {ok, 482, []} = nksip_uac:options(C1, "sip:any", 
    %                     [{route, "<sip:127.0.0.1;lr>, <sip:127.0.0.1;lr>"}]),
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


opts(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),
    
    % Server1 proxies the request to client2@nksip using ServerOpts1 options:
    % two "x-nk" headers are added
    ServerOpts1 = [{insert, "x-nk", "server"}, {insert, "x-nk", Test}],
    Body1 = base64:encode(term_to_binary(ServerOpts1)),
    Opts1 = [{insert, "x-nk", "opts2"}, {body, Body1}, {meta, [<<"x-nk">>]}],
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts1),
    Res1Rep = list_to_binary([atom_to_list(Test), ",server,opts2"]),
    [{<<"x-nk">>, [Res1Rep]}] = Values1,

    % Remove headers at server
    ServerOpts2 = [{replace, "x-nk", "server"}],
    Body2 = base64:encode(term_to_binary(ServerOpts2)),
    Opts2 = [{insert, "x-nk", "opts2"}, {body, Body2}, {meta, [<<"x-nk">>]}],
    {ok, 200, Values2} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts2),
    [{<<"x-nk">>, [<<"server">>]}] = Values2,
    
    % Add a route at server
    ServerOpts3 = [{insert, "x-nk", "server2"}, 
                    {route, "<sip:127.0.0.1:5070;lr>, <sip:1.2.3.4;lr>"}],
    Body3 = base64:encode(term_to_binary(ServerOpts3)),
    Opts3 = [{insert, "x-nk", "opts2"}, {body, Body3},
             {meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values3} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts3),
    [
        {<<"x-nk">>, [<<"server2,opts2">>]}, 
        {<<"x-nk-r">>, [<<"<sip:127.0.0.1:5070;lr>,<sip:1.2.3.4;lr>">>]}
    ] = Values3,

    % Add a route from client
    ServerOpts4 = [],
    Body4 = base64:encode(term_to_binary(ServerOpts4)),
    [Uri2] = nksip_registrar:find({Test, server1}, sip, <<"client2">>, <<"nksip">>),
    Opts4 = [{route, 
                ["<sip:127.0.0.1;lr>", Uri2#uri{opts=[lr], ext_opts=[]}, <<"sip:aaa">>]},
             {body, Body4},
             {meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts4),
    NkR4 = nksip_lib:bjoin([nksip_unparse:uri(Uri2#uri{opts=[lr], ext_opts=[]}),
                            <<"<sip:aaa>">>]),
    [
        {<<"x-nk">>, []}, 
        {<<"x-nk-r">>, [NkR4]}
    ] = Values4,

    % Remove route from client at server
    ServerOpts5 = [{route, ""}],    % equivalent to {replace, "route", ""}
    Body5 = base64:encode(term_to_binary(ServerOpts5)),
    Opts5 = [{route, ["<sip:127.0.0.1;lr>", Uri2#uri{opts=[lr]}, <<"sip:aaa">>]},
             {body, Body5}, 
             {meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values5} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts5),
    [
        {<<"x-nk">>, []}, 
        {<<"x-nk-r">>, []}
    ] = Values5,

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


transport(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),
    {ok, 200, [{<<"x-nk-id">>, [<<"client2,server1">>]}]} = 
        nksip_uac:options(C1, "sip:client2@nksip", [{meta,[<<"x-nk-id">>]}]),
    {ok, 200, [{<<"x-nk-id">>, [<<"client1,server1">>]}]} = 
        nksip_uac:options(C2, "sip:client1@nksip", [{meta,[<<"x-nk-id">>]}]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    % Register generating a TCP Contact
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", 
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, contact]),
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun(Term) -> Self ! {Ref, Term} end},
    
    nksip_uac:register(C2, "sip:127.0.0.1",
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, contact,
                        async, CB, get_request, {meta, [remote]}]),
    LPort = receive 
        {Ref, {req, Req3}} -> 
            {tcp, {127,0,0,1}, LP, <<>>} = nksip_sipmsg:field(Req3, local),
            LP
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, [{remote, {tcp, {127,0,0,1}, 5060, <<>>}}]}} -> ok
        after 1000 -> error(transport)
    end,

    % This request is sent using UDP, proxied using TCP
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:client2@nksip", 
        [{meta,[remote, <<"x-nk-id">>]}]),
    [
        {remote, {udp, {127,0,0,1}, 5060, <<>>}},
        {<<"x-nk-id">>, [<<"client2,server1">>]}
    ] = Values4,

    nksip_uac:options(C2, "sip:client1@nksip", 
                                [{route, "<sip:127.0.0.1;transport=tcp;lr>"},
                                 async, CB, get_request,
                                 {meta, [local, remote, <<"x-nk-id">>]}]),
    receive 
        {Ref, {req, ReqId5}} -> 
            % Should reuse transport
            {tcp, {127,0,0,1}, LPort, <<>>} = nksip_sipmsg:field(ReqId5, local)
        after 1000 ->
            error(transport)
    end,
    receive
        {Ref, {ok, 200, Values5}} -> 
            [
                {local, {tcp, {127,0,0,1}, LPort, <<>>}},
                {remote, {tcp, {127,0,0,1}, 5060, <<>>}},
                {<<"x-nk-id">>, [<<"client1,server1">>]}
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
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),    
    
    Ref = make_ref(),
    Self = self(),
    RepHd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    RespFun = fun({ok, Code, _}) -> Self ! {Ref, Code} end,

    % Provisional 180 and Busy
    {ok, 486, []} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                     [{add, "x-nk-op", busy}, {add, "x-nk-prov", true},
                                      {callback, RespFun}]),
    ok = tests_util:wait(Ref, [180]),

    % Provisional 180 and 200
    {ok, 200, [{dialog_id, DialogId1}]} = 
        nksip_uac:invite(C1, "sip:client2@nksip", 
                                [{add, "x-nk-op", ok}, {add, "x-nk-prov", true},
                                 {add, "x-nk-sleep", 100}, RepHd,
                                 {callback, RespFun}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [180, {client2, ack}]),

    % Several in-dialog requests
    {ok, 200, [{<<"x-nk-id">>, [<<"client2">>]}]} = 
        nksip_uac:options(C1, DialogId1, [{meta,[<<"x-nk-id">>]}]),
    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, [{<<"x-nk-id">>, [<<"client1">>]}]} = 
        nksip_uac:options(C2, DialogId2, [{meta,[<<"x-nk-id">>]}]),
    
    {ok, 200, [{dialog_id, DialogId1}, {<<"x-nk-id">>, [<<"client2">>]}]} = 
        nksip_uac:invite(C1, DialogId1, [{add, "x-nk-op", ok},
                                         {meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, [{dialog_id, DialogId2}, {<<"x-nk-id">>, [<<"client1">>]}]} = 
        nksip_uac:invite(C2, DialogId2, [{add, "x-nk-op", ok}, RepHd,     
                                         {meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(C2, DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, []} = nksip_uac:bye(C1, DialogId1, []),

    % Cancelled request
    {async, ReqId7} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                        [{add, "x-nk-op", ok}, {add, "x-nk-sleep", 5000}, RepHd,
                                         async, {callback, RespFun}]),
    ok = nksip_uac:cancel(C1, ReqId7),
    ok = tests_util:wait(Ref, [487, {client2, bye}]),
    ok.

servers(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    Ref = make_ref(),
    Self = self(),
    RepHd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    Opts2 = [{route, "<sips:127.0.0.1:5081;lr>"}, {from, "sips:client2@nksip2"}],
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                        [unregister_all|Opts2]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", 
                                        [{supported, []}, contact|Opts2]),
    
    % As the RURI is sips, it will be sent using sips, even if our Route is sip
    % server1 detects nksip2 is a domain for server2, and routes to there
    % client2 answers
    Fs1 = {meta, [remote, <<"x-nk-id">>]},
    {ok, 200, Values1} = nksip_uac:options(C1, "sips:client2@nksip2", [Fs1]),
    [
        {remote, {tls, {127,0,0,1}, 5061, <<>>}},
        {_, [<<"client2,server2,server1">>]}
    ] = Values1,

    % Sent to server2 using sips because of Opts2
    {ok, 200, Values2} = nksip_uac:options(C2, "sip:client1@nksip", [Fs1|Opts2]),
    [
        {remote, {tls, {127,0,0,1}, 5081, <<>>}},
        {_, [<<"client1,server1,server2">>]}
    ] = Values2,


    % Test a dialog through 2 proxies without Record-Route
    Fs3 = {meta, [<<"contact">>, <<"x-nk-id">>]},
    {ok, 200, Values3} = nksip_uac:invite(C1, "sips:client2@nksip2", 
                                            [Fs3, {add, "x-nk-op", ok}, RepHd]),
    [
        {dialog_id, DialogIdA1},
        {<<"contact">>, [C2Contact]},
        {<<"x-nk-id">>, [<<"client2,server2,server1">>]}
    ] = Values3,
    [#uri{port=C2Port}] = nksip_parse:uris(C2Contact),

    % ACK is sent directly
    {req, #sipmsg{ruri=#uri{scheme=sips, port=C2Port}}} = 
        nksip_uac:ack(C1, DialogIdA1, [get_request, RepHd]),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % OPTIONS is also sent directly
    Fs4 = {meta, [remote, <<"x-nk-id">>]},
    {ok, 200, Values4} = nksip_uac:options(C1, DialogIdA1, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, _, <<>>}},
        {<<"x-nk-id">>, [<<"client2">>]}
    ] = Values4,

    DialogIdA2 = nksip_dialog:field(C1, DialogIdA1, remote_id),
    {ok, 200, Values5} = nksip_uac:options(C2, DialogIdA2, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, 5071, <<>>}},
        {<<"x-nk-id">>, [<<"client1">>]}
    ] = Values5,

    {ok, 200, []} = nksip_uac:bye(C1, DialogIdA1, []),
    ok = tests_util:wait(Ref, [{client2, bye}]),

    % Test a dialog through 2 proxies with Record-Route
    Hds6 = [{add, "x-nk-op", ok}, {add, "x-nk-rr", true}, RepHd],
    Fs6 = {meta, [<<"record-route">>, <<"x-nk-id">>]},
    {ok, 200, Values6} = nksip_uac:invite(C1, "sips:client2@nksip2", [Fs6|Hds6]),
    [
        {dialog_id, DialogIdB1},
        {<<"record-route">>, [RR1, RR2]},
        {<<"x-nk-id">>, [<<"client2,server2,server1">>]}
    ] = Values6,
    [#uri{port=5081, opts=[{<<"transport">>, <<"tls">>}, <<"lr">>]}] = 
        nksip_parse:uris(RR1),
    [#uri{port=5061, opts=[{<<"transport">>, <<"tls">>}, <<"lr">>]}] =
        nksip_parse:uris(RR2),

    % Sends an options in the dialog before the ACK
    {ok, 200, Values7} = nksip_uac:options(C1, DialogIdB1, [Fs4]),
    [
        {remote, {tls, _, 5061, <<>>}},
        {<<"x-nk-id">>, [<<"client2,server2,server1">>]}
    ] = Values7,

    {req, AckReq} = nksip_uac:ack(C1, DialogIdB1, [get_request]),
    {tls, _, 5061, <<>>} = nksip_sipmsg:field(AckReq, remote),
    [
        #uri{scheme=sip, domain = <<"localhost">>, port=5061,
             opts=[{<<"transport">>,<<"tls">>},<<"lr">>]},
        #uri{scheme=sip, domain = <<"localhost">>, port=5081,
             opts=[{<<"transport">>,<<"tls">>},<<"lr">>]}
    ] = nksip_sipmsg:header(AckReq, <<"route">>, uris),
    ok = tests_util:wait(Ref, [{client2, ack}]),
 
    DialogIdB2 = nksip_dialog:field(C1, DialogIdB1, remote_id),
    Fs8 = {meta, [<<"x-nk-id">>]},
    {ok, 200, Values8} = nksip_uac:options(C2, DialogIdB2, [Fs8]),
    [{<<"x-nk-id">>, [<<"client1,server1,server2">>]}] = Values8,
    {ok, 200, []} = nksip_uac:bye(C2, DialogIdB2, [{add, "x-nk-rr", true}]),
    ok.


dialog() ->
    C1 = {stateful, client1},
    C2 = {stateful, client2},
    S1 = {stateful, server1},
    Ref = make_ref(),
    Self = self(),
    RepHd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))},
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, Values1} = nksip_uac:invite(C1, "sip:client2@nksip",
                                [{add, "x-nk-op", "answer"}, {add, "x-nk-rr", true}, 
                                  RepHd, {body, SDP}]),
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

    {ok, 200, []} = nksip_uac:bye(C2, DialogId2, [{add, "x-nk-rr", true}]),
    error = nksip_dialog:field(C1, DialogId1, status),
    error = nksip_dialog:field(C2, DialogId2, status),
    error = nksip_dialog:field(S1, DialogId1, status),
    ok.

