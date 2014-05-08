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

outbound_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0,
            fun flow/0,
            fun register/0,
            fun proxy/0,
            {timeout, 60, fun outbound/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(registrar, ?MODULE, registrar, [
        registrar,
        {local_host, "localhost"},
        {transports, [{udp, all, 5090}, {tls, all, 5091}]}
    ]),

    {ok, _} = nksip:start(ua1, ?MODULE, ua1, [
        {from, "sip:ua1@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5101}, {tls, all, 5102}]}
    ]),

    {ok, _} = nksip:start(ua2, ?MODULE, ua2, [
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5103}, {tls, all, 5104}]}
    ]),

    {ok, _} = nksip:start(p1, ?MODULE, p1, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ]),

    {ok, _} = nksip:start(p2, ?MODULE, p2, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    {ok, _} = nksip:start(p3, ?MODULE, p3, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5080}, {tls, all, 5081}]}
    ]),

    {ok, _} = nksip:start(p4, ?MODULE, p4, [
        {local_host, "localhost"},
        {transports, [{udp, all, 5200}, {tls, all, 5201}]}
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
    % Ob option is only added to dialog-generating requests
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts1}]}} ->
            true = lists:member(<<"ob">>, Opts1)
    after 1000 ->
        error(basic)
    end,
  
    {ok, 200, []} = nksip_uac:options(ua2, "sip:127.0.0.1:5103", 
                                        [contact, CB, get_request, 
                                         {supported, "path"}]),
    receive 
        {Ref, #sipmsg{contacts=[#uri{opts=Opts2}]}} ->
            false = lists:member(<<"ob">>, Opts2)
    after 1000 ->
        error(basic)
    end,
    ok.


flow() ->
    nksip_registrar:clear(registrar),
    nksip_transport:stop_all_connected(),
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
    QInstanceC1 = nksip_lib:get_value(<<"+sip.instance">>, EOpts1),

    {ok, InstanceC1} = nksip:get_uuid(ua1),
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
    }] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),
            
    {ok, Pid1, Transp1} = nksip_outbound:decode_flow(Flow1),

    [#uri{
        user = <<"ua1">>, domain = <<"127.0.0.1">>, port = 5101, 
        opts = [{<<"transport">>, <<"tcp">>}],
        headers = [{<<"route">>, QRoute1}],
        ext_opts = []
    }=Contact1] = nksip_registrar:find(registrar, sip, <<"ua1">>, <<"nksip">>),

    true = 
        list_to_binary(http_uri:decode(binary_to_list(QRoute1))) == 
        nksip_unparse:uri(Path1),

    % Now, if a send a request to this Contact, it goes to the registrar first, 
    % and the same transport is reused
    {ok, 200, [{local, Local2}, {remote, {tcp, {127,0,0,1}, 5090, <<>>}}]} = 
        nksip_uac:options(ua2, Contact1, [{meta,[local, remote]}]),

    {tcp, {127,0,0,1}, LocalPort1, <<>>} = Local1,
    {tcp, {127,0,0,1}, LocalPort2, <<>>} = Local2,
    {ok, UA1_Id} = nksip:find_app(ua1),
    {ok, UA2_Id} = nksip:find_app(ua2),
    [{#transport{local_port=LocalPort1, remote_port=5090}, _}] = 
        nksip_transport:get_all_connected(UA1_Id),
    [{#transport{local_port=LocalPort2, remote_port=5090}, _}] = 
        nksip_transport:get_all_connected(UA2_Id),

    {ok, Registrar_Id} = nksip:find_app(registrar),
    [
        {#transport{local_port=5090, remote_port=LocalPortA}, _},
        {#transport{local_port=5090, remote_port=LocalPortB}, _}
    ] = 
        nksip_transport:get_all_connected(Registrar_Id),
    true = lists:sort([LocalPort1, LocalPort2]) == lists:sort([LocalPortA, LocalPortB]),



    % If we send the OPTIONS again, but removing the flow token, it goes
    % to registrar, but it has to start a new connection to ua1 (is has no opened 
    % connection to port 5101)
  
    QRoute2 = http_uri:encode(binary_to_list(nksip_unparse:uri(Path1#uri{user = <<>>}))),
    {ok, 200, []} = 
        nksip_uac:options(ua2, Contact1#uri{headers=[{<<"route">>, QRoute2}]}, []), 

    [
        {#transport{local_port=5101, remote_port=RemotePort}, _},
        {#transport{local_port=LocalPort1, remote_port=5090}, _}
    ] = 
        lists:sort(nksip_transport:get_all_connected(UA1_Id)),
    [
        {#transport{local_port=5090, remote_port=LocalPortC}, _},
        {#transport{local_port=5090, remote_port=LocalPortD}, _},
        {#transport{local_port=RemotePort, remote_port=5101}, _}
    ] = 
        lists:sort(nksip_transport:get_all_connected(Registrar_Id)),
    true = lists:sort([LocalPort1, LocalPort2]) == lists:sort([LocalPortC, LocalPortD]),


    % Now we stop the first flow from registrar to ua1. registrar should return 430 "Flow Failed"
    nksip_connection:stop(Pid1, normal),
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
    {ok, InstanceC1} = nksip:get_uuid(ua1),
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
    }] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),

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
    ] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),


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
    {ok, InstanceC2} = nksip:get_uuid(ua2),
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
    ] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),


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
    ] = nksip_registrar:get_info(registrar, sip, <<"ua1">>, <<"nksip">>),
    {ok, _, #transport{remote_port=5101}} = nksip_outbound:decode_flow(Flow1),
    {ok, _, #transport{remote_port=5103}} = nksip_outbound:decode_flow(Flow2),
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
    [Path1, Path2] = nksip_parse:uris(http_uri:decode(binary_to_list(QRoute1))),

    #uri{user = <<"NkF", Flow1/binary>>, port = 5080, 
        opts = [<<"lr">>]} = Path1,
    #uri{user = <<"NkF", Flow2/binary>>, port = 5061,
         opts = [{<<"transport">>,<<"tls">>},<<"lr">>,<<"ob">>]} = Path2,

    {ok, _Pid1, #transport{
                    proto = tcp,
                    local_port = 5080,
                    remote_ip = {127,0,0,1},
                    remote_port = _Remote1}
    } = nksip_outbound:decode_flow(Flow1),

    {ok, Pid2, #transport{
                    proto = udp,
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
    nksip_connection:stop(Pid2, normal),
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
    [Path3] = nksip_parse:uris(http_uri:decode(binary_to_list(QRoute2))),

    
    #uri{
        user = <<"NkF", Flow3/binary>>, 
        port = 5080, 
        opts = [<<"lr">>,<<"ob">>]
    } = Path3,

    {ok, 200, [{dialog_id, DialogId}]} = 
        nksip_uac:invite(ua2, Contact2, [auto_2xx_ack, {add, "x-nk-op", "ok"}]),

    [
        #uri{
            user = <<"NkF", Flow3/binary>>,
            port = 5080,
            opts = [<<"lr">>]
        }
    ] = nksip_dialog:meta(route_set, DialogId),

    nksip_uac:bye(DialogId, []),
    ok.


outbound() ->
    nksip_registrar:clear(registrar),
    nksip_transport:stop_all_connected(),
    {ok, UA3_Id} = nksip:start(ua3, ?MODULE, ua3, [
        {from, "sip:ua3@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5106}, {tls, all, 5107}]},
        {register, "<sip:127.0.0.1:5090;transport=tcp>, 
                    <sip:127.0.0.1:5090;transport=udp>"},
        {outbound_time_all_fail, 1},
        {outbound_time_any_ok, 2},
        {sipapp_timer, 1}
    ]),
    timer:sleep(100),

    [{<<"auto-1">>, true, _},{<<"auto-2">>, true, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(ua3)),

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
    ] = lists:sort(nksip_transport:get_all_connected(UA3_Id)),

    {ok, RegistrarId} = nksip:find_app(registrar),
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
    ] = lists:sort(nksip_transport:get_all_connected(RegistrarId)),



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
        lists:sort(nksip_sipapp_auto:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (1/3)"),
    wait_register(50),

    nksip_connection:stop(Pid2, normal),
    timer:sleep(50),
    [{<<"auto-1">>, true, _},{<<"auto-2">>, false, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (2/3)"),
    wait_register(50),

    [{_, Pid5}, {_, Pid6}] = nksip_transport:get_all_connected(UA3_Id),
    nksip_connection:stop(Pid5, normal),
    nksip_connection:stop(Pid6, normal),
    timer:sleep(50),
    [{<<"auto-1">>, false, _},{<<"auto-2">>, false, _}] = 
        lists:sort(nksip_sipapp_auto:get_registers(UA3_Id)),
    ?debugMsg("waiting register... (3/3)"),
    wait_register(100),

    ok = nksip:stop(ua3),
    timer:sleep(100),
    [] = nksip_transport:get_all_connected(UA3_Id),
    [{#transport{proto=udp}, _}] = nksip_transport:get_all_connected(RegistrarId),
    ok.




check_time(Time, Limit) ->
    true = Time >= 0.8*Limit andalso Time =< Limit.

wait_register(0) -> 
    error(register);
wait_register(N) ->
    case lists:sort(nksip_sipapp_auto:get_registers(ua3)) of
        [{<<"auto-1">>, true, _},{<<"auto-2">>, true, _}] -> ok;
        _ -> timer:sleep(1000), wait_register(N-1)
    end.
        


%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.

route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:app_name(Req) of
        % P1 is the outbound proxy.
        % It domain is 'nksip', it sends the request to P2, 
        % inserting Path and x-nk-id headers
        % If not, simply proxies the request adding a x-nk-id header
        p1 ->
            Base = [{insert, "x-nk-id", "p1"}],
            case Domain of 
                <<"nksip">> -> 
                    Opts = [{route, "<sip:127.0.0.1:5071;lr;transport=tls>"}, 
                             path, record_route|Base],
                    {proxy, ruri, Opts};
                _ -> 
                    {proxy, ruri, Base}
            end;
        p2 ->
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
        p3 ->
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
        p4 ->
            % P4 is a dumb router, only adds a header
            % For 'nksip', it sends everything to the registrar, inserting Path header
            % For other proxies the request
            Base = [{insert, "x-nk-id", "p4"}, path, record_route],
            {proxy, ruri, Base};
        registrar ->
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
        _ ->
            process
    end.


invite(Req, _Call) ->
    case nksip_request:header(<<"x-nk-op">>, Req) of
        [<<"ok">>] -> {reply, ok};
        _ -> {reply, 603}
    end.


options(Req, _Call) ->
    Ids = nksip_request:header(<<"x-nk-id">>, Req),
    App = nksip_request:app_name(Req),
    Hds = [{add, "x-nk-id", nksip_lib:bjoin([App|Ids])}],
    {reply, {ok, [contact|Hds]}}.





