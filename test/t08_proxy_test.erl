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

-module(t08_proxy_test).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).
-define(RECV(T), receive T -> T after 1000 -> error(recv) end).

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
            fun() -> invalid() end,
            fun() -> opts() end,
            fun() -> transport() end, 
            fun() -> invite() end,
            fun() -> servers() end
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
            fun() -> invalid() end,
            fun() -> opts() end,
            fun() -> transport() end, 
            fun() -> invite() end,
            fun() -> servers() end,
            fun() -> dialog() end
        ]
    }.


all() ->
    start(stateful),
    timer:sleep(1000),
    invalid(),
    opts(),
    transport(),
    invite(),
    servers(),
    dialog(),
    stop(stateful),

    timer:sleep(1000),
    start(stateless),
    timer:sleep(100),
    invalid(),
    opts(),
    transport(),
    invite(),
    servers(),
    stop(stateless).


start(Test) ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(proxy_test_server1, #{
        test_type => Test,
        sip_from => "sip:proxy_test_server1@nksip",
        sip_local_host => "localhost",
        sip_supported => "100rel,timer,path",        % No outboud
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),

    {ok, _} = nksip:start_link(proxy_test_server2, #{
        test_type => Test,
        sip_from => "sip:proxy_test_server2@nksip",
        sip_local_host => "localhost",
        sip_supported => "100rel,timer,path",        % No outboud
        plugins => [nksip_registrar],
        sip_listen => "<sip:all:5080>,<sip:all:5081;transport=tls>"
    }),

    {ok, _} = nksip:start_link(proxy_test_client1, #{
        test_type => Test,
        sip_from => "sip:proxy_test_client1@nksip",
        sip_route => "<sip:127.0.0.1;lr>",
        sip_local_host => "127.0.0.1",
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    {ok, _} = nksip:start_link(proxy_test_client2, #{
        test_type => Test,
        sip_from => "sip:proxy_test_client2@nksip",
        sip_route => "<sip:127.0.0.1;lr>",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all, sips:all"
    }),

    tests_util:log(),
    ok.


stop(_) ->
    ok = nksip:stop(proxy_test_server1),
    ok = nksip:stop(proxy_test_server2),
    ok = nksip:stop(proxy_test_client1),
    ok = nksip:stop(proxy_test_client2).


invalid() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    S1 = proxy_test_server1,
    #{test_type:=Test} = ?CALL_PKG(S1, config, []),

    % Request arrives at proxy_test_server1; it has no user, and domain belongs to it,
    % so it orders to process it (statelessly or statefully depending on Test)
    {ok, 200, [{call_id, CallId1}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1", [contact, {get_meta, [call_id]}]),
    % The UAC has generated a transaction
    {ok, [{uac, _}]} = nksip_call:get_all_transactions(C1, CallId1),
    case Test of
        stateless -> 
            {ok, []} = nksip_call:get_all_transactions(S1, CallId1);
        stateful -> 
            {ok, [{uas, _}]} =
                nksip_call:get_all_transactions(S1, CallId1)
    end,

    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),

    % client@nksip is registered by C2, but it will fail because of Proxy-Require
    Opts3 = [
        {add, "proxy-require", "a, b;c=1,d"},
        {get_meta, [call_id, <<"unsupported">>]}
    ],
    {ok, 420, [{call_id, CallId3}, {<<"unsupported">>, [<<"a,b,d">>]}]} = 
        nksip_uac:options(C1, "sip:proxy_test_client2@nksip", Opts3),
    
    % The 420 response is always stateless
    {ok, []} = nksip_call:get_all_transactions(S1, CallId3),

    % Force Forwards=0 using REGISTER
    {ok, Req4, Opts4} = nksip_call_uac_make:make(C1, 'REGISTER', "sip:any", <<"callid">>, []),
    {ok, 483, _} = nksip_call:send(Req4#sipmsg{forwards=0}, Opts4),

    % Force Forwards=0 using OPTIONS. Server will reply
    {ok, Req5, Opts5} = nksip_call_uac_make:make(C1, 'OPTIONS', "sip:any", <<"callid">>, []),
    {ok, 200, [{reason_phrase, <<"Max Forwards">>}]} = 
        nksip_call:send(Req5#sipmsg{forwards=0}, [{get_meta,[reason_phrase]}|Opts5]),


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


opts() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    #{test_type:=Test} = ?CALL_PKG(C1, config, []),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),
    
    % Server1 proxies the request to proxy_test_client2@nksip using ServerOpts1 options:
    % two "x-nk" headers are added
    ServerOpts1 = [{insert, "x-nk", "server"}, {insert, "x-nk", Test}],
    Body1 = base64:encode(term_to_binary(ServerOpts1)),
    Opts1 = [{insert, "x-nk", "opts2"}, {body, Body1}, {get_meta, [<<"x-nk">>]}],
    {ok, 200, Values1} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts1),
    Res1Rep = list_to_binary([atom_to_list(Test), ",server,opts2"]),
    [{<<"x-nk">>, [Res1Rep]}] = Values1,

    % Remove headers at server
    ServerOpts2 = [{replace, "x-nk", "server"}],
    Body2 = base64:encode(term_to_binary(ServerOpts2)),
    Opts2 = [{insert, "x-nk", "opts2"}, {body, Body2}, {get_meta, [<<"x-nk">>]}],
    {ok, 200, Values2} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts2),
    [{<<"x-nk">>, [<<"server">>]}] = Values2,
    
    % Add a route at server
    ServerOpts3 = [{insert, "x-nk", "proxy_test_server2"},
                    {route, "<sip:127.0.0.1:5070;lr>, <sip:1.2.3.4;lr>"}],
    Body3 = base64:encode(term_to_binary(ServerOpts3)),
    Opts3 = [{insert, "x-nk", "opts2"}, {body, Body3},
             {get_meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values3} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts3),
    [
        {<<"x-nk">>, [<<"proxy_test_server2,opts2">>]},
        {<<"x-nk-r">>, [<<"<sip:127.0.0.1:5070;lr>,<sip:1.2.3.4;lr>">>]}
    ] = Values3,

    % Add a route from client
    ServerOpts4 = [],
    Body4 = base64:encode(term_to_binary(ServerOpts4)),
    [Uri2] = nksip_registrar:find(proxy_test_server1, sip, <<"proxy_test_client2">>, <<"nksip">>),
    Opts4 = [{route, 
                ["<sip:127.0.0.1;lr>", Uri2#uri{opts=[lr], ext_opts=[]}, <<"sip:aaa">>]},
             {body, Body4},
             {get_meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts4),
    NkR4 = nklib_util:bjoin([nklib_unparse:uri(Uri2#uri{opts=[lr], ext_opts=[]}),
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
             {get_meta, [<<"x-nk">>, <<"x-nk-r">>]}],
    {ok, 200, Values5} = nksip_uac:options(C1, "sip:client2_op@nksip", Opts5),
    [
        {<<"x-nk">>, []}, 
        {<<"x-nk-r">>, []}
    ] = Values5,

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.



transport() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),
    {ok, 200, [{<<"x-nk-id">>, [<<"proxy_test_client2,proxy_test_server1">>]}]} =
        nksip_uac:options(C1, "sip:proxy_test_client2@nksip", [{get_meta,[<<"x-nk-id">>]}]),
    {ok, 200, [{<<"x-nk-id">>, [<<"proxy_test_client1,proxy_test_server1">>]}]} =
        nksip_uac:options(C2, "sip:proxy_test_client1@nksip", [{get_meta,[<<"x-nk-id">>]}]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),

    % Register generating a TCP Contact
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1",
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, contact]),
    Ref = make_ref(),
    Self = self(),
    
    CB1 = fun
        ({req, Req1, _Call}) ->
            {ok, {tcp, {127,0,0,1}, LP1, <<>>}} = nksip_request:get_meta(local, Req1),
            Self ! {Ref, {cb1_1, LP1}};
        ({resp, 200, Resp1, _Call}) ->
            {ok, {tcp, {127,0,0,1}, 5060, <<>>}} = nksip_response:get_meta(remote, Resp1),
            Self ! {Ref, cb1_2}
    end,
    {async, _} = nksip_uac:register(C2, "sip:127.0.0.1",
                        [{route, "<sip:127.0.0.1;transport=tcp;lr>"}, contact,
                        async, {callback, CB1}, get_request]),

    {_, {cb1_1, LPort}} = ?RECV({Ref, {cb1_1, LPort1}}),
    _ = ?RECV({Ref, cb1_2}),

    % This request is sent using UDP, proxied using TCP
    {ok, 200, Values4} = nksip_uac:options(C1, "sip:proxy_test_client2@nksip",
        [{get_meta,[remote, <<"x-nk-id">>]}]),
    [
        {remote, {udp, {127,0,0,1}, 5060, <<>>}},
        {<<"x-nk-id">>, [<<"proxy_test_client2,proxy_test_server1">>]}
    ] = Values4,

    CB2 = fun
        ({req, Req2, _Call}) ->
            % Should reuse transport
            {tcp, {127,0,0,1}, LPort, <<>>} = nksip_sipmsg:get_meta(local, Req2),
            Self ! {Ref, cb2_1};
        ({resp, 200, Resp2, _Call}) ->
            {ok, [
                {local, {tcp, {127,0,0,1}, LPort, <<>>}},
                _, %{remote, {tcp, {127,0,0,1}, 5060, <<>>}},
                {<<"x-nk-id">>, [<<"proxy_test_client1,proxy_test_server1">>]}
            ]} = nksip_response:get_metas([local, remote, <<"x-nk-id">>], Resp2),
            Self ! {Ref, cb2_2}
    end,
    {async, _} = nksip_uac:options(C2, "sip:proxy_test_client1@nksip",
                                [{route, "<sip:127.0.0.1;transport=tcp;lr>"},
                                 async, {callback, CB2}, get_request]),

    _ = ?RECV({Ref, cb2_1}),
    _ = ?RECV({Ref, cb2_2}),

    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    ok.


invite() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),    
    
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    RespFun = fun({resp, Code, _Resp, _Call}) -> Self ! {Ref, Code} end,

    % Provisional 180 and Busy
    {ok, 486, []} = nksip_uac:invite(C1, "sip:proxy_test_client2@nksip",
                                     [{add, "x-nk-op", busy}, {add, "x-nk-prov", true},
                                      {callback, RespFun}]),
    ok = tests_util:wait(Ref, [180]),

    % Provisional 180 and 200
    {ok, 200, [{dialog, DialogId1}]} = 
        nksip_uac:invite(C1, "sip:proxy_test_client2@nksip",
                                [{add, "x-nk-op", ok}, {add, "x-nk-prov", true},
                                 {add, "x-nk-sleep", 100}, RepHd,
                                 {callback, RespFun}]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [180, {C2, ack}]),

    % Several in-dialog requests
    {ok, 200, [{<<"x-nk-id">>, [<<"proxy_test_client2">>]}]} =
        nksip_uac:options(DialogId1, [{get_meta,[<<"x-nk-id">>]}]),
    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, proxy_test_client2),
    {ok, 200, [{<<"x-nk-id">>, [<<"proxy_test_client1">>]}]} =
        nksip_uac:options(DialogId2, [{get_meta,[<<"x-nk-id">>]}]),
    
    {ok, 200, [{dialog, DialogId1}, {<<"x-nk-id">>, [<<"proxy_test_client2">>]}]} =
        nksip_uac:invite(DialogId1, [{add, "x-nk-op", ok},
                                         {get_meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{proxy_test_client2, ack}]),

    {ok, 200, [{dialog, DialogId2}, {<<"x-nk-id">>, [<<"proxy_test_client1">>]}]} =
        nksip_uac:invite(DialogId2, [{add, "x-nk-op", ok}, RepHd,     
                                         {get_meta, [<<"x-nk-id">>]}]),
    ok = nksip_uac:ack(DialogId2, []),
    ok = tests_util:wait(Ref, [{C1, ack}]),
    {ok, 200, []} = nksip_uac:bye(DialogId1, []),

    % Cancelled request
    {async, ReqId7} = nksip_uac:invite(C1, "sip:proxy_test_client2@nksip",
                                        [{add, "x-nk-op", ok}, {add, "x-nk-sleep", 2000}, RepHd,
                                         async, {callback, RespFun}]),
    % The CANCEL will be sent when the 100 response is received
    ok = nksip_uac:cancel(ReqId7, []),
    ok = tests_util:wait(Ref, [487, {proxy_test_client2, bye}]),
    ok.


servers() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),

    Opts2 = [{route, "<sips:127.0.0.1:5081;lr>"}, {from, "sips:proxy_test_client2@nksip2"}],
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", [unregister_all|Opts2]),
    % C1 is registered at server1, C2 is registered at server2
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    % Register with as 'sips'
    {ok, 200, []} = nksip_uac:register(C2, "sips:127.0.0.1:5081", [{supported, []}, contact|Opts2]),
    
    % As the ruri is 'sips', it will be sent using sips, even if our Route is sip
    % proxy_test_server1 detects nksip2 is a domain for proxy_test_server2, and routes to there
    % proxy_test_client2 answers
    Fs1 = {get_meta, [remote, <<"x-nk-id">>]},
    {ok, 200, Values1} = nksip_uac:options(C1, "sips:proxy_test_client2@nksip2", [Fs1]),

    [
        {remote, {tls, {127,0,0,1}, 5061, <<>>}},
        {_, [<<"proxy_test_client2,proxy_test_server2,proxy_test_server1">>]}
    ] = Values1,

    % Sent to proxy_test_server2 using sips because of Opts2
    {ok, 200, Values2} = nksip_uac:options(C2, "sip:proxy_test_client1@nksip", [Fs1|Opts2]),
    [
        {remote, {tls, {127,0,0,1}, 5081, <<>>}},
        {_, [<<"proxy_test_client1,proxy_test_server1,proxy_test_server2">>]}
    ] = Values2,


    % Test a dialog through 2 proxies without Record-Route
    Fs3 = {get_meta, [<<"contact">>, <<"x-nk-id">>]},
    {ok, 200, Values3} = nksip_uac:invite(C1, "sips:proxy_test_client2@nksip2",
                                            [Fs3, {add, "x-nk-op", ok}, RepHd]),
    [
        {dialog, DialogIdA1},
        {<<"contact">>, [C2Contact]},
        {<<"x-nk-id">>, [<<"proxy_test_client2,proxy_test_server2,proxy_test_server1">>]}
    ] = Values3,
    [#uri{port=C2Port}] = nklib_parse:uris(C2Contact),

    % ACK is sent directly
    AckFun1 = fun({req, #sipmsg{ruri=#uri{scheme=sips, port=C2Port_1}}, _Call}) ->
        C2Port_1 = C2Port,
        Self ! {Ref, ack1_ok}
    end,
    async = nksip_uac:ack(DialogIdA1, [async, {callback, AckFun1}, RepHd]),
    ok = tests_util:wait(Ref, [ack1_ok, {C2, ack}]),

    % OPTIONS is also sent directly
    Fs4 = {get_meta, [remote, <<"x-nk-id">>]},
    {ok, 200, Values4} = nksip_uac:options(DialogIdA1, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, _, <<>>}},
        {<<"x-nk-id">>, [<<"proxy_test_client2">>]}
    ] = Values4,

    DialogIdA2 = nksip_dialog_lib:remote_id(DialogIdA1, C2),
    {ok, 200, Values5} = nksip_uac:options(DialogIdA2, [Fs4]),
    [
        {remote, {tls, {127,0,0,1}, _, <<>>}},
        {<<"x-nk-id">>, [<<"proxy_test_client1">>]}
    ] = Values5,

    {ok, 200, []} = nksip_uac:bye(DialogIdA1, []),
    ok = tests_util:wait(Ref, [{C2, bye}]),

    % Test a dialog through 2 proxies with Record-Route
    Hds6 = [{add, "x-nk-op", ok}, {add, "x-nk-rr", true}, RepHd],
    Fs6 = {get_meta, [<<"record-route">>, <<"x-nk-id">>]},
    {ok, 200, Values6} = nksip_uac:invite(C1, "sips:proxy_test_client2@nksip2", [Fs6|Hds6]),
    [
        {dialog, DialogIdB1},
        {<<"record-route">>, [RR1, RR2]},
        {<<"x-nk-id">>, [<<"proxy_test_client2,proxy_test_server2,proxy_test_server1">>]}
    ] = Values6,
    [#uri{port=5081, opts=[{<<"transport">>, <<"tls">>}, <<"lr">>]}] =
        nklib_parse:uris(RR1),
    [#uri{port=5061, opts=[{<<"transport">>, <<"tls">>}, <<"lr">>]}] =
        nklib_parse:uris(RR2),

    % Sends an options in the dialog before the ACK
    {ok, 200, Values7} = nksip_uac:options(DialogIdB1, [Fs4]),
    [
        {remote, {tls, _, 5061, <<>>}},
        {<<"x-nk-id">>, [<<"proxy_test_client2,proxy_test_server2,proxy_test_server1">>]}
    ] = Values7,


    AckFun2 = fun({req, AckReq2, _Call}) ->
        [
            #uri{scheme=sip, domain = <<"localhost">>, port=5061,
                 opts=[{<<"transport">>,<<"tls">>},<<"lr">>]},
            #uri{scheme=sip, domain = <<"localhost">>, port=5081,
                 opts=[{<<"transport">>,<<"tls">>},<<"lr">>]}
        ] = nksip_sipmsg:header(<<"route">>, AckReq2, uris),
        {tls, _, 5061, <<>>} = nksip_sipmsg:get_meta(remote, AckReq2),
        Self ! {Ref, ack2_ok}
    end,
    async = nksip_uac:ack(DialogIdB1, [async, {callback, AckFun2}]),
    ok = tests_util:wait(Ref, [ack2_ok, {C2, ack}]),

    DialogIdB2 = nksip_dialog_lib:remote_id(DialogIdB1, C2),
    Fs8 = {get_meta, [<<"x-nk-id">>]},
    {ok, 200, Values8} = nksip_uac:options(DialogIdB2, [Fs8]),
    [{<<"x-nk-id">>, [<<"proxy_test_client1,proxy_test_server1,proxy_test_server2">>]}] = Values8,
    {ok, 200, []} = nksip_uac:bye(DialogIdB2, [{add, "x-nk-rr", true}]),
    ok.


dialog() ->
    C1 = proxy_test_client1,
    C2 = proxy_test_client2,
    S1 = proxy_test_server1,
    {Ref, RepHd} = tests_util:get_ref(),
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(C2, "sip:127.0.0.1", [contact]),

    SDP = nksip_sdp:new("proxy_test_client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    {ok, 200, Values1} = nksip_uac:invite(C1, "sip:proxy_test_client2@nksip",
                                [{add, "x-nk-op", "answer"}, {add, "x-nk-rr", true}, 
                                  RepHd, {body, SDP}]),
    [{dialog, DialogId1}] = Values1,
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{proxy_test_client2, ack}]),

    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, proxy_test_client2),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),

    {ok, [
        {invite_status, confirmed},
        {local_seq, LSeq}, 
        {remote_seq, RSeq}, 
        {local_uri, LUri}, 
        {remote_uri, RUri}, 
        {local_target, LTarget}, 
        {remote_target, RTarget}, 
        {invite_local_sdp, LSDP}, 
        {invite_remote_sdp, RSDP}, 
        {route_set, [#uri{domain = <<"localhost">>}]}
    ]} = 
        nksip_dialog:get_metas([
            invite_status, local_seq, remote_seq, local_uri, remote_uri,
            local_target, remote_target, invite_local_sdp, invite_remote_sdp, route_set],
            DialogId1),

    #uri{user = <<"proxy_test_client1">>, domain = <<"nksip">>} = LUri,
    #uri{user = <<"proxy_test_client2">>, domain = <<"nksip">>} = RUri,
    #uri{user = <<"proxy_test_client1">>, domain = <<"127.0.0.1">>, port=5070} = LTarget,
    #uri{user = <<"proxy_test_client2">>, domain = <<"127.0.0.1">>, port=_Port} = RTarget,

    {ok, [
        {invite_status, confirmed},
        {local_seq, RSeq},
        {remote_seq, LSeq},
        {local_uri, RUri},
        {remote_uri, LUri},
        {local_target, RTarget},
        {remote_target, LTarget},
        {invite_local_sdp, RSDP},
        {invite_remote_sdp, LSDP},
        {route_set, [#uri{domain = <<"localhost">>}]}
    ]} = 
        nksip_dialog:get_metas([
            invite_status, local_seq, remote_seq, local_uri, remote_uri,
            local_target, remote_target, invite_local_sdp, invite_remote_sdp, route_set],
            DialogId2),
    
    % DialogId1 is refered to proxy_test_client1. DialogID1S will refer to proxy_test_server1
    DialogId1S = nksip_dialog_lib:change_app(DialogId1, S1),
    {ok, [
        {invite_status, confirmed},
        {local_uri, LUri},
        {remote_uri, RUri},
        {local_target, LTarget},
        {remote_target, RTarget},
        {invite_local_sdp, LSDP},
        {invite_remote_sdp, RSDP},
        {route_set, []}          % The first route is deleted (it is itself)
    ]} =
        nksip_dialog:get_metas([
            invite_status, local_uri, remote_uri, local_target, remote_target,
            invite_local_sdp, invite_remote_sdp, route_set],
            DialogId1S),

    {ok, 200, []} = nksip_uac:bye(DialogId2, [{add, "x-nk-rr", true}]),
    {error, _} = nksip_dialog:get_meta(status, DialogId1),
    {error, _} = nksip_dialog:get_meta(status, DialogId2),
    {error, _} = nksip_dialog:get_meta(status, DialogId1S),
    ok.

