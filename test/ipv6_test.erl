%% -------------------------------------------------------------------
%%
%% ipv6_test: IPv6 Tests and RFC5118 Torture Tests
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

-module(ipv6_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

ipv6_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
        fun basic/0,
        fun invite/0,
        fun proxy/0,
        fun bridge_4_6/0,
        fun torture_1/0,
        fun torture_2/0,
        fun torture_3/0,
        fun torture_4/0,
        fun torture_5/0,
        fun torture_6/0,
        fun torture_7/0,
        fun torture_8/0,
        fun torture_9/0,
        fun torture_10/0
      ]
  }.


main_ip6() ->
    nksip_lib:to_host(nksip_transport:main_ip6(), true).

start() ->
    tests_util:start_nksip(),

    %% NOTE: using 'any6' as ip for hosts fails in Linux
    %% (it works in OSX)

    ok = sipapp_server:start({ipv6, server1}, [
        {from, "sip:server1@nksip"},
        registrar,
        {local_host6, "::1"},
        {transport, {udp, any, 5060}},
        {transport, {udp, "::1", 5060}}]),

    ok = sipapp_server:start({ipv6, server2}, [
        {from, "sip:server2@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, any, 5061}},
        {local_host6, "::1"},
        {transport, {udp, "::1", 5061}}]),

    ok = sipapp_endpoint:start({ipv6, client1}, [
        {from, "sip:client1@nksip"},
        {transport, {udp, "::1", 5070}}]),
    
    ok = sipapp_endpoint:start({ipv6, client2}, [
        {from, "sip:client2@nksip"},
        {transport, {udp, "::1", 5071}}]),

    ok = sipapp_endpoint:start({ipv6, client3}, [
        {from, "sip:client3@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, any, 5072}}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_server:stop({ipv6, server1}),
    ok = sipapp_server:stop({ipv6, server2}),
    ok = sipapp_endpoint:stop({ipv6, client1}),
    ok = sipapp_endpoint:stop({ipv6, client2}),
    ok = sipapp_endpoint:stop({ipv6, client3}).


basic() ->
    MainIp = <<"[::1]">>,
    Self = self(),
    Ref = make_ref(),

    Fun1 = fun({req, #sipmsg{contacts=[Contact]}}) ->
        #uri{user=(<<"client1">>), domain=MainIp, port=5070, opts=[]} =
            Contact,
        Self ! {Ref, ok_1}
    end,
    Opts1 = [{callback, Fun1}, get_request, get_response, make_contact],
    RUri1 = "<sip:[::1]:5071>",
    {resp, Resp1} = nksip_uac:options({ipv6, client1}, RUri1, Opts1),
    #sipmsg{
        ruri = #uri{domain=(<<"[::1]">>)}, 
        vias = [#via{domain=MainIp, opts=ViaOpts1}],
        transport = Transp1
    } = Resp1,
    <<"::1">> = nksip_lib:get_value(<<"received">>, ViaOpts1),
    RPort1 = nksip_lib:get_integer(<<"rport">>, ViaOpts1),
    %% For UDP transport, local ip is set to [:::] (?)
    #transport{
        proto = udp,
        local_ip =  {0,0,0,0,0,0,0,1},
        local_port = RPort1,
        remote_ip = {0,0,0,0,0,0,0,1},
        remote_port = 5071,
        listen_ip = {0,0,0,0,0,0,0,1},
        listen_port = 5070
    } = Transp1,
    ok = tests_util:wait(Ref, [ok_1]),


    Fun2 = fun({req, #sipmsg{contacts=[Contact]}}) ->
        #uri{
            user=(<<"client1">>), domain=MainIp, port=5070, 
            opts=[{<<"transport">>, <<"tcp">>}]
        } = Contact,
        Self ! {Ref, ok_2}
    end,
    Opts2 = [{callback, Fun2}, get_request, get_response, make_contact],
    RUri2 = "<sip:[::1]:5071;transport=tcp>",
    {resp, Resp2} = nksip_uac:options({ipv6, client1}, RUri2, Opts2),
    #sipmsg{
        ruri = #uri{domain=(<<"[::1]">>)}, 
        vias = [#via{domain=MainIp, opts=ViaOpts2}],
        transport = Transp2
    } = Resp2,
    <<"::1">> = nksip_lib:get_value(<<"received">>, ViaOpts2),
    RPort2 = nksip_lib:get_integer(<<"rport">>, ViaOpts2),
    %% For TCP transport, local ip is set to [::1]
    #transport{
        proto = tcp,
        local_ip =  {0,0,0,0,0,0,0,1},
        local_port = RPort2,
        remote_ip = {0,0,0,0,0,0,0,1},
        remote_port = 5071,
        listen_ip = {0,0,0,0,0,0,0,1},
        listen_port = 5070
    } = Transp2,
    ok = tests_util:wait(Ref, [ok_2]),
    ok.


invite() ->
    C1 = {ipv6, client1},
    C2 = {ipv6, client2},
    RUri = "sip:[::1]:5071",
    Ref = make_ref(),
    Hds = {headers, [
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
        {"Nk-Op", "ok"}
    ]},
    {ok, 200, [{dialog_id, DialogId1}]} = nksip_uac:invite(C1, RUri, [Hds]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, []} = nksip_uac:options(C1, DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(C1, DialogId1, [Hds]),
    ok = nksip_uac:ack(C1, DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),
    {ok, 200, [{dialog_id, DialogId2}]} = nksip_uac:invite(C2, DialogId2, [Hds]),
    ok = nksip_uac:ack(C2, DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, []} = nksip_uac:bye(C2, DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, bye}]),
    ok.



proxy() ->
    C1 = {ipv6, client1},
    C2 = {ipv6, client2},
    S1Uri = "sip:[::1]",
    Ref = make_ref(),
    Hds = {headers, [
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
        {"Nk-Op", "ok"}
    ]},

    {ok, 200, []} = nksip_uac:register(C1, S1Uri, [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C2, S1Uri, [unregister_all]),
    
    {ok, 200, []} = nksip_uac:register(C1, S1Uri, [make_contact]),
    {ok, 200, []} = nksip_uac:register(C2, S1Uri, [make_contact]),

    %% C1 will send an INVITE to C2
    %% First, it is sent to Server1, which changes the uri to the registered one
    %% and routes the request (stateless, no record_route) to Server2
    %% Server2 routes to C2 (stateful, record_route)
    Route = {route, "<sip:[::1];lr>"},
    {ok, 200, [{dialog_id, DialogId1}, {<<"Nk-Id">>, [<<"client2,server2,server1">>]}]} = 
        nksip_uac:invite(C1, "sip:client2@nksip", [Route, Hds, {fields, [<<"Nk-Id">>]}]),

    %% The ACK is sent to Server2, and it sends it to Client2
    {req, ACK} = nksip_uac:ack(C1, DialogId1, [get_request]),
    [#uri{domain=(<<"[::1]">>), port=5061, opts=[<<"lr">>, {<<"transport">>, <<"tcp">>}]}]   = 
        nksip_sipmsg:field(ACK, parsed_routes),

    DialogId2 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(C2, DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(C1, DialogId1, []),
    ok.


bridge_4_6() ->
    %% Client1 is IPv6
    %% Client3 is IPv4
    %% Server1 and Server2 listens on both
    C1 = {ipv6, client1},
    C3 = {ipv6, client3},
    Hds = {headers, [{"Nk-Op", "ok"}]},

    {ok, 200, []} = nksip_uac:register(C1, "sip:[::1]", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(C3, "sip:127.0.0.1", [unregister_all]),
    
    {ok, 200, []} = nksip_uac:register(C1, "sip:[::1]", [make_contact]),
    {ok, 200, []} = nksip_uac:register(C3, "sip:127.0.0.1", [make_contact]),

    %% C1 will send an INVITE to C3
    %% First, it is sent to Server1 (IPv6), which changes the uri to the registered one
    %% and routes the request (stateless, no record_route, IPv6) to Server2
    %% Server2 routes to C3 (stateful, record_route, IPv4)
    Route1 = {route, "<sip:[::1];lr>"},
    Fields1 = {fields, [<<"Nk-Id">>, parsed_contacts]},
    {ok, 200, Values1} = nksip_uac:invite(C1, "sip:client3@nksip", [Route1, Hds, Fields1]),
    %% C3 has generated a IPv4 Contact
    [
        {dialog_id, DialogId1}, 
        {<<"Nk-Id">>, [<<"client3,server2,server1">>]},
        {parsed_contacts, [#uri{domain = <<"127.0.0.1">>}]}
    ] = Values1,

    %% The ACK is sent to Server2, and it sends it to Client2
    {req, ACK1} = nksip_uac:ack(C1, DialogId1, [get_request]),
    [#uri{domain=(<<"[::1]">>), port=5061, opts=[<<"lr">>, {<<"transport">>, <<"tcp">>}]}]   = 
        nksip_sipmsg:field(ACK1, parsed_routes),
    #uri{domain=(<<"127.0.0.1">>)} = nksip_sipmsg:field(ACK1, parsed_ruri),

    DialogId3 = nksip_dialog:field(C1, DialogId1, remote_id),
    {ok, 200, []} = nksip_uac:options(C3, DialogId3, []),
    {ok, 200, []} = nksip_uac:bye(C1, DialogId1, []),
    ok.


torture_1() ->
    Msg1 = 
        <<"REGISTER sip:[2001:db8::10] SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Max-Forwards: 70\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::1]>\r\n"
        "CSeq: 98176 REGISTER\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
   #sipmsg{
        ruri = #uri{domain = <<"[2001:db8::10]">>, port = 0},
        vias = [#via{domain = <<"[2001:db8::9:1]">>, 
                     opts = [{<<"branch">>,<<"z9hG4bKas3-111">>}]}],
        contacts = [#uri{disp = <<"\"Caller\" ">>, user = <<"caller">>,
                         domain = <<"[2001:db8::1]">>}]
    } = parse(Msg1),
    ok.

torture_2() ->
    Msg2 = 
        <<"REGISTER sip:2001:db8::10 SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Max-Forwards: 70\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::1]>\r\n"
        "CSeq: 98176 REGISTER\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    {reply_error, 400, <<"Invalid Request-URI">>} = parse(Msg2),
    ok.

torture_3() ->
    Msg3 = 
        <<"REGISTER sip:[2001:db8::10:5070] SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::1]>\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 98176 REGISTER\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    #sipmsg{ruri = #uri{domain = <<"[2001:db8::10:5070]">>, port=0}} = parse(Msg3),
    ok.

torture_4() ->
    Msg4 = 
        <<"REGISTER sip:[2001:db8::10]:5070 SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::1]>\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 98176 REGISTER\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    #sipmsg{ruri = #uri{domain = <<"[2001:db8::10]">>, port=5070}} = parse(Msg4),
    ok.

torture_5() ->
    Msg5 = 
        <<"BYE sip:[2001:db8::10] SIP/2.0\r\n"
        "To: sip:user@example.com;tag=bd76ya\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];received=[2001:db8::9:255];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 321 BYE\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    #sipmsg{
        vias = [#via{domain = <<"[2001:db8::9:1]">>,
                     opts = [{<<"received">>, Rec1 = <<"[2001:db8::9:255]">>},
                             {<<"branch">>, <<"z9hG4bKas3-111">>}]}]
    } = parse(Msg5),
    {ok,{16#2001,16#db8,0,0,0,0,16#9,16#255}} = nksip_lib:to_ip(Rec1),
    ok.

torture_6() ->
    Msg6 = 
        <<"OPTIONS sip:[2001:db8::10] SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];received=2001:db8::9:255;branch=z9hG4bKas3\r\n"
        "Call-ID: SSG95523997077@hlau_4100\r\n"
        "Max-Forwards: 70\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::9:1]>\r\n"
        "CSeq: 921 OPTIONS\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    #sipmsg{
        vias = [#via{domain = <<"[2001:db8::9:1]">>,
                     opts = [{<<"received">>, Rec2 = <<"2001:db8::9:255">>},
                             {<<"branch">>, <<"z9hG4bKas3">>}]}]
    } = parse(Msg6),
    {ok,{8193,3512,0,0,0,0,9,597}} = nksip_lib:to_ip(Rec2),
    ok.

torture_7() ->
    Msg7 = 
        <<"INVITE sip:user@[2001:db8::10] SIP/2.0\r\n"
        "To: sip:user@[2001:db8::10]\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::20];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::20]>\r\n"
        "CSeq: 8612 INVITE\r\n"
        "Max-Forwards: 70\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 251\r\n"   %% RFC says 268!! errata??
        "\r\n"
        "v=0\r\n"
        "o=assistant 971731711378798081 0 IN IP6 2001:db8::20\r\n"
        "s=Live video feed for today's meeting\r\n"
        "c=IN IP6 2001:db8::20\r\n"
        "t=3338481189 3370017201\r\n"
        "m=audio 6000 RTP/AVP 2\r\n"
        "a=rtpmap:2 G726-32/8000\r\n"
        "m=video 6024 RTP/AVP 107\r\n"
        "a=rtpmap:107 H263-1998/90000\r\n">>,
    #sipmsg{
        body = #sdp{address = {<<"IN">>,<<"IP6">>,<<"2001:db8::20">>},
                    connect = {<<"IN">>,<<"IP6">>,<<"2001:db8::20">>}}
    } = parse(Msg7),
    ok.
    
torture_8() ->
    Msg8 = 
        <<"BYE sip:user@host.example.net SIP/2.0\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1]:6050;branch=z9hG4bKas3-111\r\n"
        "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bKjhja8781hjuaij65144\r\n"
        "Via: SIP/2.0/TCP [2001:db8::9:255];branch=z9hG4bK451jj;received=192.0.2.200\r\n"
        "Call-ID: 997077@lau_4100\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 89187 BYE\r\n"
        "To: sip:user@example.net;tag=9817--94\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    #sipmsg{vias = [
        #via{domain = <<"[2001:db8::9:1]">>, port = 6050,
             opts = [{<<"branch">>,<<"z9hG4bKas3-111">>}]},
        #via{domain = <<"192.0.2.1">>, port = 0,
             opts = [{<<"branch">>,<<"z9hG4bKjhja8781hjuaij65144">>}]},
        #via{proto = tcp, domain = <<"[2001:db8::9:255]">>, port = 0,
             opts = [{<<"branch">>,<<"z9hG4bK451jj">>}, {<<"received">>,<<"192.0.2.200">>}]}
    ]} = parse(Msg8),
    ok.

torture_9() ->
    Msg9 = 
        <<"INVITE sip:user@[2001:db8::10] SIP/2.0\r\n"
        "To: sip:user@[2001:db8::10]\r\n"
        "From: sip:user@example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [2001:db8::9:1];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Contact: \"Caller\" <sip:caller@[2001:db8::9:1]>\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 8912 INVITE\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 189\r\n"   %% RFC says 181!!
        "\r\n"
        "v=0\r\n"
        "o=bob 280744730 28977631 IN IP4 host.example.com\r\n"
        "s=\r\n"
        "t=0 0\r\n"
        "m=audio 22334 RTP/AVP 0\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "m=video 6024 RTP/AVP 107\r\n"
        "c=IN IP6 2001:db8::1\r\n"
        "a=rtpmap:107 H263-1998/90000\r\n">>,
    #sipmsg{
        body = #sdp{
            address = {<<"IN">>,<<"IP4">>,<<"host.example.com">>},
            medias = [
                #sdp_m{connect = {<<"IN">>,<<"IP4">>,<<"192.0.2.1">>}},
                #sdp_m{connect = {<<"IN">>,<<"IP6">>,<<"2001:db8::1">>}}
            ]
        }
    } = parse(Msg9),
    ok.
 
torture_10() ->
    Msg10 = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@east.example.com;tag=81x2\r\n"
        "Via: SIP/2.0/UDP [::ffff:192.0.2.10]:19823;branch=z9hG4bKbh19\r\n"
        "Via: SIP/2.0/UDP [::ffff:192.0.2.2];branch=z9hG4bKas3-111\r\n"
        "Call-ID: SSG9559905523997077@hlau_4100\r\n"
        "Contact: \"T. desk phone\" <sip:ted@[::ffff:192.0.2.2]>\r\n"
        "CSeq: 612 INVITE\r\n"
        "Max-Forwards: 70\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 245\r\n"     %% RFC says 236!!
        "\r\n"
        "v=0\r\n"
        "o=assistant 971731711378798081 0 IN IP6 ::ffff:192.0.2.2\r\n"
        "s=Call me soon, please!\r\n"
        "c=IN IP6 ::ffff:192.0.2.2\r\n"
        "t=3338481189 3370017201\r\n"
        "m=audio 6000 RTP/AVP 2\r\n"
        "a=rtpmap:2 G726-32/8000\r\n"
        "m=video 6024 RTP/AVP 107\r\n"
        "a=rtpmap:107 H263-1998/90000\r\n">>,
    #sipmsg{
        vias = [
            #via{domain = <<"[::ffff:192.0.2.10]">>, port = 19823},
            #via{domain = <<"[::ffff:192.0.2.2]">>,port = 0}
        ],
        body = #sdp{
            address = {<<"IN">>,<<"IP6">>,<<"::ffff:192.0.2.2">>},
            connect = {<<"IN">>,<<"IP6">>,<<"::ffff:192.0.2.2">>}
        }
    } = parse(Msg10),

    error = nksip_lib:to_ip(<<"2001:db8:::192.0.2.1">>),
    {ok, {0,0,0,0,0,16#ffff,16#C000,16#0202}} = 
        nksip_lib:to_ip(<<"::ffff:192.0.2.2">>),
    ok.




parse(Msg) ->
    case nksip_parse:packet(test, #transport{}, Msg) of
        {ok, Raw, <<>>}  -> nksip_parse:raw_sipmsg(Raw);
        {error, Error} -> {error, Error}
    end.
