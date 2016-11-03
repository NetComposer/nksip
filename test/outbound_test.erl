%% -------------------------------------------------------------------
%%
%% outbound_test: Path (RFC5626) Tests
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

-module(outbound_test).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").
-include("../include/nksip_registrar.hrl").

-compile([export_all]).

outbound_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0,
            fun flow/0,
            fun register/0,
            fun proxy/0,
            {timeout, 60, fun uac_auto/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = tests_util:start(registrar, ?MODULE, [
        {sip_local_host, "localhost"},
        {plugins, [nksip_registrar, nksip_outbound]},
        {sip_listen, ["<sip:all:5090>", "<sip:all:5091;transport=tls>"]}
    ]),

    ok = tests_util:start(ua1, ?MODULE, [
        {sip_from, "sip:ua1@nksip"},
        {sip_local_host, "127.0.0.1"},
        {plugins, [nksip_outbound]},
        {sip_listen, ["<sip:all:5101>", "<sip:all:5102;transport=tls>"]}
    ]),

    ok = tests_util:start(ua2, ?MODULE, [
        {sip_local_host, "127.0.0.1"},
        {plugins, [nksip_outbound]},
        {sip_listen, ["<sip:all:5103>", "<sip:all:5104;transport=tls>"]}
    ]),

    ok = tests_util:start(p1, ?MODULE, [
        {sip_local_host, "localhost"},
        {plugins, [nksip_outbound]},
        {sip_listen, "sip:all:5060, <sip:all:5061;transport=tls>"}
    ]),

    ok = tests_util:start(p2, ?MODULE, [
        {sip_local_host, "localhost"},
        {plugins, [nksip_outbound]},
        {sip_listen, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]}
    ]),

    ok = tests_util:start(p3, ?MODULE, [
        {sip_local_host, "localhost"},
        {plugins, [nksip_outbound]},
        {sip_listen, "<sip:all:5080>,<sip:all:5081;transport=tls>"}
    ]),

    ok = tests_util:start(p4, ?MODULE, [
        {sip_local_host, "localhost"},
        {plugins, [nksip_outbound]},
        {sip_listen, ["<sip:all:5200>", "<sip:all:5201;transport=tls>"]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(p1),
    ok = nksip:stop(p2),
    ok = nksip:stop(p3),
    ok = nksip:stop(p4),
    ok = nksip:stop(registrar),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2).


basic() ->
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R, _Call}) -> Self ! {Ref, R}; (_) -> ok end},
    % RepHd = {<<"x-nk-reply">>, base64:encode(erlang:term_to_binary({Ref, Self}))},

    {ok, 603, []} = nksip_uac:invite(ua2, "sip:127.0.0.1:5103", 
                                    [contact, CB, get_request]),
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts1}]}} ->
            true = lists:member(<<"ob">>, Opts1)
    after 1000 ->
        error(basic)
    end,
  
    % Ob option is only added to dialog-generating requests
    {ok, 603, []} = nksip_uac:invite(ua2, "sip:127.0.0.1:5103", 
                                    [contact, CB, get_request, {supported, []}]),
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts2}]}} ->
            false = lists:member(<<"ob">>, Opts2)
    after 1000 ->
        error(basic)
    end,


    {ok, 200, []} = nksip_uac:options(ua2, "sip:127.0.0.1:5103", 
                                        [contact, CB, get_request]),
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts3}]}} ->
            false = lists:member(<<"ob">>, Opts3)
    after 1000 ->
        error(basic)
    end,
    ok.



flow() ->
    nksip_registrar:clear(registrar),
    nkpacket_connection:stop_all(),
    timer:sleep(50),
    
    % REGISTER with no reg-id, it is not processed using outbound (no Require in response)
    % but, as both parties support otbound, and the connection is direct,
    % registrar adds a path with the flow

    {ok, 200, [{<<"require">>, []}, {contacts, [PContact]}, {local, Local1}]} = 
        nksip_uac:register(ua1, "<sip:127.0.0.1:5090;transport=tcp>", 
            [contact, {meta, [<<"require">>, contacts, local]}]),

    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, 
        opts = [{<<"transport">>, <<"tcp">>}],
        ext_opts = EOpts1
    } = PContact,
    QInstanceC1 = nklib_util:get_value(<<"+sip.instance">>, EOpts1),

    InstanceC1 = nksip:get_uuid(ua1),
    true = <<$", InstanceC1/binary, $">> == QInstanceC1,
    
    {ok, Registrar} = nkservice_srv:get_srv_id(registrar),
    [#reg_contact{
        index = {sip, tcp, <<"ua1">>, <<"127.0.0.1">>, 5101},
        contact = PContact,
        nkport = Transp1,
        path = [#uri{
            user = <<"NkF", Flow1/binary>>,
            domain = <<"localhost">>,
            port = 5090,
            opts = [{<<"transport">>, <<"tcp">>}, <<"lr">>, <<"ob">>]
        }=Path1]
    }] = nksip_registrar_lib:get_info(Registrar, sip, <<"ua1">>, <<"nksip">>),
            
    {ok, Transp1} = nksip_outbound:decode_flow(Flow1),
    #nkport{pid=Pid1} = Transp1,

    [#uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, 
        opts = [{<<"transport">>, <<"tcp">>}],
        headers = [{<<"route">>, QRoute1}],
        ext_opts = []
    }=Contact1] = nksip_registrar:find(Registrar, sip, <<"ua1">>, <<"nksip">>),

    true = 
        list_to_binary(http_uri:decode(binary_to_list(QRoute1))) == 
        nklib_unparse:uri(Path1),

    % Now, if we send a request to this Contact, it goes to the registrar first, 
    % and the same transport is reused
    {ok, 200, [{local, Local2}, {remote, {tcp, {127,0,0,1}, 5090, <<>>}}]} = 
        nksip_uac:options(ua2, Contact1, [{meta,[local, remote]}]),

    {tcp, {127,0,0,1}, LocalPort1, <<>>} = Local1,
    {tcp, {127,0,0,1}, LocalPort2, <<>>} = Local2,
    {ok, UA1_Id} = nkservice_srv:get_srv_id(ua1),
    {ok, UA2_Id} = nkservice_srv:get_srv_id(ua2),
    [#nkport{local_port=LocalPort1, remote_port=5090}] = get_all_connected(UA1_Id),
    [#nkport{local_port=LocalPort2, remote_port=5090}] = get_all_connected(UA2_Id),

    {ok, Registrar_Id} = nkservice_srv:get_srv_id(Registrar),
    [
        #nkport{local_port=5090, remote_port=LocalPortA},
        #nkport{local_port=5090, remote_port=LocalPortB}
    ] = 
        get_all_connected(Registrar_Id),
    true = lists:sort([LocalPort1, LocalPort2]) == lists:sort([LocalPortA, LocalPortB]),



    % If we send the OPTIONS again, but removing the flow token, it goes
    % to registrar, but it has to start a new connection to ua1 (is has no opened 
    % connection to port 5101)
  
    QRoute2 = http_uri:encode(binary_to_list(nklib_unparse:uri(Path1#uri{user = <<>>}))),
    {ok, 200, []} = 
        nksip_uac:options(ua2, Contact1#uri{headers=[{<<"route">>, QRoute2}]}, []), 

    [
        #nkport{local_port=5101, remote_port=RemotePort},
        #nkport{local_port=LocalPort1, remote_port=5090}
    ] = 
        lists:sort(get_all_connected(UA1_Id)),
    [
        #nkport{local_port=5090, remote_port=LocalPortC},
        #nkport{local_port=5090, remote_port=LocalPortD},
        #nkport{local_port=RemotePort, remote_port=5101}
    ] = 
        lists:sort(get_all_connected(Registrar_Id)),
    true = lists:sort([LocalPort1, LocalPort2]) == lists:sort([LocalPortC, LocalPortD]),


    % Now we stop the first flow from registrar to ua1. registrar should return 430 "Flow Failed"
    nkpacket_connection:stop(Pid1, normal),
    timer:sleep(50),
    {ok, 430, []} = nksip_uac:options(ua1, Contact1, []),
    ok.


register() ->
    nksip_registrar:clear(registrar),

    % Several reg-ids are not allowed in a single registration
    {ok, 400, [{_, <<"Several 'reg-id' Options">>}]} = 
        nksip_uac:register(ua1, "sip:127.0.0.1:5090", 
            [{contact, "<sip:a@a.com;ob>;+sip.instance=i;reg-id=1, 
                        <sip:b@a.com;ob>;+sip.instance=i;reg-id=2"},
            {meta, [reason_phrase]}]),

    % Registration with +sip.instance y reg-id=1
    {ok, 200, [{_, [Contact1]}, {_, [<<"outbound">>]}]} = 
        nksip_uac:register(ua1, "sip:127.0.0.1:5090", 
                            [contact, {reg_id, 1}, {meta, [contacts, require]}]),

    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, opts = [],
        headers = [],
        ext_opts = [
            {<<"reg-id">>,<<"1">>},
            {<<"+sip.instance">>, QInstanceC1},
            {<<"expires">>,<<"3600">>}]
    } = Contact1,
    InstanceC1 = nksip:get_uuid(ua1),
    true = <<$", InstanceC1/binary, $">> == QInstanceC1,

    {ok, Registrar} = nkservice_srv:get_srv_id(registrar),
    QInstanceC1_id = nklib_util:hash(QInstanceC1),
    [#reg_contact{
        index = {ob, QInstanceC1_id, <<"1">>},
        contact = Contact1,
        path = [#uri{
            user = <<"NkF", _Flow1/binary>>,
            domain = <<"localhost">>,
            port = 5090,
            opts = [<<"lr">>, <<"ob">>]
        }]
    }] = nksip_registrar_lib:get_info(Registrar, sip, <<"ua1">>, <<"nksip">>),

    % Register a new registration from the same instance, reg-id=2
    {ok, 200, [{_, [Contact2, Contact1]}]} = 
        nksip_uac:register(ua1, "sip:127.0.0.1:5090", 
                            [contact, {reg_id, 2}, {meta, [contacts]}]),

    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, opts = [],
        headers = [],
        ext_opts = [
            {<<"reg-id">>,<<"2">>},
            {<<"+sip.instance">>, QInstanceC1},
            {<<"expires">>,<<"3600">>}]
    } = Contact2,

    [
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"2">>},
            contact = Contact2
        },
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"1">>},
            contact = Contact1
        }
    ] = nksip_registrar_lib:get_info(Registrar, sip, <<"ua1">>, <<"nksip">>),


    % Send a third registration from a different instance
    {ok, 200, [{_, [Contact3, Contact2, Contact1]}]} = 
        nksip_uac:register(ua2, "sip:127.0.0.1:5090", 
                            [{from, "sip:ua1@nksip"}, contact, {reg_id, 1}, 
                             {meta, [contacts]}]),
    
    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5103, opts = [],
        headers = [],
        ext_opts = [
            {<<"reg-id">>,<<"1">>},
            {<<"+sip.instance">>, QInstanceC2},
            {<<"expires">>,<<"3600">>}]
    } = Contact3,
    InstanceC2 = nksip:get_uuid(ua2),
    true = <<$", InstanceC2/binary, $">> == QInstanceC2,
    true = InstanceC1 /= InstanceC2,

    QInstanceC2_id = nklib_util:hash(QInstanceC2),
    [
        #reg_contact{
            index = {ob, QInstanceC2_id, <<"1">>},
            contact = Contact3
        },
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"2">>},
            contact = Contact2
        },
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"1">>},
            contact = Contact1
        }
    ] = nksip_registrar_lib:get_info(Registrar, sip, <<"ua1">>, <<"nksip">>),


    % Lastly, we send a new registration for reg_id=2
    % Register a new registration from the same instance, reg-id=2
    {ok, 200, [{_, [Contact2, Contact3, Contact1]}]} = 
        nksip_uac:register(ua1, "sip:127.0.0.1:5090", 
                            [contact, {reg_id, 2}, {meta, [contacts]}]),
    [
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"2">>},
            contact = Contact2,
            path = [#uri{user = <<"NkF", Flow1/binary>>}]
        },
        #reg_contact{
            index = {ob, QInstanceC2_id, <<"1">>},
            contact = Contact3,
            path = [#uri{user = <<"NkF", Flow2/binary>>}]
        },
        #reg_contact{
            index = {ob, QInstanceC1_id, <<"1">>},
            contact = Contact1,
            path = [#uri{user = <<"NkF", Flow1/binary>>}]
        }
    ] = nksip_registrar_lib:get_info(Registrar, sip, <<"ua1">>, <<"nksip">>),
    {ok, #nkport{remote_port=5101}} = nksip_outbound:decode_flow(Flow1),
    {ok, #nkport{remote_port=5103}} = nksip_outbound:decode_flow(Flow2),
    ok.


proxy() ->
    nksip_registrar:clear(registrar),

    % Send a register to P1. As it is the first proxy, it adds a flow
    % header to its path. 
    % It then sends the request to P2, and this to P3, that adds another path
    % (but without ob, as it is not the first)
    % It arrives at the registrar, that sees the first proxy has outbound
    % support
    
    {ok, 200, [{require, [<<"outbound">>]}]} = 
        nksip_uac:register(ua1, "sip:nksip", 
            [contact, {reg_id, 1}, {route, "<sip:127.0.0.1;lr>"}, 
            {meta, [require]}]),

    Contact1 = nksip_registrar:find(registrar, sip, <<"ua1">>, <<"nksip">>),
    [#uri{headers=[{<<"route">>, QRoute1}]}] = Contact1,
    [Path1, Path2] = nklib_parse:uris(http_uri:decode(binary_to_list(QRoute1))),

    #uri{user = <<"NkF", Flow1/binary>>, port = 5080, 
        opts = [<<"lr">>]} = Path1,
    #uri{user = <<"NkF", Flow2/binary>>, port = 5061,
         opts = [{<<"transport">>,<<"tls">>},<<"lr">>,<<"ob">>]} = Path2,

    {ok, #nkport{
            transp = tcp,
            local_port = 5080,
            remote_ip = {127,0,0,1},
            remote_port = _Remote1}
    } = nksip_outbound:decode_flow(Flow1),

    {ok, #nkport{
                    transp = udp,
                    pid = Pid2,
                    local_port = 5060,
                    remote_ip = {127,0,0,1},
                    remote_port = 5101}
    } = nksip_outbound:decode_flow(Flow2),
     

    % Now, if we send a request to this contact, it has two routes
    % First one to P3 (with a flow to P2)
    % Second one to P1 (with a flow to UA1)
    % Request is sent to P3, that follows the flow to P2
    % P2 sees a route to P1, so it sens it there
    % P1 follows the flow to UA1

    {ok, 200, [{_, [<<"ua1,p1,p2,p3">>]}]} = 
        nksip_uac:options(ua2, Contact1, [{meta,[<<"x-nk-id">>]}]),

    % If we stop the flow, P1 will return Flow Failed
    nkpacket_connection:stop(Pid2, normal),
    timer:sleep(50),
    {ok, 430, []} = nksip_uac:options(ua2, Contact1, []),


    % If we send the REGISTER to P2 directly, the first path (P3) has no
    % outbound support, so it fails
    {ok, 439, []} = 
        nksip_uac:register(ua1, "sip:nksip", 
            [contact, {reg_id, 1}, {route, "<sip:127.0.0.1:5070;lr>"}]),


    % It we send to P3, it adds its Path, now with outbound support because of
    % being first hop. 

    {ok, 200, [{require, [<<"outbound">>]}]} = 
        nksip_uac:register(ua1, "sip:nksip", 
            [contact, {reg_id, 1}, {route, "<sip:127.0.0.1:5080;lr>"}, 
            {meta, [require]}]),

    Contact2 = nksip_registrar:find(registrar, sip, <<"ua1">>, <<"nksip">>),
    [#uri{headers=[{<<"route">>, QRoute2}]}] = Contact2,
    [Path3] = nklib_parse:uris(http_uri:decode(binary_to_list(QRoute2))),

    
    #uri{
        user = <<"NkF", Flow3/binary>>, 
        port = 5080, 
        opts = [<<"lr">>,<<"ob">>]
    } = Path3,

    {ok, 200, [{dialog, DialogId}]} = 
        nksip_uac:invite(ua2, Contact2, [auto_2xx_ack, {add, "x-nk-op", "ok"}]),

    {ok, [
        #uri{
            user = <<"NkF", Flow3/binary>>,
            port = 5080,
            opts = [<<"lr">>]
        }
    ]} = nksip_dialog:meta(route_set, DialogId),

    nksip_uac:bye(DialogId, []),
    ok.


uac_auto() ->
    nksip_registrar:clear(registrar),
    nkpacket_connection:stop_all(),
    ok = tests_util:start(ua3, ?MODULE, [
        {sip_from, "sip:ua3@nksip"},
        {sip_local_host, "127.0.0.1"},
        {sip_uac_auto_outbound_all_fail, 1},
        {sip_uac_auto_outbound_any_ok, 2},
        {sip_uac_auto_register_timer, 1},
        {plugins, [nksip_uac_auto_outbound]},
        {sip_listen, ["<sip:all:5106>", "<sip:all:5107;transport=tls>"]}
    ]),
    {ok, UA3_Id} = nkservice_srv:get_srv_id(ua3),
    timer:sleep(100),
    {ok, true} = 
        nksip_uac_auto_outbound:start_register(ua3, auto1, 
                                               "<sip:127.0.0.1:5090;transport=tcp>", []),
    {ok, true} = 
        nksip_uac_auto_outbound:start_register(ua3, auto2, 
                                               "<sip:127.0.0.1:5090;transport=udp>", []),


    [{auto1, true, _},{auto2, true, _}] = 
        lists:sort(nksip_uac_auto_register:get_registers(ua3)),
    [{auto1, true, _, _},{auto2, true, _, _}] = 
        lists:sort(nksip_uac_auto_outbound:get_registers(ua3)),

    timer:sleep(100),
    % UA3 should have two connections to Registrar
    [
        #nkport{transp = tcp, local_port = Local1, pid = Pid1,
                remote_port = 5090, listen_port = 5106},
        #nkport{transp = udp, local_port = 5106, pid = Pid2,
                       remote_port = 5090, listen_port = 5106}
    ] = lists:sort(get_all_connected(UA3_Id)),

    {ok, RegistrarId} = nkservice_srv:get_srv_id(registrar),
    [
        #nkport{transp = tcp, local_port = 5090, pid = Pid3,
                remote_port = Local1, listen_port=5090},
        #nkport{transp = udp, local_port = 5090, pid = Pid4,
                remote_port = 5106, listen_port = 5090}
    ] = lists:sort(get_all_connected(RegistrarId)),

    {true, KA1, Refresh1} = nksip_protocol:get_refresh(Pid1),
    check_time(KA1, 120),
    {true, KA2, Refresh2} = nksip_protocol:get_refresh(Pid2),
    check_time(KA2, 25),
    true = Refresh1 > 1 andalso Refresh2 > 1,

    false = nksip_protocol:get_refresh(Pid3),
    false = nksip_protocol:get_refresh(Pid4),

    % lager:error("Next error about process failed is expected"),
    exit(Pid1, kill),
    timer:sleep(50),
    [{auto1, false, _},{auto2, true, _}] = 
        lists:sort(nksip_uac_auto_register:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (1/3)"),
    wait_register(10),  % 50

    nkpacket_connection:stop(Pid2, normal),
    timer:sleep(50),
    [{auto1, true, _},{auto2, false, _}] = 
        lists:sort(nksip_uac_auto_register:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (2/3)"),
    wait_register(50),

    [#nkport{pid=Pid5}, #nkport{pid=Pid6}] = get_all_connected(UA3_Id),
    nkpacket_connection:stop(Pid5, normal),
    nkpacket_connection:stop(Pid6, normal),
    timer:sleep(50),
    [{auto1, false, _},{auto2, false, _}] = 
        lists:sort(nksip_uac_auto_register:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (3/3)"),
    wait_register(100),

    ok = nksip:stop(ua3),
    timer:sleep(100),
    [] = get_all_connected(UA3_Id),
    [#nkport{transp=udp}] = get_all_connected(RegistrarId),
    ok.




check_time(Time, Limit) ->
    case Time >= 0.8*Limit andalso Time =< Limit of
        true ->
            ok;
        false ->
            lager:warning("Time error ~p not int ~p", [Time, Limit]),
            error(time_error)
    end.


wait_register(0) -> 
    error(register);
wait_register(N) ->
    case lists:sort(nksip_uac_auto_register:get_registers(ua3)) of
        [{auto1, true, _},{auto2, true, _}] -> ok;
        _ -> timer:sleep(500), wait_register(N-1)
    end.
        

get_all_connected(Id) ->
    [
        element(2, nkpacket:get_nkport(Pid))
        || Pid <- nkpacket_connection:get_all({nksip, Id})
    ].



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        % P1 is the outbound proxy.
        % It domain is 'nksip', it sends the request to P2, 
        % inserting Path and x-nk-id headers
        % If not, simply proxies the request adding a x-nk-id header
        {ok, p1} ->
            Base = [{insert, "x-nk-id", "p1"}],
            case Domain of 
                <<"nksip">> -> 
                    Opts = [{route, "<sip:127.0.0.1:5071;lr;transport=tls>"}, 
                             path, record_route|Base],
                    {proxy, ruri, Opts};
                _ -> 
                    {proxy, ruri, Base}
            end;
        {ok, p2} ->
            % P2 is an intermediate proxy.
            % For 'nksip' domain, sends the request to P3, inserting x-nk-id header
            % For other, simply proxies and adds header
            Base = [{insert, "x-nk-id", "p2"}],
            case Domain of 
                <<"nksip">> -> 
                    Opts = [{route, "<sip:127.0.0.1:5080;lr;transport=tcp>"}|Base],
                    {proxy, ruri, Opts};
                _ -> 
                    {proxy, ruri, Base}
            end;
        {ok, p3} ->
            % P3 is the SBC. 
            % For 'nksip', it sends everything to the registrar, inserting Path header
            % For other proxies the request
            Base = [{insert, "x-nk-id", "p3"}],
            case Domain of 
                <<"nksip">> -> 
                    Opts = [{route, "<sip:127.0.0.1:5090;lr>"}, path, record_route|Base],
                    {proxy, ruri, Opts};
                _ -> 
                    {proxy, ruri, [record_route|Base]}
            end;
        {ok, p4} ->
            % P4 is a dumb router, only adds a header
            % For 'nksip', it sends everything to the registrar, inserting Path header
            % For other proxies the request
            Base = [{insert, "x-nk-id", "p4"}, path, record_route],
            {proxy, ruri, Base};
        {ok, registrar} ->
            % Registrar is the registrar proxy for "nksip" domain
            case Domain of
                <<"nksip">> when User == <<>> ->
                    process;
                <<"127.0.0.1">> when User == <<>> ->
                    process;
                <<"nksip">> ->
                    case nksip_registrar:find(registrar, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy, UriList}
                    end;
                _ ->
                    {proxy, ruri, []}
            end;
        {ok, _} ->
            process
    end.


sip_invite(Req, _Call) ->
    case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [<<"ok">>]} -> {reply, ok};
        {ok, _} -> {reply, 603}
    end.


sip_options(Req, _Call) ->
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, App} = nksip_request:srv_name(Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([App|Ids])}],
    {reply, {ok, [contact|Hds]}}.





