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

    {ok, _} = nksip:start({Test, server1}, ?MODULE, {Test, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    {ok, _} = nksip:start({Test, server2}, ?MODULE, {Test, server2}, [
        {from, "sip:server2@nksip"},
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    {ok, _} = nksip:start({Test, client1}, ?MODULE, {Test, client1}, [
        {from, "sip:client1@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    {ok, _} = nksip:start({Test, client2}, ?MODULE, {Test, client2}, [
        {from, "sip:client2@nksip"},
        {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, any}, {tls, all, any}]}
    ]),

    tests_util:log(),
    ok.


stop(Test) ->
    ok = nksip:stop({Test, server1}),
    ok = nksip:stop({Test, server2}),
    ok = nksip:stop({Test, client1}),
    ok = nksip:stop({Test, client2}).


invalid(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    S1 = {Test, server1},

    % Request arrives at server1; it has no user, and domain belongs to it,
    % so it orders to process it (statelessly or statefully depending on Test)
    {ok, 200, [{call_id, CallId1}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1", [contact, {meta, [call_id]}]),
    % The UAC has generated a transaction
    {ok, C1Id} = nksip:find_app(C1),
    [{uac, _}] = nksip_call_router:get_all_transactions(C1Id, CallId1),
    case Test of
        stateless -> 
            {ok, S1Id} = nksip:find_app(S1),
            [] = nksip_call_router:get_all_transactions(S1Id, CallId1);
        stateful -> 
            {ok, S1Id} = nksip:find_app(S1),
            [{uas, _}] = 
                nksip_call_router:get_all_transactions(S1Id, CallId1)
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
    [] = nksip_call_router:get_all_transactions(S1Id, CallId3),

    % Force Forwards=0 using REGISTER
    CallId4 = nksip_lib:luid(),
    Work4 = {make, 'REGISTER', "sip:any", []},
    {ok, C1Id} = nksip:find_app(C1),
    {ok, Req4, Opts4} = nksip_call_router:send_work_sync(C1Id, CallId4, Work4),
    {ok, 483, _} = nksip_call:send(Req4#sipmsg{forwards=0}, Opts4),

    % Force Forwards=0 using OPTIONS. Server will reply
    CallId5 = nksip_lib:luid(),
    Work5 = {make, 'OPTIONS', "sip:any", []},
    {ok, Req5, Opts5} = nksip_call_router:send_work_sync(C1Id, CallId5, Work5),
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
            {tcp, {127,0,0,1}, LP, <<>>} = nksip_sipmsg:meta(local, Req3),
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
            {tcp, {127,0,0,1}, LPort, <<>>} = nksip_sipmsg:meta(local, ReqId5)
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
    
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
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
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [180, {C2, ack}]),

    % Several in-dialog requests
    {ok, 200, [{<<"x-nk-id">>, [<<"client2">>]}]} = 
        nksip_uac:options(DialogId1, [{meta,[<<"x-nk-id">>]}]),
    DialogId2 = nksip_dialog:remote_id(DialogId1, {Test, client2}),
    {ok, 200, [{<<"x-nk-id">>, [<<"client1">>]}]} = 
        nksip_uac:options(DialogId2, [{meta,[<<"x-nk-id">>]}]),
    
    {ok, 200, [{dialog_id, DialogId1}, {<<"x-nk-id">>, [<<"client2">>]}]} = 
        nksip_uac:invite(DialogId1, [{add, "x-nk-op", ok},
                                         {meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{{Test, client2}, ack}]),

    {ok, 200, [{dialog_id, DialogId2}, {<<"x-nk-id">>, [<<"client1">>]}]} = 
        nksip_uac:invite(DialogId2, [{add, "x-nk-op", ok}, RepHd,     
                                         {meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(DialogId2, []),
    ok = tests_util:wait(Ref, [{C1, ack}]),
    {ok, 200, []} = nksip_uac:bye(DialogId1, []),

    % Cancelled request
    {async, ReqId7} = nksip_uac:invite(C1, "sip:client2@nksip", 
                                        [{add, "x-nk-op", ok}, {add, "x-nk-sleep", 5000}, RepHd,
                                         async, {callback, RespFun}]),
    ok = nksip_uac:cancel(ReqId7),
    ok = tests_util:wait(Ref, [487, {{Test, client2}, bye}]),
    ok.

servers(Test) ->
    C1 = {Test, client1},
    C2 = {Test, client2},
    {Ref, RepHd} = tests_util:get_ref(),

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
        nksip_uac:ack(DialogIdA1, [get_request, RepHd]),
    ok = tests_util:wait(Ref, [{C2, ack}]),

    % OPTIONS is also sent directly
    Fs4 = {meta, [remote, <<"x-nk-id">>]},
    {ok, 200, Values4} = nksip_uac:options(DialogIdA1, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, _, <<>>}},
        {<<"x-nk-id">>, [<<"client2">>]}
    ] = Values4,

    DialogIdA2 = nksip_dialog:remote_id(DialogIdA1, C2),
    {ok, 200, Values5} = nksip_uac:options(DialogIdA2, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, 5071, <<>>}},
        {<<"x-nk-id">>, [<<"client1">>]}
    ] = Values5,

    {ok, 200, []} = nksip_uac:bye(DialogIdA1, []),
    ok = tests_util:wait(Ref, [{C2, bye}]),

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
    {ok, 200, Values7} = nksip_uac:options(DialogIdB1, [Fs4]),
    [
        {remote, {tls, _, 5061, <<>>}},
        {<<"x-nk-id">>, [<<"client2,server2,server1">>]}
    ] = Values7,

    {req, AckReq} = nksip_uac:ack(DialogIdB1, [get_request]),
    {tls, _, 5061, <<>>} = nksip_sipmsg:meta(remote, AckReq),
    [
        #uri{scheme=sip, domain = <<"localhost">>, port=5061,
             opts=[{<<"transport">>,<<"tls">>},<<"lr">>]},
        #uri{scheme=sip, domain = <<"localhost">>, port=5081,
             opts=[{<<"transport">>,<<"tls">>},<<"lr">>]}
    ] = nksip_sipmsg:header(<<"route">>, AckReq, uris),
    ok = tests_util:wait(Ref, [{C2, ack}]),
 
    DialogIdB2 = nksip_dialog:remote_id(DialogIdB1, C2),
    Fs8 = {meta, [<<"x-nk-id">>]},
    {ok, 200, Values8} = nksip_uac:options(DialogIdB2, [Fs8]),
    [{<<"x-nk-id">>, [<<"client1,server1,server2">>]}] = Values8,
    {ok, 200, []} = nksip_uac:bye(DialogIdB2, [{add, "x-nk-rr", true}]),
    ok.


dialog() ->
    C1 = {stateful, client1},
    C2 = {stateful, client2},
    S1 = {stateful, server1},
    {Ref, RepHd} = tests_util:get_ref(),
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, Values1} = nksip_uac:invite(C1, "sip:client2@nksip",
                                [{add, "x-nk-op", "answer"}, {add, "x-nk-rr", true}, 
                                  RepHd, {body, SDP}]),
    [{dialog_id, DialogId1}] = Values1,
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{{stateful, client2}, ack}]),

    DialogId2 = nksip_dialog:remote_id(DialogId1, {stateful, client2}),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),

    [
        {app_name, C1}, 
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
        nksip_dialog:fields(DialogId1, 
                [app_name, invite_status, local_seq, remote_seq, parsed_local_uri, 
                 parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                 invite_local_sdp, invite_remote_sdp, parsed_route_set]),

    #uri{user = <<"client1">>, domain = <<"nksip">>} = LUri, 
    #uri{user = <<"client2">>, domain = <<"nksip">>} = RUri, 
    #uri{user = <<"client1">>, domain = <<"127.0.0.1">>, port=5070} = LTarget, 
    #uri{user = <<"client2">>, domain = <<"127.0.0.1">>, port=_Port} = RTarget, 

    [
        {app_name, C2},
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
        nksip_dialog:fields(DialogId2,
                [app_name, invite_status, local_seq, remote_seq, parsed_local_uri, 
                 parsed_remote_uri, parsed_local_target, parsed_remote_target, 
                 invite_local_sdp, invite_remote_sdp, parsed_route_set]),
    
    % DialogId1 is refered to client1. DialogID1S will refer to server1
    DialogId1S = nksip_dialog:change_app(DialogId1, S1),
    [
        {app_name, S1},
        {invite_status, confirmed},
        {parsed_local_uri, LUri},
        {parsed_remote_uri, RUri},
        {parsed_local_target, LTarget},
        {parsed_remote_target, RTarget},
        {invite_local_sdp, LSDP},
        {invite_remote_sdp, RSDP},
        {parsed_route_set, []}          % The first route is deleted (it is itself)
    ] =
        nksip_dialog:fields(DialogId1S, 
            [app_name, invite_status, parsed_local_uri, parsed_remote_uri,
             parsed_local_target, parsed_remote_target, invite_local_sdp, 
             invite_remote_sdp, parsed_route_set]),

    {ok, 200, []} = nksip_uac:bye(DialogId2, [{add, "x-nk-rr", true}]),
    error = nksip_dialog:meta(status, DialogId1),
    error = nksip_dialog:meta(status, DialogId2),
    error = nksip_dialog:meta(status, DialogId1S),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    Domains = case Id of
        {_, server1} -> [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>];
        {_, server2} -> [<<"nksip2">>, <<"127.0.0.1">>, <<"[::1]">>];
        _ -> []
    end,
    ok = nksip:put(Id, domains, Domains),
    {ok, Id}.


route(ReqId, Scheme, User, Domain, _From, {Test, Id}=AppId=State) 
        when Id==server1; Id==server2 ->
    Opts = [
        case Test of stateless -> stateless; _ -> ignore end,
        {insert, "x-nk-id", Id},
        case nksip_request:header(<<"x-nk-rr">>, ReqId) of
            [<<"true">>] -> record_route;
            _ -> ignore
        end
    ],
    {ok, Domains} = nksip:get(AppId, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            {reply, {process, Opts}, State};
        true when User =:= <<"client2_op">>, Domain =:= <<"nksip">> ->
            UriList = nksip_registrar:find(AppId, sip, <<"client2">>, Domain),
            Body = nksip_request:body(ReqId),
            ServerOpts = binary_to_term(base64:decode(Body)),
            {reply, {proxy, UriList, ServerOpts++Opts}, State};
        true when Domain =:= <<"nksip">>; Domain =:= <<"nksip2">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> 
                    % ?P("FIND ~p: []", [{AppId, Scheme, User, Domain}]),
                    {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        true ->
            {reply, {proxy, ruri, Opts}, State};
        false when Domain =:= <<"nksip">> ->
            {reply, {proxy, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]}, State};
        false when Domain =:= <<"nksip2">> ->
            {reply, {proxy, ruri, [{route, "<sips:127.0.0.1:5081;lr>"}|Opts]}, State};
        false ->
            {reply, {proxy, ruri, Opts}, State}
    end;

route(_, _, _, _, _, State) ->
    {reply, process, State}.



invite(ReqId, Meta, From, {_Test, Id}=AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Values = nksip_request:header(<<"x-nk">>, ReqId),
    Routes = nksip_request:header(<<"route">>, ReqId),
    Ids = nksip_request:header(<<"x-nk-id">>, ReqId),
    Hds = [
        case Values of [] -> ignore; _ -> {add, "x-nk", nksip_lib:bjoin(Values)} end,
        case Routes of [] -> ignore; _ -> {add, "x-nk-r", nksip_lib:bjoin(Routes)} end,
        {add, "x-nk-id", nksip_lib:bjoin([Id|Ids])}
    ],
    Op = case nksip_request:header(<<"x-nk-op">>, ReqId) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    Sleep = case nksip_request:header(<<"x-nk-sleep">>, ReqId) of
        [Sleep0] -> nksip_lib:to_integer(Sleep0);
        _ -> 0
    end,
    Prov = case nksip_request:header(<<"x-nk-prov">>, ReqId) of
        [<<"true">>] -> true;
        _ -> false
    end,
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(ringing, ReqId); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip:reply(From, {ok, Hds});
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip:reply(From, {ok, [{body, SDP}|Hds]});
                <<"busy">> ->
                    nksip:reply(From, busy);
                <<"increment">> ->
                    DialogId = nksip_lib:get_value(dialog_id, Meta),
                    SDP1 = nksip_dialog:meta(invite_local_sdp, DialogId),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {ok, [{body, SDP2}|Hds]});
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State}.



reinvite(ReqId, Meta, From, State) ->
    invite(ReqId, Meta, From, State).


ack(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, ack),
    {reply, ok, State}.


bye(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, bye),
    {reply, ok, State}.


options(ReqId, _Meta, _From, {_Test, Id}=State) ->
    Values = nksip_request:header(<<"x-nk">>, ReqId),
    Ids = nksip_request:header(<<"x-nk-id">>, ReqId),
    Routes = nksip_request:header(<<"route">>, ReqId),
    Hds = [
        case Values of [] -> ignore; _ -> {add, "x-nk", nksip_lib:bjoin(Values)} end,
        case Routes of [] -> ignore; _ -> {add, "x-nk-r", nksip_lib:bjoin(Routes)} end,
        {add, "x-nk-id", nksip_lib:bjoin([Id|Ids])}
    ],
    {reply, {ok, [contact|Hds]}, State}.

