%% -------------------------------------------------------------------
%%
%% websocket_test: Websocket Test Suite
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

-module(websocket_test).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


ws1_test_() ->
    {setup, spawn, 
        fun() -> start1() end,
        fun(_) -> stop1() end,
        [
            fun webserver/0
        ]
    }.


start1() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(ws_a, [
        {callback, ?MODULE},
        {transports, [
            "<sip:all:8090;transport=ws>",
            "<sip:all:8091;transport=wss>",
            "<sip:all/ws;transport=ws>"
        ]}
    ]),

    {ok, _} = nksip:start(ws_b, [
        {callback, ?MODULE},
        {transports, [
            "<sip:all:8090;transport=ws>",
            "<sip:all/ws:8092;transport=ws>"
            % {wss, all, 8092, [{dispatch, [{'_', ["/ws"]}]}]}
        ]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

webserver() ->
    {ok, WsA} = nkservice_server:find(ws_a),
    {ok, WsB} = nkservice_server:find(ws_b),
    [
        {#nkport{transp=ws, local_port=0, listen_port=_LP}, _},
        {#nkport{transp=ws, local_port=8090, listen_port=8090}, _},
        {#nkport{transp=wss, local_port=8091, listen_port=8091}, _}
    ] = 
        lists:sort(nksip_transport:get_all(WsA)),

    [
        {#nkport{transp=ws, local_port=8090, listen_port=8090}, _},
        {#nkport{transp=wss, local_port=8092, listen_port=8092}, _}
    ] = 
        lists:sort(nksip_transport:get_all(WsB)),

    [
        {ws,{0,0,0,0},0},
        {ws,{0,0,0,0},8090},
        {wss,{0,0,0,0},8091},
        {wss,{0,0,0,0},8092}
    ] = 
        lists:sort(nksip_webserver_sup:get_all()),

    nksip:stop(WsA),
    timer:sleep(100),
    [] = nksip_transport:get_all(WsA),
    [{ws,{0,0,0,0},8090},{wss,{0,0,0,0},8092}] = 
        lists:sort(nksip_webserver_sup:get_all()),

    nksip:stop(WsB),
    timer:sleep(100),
    [] = nksip_transport:get_all(WsB),
    [] = lists:sort(nksip_webserver_sup:get_all()),
    ok.

stop1() ->
    ok.


ws2_test_() ->
    {setup, spawn, 
        fun() -> start2() end,
        fun(_) -> stop2() end,
        [
            fun basic/0, 
            fun sharing/0,
            fun proxy/0
        ]
    }.


start2() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(server1, [
        {callback, ?MODULE},
        {from, "\"NkSIP Server\" <sip:server1@nksip>"},
        {plugins, [nksip_registrar, nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, [
            "sip:all:5060",
            "<sip:all:5061;transport=tls>",
            "<sip:all:8080;transport=ws>;listeners=10",
            "<sip:all/wss:8081;transport=wss>"
        ]}
    ]),

    {ok, _} = nksip:start(ua1, [
        {callback, ?MODULE},
        {from, "\"NkSIP Client\" <sip:client1@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]}
    ]),

    {ok, _} = nksip:start(ua2, [
        {callback, ?MODULE},
        {from, "<sip:client2@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, "sip:all;transport=ws, sip:all:8091;transport=wss"}
    ]),

    {ok, _} = nksip:start(ua3, [
        {callback, ?MODULE},
        {from, "<sip:client3@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "invalid.invalid"},
        {transports, "sip:all/client3:8080;transport=ws"}
    ]),

    tests_util:log().


stop2() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2),
    ok = nksip:stop(ua3),
    ok.


basic() ->
    {ok, UA2} = nkservice_server:find(ua2),
    {ok, S1} = nkservice_server:find(server1),

    [] = nksip_transport:get_all_connected(S1),
    [] = nksip_transport:get_all_connected(UA2),

    {ok, 200, Values1} = nksip_uac:options(ua2, 
                         "<sip:localhost:8080/;transport=ws>", 
                         [{meta, [vias, local, remote]}]),

    [
        {_, [#via{transp=ws, domain = <<"localhost">>, port=Port1}]},
        {_, {ws, {127,0,0,1}, Port2, <<"/">>}},
        {_, {ws, {127,0,0,1}, 8080, <<"/">>}}
    ] = Values1,

    [
        {#nkport{
            transp = ws,
            local_ip = {127,0,0,1},
            local_port = Port2,
            remote_ip = {127,0,0,1},
            remote_port = 8080,
            listen_ip = {0,0,0,0},
            listen_port = Port1
        }, Pid1}
    ] = nksip_transport:get_all_connected(UA2),

    [
        {#nkport{
            transp = ws,
            local_ip = {0,0,0,0},
            local_port = 8080,
            remote_ip = {127,0,0,1},
            remote_port = Port2,
            listen_ip = {0,0,0,0},
            listen_port = 8080
        }, Pid2}
    ] = nksip_transport:get_all_connected(S1),

    % If we send another request, it is going to use the same transport
    {ok, 200, []} = nksip_uac:options(ua2, "<sip:localhost:8080/;transport=ws>", []),
    [{_, Pid1}] = nksip_transport:get_all_connected(UA2),
    [{_, Pid2}] = nksip_transport:get_all_connected(S1),

    % Now with SSL, but the path is incorrect
    {error, service_unavailable} =  nksip_uac:options(ua2, 
                                            "<sips:localhost:8081/;transport=ws>", []),

    {ok, 200, Values2} = nksip_uac:options(ua2, 
                         "<sips:localhost:8081/wss;transport=ws>", 
                         [{meta, [vias, local, remote]}]),

    [
        {_, [#via{transp=wss, domain = <<"localhost">>, port=8091}]},
        {_, {wss, {127,0,0,1}, Port3, <<"/wss">>}},
        {_, {wss, {127,0,0,1}, 8081, <<"/wss">>}}
    ] = Values2,

    [
        {_, Pid1},
        {#nkport{
            transp = wss,
            local_ip = {127,0,0,1},
            local_port = Port3,
            remote_ip = {127,0,0,1},
            remote_port = 8081,
            listen_ip = {0,0,0,0},
            listen_port = 8091
        }, Pid3}
    ] = lists:sort(nksip_transport:get_all_connected(UA2)),

    [
        {_, Pid2},
        {#nkport{
            transp = wss,
            local_ip = {0,0,0,0},
            local_port = 8081,
            remote_ip = {127,0,0,1},
            remote_port = Port3,
            listen_ip = {0,0,0,0},
            listen_port = 8081
        }, Pid4}
    ] = lists:sort(nksip_transport:get_all_connected(S1)),

    [nksip_connection:stop(Pid, normal) || Pid <- [Pid1,Pid2,Pid3,Pid4]],
    ok.


sharing() ->
    % Server1 must answer
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(ua2, "<sip:localhost:8080/;transport=ws>", 
                                      [{meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8080} = S1C,

    {error, service_unavailable} = nksip_uac:options(ua2, 
                                    "<sip:localhost:8080/other;transport=ws>", []),

    % Client3 must answer
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options(ua2, 
                                            "<sip:localhost:8080/client3;transport=ws>", 
                                            [{meta, [contacts]}]),
    #uri{domain = <<"invalid.invalid">>, port=8080} = C3C,
    
    % Client2 must unswer
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options(server1,
                                            "<sips:localhost:8091/;transport=ws>", 
                                            [{meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8091} = C2C,
    ok.


proxy() ->
    {ok, 200, []} = 
        nksip_uac:register(ua2, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [unregister_all]),
    {ok, 200, []} = 
        nksip_uac:register(ua3, "<sip:127.0.0.1:8080;transport=ws>", 
                           [unregister_all]),

    
    % UA2 registers with the registrar, using WSS
    {ok, 200, []} = 
        nksip_uac:register(ua2, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [contact]),

    % Using or public GRUU, UA1 (without websocket support) is able to reach us
    {ok, C2Pub} = nksip_gruu:get_gruu_pub(ua2),
    {ok, 200, [{_, [<<"ua2">>]}]} = 
        nksip_uac:options(ua1, C2Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}, {meta, [<<"x-nk-id">>]}]),

    % The same with our private GRUU
    {ok, C2Priv} = nksip_gruu:get_gruu_temp(ua2),
    {ok, 200, [{_, [<<"ua2">>]}]} = 
        nksip_uac:options(ua1, C2Priv, 
                          [{route, "<sip:127.0.0.1;lr>"}, {meta, [<<"x-nk-id">>]}]),


    % UA3 registers. Its contact is not routable
    {ok, 200, [{_, [C3Contact]}]} = 
        nksip_uac:register(ua3, "<sip:127.0.0.1:8080;transport=ws>", 
                           [contact, {meta, [contacts]}]),
    #uri{domain = <<"invalid.invalid">>} = C3Contact,
    
    {ok, C3Pub} = nksip_gruu:get_gruu_pub(ua3),
    {ok, 200, [{_, [<<"ua3">>]}]} = 
        nksip_uac:options(ua1, C3Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}, {meta, [<<"x-nk-id">>]}]),

    {ok, C3Priv} = nksip_gruu:get_gruu_temp(ua3),
    {ok, 200, [{_, [<<"ua3">>]}]} = 
        nksip_uac:options(ua1, C3Priv, 
                          [{route, "<sip:127.0.0.1;lr>"}, {meta, [<<"x-nk-id">>]}]),


    % Let's stop the transports
    [nksip_connection:stop(Pid, normal) || 
        {_, Pid} <- nksip_transport:get_all_connected(element(2, nkservice_server:find(server1)))],
    timer:sleep(100),

    {ok, 430, []} = nksip_uac:options(ua1, C2Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),

    {ok, 430, []} = nksip_uac:options(ua1, C3Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(#{name:=Id}, State) ->
    ok = nkservice_server:put(Id, domains, [<<"localhost">>, <<"127.0.0.1">>, <<"nksip">>]),
    {ok, State}.


sip_route(_Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        {ok, server1} ->
            Opts = [record_route, {insert, "x-nk-server", "server1"}],
            Domains = nkservice_server:get(server1, domains),
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    process;
                true when Domain =:= <<"nksip">> ->
                    {ok, RUri} = nksip_request:meta(ruri, Req),
                    case nksip_gruu:registrar_find(server1, RUri) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy, UriList, Opts}
                    end;
                _ ->
                    {proxy, ruri, Opts}
            end;
        _ ->
            process
    end.


sip_options(Req, _Call) ->
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, App} = nksip_request:srv_name(Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([App|Ids])}],
    {reply, {ok, [contact|Hds]}}.

