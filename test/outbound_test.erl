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

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

% outbound_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             fun basic/0,
%             fun flow/0,
%             fun register/0,
%             fun proxy/0,
%             {timeout, 60, fun outbound/0}
%         ]
%     }.

start() ->
    tests_util:start_nksip(),

    nksip_config:put(outbound_time_all_fail, 1),
    nksip_config:put(outbound_time_any_ok, 2),

    ok = path_server:start({outbound, registrar}, [
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5090}},
        {transport, {tls, {0,0,0,0}, 5091}}
        % {transport, {sctp, {0,0,0,0}, 5090}}
    ]),

    ok = sipapp_endpoint:start({outbound, ua1}, [
        {from, "sip:ua1@nksip"},
        % {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5101}},
        {transport, {tls, {0,0,0,0}, 5102}}
        % {transport, {sctp, {0,0,0,0}, 0}}
    ]),

    ok = sipapp_endpoint:start({outbound, ua2}, [
        % {route, "<sip:127.0.0.1:5090;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5103}},
        {transport, {tls, {0,0,0,0}, 5104}}
    ]),

    ok = path_server:start({outbound, p1}, [
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}]),

    ok = path_server:start({outbound, p2}, [
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),

    ok = path_server:start({outbound, p3}, [
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5080}},
        {transport, {tls, {0,0,0,0}, 5081}}]),

    ok = path_server:start({outbound, p4}, [
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5200}},
        {transport, {tls, {0,0,0,0}, 5201}}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    nksip_config:put(outbound_time_all_fail, 30),
    nksip_config:put(outbound_time_any_ok, 90),

    ok = sipapp_server:stop({outbound, p1}),
    ok = sipapp_server:stop({outbound, p2}),
    ok = sipapp_server:stop({outbound, p3}),
    ok = sipapp_server:stop({outbound, p4}),
    ok = sipapp_server:stop({outbound, registrar}),
    ok = sipapp_endpoint:stop({outbound, ua1}),
    ok = sipapp_endpoint:stop({outbound, ua2}).


basic() ->
    C2 = {outbound, ua2},
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},
    % RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    {ok, 603, []} = nksip_uac:invite(C2, "sip:127.0.0.1:5103", 
                                        [make_contact, CB, get_request]),
    % Ob option is only added to dialog-generating requests
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts1}]}} ->
            true = lists:member(<<"ob">>, Opts1)
    after 1000 ->
        error(basic)
    end,
  
    {ok, 200, []} = nksip_uac:options(C2, "sip:127.0.0.1:5103", 
                                        [make_contact, CB, get_request, 
                                         {supported, "path"}]),
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts2}]}} ->
            false = lists:member(<<"ob">>, Opts2)
    after 1000 ->
        error(basic)
    end,
    ok.


flow() ->
    C1 = {outbound, ua1},
    R1 = {outbound, registrar},

    nksip_registrar:clear(R1),
    nksip_transport:stop_all_connected(),
    timer:sleep(50),
    
    % REGISTER with no reg-id, it is not processed using outbound (no Require)
    % but, as both parties support otbound, and the connection is direct,
    % registrar adds a path with the flow

    {ok, 200, [{<<"Require">>, []}, {parsed_contacts, [PContact]}, {local, Local}]} = 
        nksip_uac:register(C1, "<sip:127.0.0.1:5090;transport=tcp>", 
            [make_contact, {fields, [<<"Require">>, parsed_contacts, local]}]),

    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, 
        opts = [{<<"transport">>, <<"tcp">>}],
        ext_opts = EOpts1
    } = PContact,
    QInstanceC1 = nksip_lib:get_value(<<"+sip.instance">>, EOpts1),

    {ok, InstanceC1} = nksip_sipapp_srv:get_uuid(C1),
    true = <<$", InstanceC1/binary, $">> == QInstanceC1,
    
    [#reg_contact{
        index = {sip, tcp, <<"ua1">>, <<"127.0.0.1">>, 5101},
        contact = PContact,
        transport = Transp1,
        path = [#uri{
            user = <<"NkF", Flow1/binary>>,
            domain = <<"localhost">>,
            port = 5090,
            opts = [{<<"transport">>, <<"tcp">>}, <<"lr">>, <<"ob">>]
        }=Path1]
    }] = nksip_registrar:get_info(R1, sip, <<"ua1">>, <<"nksip">>),
            
    Pid1 = binary_to_term(base64:decode(Flow1)),
    {ok, Transp1} = nksip_connection:get_transport(Pid1),

    [#uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, 
        opts = [{<<"transport">>, <<"tcp">>}],
        headers = [{<<"Route">>, QRoute1}],
        ext_opts = []
    }=Contact1] = nksip_registrar:find(R1, sip, <<"ua1">>, <<"nksip">>),

    true = 
        list_to_binary(http_uri:decode(binary_to_list(QRoute1))) == 
        nksip_unparse:uri(Path1),

    % Now, if a send a request to this Contact, it goes to the registrar first, 
    % and the same transport is reused
    {ok, 200, [{local, Local}, {remote, {tcp, {127,0,0,1}, 5090, <<>>}}]} = 
        nksip_uac:options(C1, Contact1, [{fields, [local, remote]}]),

    {tcp, {127,0,0,1}, LocalPort, <<>>} = Local,
    [{#transport{local_port=LocalPort, remote_port=5090}, _}] = 
        nksip_transport:get_all_connected(C1),
    [{#transport{local_port=5090, remote_port=LocalPort}, _}] = 
        nksip_transport:get_all_connected(R1),

    % If we send the OPTIONS again, but removing the flow token, it goes
    % to R1, but it has to start a new connection to C1 (is has no opened 
    % connection to port 5101)
  
    QRoute2 = http_uri:encode(binary_to_list(nksip_unparse:uri(Path1#uri{user = <<>>}))),
    {ok, 200, []} = 
        nksip_uac:options(C1, Contact1#uri{headers=[{<<"Route">>, QRoute2}]}, []), 

    [
        {#transport{local_port=5101, remote_port=RemotePort}, _},
        {#transport{local_port=LocalPort, remote_port=5090}, _}
    ] = 
        lists:sort(nksip_transport:get_all_connected(C1)),
    [
        {#transport{local_port=5090, remote_port=LocalPort}, _},
        {#transport{local_port=RemotePort, remote_port=5101}, _}
    ] = 
        lists:sort(nksip_transport:get_all_connected(R1)),


    % Now we stop the first flow from R1 to C1. R1 should return 430 "Flow Failed"
    nksip_connection:stop(Pid1, normal),
    timer:sleep(50),
    {ok, 430, []} = nksip_uac:options(C1, Contact1, []),
    ok.


register() ->
    C1 = {outbound, ua1},
    C2 = {outbound, ua2},
    R1 = {outbound, registrar},
    nksip_registrar:clear(R1),

    % Several reg-ids are not allowed in a single registration
    {ok, 400, [{_, <<"Several 'reg-id' Options">>}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1:5090", 
            [{contact, "<sip:a@a.com;ob>;+sip.instance=i;reg-id=1, 
                        <sip:b@a.com;ob>;+sip.instance=i;reg-id=2"},
            {fields, [reason_phrase]}]),

    % Registration with +sip.instance y reg-id=1
    {ok, 200, [{_, [Contact1]}, {_, [<<"outbound">>]}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1:5090", 
                            [make_contact, {reg_id, 1}, 
                             {fields, [parsed_contacts, parsed_require]}]),

    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, opts = [],
        headers = [],
        ext_opts = [
            {<<"reg-id">>,<<"1">>},
            {<<"+sip.instance">>, QInstanceC1},
            {<<"expires">>,<<"3600">>}]
    } = Contact1,
    {ok, InstanceC1} = nksip_sipapp_srv:get_uuid(C1),
    true = <<$", InstanceC1/binary, $">> == QInstanceC1,

    QInstanceC1_id = nksip_lib:hash(QInstanceC1),
    [#reg_contact{
        index = {ob, QInstanceC1_id, <<"1">>},
        contact = Contact1,
        path = [#uri{
            user = <<"NkF", _Flow1/binary>>,
            domain = <<"localhost">>,
            port = 5090,
            opts = [<<"lr">>, <<"ob">>]
        }]
    }] = nksip_registrar:get_info(R1, sip, <<"ua1">>, <<"nksip">>),

    % Register a new registration from the same instance, reg-id=2
    {ok, 200, [{_, [Contact2, Contact1]}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1:5090", 
                            [make_contact, {reg_id, 2}, {fields, [parsed_contacts]}]),

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
    ] = nksip_registrar:get_info(R1, sip, <<"ua1">>, <<"nksip">>),


    % Send a third registration from a different instance
    {ok, 200, [{_, [Contact3, Contact2, Contact1]}]} = 
        nksip_uac:register(C2, "sip:127.0.0.1:5090", 
                            [{from, "sip:ua1@nksip"}, make_contact, {reg_id, 1}, 
                             {fields, [parsed_contacts]}]),
    
    #uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5103, opts = [],
        headers = [],
        ext_opts = [
            {<<"reg-id">>,<<"1">>},
            {<<"+sip.instance">>, QInstanceC2},
            {<<"expires">>,<<"3600">>}]
    } = Contact3,
    {ok, InstanceC2} = nksip_sipapp_srv:get_uuid(C2),
    true = <<$", InstanceC2/binary, $">> == QInstanceC2,
    true = InstanceC1 /= InstanceC2,

    QInstanceC2_id = nksip_lib:hash(QInstanceC2),
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
    ] = nksip_registrar:get_info(R1, sip, <<"ua1">>, <<"nksip">>),


    % Lastly, we send a new registration for reg_id=2
    % Register a new registration from the same instance, reg-id=2
    {ok, 200, [{_, [Contact2, Contact3, Contact1]}]} = 
        nksip_uac:register(C1, "sip:127.0.0.1:5090", 
                            [make_contact, {reg_id, 2}, {fields, [parsed_contacts]}]),
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
    ] = nksip_registrar:get_info(R1, sip, <<"ua1">>, <<"nksip">>),
    Pid1 = binary_to_term(base64:decode(Flow1)),
    {ok, #transport{remote_port=5101}} = nksip_connection:get_transport(Pid1),

    Pid2 = binary_to_term(base64:decode(Flow2)),
    {ok, #transport{remote_port=5103}} = nksip_connection:get_transport(Pid2),

    ok.


proxy() ->
    C1 = {outbound, ua1},
    C2 = {outbound, ua2},
    R1 = {outbound, registrar},
    nksip_registrar:clear(R1),

    % Send a register to P1. As it is the first proxy, it adds a flow
    % header to its path. 
    % It then sends the request to P2, and this to P3, that adds another path
    % It arrives at the registrar, that sees the first proxy has outbound
    % support
    
    {ok, 200, [{parsed_require, [<<"outbound">>]}]} = 
        nksip_uac:register(C1, "sip:nksip", 
            [make_contact, {reg_id, 1}, {route, "<sip:127.0.0.1;lr>"}, 
            {fields, [parsed_require]}]),

    Contact1 = nksip_registrar:find(R1, sip, <<"ua1">>, <<"nksip">>),
    [#uri{headers=[{<<"Route">>, QRoute1}]}] = Contact1,
    [Path1, Path2] = nksip_parse:uris(http_uri:decode(binary_to_list(QRoute1))),

    #uri{user = <<"NkQ", _/binary>>, port = 5080} = Path1,
    #uri{user = <<"NkF", Flow1/binary>>, port = 5061,
         opts = [{<<"transport">>,<<"tls">>},<<"lr">>,<<"ob">>]} = Path2,

    Pid1 = binary_to_term(base64:decode(Flow1)),
    {ok,
        #transport{
            proto = udp,
            local_port = 5060,
            remote_ip = {127,0,0,1},
            remote_port = 5101}} = 
        nksip_connection:get_transport(Pid1),

    % Now, if we send a request to this contact, it will go to 
    % P3, to P1, and P1 will use the indicated flow to go to UA1
    {ok, 200, [{_, [<<"ua1,p1,p3">>]}]} = 
        nksip_uac:options(C2, Contact1, [{fields, [<<"Nk-Id">>]}]),

    % If we stop the flow, P1 will return Flow Failed
    nksip_connection:stop(Pid1, normal),
    timer:sleep(50),
    {ok, 430, []} = nksip_uac:options(C2, Contact1, []),


    % If we send the REGISTER to P2 directly, the first path (P3) has no
    % outbound support, so it fails
    {ok, 439, []} = 
        nksip_uac:register(C1, "sip:nksip", 
            [make_contact, {reg_id, 1}, {route, "<sip:127.0.0.1:5070;lr>"}]),


    % It we send to P3, it adds its Path, now with outbound support because of
    % (being first hop). 

    {ok, 200, [{parsed_require, [<<"outbound">>]}]} = 
        nksip_uac:register(C1, "sip:nksip", 
            [make_contact, {reg_id, 1}, {route, "<sip:127.0.0.1:5080;lr>"}, 
            {fields, [parsed_require]}]),

    Contact2 = nksip_registrar:find(R1, sip, <<"ua1">>, <<"nksip">>),
    [#uri{headers=[{<<"Route">>, QRoute2}]}] = Contact2,
    [Path3] = nksip_parse:uris(http_uri:decode(binary_to_list(QRoute2))),

    #uri{
        user = <<"NkF", Flow2/binary>>, 
        port = 5080, 
        opts = [<<"lr">>,<<"ob">>]
    } = Path3,

    {ok, 200, [{dialog_id, DialogId}]} = 
        nksip_uac:invite(C2, Contact2, 
                    [auto_2xx_ack, {headers, [{"Nk-Op", "ok"}]}]),

    [
        #uri{
            user = <<"NkF", Flow2/binary>>,
            port = 5080,
            opts = [<<"lr">>]
        }
    ] = nksip_dialog:field(C2, DialogId, parsed_route_set),

    nksip_uac:bye(C2, DialogId, []),
    ok.


outbound() ->
    C3 = {outbound, ua3},
    R1 = {outbound, registrar},

    nksip_registrar:clear(R1),
    nksip_transport:stop_all_connected(),
    ok = sipapp_endpoint:start(C3, [
        % {route, "<sip:127.0.0.1:5090;lr>"},
        {from, "sip:ua3@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5106}},
        {transport, {tls, {0,0,0,0}, 5107}},
        {register, "<sip:127.0.0.1:5090;transport=tcp>"},
        {register, "<sip:127.0.0.1:5090;transport=udp>"}
    ]),
    timer:sleep(100),

    [{<<"auto-1">>, true, _},{<<"auto-2">>, true, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C3)),

    % UA3 should have to connections to Registrar
    [
        {
            #transport{proto = tcp, local_port = Local1,
                       remote_port = 5090, listen_port = 5106},
            Pid1
        },
        {
            #transport{proto = udp, local_port = 5106,
                       remote_port = 5090, listen_port = 5106},
            Pid2
        }
    ] = lists:sort(nksip_transport:get_all_connected(C3)),

    [
        {
            #transport{proto = tcp, local_port = 5090,
                       remote_port = Local1, listen_port=5090},
            Pid3
        },
        {
            #transport{proto = udp, local_port = 5090, 
             remote_port = 5106, listen_port = 5090},
            Pid4
        }
    ] = lists:sort(nksip_transport:get_all_connected(R1)),



    {true, KA1, Refresh1} = nksip_connection:get_refresh(Pid1),
    check_time(KA1, ?DEFAULT_TCP_KEEPALIVE),
    {true, KA2, Refresh2} = nksip_connection:get_refresh(Pid2),
    check_time(KA2, ?DEFAULT_UDP_KEEPALIVE),
    true = Refresh1 > 1 andalso Refresh2 > 1,

    {false, _} = nksip_connection:get_refresh(Pid3),
    {false, _} = nksip_connection:get_refresh(Pid4),

    lager:error("Next error about process failed is expected"),
    exit(Pid1, kill),
    timer:sleep(50),
    [{<<"auto-1">>, false, _},{<<"auto-2">>, true, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C3)),
    ?debugMsg("waiting register... (1/3)"),
    wait_register(50),

    nksip_connection:stop(Pid2, normal),
    timer:sleep(50),
    [{<<"auto-1">>, true, _},{<<"auto-2">>, false, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C3)),
    ?debugMsg("waiting register... (2/3)"),
    wait_register(50),

    [{_, Pid5}, {_, Pid6}] = nksip_transport:get_all_connected(C3),
    nksip_connection:stop(Pid5, normal),
    nksip_connection:stop(Pid6, normal),
    timer:sleep(50),
    [{<<"auto-1">>, false, _},{<<"auto-2">>, false, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(C3)),
    ?debugMsg("waiting register... (3/3)"),
    wait_register(100),

    ok = nksip:stop(C3),
    timer:sleep(100),
    [] = nksip_transport:get_all_connected(C3),
    [{#transport{proto=udp}, _}] = nksip_transport:get_all_connected(R1),

    nksip_config:put(outbound_time_all_fail, 30),
    nksip_config:put(outbound_time_any_ok, 90),
    ok.




check_time(Time, Limit) ->
    true = Time >= 0.8*Limit andalso Time =< Limit.

wait_register(0) -> 
    error(register);
wait_register(N) ->
    case lists:sort(nksip_sipapp_auto:get_registers({outbound, ua3})) of
        [{<<"auto-1">>, true, _},{<<"auto-2">>, true, _}] -> ok;
        _ -> timer:sleep(1000), wait_register(N-1)
    end.
        



