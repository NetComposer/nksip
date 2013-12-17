%% -------------------------------------------------------------------
%%
%% torture_test: RFC4475 Transaction (3.2.1) and Application (3.3.1 to 3.3.15) 
%% Torture Tests
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

-module(torture3_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


torture3_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun transaction_1/0}, 
            {timeout, 60, fun application_1/0}, 
            {timeout, 60, fun application_2/0}, 
            {timeout, 60, fun application_3/0}, 
            {timeout, 60, fun application_4/0}, 
            {timeout, 60, fun application_5/0}, 
            {timeout, 60, fun application_6/0}, 
            {timeout, 60, fun application_7/0}, 
            {timeout, 60, fun application_8/0}, 
            {timeout, 60, fun application_9/0}, 
            {timeout, 60, fun application_10/0}, 
            {timeout, 60, fun application_11/0}, 
            {timeout, 60, fun application_12/0}, 
            {timeout, 60, fun application_13/0}, 
            {timeout, 60, fun application_14/0}, 
            {timeout, 60, fun application_15/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({torture, server1}, [
        {transport, {udp, {0,0,0,0}, 5060}},
        registrar,
        no_100
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = sipapp_server:stop({torture, server1}).



transaction_1() ->
	Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.org;tag=33242\r\n"
        "Max-Forwards: 3\r\n"
        "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bK\r\n"
        "Accept: application/sdp\r\n"
        "Call-ID: badbranch.sadonfo23i420jv0as0derf3j3n\r\n"
        "CSeq: 8 OPTIONS\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{vias=[#via{opts = [{<<"branch">>,<<"z9hG4bK">>}]}]} = Req = parse(Msg),
    % It is detected as a pre-RFC3261 tag
    true = nksip_call_uas:transaction_id(Req) < 0,
    ok.


application_1() ->
	Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "CSeq: 193942 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.95;branch=z9hG4bKkdj.insuf\r\n"
        "Content-Type: application/sdp\r\n"
        "l: 152\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.95\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.95\r\n"
        "t=0 0""\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid From\r\n", _/binary>> = send(udp, Msg),
    ok.


application_2() ->        
	Msg = 
        <<"OPTIONS nobodyKnowsThisScheme:totallyopaquecontent SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=384\r\n"
        "Max-Forwards: 3\r\n"
        "Call-ID: unkscm.nasdfasser0q239nwsdfasdkl34\r\n"
        "CSeq: 3923423 OPTIONS\r\n"
        "Via: SIP/2.0/TCP host9.example.com;branch=z9hG4bKkdjuw39234\r\n"
        "Content-Length: 0\r\n"
    	"\r\n">>,
    <<"SIP/2.0 416 Unsupported URI Scheme\r\n", _/binary>> = send(tcp, Msg),
    ok.


application_3() ->        
    Msg = 
        <<"OPTIONS soap.beep://192.0.2.103:3002 SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=384\r\n"
        "Max-Forwards: 3\r\n"
        "Call-ID: novelsc.asdfasser0q239nwsdfasdkl34\r\n"
        "CSeq: 3923423 OPTIONS\r\n"
        "Via: SIP/2.0/TCP host9.example.com;branch=z9hG4bKkdjuw39234\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    <<"SIP/2.0 416 Unsupported URI Scheme\r\n", _/binary>> = send(tcp, Msg),
    ok.


%% NOTE: Changed Via parameters to use TCP and avoid retransmissions
application_4() ->        
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: isbn:2983792873\r\n"
        "From: <http://www.example.com>;tag=3234233\r\n"
        "Call-ID: unksm2.daksdj@hyphenated-host.example.com\r\n"
        "CSeq: 234902 REGISTER\r\n"
        "Max-Forwards: 70\r\n"
        "Via: SIP/2.0/TCP 192.0.2.21:5060;branch=z9hG4bKkdjuw\r\n"
        "Contact: <name:John_Smith>\r\n"
        "l: 0\r\n"
        "\r\n">>,
    <<"SIP/2.0 416 Unsupported URI Scheme\r\n", _/binary>> = send(tcp, Msg),
    ok.


%% NOTE: Changed Via parameters to use TCP
application_5() ->        
    Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:j_user@example.com\r\n"
        "From: sip:caller@example.net;tag=242etr\r\n"
        "Max-Forwards: 6\r\n"
        "Call-ID: bext01.0ha0isndaksdj\r\n"
        "Require: nothingSupportsThis, nothingSupportsThisEither\r\n"
        "Proxy-Require: noProxiesSupportThis, norDoAnyProxiesSupportThis\r\n"
        "CSeq: 8 OPTIONS\r\n"
        "Via: SIP/2.0/TCP fold-and-staple.example.com;branch=z9hG4bKkdjuw\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    <<"SIP/2.0 420 Bad Extension\r\n", _/binary>> = send(tcp, Msg),
    ok.


application_6() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "Contact: <sip:caller@host5.example.net>\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=8392034\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: invut.0ha0isndaksdjadsfij34n23d\r\n"
        "CSeq: 235448 INVITE\r\n"
        "Via: SIP/2.0/UDP somehost.example.com;branch=z9hG4bKkdjuw\r\n"
        "Content-Type: application/unknownformat\r\n"
        "Content-Length: 40\r\n"
        "\r\n"
        "<audio>\r\n"
        " <pcmu port=\"443\"/>\r\n"
        "</audio>\r\n">>,
    #sipmsg{
        content_type = {<<"application/unknownformat">>,[]},
        body = <<"<audio>\r\n <pcmu port=\"443\"/>\r\n</audio>\r\n">>
    } = parse(Msg),
    ok.


application_7() ->
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:j.user@example.com;tag=87321hj23128\r\n"
        "Max-Forwards: 8\r\n"
        "Call-ID: regaut01.0ha0isndaksdj\r\n"
        "CSeq: 9338 REGISTER\r\n"
        "Via: SIP/2.0/TCP 192.0.2.253;branch=z9hG4bKkdjuw\r\n"
        "Authorization: NoOneKnowsThisScheme opaque-data=here\r\n"
        "Content-Length:0\r\n"
        "\r\n">>,
    Req = #sipmsg{} = parse(Msg),
    % No authentication token found
    [] = nksip_auth:get_authentication(Req, fun(_, _) -> <<"1234">> end),
    ok.

    
application_8() ->
    Msg = 
        <<"INVITE sip:user@company.com SIP/2.0\r\n"
        "Contact: <sip:caller@host25.example.net>\r\n"
        "Via: SIP/2.0/UDP 192.0.2.25;branch=z9hG4bKkdjuw\r\n"
        "Max-Forwards: 70\r\n"
        "CSeq: 5 INVITE\r\n"
        "Call-ID: multi01.98asdh@192.0.2.1\r\n"
        "CSeq: 59 INVITE\r\n"
        "Call-ID: multi01.98asdh@192.0.2.2\r\n"
        "From: sip:caller@example.com;tag=3413415\r\n"
        "To: sip:user@example.com\r\n"
        "To: sip:other@example.net\r\n"
        "From: sip:caller@example.net;tag=2923420123\r\n"
        "Content-Type: application/sdp\r\n"
        "l: 154\r\n"
        "Contact: <sip:caller@host36.example.net>\r\n"
        "Max-Forwards: 5\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.25\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.25\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
        <<"SIP/2.0 400 Invalid From\r\n", _/binary>> = send(udp, Msg),
        ok.


application_9() ->
    Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "Via: SIP/2.0/UDP host5.example.net;branch=z9hG4bK293423\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:other@example.net;tag=3923942\r\n"
        "Call-ID: mcl01.fhn2323orihawfdoa3o4r52o3irsdf\r\n"
        "CSeq: 15932 OPTIONS\r\n"
        "Content-Length: 13\r\n"
        "Max-Forwards: 60\r\n"
        "Content-Length: 5\r\n"
        "Content-Type: text/plain\r\n"
        "\r\n"
        "Theres no way to know how many octets are supposed to be here.\r\n">>,
    <<"SIP/2.0 400 Invalid Content-Length\r\n", _/binary>> = send(udp, Msg),
    ok.


%% Where in RFC3261 says a message with a Via having 255.255.255.255
%% must be dicarded?
application_10() ->
    _Msg = 
        <<"SIP/2.0 200 OK\r\n"
        "Via: SIP/2.0/UDP 192.0.2.198;branch=z9hG4bK1324923\r\n"
        "Via: SIP/2.0/UDP 255.255.255.255;branch=z9hG4bK1saber23\r\n"
        "Call-ID: bcast.0384840201234ksdfak3j2erwedfsASdf\r\n"
        "CSeq: 35 INVITE\r\n"
        "From: sip:user@example.com;tag=11141343\r\n"
        "To: sip:user@example.edu;tag=2229\r\n"
        "Content-Length: 154\r\n"
        "Content-Type: application/sdp\r\n"
        "Contact: <sip:user@host28.example.com>\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.198\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.198\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    ok.


application_11() ->
    %% Control of Max-Forwards=0 is already done in proxy_test
    _Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=3ghsd41\r\n"
        "Call-ID: zeromf.jfasdlfnm2o2l43r5u0asdfas\r\n"
        "CSeq: 39234321 OPTIONS\r\n"
        "Via: SIP/2.0/UDP host1.example.com;branch=z9hG4bKkdjuw2349i\r\n"
        "Max-Forwards: 0\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    ok.


%% Changed to TCP
application_12() ->
    nksip_registrar:delete({torture, server1}, sip, <<"watson">>, <<"example.com">>),
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "Via: SIP/2.0/TCP saturn.example.com:5060;branch=z9hG4bKkdjuw\r\n"
        "Max-Forwards: 70\r\n"
        "From: sip:watson@example.com;tag=DkfVgjkrtMwaerKKpe\r\n"
        "To: sip:watson@example.com\r\n"
        "Call-ID: cparam01.70710@saturn.example.com\r\n"
        "CSeq: 2 REGISTER\r\n"
        "Contact: sip:+19725552222@gw1.example.net;unknownparam\r\n"
        "l: 0\r\n"
        "\r\n">>,
    Reply = send(tcp, Msg),
    #sipmsg{
        class = {resp, 200, _},
        contacts = [
            #uri{
                scheme = sip, user = <<"+19725552222">>,
                domain = <<"gw1.example.net">>, port = 0, 
                opts = [],  ext_opts = [<<"unknownparam">>,{<<"expires">>,<<"3600">>}]
            }
        ]
    } = parse(Reply),
    ok.


%% Changed to TCP
application_13() ->
    nksip_registrar:delete({torture, server1}, sip, <<"watson">>, <<"example.com">>),
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "Via: SIP/2.0/TCP saturn.example.com:5060;branch=z9hG4bKkdjuw\r\n"
        "Max-Forwards: 70\r\n"
        "From: sip:watson@example.com;tag=838293\r\n"
        "To: sip:watson@example.com\r\n"
        "Call-ID: cparam02.70710@saturn.example.com\r\n"
        "CSeq: 3 REGISTER\r\n"
        "Contact: <sip:+19725552222@gw1.example.net;unknownparam>\r\n"
        "l: 0\r\n"
        "\r\n">>,
    Reply = send(tcp, Msg),
    #sipmsg{
        class = {resp, 200, _},
        contacts = [
            #uri{
                scheme = sip, user = <<"+19725552222">>,
                domain = <<"gw1.example.net">>, port = 0,
                opts = [<<"unknownparam">>], ext_opts = [{<<"expires">>,<<"3600">>}]
            }
        ]
    } = parse(Reply),
    ok.


%% Changed to TCP
application_14() ->
    nksip_registrar:delete({torture, server1}, sip, <<"user">>, <<"example.com">>),
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=8\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: regescrt.k345asrl3fdbv@192.0.2.1\r\n"
        "CSeq: 14398234 REGISTER\r\n"
        "Via: SIP/2.0/TCP host5.example.com;branch=z9hG4bKkdjuw\r\n"
        "M: <sip:user@example.com?Route=%3Csip:sip.example.com%3E>\r\n"
        "L:0\r\n"
        "\r\n">>,
    Reply = send(tcp, Msg),
    #sipmsg{
        class = {resp, 200, _},
        contacts = [
            #uri{
                scheme = sip, user = <<"user">>,
                domain = <<"example.com">>, port = 0, opts = [],
                headers = [{<<"Route">>,<<"%3Csip:sip.example.com%3E">>}],
                ext_opts = [{<<"expires">>,<<"3600">>}],
                ext_headers = []
            }
        ]
    } = parse(Reply),
    ok.


application_15() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: sip:j_user@example.com\r\n"
        "Contact: <sip:caller@host15.example.net>\r\n"
        "From: sip:caller@example.net;tag=234\r\n"
        "Max-Forwards: 5\r\n"
        "Call-ID: sdp01.ndaksdj9342dasdd\r\n"
        "Accept: text/nobodyKnowsThis\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.15;branch=z9hG4bKkdjuw\r\n"
        "Content-Length: 150\r\n"
        "Content-Type: application/sdp\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.5\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.5\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    #sipmsg{
        headers = [{<<"Accept">>, <<"text/nobodyKnowsThis">>}]
    } = parse(Msg),
    ok.
 


%% Internal

parse(Msg) ->
    case nksip_parse:packet(test, #transport{proto=udp}, Msg) of
        {ok, Raw, <<>>} -> nksip_parse:raw_sipmsg(Raw);
        {ok, Raw, Tail} -> {tail, nksip_parse:raw_sipmsg(Raw), Tail};
        {more, More} -> {more, More};
        {error, Error} -> {error, Error}
    end.


send(udp, Msg) ->
    {ok, S} = gen_udp:open(0, [binary, {active, false}]),
    ok = gen_udp:send(S, {127,0,0,1}, 5060, Msg),
    {ok, {_, _, Bin}} = gen_udp:recv(S, 0, 1000),
    gen_udp:close(S),
    Bin;

send(tcp, Msg) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, 5060, [binary, {active, false}]),
    ok = gen_tcp:send(S, Msg),
    {ok, Bin} = gen_tcp:recv(S, 0, 5000),
    gen_tcp:close(S),
    Bin.



