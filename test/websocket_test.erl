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


ws_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic1/0, 
            fun basic2/0, 
            fun sharing/0,
            fun proxy/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = tests_util:start(ws_a, ?MODULE, [
        {transports, [
            "<sip:all:8090;transport=ws>",
            "<sips:all:8091;transport=wss>",
            "<sip:all/ws;transport=ws>"
        ]}
    ]),

    ok = tests_util:start(ws_b, ?MODULE, [
        {transports, [
            "sip:all:8090;transport=ws",
            "sip:all:8092/ws;transport=wss"
        ]}
    ]),

    ok = tests_util:start(server1, ?MODULE, [
        {from, "\"NkSIP Server\" <sip:server1@nksip>"},
        {plugins, [nksip_registrar, nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, 
            "sip:all:5060, "
            "<sip:all:5061;transport=tls>, "
            "<sip:all:8080;transport=ws>;listeners=10, "
            "<sip:all:8081/wss;transport=wss>"
        }
    ]),

    ok = tests_util:start(ua1, ?MODULE, [
        {from, "\"NkSIP Client\" <sip:client1@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]}
    ]),

    ok = tests_util:start(ua2, ?MODULE, [
        {from, "<sip:client2@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "localhost"},
        {transports, "sip:all;transport=ws, sip:all:8091/ua2;transport=wss"}
    ]),

    ok = tests_util:start(ua3, ?MODULE, [
        {from, "<sip:client3@nksip>"},
        {plugins, [nksip_gruu, nksip_outbound]},
        {local_host, "invalid.invalid"},
        {transports, "sip:all:8080/client3;transport=ws"}
    ]),

    tests_util:log().


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2),
    ok = nksip:stop(ua3),
    ok.


basic1() ->
    {ok, WsA} = nkservice_server:get_srv_id(ws_a),
    {ok, WsB} = nkservice_server:get_srv_id(ws_b),
    
    [
        #nkport{transp=ws, local_port=8090, listen_port=8090,
                 meta=#{ws_proto:=<<"sip">>}},
        #nkport{transp=ws, local_port=_LP1, listen_port=_LP1,
                 meta=#{path:=<<"/ws">>, ws_proto:=<<"sip">>}}
    ] 
        = all_listeners(ws, WsA),

    [
        #nkport{transp=wss, local_port=8091, listen_port=8091, 
                meta=#{ws_proto:=<<"sip">>}}
    ]
        = all_listeners(wss, WsA),

    [
        #nkport{transp=ws, local_port=8090, listen_port=8090,
                 meta=#{ws_proto:=<<"sip">>}}
    ] 
        = L3 = all_listeners(ws, WsB),

    [
        #nkport{transp=wss, local_port=8092, listen_port=8092, 
                meta=#{path:=<<"/ws">>, ws_proto:=<<"sip">>}}
    ]
        = L4 = all_listeners(wss, WsB),

    nksip:stop(WsA),
    timer:sleep(100),
    [] = all_listeners(ws, WsA),
    [] = all_listeners(wss, WsA),
    L3 = all_listeners(ws, WsB),
    L4 = all_listeners(wss, WsB),

    nksip:stop(WsB),
    timer:sleep(100),
    [] = all_listeners(ws, WsB),
    [] = all_listeners(wss, WsB),
    ok.


basic2() ->
    % start2(),
    {ok, UA2} = nkservice_server:get_srv_id(ua2),
    {ok, S1} = nkservice_server:get_srv_id(server1),

    [] = all_connected(S1),
    [] = all_connected(UA2),

    {ok, 200, Values1} = nksip_uac:options(ua2, 
                         "<sip:localhost:8080/s1;transport=ws>", 
                         [{meta, [vias, local, remote]}]),

    [
        {vias, [#via{transp=ws, domain = <<"localhost">>, port=Port1}]},
        {local, {ws, {127,0,0,1}, Port2, <<"/s1">>}},
        {remote, {ws, {127,0,0,1}, 8080, <<"/s1">>}}
    ] = Values1,

    [
        #nkport{
            transp = ws,
            local_ip = {127,0,0,1},
            local_port = Port2,
            remote_ip = {127,0,0,1},
            remote_port = 8080,
            listen_ip = {0,0,0,0},
            listen_port = Port1,
            pid = Pid1,
            meta = #{path:=<<"/s1">>, host:=<<"localhost">>, ws_proto:=<<"sip">>}
        }
    ] = all_connected(UA2),

    [
        #nkport{
            transp = ws,
            local_ip = {0,0,0,0},
            local_port = 8080,
            remote_ip = {127,0,0,1},
            remote_port = Port2,
            listen_ip = {0,0,0,0},
            listen_port = 8080,
            pid = Pid2,
            meta = #{ws_proto:=<<"sip">>}
        }
    ] = all_connected(S1),

    % If we send another request, it is going to use the same transport
    {ok, 200, []} = nksip_uac:options(ua2, "<sip:localhost:8080/s1;transport=ws>", []),
    [#nkport{pid=Pid1}] = all_connected(UA2),
    [#nkport{pid=Pid2}] = all_connected(S1),

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
        #nkport{pid=Pid1},
        #nkport{
            transp = wss,
            local_ip = {127,0,0,1},
            local_port = Port3,
            remote_ip = {127,0,0,1},
            remote_port = 8081,
            listen_ip = {0,0,0,0},
            listen_port = 8091,
            pid = Pid3
        }
    ] = all_connected(UA2),

    [
        #nkport{pid=Pid2},
        #nkport{
            transp = wss,
            local_ip = {0,0,0,0},
            local_port = 8081,
            remote_ip = {127,0,0,1},
            remote_port = Port3,
            listen_ip = {0,0,0,0},
            listen_port = 8081,
            pid = Pid4
        }
    ] = all_connected(S1),

    [nkpacket_connection:stop(Pid, normal) || Pid <- [Pid1,Pid2,Pid3,Pid4]],
    ok.


sharing() ->
    % Server1 must answer
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(ua2, "<sip:localhost:8080/s1;transport=ws>", 
                                      [{meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8080} = S1C,
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(ua2, "<sip:localhost:"
                                                     "8080/s1/other/more;transport=ws>", 
                                      [{meta, [contacts]}]),

    %% Server is also listening on anything above /
    {ok, 200, [{_, [S1C]}]} = nksip_uac:options(ua2, 
                                    "<sip:localhost:8080/other;transport=ws>", 
                                    [{meta, [contacts]}]),

    % Client3 must answer (it takes more priority than /)
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options(ua2, 
                                            "<sip:localhost:8080/client3;transport=ws>", 
                                            [{meta, [contacts]}]),
    #uri{domain = <<"invalid.invalid">>, port=8080} = C3C,
    {ok, 200, [{_, [C3C]}]} = nksip_uac:options(ua2, 
                                            "<sip:localhost:8080/client3/more;transport=ws>", 
                                            [{meta, [contacts]}]),
    
    % Client2 must unswer
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options(server1,
                                            "<sips:localhost:8091/ua2;transport=ws>", 
                                            [{meta, [contacts]}]),
    #uri{domain = <<"localhost">>, port=8091} = C2C,
    {ok, 200, [{_, [C2C]}]} = nksip_uac:options(server1,
                                            "<sips:localhost:8091/ua2/any/thing;transport=ws>", 
                                            [{meta, [contacts]}]),

    % But not now
    {error, service_unavailable} = nksip_uac:options(server1,
                                            "<sips:localhost:8091/;transport=ws>", []),
    ok.


proxy() ->
    {ok, 200, []} = 
        nksip_uac:register(ua2, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [unregister_all]),
    {ok, 200, []} = 
        nksip_uac:register(ua3, "<sip:127.0.0.1:8080/s1;transport=ws>", 
                           [unregister_all]),

    
    % UA2 registers with the registrar, using WSS
    {ok, 200, []} = 
        nksip_uac:register(ua2, "<sip:127.0.0.1:8081/wss;transport=wss>", 
                           [contact]),

    % Using our public GRUU, UA1 (without websocket support) is able to reach us
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
        nksip_uac:register(ua3, "<sip:127.0.0.1:8080/s1;transport=ws>", 
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
    {ok, S1} = nkservice_server:get_srv_id(server1),
    [nkpacket_connection:stop(Pid, normal) || #nkport{pid=Pid} <- all_connected(S1)],
    timer:sleep(100),

    {ok, 430, []} = nksip_uac:options(ua1, C2Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),

    {ok, 430, []} = nksip_uac:options(ua1, C3Pub, 
                          [{route, "<sip:127.0.0.1;lr>"}]),
    ok.



all_listeners(Transp, SrvId) ->
    lists:sort(
        nkpacket:get_listening(nksip_protocol, Transp, #{srv_id=>{nksip, SrvId}})).

all_connected(SrvId) ->
    lists:sort([
        element(2, nkpacket:get_nkport(Pid)) ||
        Pid <- nkpacket_connection:get_all({nksip, SrvId})]).




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
                        [] -> 
                            {reply, temporarily_unavailable};
                        UriList -> 
                            {proxy, UriList, Opts}
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

