%% -------------------------------------------------------------------
%%
%% torture_test: RFC4475 "Invalid" tests (3.1.2.1 to 3.1.2.19)
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

-module(torture2_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


torture2_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun invalid_1/0, 
            fun invalid_2/0, 
            fun invalid_3/0, 
            fun invalid_4/0, 
            fun invalid_5/0, 
            fun invalid_6/0, 
            fun invalid_7/0, 
            fun invalid_8/0, 
            fun invalid_9/0, 
            fun invalid_10/0, 
            fun invalid_11/0, 
            fun invalid_12/0, 
            fun invalid_13/0, 
            fun invalid_14/0, 
            fun invalid_15/0, 
            fun invalid_16/0, 
            fun invalid_17/0, 
            fun invalid_18/0, 
            fun invalid_19/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = sipapp_server:start({torture, server1}, [
        {transport, {udp, {0,0,0,0}, 5060}},
        no_100
    ]),
    timer:sleep(100),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = sipapp_server:stop({torture, server1}).



invalid_1() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=134161461246\r\n"
        "Max-Forwards: 7\r\n"
        "Call-ID: badinv01.0ha0isndaksdjasdf3234nas\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.15;;,;,,\r\n"
        "Contact: \"Joe\" <sip:joe@example.org>;;;;\r\n"
        "Content-Length: 152\r\n"
        "Content-Type: application/sdp\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.15\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid Via\r\n", _/binary>> = send(tcp, Msg),
    ok.


invalid_2() ->
    Msg =
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "Max-Forwards: 80\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=93942939o2\r\n"
        "Contact: <sip:caller@hungry.example.net>\r\n"
        "Call-ID: clerr.0ha0isndaksdjweiafasdk3\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP host5.example.com;branch=z9hG4bK-39234-23523\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 9999\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.155\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.155\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid Content-Length\r\n", _/binary>> = send(udp, Msg),
    ok.


invalid_3() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "Max-Forwards: 254\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=32394234\r\n"
        "Call-ID: ncl.0ha0isndaksdj2193423r542w35\r\n"
        "CSeq: 0 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.53;branch=z9hG4bKkdjuw\r\n"
        "Contact: <sip:caller@example53.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: -999\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.53\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.53\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid Content-Length\r\n", _/binary>> = send(tcp, Msg),
    ok.


invalid_4() ->
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "Via: SIP/2.0/TCP host129.example.com;branch=z9hG4bK342sdfoi3\r\n"
        "To: <sip:user@example.com>\r\n"
        "From: <sip:user@example.com>;tag=239232jh3\r\n"
        "CSeq: 36893488147419103232 REGISTER\r\n"
        "Call-ID: scalar02.23o0pd9vanlq3wnrlnewofjas9ui32\r\n"
        "Max-Forwards: 300\r\n"
        "Expires: 1<repeat count=100>0</repeat>\r\n"
        "Contact: <sip:user@host129.example.com>\r\n"
        "  ;expires=280297596632815\r\n"
        "Content-Length: 0""\r\n"
        "\r\n">>,
    <<"SIP/2.0 400 Invalid CSeq\r\n", _/binary>> = send(tcp, Msg),
    ok.


invalid_5() ->
    Msg = 
        <<"SIP/2.0 503 Service Unavailable\r\n"
        "Via: SIP/2.0/TCP host129.example.com;branch=z9hG4bKzzxdiwo34sw;received=192.0.2.129\r\n"
        "To: <sip:user@example.com>\r\n"
        "From: <sip:other@example.net>;tag=2easdjfejw\r\n"
        "CSeq: 9292394834772304023312 OPTIONS\r\n"
        "Call-ID: scalarlg.noase0of0234hn2qofoaf0232aewf2394r\r\n"
        "Retry-After: 949302838503028349304023988""\r\n"
        "Warning: 1812 overture \"In Progress\"\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    {error, <<"Invalid CSeq">>} = parse(Msg),
    ok.


invalid_6() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: \"Mr. J. User <sip:j.user@example.com>\r\n"
        "From: sip:caller@example.net;tag=93334\r\n"
        "Max-Forwards: 10\r\n"
        "Call-ID: quotbal.aksdj\r\n"
        "Contact: <sip:caller@host59.example.net>\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.59:5050;branch=z9hG4bKkdjuw39234\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 152\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.15\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid To\r\n", _/binary>> = send(udp, Msg),
    ok.



invalid_7() ->
    Msg = 
        <<"INVITE <sip:user@example.com> SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=39291\r\n"
        "Max-Forwards: 23\r\n"
        "Call-ID: ltgtruri.1@192.0.2.5\r\n"
        "CSeq: 1 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.5\r\n"
        "Contact: <sip:caller@host5.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 159\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.5\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.5\r\n"
        "t=3149328700 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Invalid Request-URI\r\n", _/binary>> = send(tcp, Msg),
    ok.


%% NOTE: NkSIP consideres this message a invalid one, and it is discarded
invalid_8() ->
    Msg = 
        <<"INVITE sip:user@example.com; lr SIP/2.0\r\n"
        "To: sip:user@example.com;tag=3xfe-9921883-z9f\r\n"
        "From: sip:caller@example.net;tag=231413434\r\n"
        "Max-Forwards: 5\r\n"
        "Call-ID: lwsruri.asdfasdoeoi2323-asdfwrn23-asd834rk423\r\n"
        "CSeq: 2130706432 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.1:5060;branch=z9hG4bKkdjuw2395\r\n"
        "Contact: <sip:caller@host1.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 159\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "t=3149328700 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    {error, message_unrecognized} = parse(Msg),
    ok.


invalid_9() ->
    Msg = 
        <<"INVITE  sip:user@example.com  SIP/2.0\r\n"
        "Max-Forwards: 8\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=8814\r\n"
        "Call-ID: lwsstart.dfknq234oi243099adsdfnawe3@example.com\r\n"
        "CSeq: 1893884 INVITE\r\n"
        "Via: SIP/2.0/UDP host1.example.com;branch=z9hG4bKkdjuw3923\r\n"
        "Contact: <sip:caller@host1.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 150\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    {error, message_unrecognized} = parse(Msg),
    ok.


invalid_10() ->
    Msg = 
        <<"OPTIONS sip:remote-target@example.com SIP/2.0\x20\x20\r\n"
        "Via: SIP/2.0/TCP host1.example.com;branch=z9hG4bK299342093\r\n"
        "To: <sip:remote-target@example.com>\r\n"
        "From: <sip:local-resource@example.com>;tag=329429089\r\n"
        "Call-ID: trws.oicu34958239neffasdhr2345r\r\n"
        "Accept: application/sdp\r\n"
        "CSeq: 238923 OPTIONS\r\n"
        "Max-Forwards: 70\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    {error, message_unrecognized} = parse(Msg),
    ok.


%% NOTE: NkSIP accepts escaped characters in RURI
invalid_11() ->
    Msg = 
         <<"INVITE sip:user@example.com?Route=%3Csip:example.com%3E SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=341518\r\n"
        "Max-Forwards: 7\r\n"
        "Contact: <sip:caller@host39923.example.net>\r\n"
        "Call-ID: escruri.23940-asdfhj-aje3br-234q098w-fawerh2q-h4n5\r\n"
        "CSeq: 149209342 INVITE\r\n"
        "Via: SIP/2.0/UDP host-of-the-hour.example.com;branch=z9hG4bKkdjuw\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 150\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    #sipmsg{} = parse(Msg),
    ok.


invalid_12() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:caller@example.net;tag=2234923\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: baddate.239423mnsadf3j23lj42--sedfnm234\r\n"
        "CSeq: 1392934 INVITE\r\n"
        "Via: SIP/2.0/UDP host.example.com;branch=z9hG4bKkdjuw\r\n"
        "Date: Fri, 01 Jan 2010 16:00:00 EST\r\n"
        "Contact: <sip:caller@host5.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 150\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.5\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.5\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    #sipmsg{headers=[{<<"Date">>, Date}]} = parse(Msg),
    error = nksip_parse:dates(Date),
    ok.


%% NOTE: NkSIP accepts escaped characters without <>,
%% but in this example, it is an "external" header
invalid_13() ->
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: sip:user@example.com;tag=998332\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: regbadct.k345asrl3fdbv@10.0.0.1\r\n"
        "CSeq: 1 REGISTER\r\n"
        "Via: SIP/2.0/UDP 135.180.130.133:5060;branch=z9hG4bKkdjuw\r\n"
        "Contact: sip:user@example.com?Route=%3Csip:sip.example.com%3E\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{contacts = [Contact]} = parse(Msg),
    #uri{ext_headers = [{<<"Route">>, <<"%3Csip:sip.example.com%3E">>}]} = Contact,
    ok.


invalid_14() ->
    Msg = 
        <<"OPTIONS sip:user@example.org SIP/2.0\r\n"
        "Via: SIP/2.0/UDP host4.example.com:5060;branch=z9hG4bKkdju43234\r\n"
        "Max-Forwards: 70\r\n"
        "From: \"Bell, Alexander\" <sip:a.g.bell@example.com>;tag=433423\r\n"
        "To: \"Watson, Thomas\" < sip:t.watson@example.org >\r\n"
        "Call-ID: badaspec.sdf0234n2nds0a099u23h3hnnw009cdkne3\r\n"
        "Accept: application/sdp\r\n"
        "CSeq: 3923239 OPTIONS\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{
        to = #uri{
            disp = <<"\"Watson, Thomas\" ">>, scheme = sip,
            user = <<"t.watson">>, pass = <<>>,
            domain = <<"example.org">>, port = 0
        }
    } = parse(Msg),
    ok.


invalid_15() ->
    Msg = 
         <<"OPTIONS sip:t.watson@example.org SIP/2.0\r\n"
        "Via:     SIP/2.0/UDP c.example.com:5060;branch=z9hG4bKkdjuw\r\n"
        "Max-Forwards:      70\r\n"
        "From:    Bell, Alexander <sip:a.g.bell@example.com>;tag=43\r\n"
        "To:      Watson, Thomas <sip:t.watson@example.org>\r\n"
        "Call-ID: baddn.31415@c.example.com\r\n"
        "Accept: application/sdp\r\n"
        "CSeq:    3923239 OPTIONS\r\n"
        "l: 0\r\n"
        "\r\n">>,
    <<"SIP/2.0 400 Invalid From\r\n", _/binary>> = send(tcp, Msg),
    ok.


%% NOTE: NkSIP treats this message as invalid, not as having a invalid SIP version
invalid_16() ->
    Msg = 
        <<"OPTIONS sip:t.watson@example.org SIP/7.0\r\n"
        "Via:     SIP/7.0/UDP c.example.com;branch=z9hG4bKkdjuw\r\n"
        "Max-Forwards:     70\r\n"
        "From:    A. Bell <sip:a.g.bell@example.com>;tag=qweoiqpe\r\n"
        "To:      T. Watson <sip:t.watson@example.org>\r\n"
        "Call-ID: badvers.31417@c.example.com\r\n"
        "CSeq:    1 OPTIONS\r\n"
        "l: 0\r\n"
        "\r\n">>,
    {error, message_unrecognized} = parse(Msg),
    ok.


invalid_17() ->
    Msg = 
         <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=34525\r\n"
        "Max-Forwards: 6\r\n"
        "Call-ID: mismatch01.dj0234sxdfl3\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP host.example.com;branch=z9hG4bKkdjuw\r\n"
        "l: 0\r\n"
        "\r\n">>,
    <<"SIP/2.0 400 Method Mismatch\r\n", _/binary>> = send(tcp, Msg),
    ok.


invalid_18() ->
    Msg = 
        <<"NEWMETHOD sip:user@example.com SIP/2.0\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:caller@example.net;tag=34525\r\n"
        "Max-Forwards: 6\r\n"
        "Call-ID: mismatch02.dj0234sxdfl3\r\n"
        "CSeq: 8 INVITE\r\n"
        "Contact: <sip:caller@host.example.net>\r\n"
        "Via: SIP/2.0/UDP host.example.net;branch=z9hG4bKkdjuw\r\n"
        "Content-Type: application/sdp\r\n"
        "l: 138\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    <<"SIP/2.0 400 Method Mismatch\r\n", _/binary>> = send(tcp, Msg),
    ok.


invalid_19() ->
    Msg = 
        <<"SIP/2.0 4294967301 better not break the receiver\r\n"
        "Via: SIP/2.0/UDP 192.0.2.105;branch=z9hG4bK2398ndaoe\r\n"
        "Call-ID: bigcode.asdof3uj203asdnf3429uasdhfas3ehjasdfas9i\r\n"
        "CSeq: 353494 INVITE\r\n"
        "From: <sip:user@example.com>;tag=39ansfi3\r\n"
        "To: <sip:user@example.edu>;tag=902jndnke3\r\n"
        "Content-Length: 0\r\n"
        "Contact: <sip:user@host105.example.com>\r\n"
        "\r\n">>,
    {error, <<"Invalid Code">>} = parse(Msg),
    ok.



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
    {ok, {_, _, Bin}} = gen_udp:recv(S, 0, 5000),
    gen_udp:close(S),
    Bin;

send(tcp, Msg) ->
    {ok, S} = gen_tcp:connect({127,0,0,1}, 5060, [binary, {active, false}]),
    ok = gen_tcp:send(S, Msg),
    {ok, Bin} = gen_tcp:recv(S, 0, 5000),
    gen_tcp:close(S),
    Bin.

