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
-include_lib("nkpacket/include/nkpacket.hrl").
-include("../include/nksip.hrl").
-include_lib("nklib/include/nklib.hrl").

-compile([export_all]).
-define(RECV(T), receive T -> ok after 1000 -> error(recv) end).

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
    nksip_config_cache:main_ip6().

start() ->
    tests_util:start_nksip(),

    %% NOTE: using 'any6' as ip for hosts fails in Linux
    %% (it works in OSX)

    {ok, _} = nksip:start(server1, ?MODULE, [
        {from, "sip:server1@nksip"},
        {plugins, [nksip_registrar]},
        {local_host6, "::1"},
        {transports, [{udp, all, 5060}, {udp, "::1", 5060}]}
    ]),

    {ok, _} = nksip:start(server2, ?MODULE, [
        {from, "sip:server2@nksip"},
        {local_host, "127.0.0.1"},
        {local_host6, "::1"},
        {transports, [{udp, all, 5061}, {udp, "::1", 5061}]}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, [
        {from, "sip:client1@nksip"},
        {transports, [{udp, "::1", 5070}]}
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, [
        {from, "sip:client2@nksip"},
        {transports, [{udp, "::1", 5071}]}
    ]),

    {ok, _} = nksip:start(client3, ?MODULE, [
        {from, "sip:client3@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5072}]}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(server2),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2),
    ok = nksip:stop(client3).


basic() ->
    MainIp = <<"[::1]">>,
    Self = self(),
    Ref = make_ref(),

    Fun1 = fun
        ({req, #sipmsg{contacts=[Contact]}, _Call}) ->
            #uri{user=(<<"client1">>), domain=MainIp, port=5070} = Contact,
            Self ! {Ref, ok_1};
        ({resp, 200, Resp1, _Call}) ->
            #sipmsg{
                ruri = #uri{domain=(<<"[::1]">>)}, 
                vias = [#via{domain=F_MainIp, opts=ViaOpts1}],
                nkport = NkPort1
            } = Resp1,
            <<"::1">> = nklib_util:get_value(<<"received">>, ViaOpts1),
            RPort1 = nklib_util:get_integer(<<"rport">>, ViaOpts1),
            %% For UDP transport, local ip is set to [:::] (?)
            #nkport{
                transp = udp,
                local_ip =  {0,0,0,0,0,0,0,1},
                local_port = RPort1,
                remote_ip = {0,0,0,0,0,0,0,1},
                remote_port = 5071,
                listen_ip = {0,0,0,0,0,0,0,1},
                listen_port = 5070
            } = NkPort1,
            Self ! {Ref, {ok_2, F_MainIp}}
    end,
    RUri1 = "<sip:[::1]:5071>",
    Opts1 = [async, {callback, Fun1}, get_request, contact],
    {async, _} = nksip_uac:options(client1, RUri1, Opts1),
    ?RECV({Ref, ok_1}),
    ?RECV({Ref, {ok_2, MainIp}}),
    
    Fun2 = fun
        ({req, #sipmsg{contacts=[Contact]}, _Call}) ->
            #uri{user=(<<"client1">>), domain=MainIp, port=5070, opts=COpts2} = Contact,
            true = lists:member({<<"transport">>, <<"tcp">>}, COpts2),
            Self ! {Ref, ok_3};
        ({resp, 200, Resp2, _Call}) ->
            #sipmsg{
                ruri = #uri{domain=(<<"[::1]">>)}, 
                vias = [#via{domain=MainIp, opts=ViaOpts2}],
                nkport = NkPort2
            } = Resp2,
            <<"::1">> = nklib_util:get_value(<<"received">>, ViaOpts2),
            RPort2 = nklib_util:get_integer(<<"rport">>, ViaOpts2),
            %% For TCP transport, local ip is set to [::1]
            #nkport{
                transp = tcp,
                local_ip =  {0,0,0,0,0,0,0,1},
                local_port = RPort2,
                remote_ip = {0,0,0,0,0,0,0,1},
                remote_port = 5071,
                listen_ip = {0,0,0,0,0,0,0,1},
                listen_port = 5070
            } = NkPort2,
            Self ! {Ref, ok_4}
    end,
    RUri2 = "<sip:[::1]:5071;transport=tcp>",
    Opts2 = [async, {callback, Fun2}, get_request, contact],
    {async, _} = nksip_uac:options(client1, RUri2, Opts2),
    ?RECV({Ref, ok_3}),
    ?RECV({Ref, ok_4}),
    ok.


invite() ->
    RUri = "sip:[::1]:5071",
    {Ref, RepHd} = tests_util:get_ref(),
    Hds = [ {add, "x-nk-op", "ok"}, RepHd],
    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(client1, RUri, Hds),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    {ok, 200, []} = nksip_uac:options(DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(DialogId1, Hds),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, client2),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, [{dialog, DialogId2}]} = nksip_uac:invite(DialogId2, Hds),
    ok = nksip_uac:ack(DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, []} = nksip_uac:bye(DialogId2, []),
    ok = tests_util:wait(Ref, [{client1, bye}]),
    ok.



proxy() ->
    S1Uri = "sip:[::1]",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),
    Hds = [{add, "x-nk-op", "ok"}, RepHd],

    {ok, 200, []} = nksip_uac:register(client1, S1Uri, [unregister_all]),
    {ok, 200, []} = nksip_uac:register(client2, S1Uri, [unregister_all]),
    
    % Avoid outbound support
    {ok, 200, []} = nksip_uac:register(client1, S1Uri, [contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(client2, S1Uri, [contact, {supported, ""}]),

    %% client1 will send an INVITE to client2
    %% First, it is sent to Server1, which changes the uri to the registered one
    %% and routes the request (stateless, no record_route) to Server2
    %% Server2 routes to client2 (stateful, record_route)
    Route = {route, "<sip:[::1];lr>"},
    {ok, 200, [{dialog, DialogId1}, {<<"x-nk-id">>, [<<"client2,server2,server1">>]}]} = 
        nksip_uac:invite(client1, "sip:client2@nksip", [Route, {meta, [<<"x-nk-id">>]}, 
                                                  {supported, ""}|Hds]),
    % Without outbound, the Record-Route has the NkQ format, and it is converted
    % to NkS when back, with transport tcp
    % With outbound, is has the N kF format, and it is not converted back (the flow
    % token has already info about the tcp)
    
    %% The ACK is sent to Server2, and it sends it to Client2
    AckFun = fun({req, AckReq, _Call}) ->
        [#uri{domain=(<<"[::1]">>), port=5061, opts=AckOpts}] = 
            nksip_sipmsg:meta(routes, AckReq),
        true = lists:member(<<"lr">>, AckOpts),
        true = lists:member({<<"transport">>, <<"tcp">>}, AckOpts),
        Self ! {Ref, ok_1}
    end,
    async = nksip_uac:ack(DialogId1, [async, {callback, AckFun}]),
    ?RECV({Ref, ok_1}),

    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, client2),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(DialogId1, []),
    ok.


bridge_4_6() ->
    %% Client1 is IPv6
    %% Client3 is IPv4
    %% Server1 and Server2 listens on both
    Ref = make_ref(),
    Self = self(),
    Hd = {add, "x-nk-op", "ok"},

    {ok, 200, []} = nksip_uac:register(client1, "sip:[::1]", [unregister_all]),
    {ok, 200, []} = nksip_uac:register(client3, "sip:127.0.0.1", [unregister_all]),
    
    % Avoid outbound support
    {ok, 200, []} = nksip_uac:register(client1, "sip:[::1]", [contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(client3, "sip:127.0.0.1", [contact, {supported, ""}]),

    %% client1 will send an INVITE to client3
    %% First, it is sent to Server1 (IPv6), which changes the uri to the registered one
    %% and routes the request (stateless, no record_route, IPv6) to Server2
    %% Server2 routes to client3 (stateful, record_route, IPv4)
    Route1 = {route, "<sip:[::1];lr>"},
    Fields1 = {meta, [<<"x-nk-id">>, contacts]},
    {ok, 200, Values1} = nksip_uac:invite(client1, "sip:client3@nksip", 
                                [Route1, Hd, Fields1, {supported, ""}]),
    %% client3 has generated a IPv4 Contact
    [
        {dialog, DialogId1}, 
        {<<"x-nk-id">>, [<<"client3,server2,server1">>]},
        {contacts, [#uri{domain = <<"127.0.0.1">>}]}
    ] = Values1,

    %% The ACK is sent to Server2, and it sends it to Client2
    FunAck = fun({req, ReqAck1, _Call}) ->
        [#uri{domain=(<<"[::1]">>), port=5061, opts=AckOpts}] = 
            nksip_sipmsg:meta(routes, ReqAck1),
        true = lists:member(<<"lr">>, AckOpts),
        true = lists:member({<<"transport">>, <<"tcp">>}, AckOpts),
        #uri{domain=(<<"127.0.0.1">>)} = nksip_sipmsg:meta(ruri, ReqAck1),
        Self ! {Ref, ok_1}
    end,
    async  = nksip_uac:ack(DialogId1, [async, {callback, FunAck}]),
    ?RECV({Ref, ok_1}),
   
    DialogId3 = nksip_dialog_lib:remote_id(DialogId1, client3),
    {ok, 200, []} = nksip_uac:options(DialogId3, []),
    {ok, 200, []} = nksip_uac:bye(DialogId1, []),
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
    {reply_error, {invalid, <<"Request-URI">>}, 
                  <<"SIP/2.0 400 Invalid Request-URI", _/binary>>} = parse(Msg2),
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
    {ok,{16#2001,16#db8,0,0,0,0,16#9,16#255}} = nklib_util:to_ip(Rec1),
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
    {ok,{8193,3512,0,0,0,0,9,597}} = nklib_util:to_ip(Rec2),
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
        #via{transp = tcp, domain = <<"[2001:db8::9:255]">>, port = 0,
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

    error = nklib_util:to_ip(<<"2001:db8:::192.0.2.1">>),
    {ok, {0,0,0,0,0,16#ffff,16#C000,16#0202}} = 
        nklib_util:to_ip(<<"::ffff:192.0.2.2">>),
    ok.


parse(Msg) ->
    case nksip_parse:packet(test, #nkport{}, Msg) of
        {ok, SipMsg, <<>>}  -> SipMsg;
        {reply_error, Error, Bin} -> {reply_error, Error, Bin};
        {error, Error} -> {error, Error}
    end.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(#{name:=Name}, State) ->
    ok = nkservice_server:put(Name, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        {ok, server1} ->
            Opts = [
                {insert, "x-nk-id", "server1"},
                {route, "<sip:[::1]:5061;lr;transport=tcp>"}
            ],
            Domains = nkservice_server:get(server1, domains),
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    process;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy_stateless, UriList, Opts}
                    end;
                _ ->
                    {proxy_stateless, ruri, Opts}
            end;
        {ok, server2} ->
            Opts = [
                record_route,
                {insert, "x-nk-id", "server2"}
            ],
            {proxy, ruri, Opts};
        {ok, _} ->
            process
    end.


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, SrvName} = nksip_request:srv_name(Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([SrvName|Ids])}],
    {reply, {ok, Hds}}.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.



