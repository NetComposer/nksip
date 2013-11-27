%% -------------------------------------------------------------------
%%
%% torture1_test: RFC4475 "Valid" tests (3.1.1.1 to 3.1.1.13)
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

-module(torture1_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


valid_1_test() ->
    ?debugFmt("Starting ~p", [?MODULE]),

    Msg = 
        <<"INVITE sip:vivekg@chair-dnrc.example.com;unknownparam SIP/2.0\r\n"
        "TO :\r\n"
        " sip:vivekg@chair-dnrc.example.com ;   tag    = 1918181833n\r\n"
        "from   : \"J Rosenberg \\\\\\\"\"       <sip:jdrosen@example.com>\r\n"
        " ;\r\n"
        " tag = 98asjd8\r\n"
        "MaX-fOrWaRdS: 0068\r\n"
        "Call-ID: wsinv.ndaksdj@192.0.2.1\r\n"
        "Content-Length   : 150\r\n"
        "cseq: 0009\r\n"
        " INVITE\r\n"
        "Via  : SIP  /   2.0\r\n"
        " /UDP\r\n"
        "    192.0.2.2;branch=390skdjuw\r\n"
        "s :\r\n"
        "NewFangledHeader:   newfangled value\r\n"
        " continued newfangled value\r\n"
        "UnknownHeaderWithUnusualValue: ;;,,;;,;\r\n"
        "Content-Type: application/sdp\r\n"
        "Route:\r\n"
        " <sip:services.example.com;lr;unknownwith=value;unknown-no-value>\r\n"
        "v:  SIP  / 2.0  / TCP     spindle.example.com   ;\r\n"
        "  branch  =   z9hG4bK9ikj8  ,\r\n"
        " SIP  /    2.0   / UDP  192.168.255.111   ; branch=\r\n"
        " z9hG4bK30239\r\n"
        "m:\"Quoted string \\\"\\\"\" <sip:jdrosen@example.com> ; newparam =\r\n"
        "      newvalue ;\r\n"
        "    secondparam ; q = 0.33\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.3\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.4\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    case parse(Msg) of
        #sipmsg{
            ruri = #uri{user = <<"vivekg">>, domain = <<"chair-dnrc.example.com">>,
                        port = 0, opts = [<<"unknownparam">>]},
            to = #uri{user = <<"vivekg">>, domain = <<"chair-dnrc.example.com">>,
                      port = 0, ext_opts = [{<<"tag">>,<<"1918181833n">>}],
                      ext_headers = []},
            from = #uri{disp = <<"\"J Rosenberg \\\\\\\"\"       ">>,
                        user = <<"jdrosen">>, domain = <<"example.com">>,
                        port = 0, ext_opts = [{<<"tag">>,<<"98asjd8">>}]},
            forwards = 68,
            call_id = <<"wsinv.ndaksdj@192.0.2.1">>,
            cseq = 9,
            cseq_method = 'INVITE',
            vias = [
                #via{proto = udp, domain = <<"192.0.2.2">>, port = 0,
                     opts = [{<<"branch">>, <<"390skdjuw">>}]},
                #via{proto = tcp, domain = <<"spindle.example.com">>, port = 0,
                     opts = [{<<"branch">>,<<"z9hG4bK9ikj8">>}]},
                #via{proto = udp, domain = <<"192.168.255.111">>, port = 0,
                     opts = [{<<"branch">>,<<"z9hG4bK30239">>}]}
            ],
            content_type = {<<"application/sdp">>,[]},
            routes = [#uri{scheme = sip,user = <<>>,
                           domain = <<"services.example.com">>,port = 0,
                           opts = [<<"lr">>,
                                   {<<"unknownwith">>,<<"value">>},
                                   <<"unknown-no-value">>]}],
            contacts = [#uri{disp = <<"\"Quoted string \\\"\\\"\" ">>,
                             scheme = sip,user = <<"jdrosen">>,pass = <<>>,
                             domain = <<"example.com">>,port = 0,opts = [],headers = [],
                             ext_opts = [{<<"newparam">>,<<"newvalue">>},
                                         <<"secondparam">>, {<<"q">>,<<"0.33">>}]}],
            headers = [
                {<<"Subject">>, <<>>},
                {<<"Newfangledheader">>, 
                    <<"newfangled value\r\n continued newfangled value">>},
                {<<"Unknownheaderwithunusualvalue">>,<<";;,,;;,;">>}
            ],
            from_tag = <<"98asjd8">>,
            to_tag = <<"1918181833n">>,
            body = #sdp{
                sdp_vsn = <<"0">>, user = <<"mhandley">>,
                id = 29739,vsn = 7272939,
                address = {<<"IN">>,<<"IP4">>,<<"192.0.2.3">>},
                session = <<"-">>,
                connect = {<<"IN">>,<<"IP4">>,<<"192.0.2.4">>},
                bandwidth = [],
                time = [{0,0,[]}],      
                attributes = [],
                medias = [
                    #sdp_m{
                        media = <<"audio">>, port = 49217, nports = 1, 
                        proto = <<"RTP/AVP">>, fmt = [<<"0">>,<<"12">>]
                    },
                    #sdp_m{
                        media = <<"video">>,port = 3227,nports = 1,   
                        proto = <<"RTP/AVP">>, fmt = [<<"31">>],
                        attributes = [{<<"rtpmap">>,[<<"31">>,<<"LPC">>]}]}
                ]
            }
        } ->
            ok;
        Other ->
            ?debugFmt("Error ~p\n~p\n", [?LINE, lager:pr(Other, ?MODULE)])
    end.


valid_2_test() ->
    Msg = 
        <<"!interesting-Method0123456789_*+`.%indeed'~ sip:1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*:&it+has=1,weird!*pas$wo~d_too.(doesn't-it)@example.com SIP/2.0\r\n"
        "Via: SIP/2.0/TCP host1.example.com;branch=z9hG4bK-.!%66*_+`'~\r\n"
        "To: \"BEL:\\\x07 NUL:\\\x00 DEL:\\\x7F\" <sip:1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*@example.com>\r\n"
        "From: token1~` token2'+_ token3*%!.- <sip:mundane@example.com> ;fromParam''~+*_!.-%="
            "\xD1\x80\xD0\xB0\xD0\xB1\xD0\xBE\xD1\x82\xD0\xB0\xD1\x8E\xD1\x89\xD0\xB8\xD0\xB9"
            ";tag=_token~1'+`*%!-.\r\n"
        "Call-ID: intmeth.word%ZK-!.*_+'@word`~)(><:\\/\"][?}{\r\n"
        "CSeq: 139122385 !interesting-Method0123456789_*+`.%indeed'~\r\n"
        "Max-Forwards: 255\r\n"
        "extensionHeader-!.%*+_`'~:\xEF\xBB\xBF\xE5\xA4\xA7\xE5\x81\x9C\xE9\x9B\xBB\r\n"
        "Content-Length: 0\r\n"
        "\r\n">>,
    L1 = list_to_binary("\xD1\x80\xD0\xB0\xD0\xB1\xD0\xBE\xD1\x82\xD0\xB0\xD1\x8E\xD1\x89\xD0\xB8\xD0\xB9"),
    L2 = list_to_binary("\"BEL:\\\x07 NUL:\\\x00 DEL:\\\x7F\" "),
    L3 = list_to_binary("\xEF\xBB\xBF\xE5\xA4\xA7\xE5\x81\x9C\xE9\x9B\xBB"),    
    case parse(Msg) of
        #sipmsg{
            class = {req,<<"!interesting-Method0123456789_*+`.%indeed'~">>},
            ruri = #uri{
                    scheme = sip, 
                    user = <<"1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*">>,
                    pass = <<"&it+has=1,weird!*pas$wo~d_too.(doesn't-it)">>,
                    domain = <<"example.com">>,port = 0
            },
            vias = [
                #via{
                    proto = tcp, domain = <<"host1.example.com">>,
                    port = 0, opts = [{<<"branch">>,<<"z9hG4bK-.!%66*_+`'~">>}]}
            ],
            to = #uri{
                disp = L2,
                scheme = sip, 
                user = <<"1_unusual.URI~(to-be!sure)&isn't+it$/crazy?,/;;*">>,
                pass = <<>>,
                domain = <<"example.com">>, port = 0,opts = []
            },
            from = #uri{
                disp = <<"token1~` token2'+_ token3*%!.- ">>,
                scheme = sip, user = <<"mundane">>,
                domain = <<"example.com">>, port = 0,opts = [],headers = [],
                ext_opts = [
                    {<<"fromParam''~+*_!.-%">>, L1},
                    {<<"tag">>,<<"_token~1'+`*%!-.">>}
                ]
            },
            call_id = <<"intmeth.word%ZK-!.*_+'@word`~)(><:\\/\"][?}{">>,
            cseq = 139122385,
            cseq_method = <<"!interesting-Method0123456789_*+`.%indeed'~">>,
            forwards = 255,
            headers = [{<<"Extensionheader-!.%*+_`'~">>, L3}], 
            from_tag = <<"_token~1'+`*%!-.">>, to_tag = <<>>
        } ->
            ok;
        Other ->
            ?debugFmt("Error ~p\n~p\n", [?LINE, lager:pr(Other, ?MODULE)])
    end.


valid_3_test() ->
    Msg = 
        <<"INVITE sip:sips%3Auser%40example.com@example.net SIP/2.0\r\n"
        "To: sip:%75se%72@example.com\r\n"
        "From: <sip:I%20have%20spaces@example.net>;tag=938\r\n"
        "Max-Forwards: 87\r\n"
        "i: esc01.239409asdfakjkn23onasd0-3234\r\n"
        "CSeq: 234234 INVITE\r\n"
        "Via: SIP/2.0/UDP host5.example.net;branch=z9hG4bKkdjuw\r\n"
        "C: application/sdp\r\n"
        "Contact:\r\n"
        "    <sip:cal%6Cer@host5.example.net;%6C%72;n%61me=v%61lue%25%34%31>\r\n"
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
    #sipmsg{
        ruri = #uri{
            user = <<"sips%3Auser%40example.com">>, pass = <<>>,
            domain = <<"example.net">>, port = 0
        },
        to = #uri{
            user = <<"%75se%72">>, domain = <<"example.com">>,port = 0
        },
        from = #uri{
            user = <<"I%20have%20spaces">>, domain = <<"example.net">>,port = 0,
            ext_opts = [{<<"tag">>,<<"938">>}]
        },
        contacts = [
            #uri{
                disp = <<>>,scheme = sip,
                user = <<"cal%6Cer">>,pass = <<>>,
                domain = <<"host5.example.net">>,port = 0,
                opts = [<<"%6C%72">>,{<<"n%61me">>,<<"v%61lue%25%34%31">>}]
            }
        ]
    } = parse(Msg),
    ok.


valid_4_test() ->
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: sip:null-%00-null@example.com\r\n"
        "From: sip:null-%00-null@example.com;tag=839923423\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: escnull.39203ndfvkjdasfkq3w4otrq0adsfdfnavd\r\n"
        "CSeq: 14398234 REGISTER\r\n"
        "Via: SIP/2.0/UDP host5.example.com;branch=z9hG4bKkdjuw\r\n"
        "Contact: <sip:%00@host5.example.com>\r\n"
        "Contact: <sip:%00%00@host5.example.com>\r\n"
        "L:0\r\n"
        "\r\n">>,
#sipmsg{
        to = #uri{
            user = <<"null-%00-null">>, domain = <<"example.com">>
        },
        from = #uri{
            user = <<"null-%00-null">>, domain = <<"example.com">>,
            port = 0, ext_opts = [{<<"tag">>,<<"839923423">>}]
        },
        contacts = [
            #uri{user = <<"%00">>, domain = <<"host5.example.com">>},
            #uri{user = <<"%00%00">>, domain = <<"host5.example.com">>}
        ]
    } = parse(Msg),
    ok.


valid_5_test() ->
    Msg = 
        <<"RE%47IST%45R sip:registrar.example.com SIP/2.0\r\n"
        "To: \"%Z%45\" <sip:resource@example.com>\r\n"
        "From: \"%Z%45\" <sip:resource@example.com>;tag=f232jadfj23\r\n"
        "Call-ID: esc02.asdfnqwo34rq23i34jrjasdcnl23nrlknsdf\r\n"
        "Via: SIP/2.0/TCP host.example.com;branch=z9hG4bK209%fzsnel234\r\n"
        "CSeq: 29344 RE%47IST%45R\r\n"
        "Max-Forwards: 70\r\n"
        "Contact: <sip:alias1@host1.example.com>\r\n"
        "C%6Fntact: <sip:alias2@host2.example.com>\r\n"
        "Contact: <sip:alias3@host3.example.com>\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{
        class = {req,<<"RE%47IST%45R">>},
        ruri = #uri{domain = <<"registrar.example.com">>},
        to = #uri{
            disp = <<"\"%Z%45\" ">>, user = <<"resource">>,pass = <<>>,
            domain = <<"example.com">>,port = 0
        },
        from = #uri{
            disp = <<"\"%Z%45\" ">>, user = <<"resource">>,pass = <<>>,
            domain = <<"example.com">>,port = 0, ext_opts = [{<<"tag">>,<<"f232jadfj23">>}]
        },
        contacts = [
            #uri{user = <<"alias1">>, domain = <<"host1.example.com">>},
            #uri{user = <<"alias3">>, domain = <<"host3.example.com">>}
        ],
        headers = [{<<"C%6fntact">>, <<"<sip:alias2@host2.example.com>">>}]
    } = parse(Msg),
    ok.


valid_6_test() ->
    Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: caller<sip:caller@example.com>;tag=323\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID: lwsdisp.1234abcd@funky.example.com\r\n"
        "CSeq: 60 OPTIONS\r\n"
        "Via: SIP/2.0/UDP funky.example.com;branch=z9hG4bKkdjuw\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{
        from = #uri{disp = <<"caller">>, scheme = sip,
                    user = <<"caller">>, pass = <<>>, domain = <<"example.com">>,
                    port = 0,opts = [],headers = [],
                    ext_opts = [{<<"tag">>,<<"323">>}],
                    ext_headers = []
                }
    } = parse(Msg),
    ok.


valid_7_test() ->
    Msg = 
        <<"INVITE sip:user@example.com SIP/2.0\r\n"
        "To: \"I have a user name of extreme extreme extreme extreme extreme extreme extreme extreme extreme extreme proportion\" <sip:user@example.com:6000;unknownparam1=verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongvalue;longparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename=shortvalue;verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongParameterNameWithNoValue>\r\n"
        "F: sip:amazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallername@example.net;tag=12982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982424;unknownheaderparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename=unknowheaderparamvaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue;unknownValuelessparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamname\r\n"
        "Call-ID: longreq.onereallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallylongcallid\r\n"
        "CSeq: 3882340 INVITE\r\n"
        "Unknown-LongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLong-Name:unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-value;unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-name =unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-value\r\n"
        "Via: SIP/2.0/TCP sip33.example.com\r\n"
        "v: SIP/2.0/TCP sip32.example.com\r\n"
        "V: SIP/2.0/TCP sip31.example.com\r\n"
        "Via: SIP/2.0/TCP sip30.example.com\r\n"
        "ViA: SIP/2.0/TCP sip29.example.com\r\n"
        "VIa: SIP/2.0/TCP sip28.example.com\r\n"
        "VIA: SIP/2.0/TCP sip27.example.com\r\n"
        "via: SIP/2.0/TCP sip26.example.com\r\n"
        "viA: SIP/2.0/TCP sip25.example.com\r\n"
        "vIa: SIP/2.0/TCP sip24.example.com\r\n"
        "vIA: SIP/2.0/TCP sip23.example.com\r\n"
        "V :  SIP/2.0/TCP sip22.example.com\r\n"
        "v :  SIP/2.0/TCP sip21.example.com\r\n"
        "V  : SIP/2.0/TCP sip20.example.com\r\n"
        "v  : SIP/2.0/TCP sip19.example.com\r\n"
        "Via : SIP/2.0/TCP sip18.example.com\r\n"
        "Via  : SIP/2.0/TCP sip17.example.com\r\n"
        "Via: SIP/2.0/TCP sip16.example.com\r\n"
        "Via: SIP/2.0/TCP sip15.example.com\r\n"
        "Via: SIP/2.0/TCP sip14.example.com\r\n"
        "Via: SIP/2.0/TCP sip13.example.com\r\n"
        "Via: SIP/2.0/TCP sip12.example.com\r\n"
        "Via: SIP/2.0/TCP sip11.example.com\r\n"
        "Via: SIP/2.0/TCP sip10.example.com\r\n"
        "Via: SIP/2.0/TCP sip9.example.com\r\n"
        "Via: SIP/2.0/TCP sip8.example.com\r\n"
        "Via: SIP/2.0/TCP sip7.example.com\r\n"
        "Via: SIP/2.0/TCP sip6.example.com\r\n"
        "Via: SIP/2.0/TCP sip5.example.com\r\n"
        "Via: SIP/2.0/TCP sip4.example.com\r\n"
        "Via: SIP/2.0/TCP sip3.example.com\r\n"
        "Via: SIP/2.0/TCP sip2.example.com\r\n"
        "Via: SIP/2.0/TCP sip1.example.com\r\n"
        "Via: SIP/2.0/TCP host.example.com;received=192.0.2.5;branch=verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongbranchvalue\r\n"
        "Max-Forwards: 70\r\n"
        "Contact: <sip:amazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallername@host5.example.net>\r\n"
        "Content-Type: application/sdp\r\n"
        "l: 150\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.1\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.1\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    #sipmsg{
        to = #uri{
            disp = <<"\"I have a user name of extreme extreme extreme extreme extreme extreme extreme extreme extreme extreme proportion\" ">>,
            scheme = sip, user = <<"user">>,pass = <<>>, domain = <<"example.com">>,port = 6000,
            opts = [
                {<<"unknownparam1">>,
                    <<"verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongvalue">>},
                {<<"longparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename">>,
                    <<"shortvalue">>},
                <<"verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongParameterNameWithNoValue">>
            ]
        },
        from = #uri{
            user = <<"amazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallername">>,
            pass = <<>>,domain = <<"example.net">>,port = 0,opts = [],
            ext_opts = [
                {<<"tag">>,<<"12982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982982424">>},
                {<<"unknownheaderparamnamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamenamename">>,
                    <<"unknowheaderparamvaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevaluevalue">>},
                <<"unknownValuelessparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamnameparamname">>
            ]
        },
        call_id = <<"longreq.onereallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallyreallylongcallid">>,
        cseq = 3882340,
        vias = [
            #via{proto = tcp,domain = <<"sip33.example.com">>},
            #via{domain = <<"sip32.example.com">>},
            #via{domain = <<"sip31.example.com">>},
            #via{domain = <<"sip30.example.com">>},
            #via{domain = <<"sip29.example.com">>},
            #via{domain = <<"sip28.example.com">>},
            #via{domain = <<"sip27.example.com">>},
            #via{domain = <<"sip26.example.com">>},
            #via{domain = <<"sip25.example.com">>},
            #via{domain = <<"sip24.example.com">>},
            #via{domain = <<"sip23.example.com">>},
            #via{domain = <<"sip22.example.com">>},
            #via{domain = <<"sip21.example.com">>},
            #via{domain = <<"sip20.example.com">>},
            #via{domain = <<"sip19.example.com">>},
            #via{domain = <<"sip18.example.com">>},
            #via{domain = <<"sip17.example.com">>},
            #via{domain = <<"sip16.example.com">>},
            #via{domain = <<"sip15.example.com">>},
            #via{domain = <<"sip14.example.com">>},
            #via{domain = <<"sip13.example.com">>},
            #via{domain = <<"sip12.example.com">>},
            #via{domain = <<"sip11.example.com">>},
            #via{domain = <<"sip10.example.com">>},
            #via{domain = <<"sip9.example.com">>},
            #via{domain = <<"sip8.example.com">>},
            #via{domain = <<"sip7.example.com">>},
            #via{domain = <<"sip6.example.com">>},
            #via{domain = <<"sip5.example.com">>},
            #via{domain = <<"sip4.example.com">>},
            #via{domain = <<"sip3.example.com">>},
            #via{domain = <<"sip2.example.com">>},
            #via{domain = <<"sip1.example.com">>},
            #via{
                proto = tcp,domain = <<"host.example.com">>, port = 0,
                opts = [
                    {<<"received">>,<<"192.0.2.5">>},
                    {<<"branch">>,<<"verylonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglongbranchvalue">>}]
            }
        ], 
        contacts = [
            #uri{
                user = <<"amazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallernameamazinglylongcallername">>,
                domain = <<"host5.example.net">>
            }
        ],
        headers = [{<<"Unknown-LongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLongLong-Name">>, HeaderValue}]
    } = parse(Msg),
    [
        {<<"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-value">>,
            [{<<"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-name">>,
                <<"unknown-longlonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglonglong-parameter-value">>}]}
    ] = nksip_parse:tokens(HeaderValue),
    ok.


valid_8_test() ->
    Msg = 
        <<"REGISTER sip:example.com SIP/2.0\r\n"
        "To: sip:j.user@example.com\r\n"
        "From: sip:j.user@example.com;tag=43251j3j324\r\n"
        "Max-Forwards: 8\r\n"
        "I: dblreq.0ha0isndaksdj99sdfafnl3lk233412\r\n"
        "Contact: sip:j.user@host.example.com\r\n"
        "CSeq: 8 REGISTER\r\n"
        "Via: SIP/2.0/UDP 192.0.2.125;branch=z9hG4bKkdjuw23492\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
        "INVITE sip:joe@example.com SIP/2.0\r\n"
        "t: sip:joe@example.com\r\n"
        "From: sip:caller@example.net;tag=141334\r\n"
        "Max-Forwards: 8\r\n"
        "Call-ID: dblreq.0ha0isnda977644900765@192.0.2.15\r\n"
        "CSeq: 8 INVITE\r\n"
        "Via: SIP/2.0/UDP 192.0.2.15;branch=z9hG4bKkdjuw380234\r\n"
        "Content-Type: application/sdp\r\n"
        "Content-Length: 150\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.15\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.15\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m =video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    {tail, #sipmsg{}, <<"INVITE ", _/binary>>} = parse(Msg),
    ok.


valid_9_test() ->
    Msg = 
        <<"OPTIONS sip:user;par=u%40example.net@example.com SIP/2.0\r\n"
        "To: sip:j_user@example.com\r\n"
        "From: sip:caller@example.org;tag=33242\r\n"
        "Max-Forwards: 3\r\n"
        "Call-ID: semiuri.0ha0isndaksdj\r\n"
        "CSeq: 8 OPTIONS\r\n"
        "Accept: application/sdp, application/pkcs7-mime,\r\n"
        "  multipart/mixed, multipart/signed,\r\n"
        "  message/sip, message/sipfrag\r\n"
        "Via: SIP/2.0/UDP 192.0.2.1;branch=z9hG4bKkdjuw\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{
        ruri = #uri{
            user = <<"user;par=u%40example.net">>, pass = <<>>,
            domain = <<"example.com">>
        },
        to = #uri{
            disp = <<>>,scheme = sip,user = <<"j_user">>,
            pass = <<>>,domain = <<"example.com">>,port = 0
        },
        from = #uri{
            disp = <<>>,scheme = sip,user = <<"caller">>,
            pass = <<>>,domain = <<"example.org">>,port = 0,
            ext_opts = [{<<"tag">>,<<"33242">>}]
        },
        headers = [{<<"Accept">>, Accept}]
    } = parse(Msg),
    [ 
        {<<"application/sdp">>,[]},
        {<<"application/pkcs7-mime">>,[]},
        {<<"multipart/mixed">>,[]},
        {<<"multipart/signed">>,[]},
        {<<"message/sip">>,[]},
        {<<"message/sipfrag">>,[]}
    ] = nksip_parse:tokens(Accept),
    ok.


valid_10_test() ->
    Msg = 
        <<"OPTIONS sip:user@example.com SIP/2.0\r\n"
        "To: sip:user@example.com\r\n"
        "From: <sip:caller@example.com>;tag=323\r\n"
        "Max-Forwards: 70\r\n"
        "Call-ID:  transports.kijh4akdnaqjkwendsasfdj\r\n"
        "Accept: application/sdp\r\n"
        "CSeq: 60 OPTIONS\r\n"
        "Via: SIP/2.0/UDP t1.example.com;branch=z9hG4bKkdjuw\r\n"
        "Via: SIP/2.0/SCTP t2.example.com;branch=z9hG4bKklasjdhf\r\n"
        "Via: SIP/2.0/TLS t3.example.com;branch=z9hG4bK2980unddj\r\n"
        "Via: SIP/2.0/UNKNOWN t4.example.com;branch=z9hG4bKasd0f3en\r\n"
        "Via: SIP/2.0/TCP t5.example.com;branch=z9hG4bK0a9idfnee\r\n"
        "l: 0\r\n"
        "\r\n">>,
    #sipmsg{
        vias = [
            #via{
                proto = udp, domain = <<"t1.example.com">>, port = 0,
                opts = [{<<"branch">>,<<"z9hG4bKkdjuw">>}]
            },
            #via{
                proto = sctp, domain = <<"t2.example.com">>, port = 0,
                opts = [{<<"branch">>,<<"z9hG4bKklasjdhf">>}]
            },
            #via{
                proto = tls, domain = <<"t3.example.com">>, port = 0,
                opts = [{<<"branch">>,<<"z9hG4bK2980unddj">>}]
            },
            #via{
                proto = <<"UNKNOWN">>,domain = <<"t4.example.com">>, port = 0,
                opts = [{<<"branch">>,<<"z9hG4bKasd0f3en">>}]
            },
            #via{
                proto = tcp, domain = <<"t5.example.com">>, port = 0,
                opts = [{<<"branch">>,<<"z9hG4bK0a9idfnee">>}]
            }
        ]
    } = parse(Msg),
    ok.


valid_11_test() ->
    Msg = 
        <<"MESSAGE sip:kumiko@example.org SIP/2.0\r\n"
        "Via: SIP/2.0/UDP 127.0.0.1:5070;branch=z9hG4bK-d87543-4dade06d0bdb11ee-1--d87543-;rport\r\n"
        "Max-Forwards: 70\r\n"
        "Route: <sip:127.0.0.1:5080>\r\n"
        "Identity: r5mwreLuyDRYBi/0TiPwEsY3rEVsk/G2WxhgTV1PF7hHuLIK0YWVKZhKv9Mj8UeXqkMVbnVq37CD+813gvYjcBUaZngQmXc9WNZSDNGCzA+fWl9MEUHWIZo1CeJebdY/XlgKeTa0Olvq0rt70Q5jiSfbqMJmQFteeivUhkMWYUA=\r\n"
        "Contact: <sip:fluffy@127.0.0.1:5070>\r\n"
        "To: <sip:kumiko@example.org>\r\n"
        "From: <sip:fluffy@example.com>;tag=2fb0dcc9\r\n"
        "Call-ID: 3d9485ad0c49859b@Zmx1ZmZ5LW1hYy0xNi5sb2NhbA..\r\n"
        "CSeq: 1 MESSAGE\r\n"
        "Content-Transfer-Encoding: binary\r\n"
        "Content-Type: multipart/mixed;boundary=7a9cbec02ceef655\r\n"
        "Date: Sat, 15 Oct 2005 04:44:56 GMT\r\n"
        "User-Agent: SIPimp.org/0.2.5 (curses)\r\n"
        "Content-Length: 553\r\n"
        "\r\n"
        "--7a9cbec02ceef655\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Transfer-Encoding: binary\r\n"
        "\r\n"
        "Hello\r\n"
        "--7a9cbec02ceef655\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Content-Transfer-Encoding: binary\r\n"
        "\r\n"
        "\x30\x82\x01\x52\x06\x09\x2A\x86\r\n"
        "\x48\x86\xF7\x0D\x01\x07\x02\xA0\x82\x01\x43\x30\x82\x01\x3F\x02"
        "\x01\x01\x31\x09\x30\x07\x06\x05\x2B\x0E\x03\x02\x1A\x30\x0B\x06"
        "\x09\x2A\x86\x48\x86\xF7\x0D\x01\x07\x01\x31\x82\x01\x20\x30\x82"
        "\x01\x1C\x02\x01\x01\x30\x7C\x30\x70\x31\x0B\x30\x09\x06\x03\x55"
        "\x04\x06\x13\x02\x55\x53\x31\x13\x30\x11\x06\x03\x55\x04\x08\x13"
        "\x0A\x43\x61\x6C\x69\x66\x6F\x72\x6E\x69\x61\x31\x11\x30\x0F\x06"
        "\x03\x55\x04\x07\x13\x08\x53\x61\x6E\x20\x4A\x6F\x73\x65\x31\x0E"
        "\x30\x0C\x06\x03\x55\x04\x0A\x13\x05\x73\x69\x70\x69\x74\x31\x29"
        "\x30\x27\x06\x03\x55\x04\x0B\x13\x20\x53\x69\x70\x69\x74\x20\x54"
        "\x65\x73\x74\x20\x43\x65\x72\x74\x69\x66\x69\x63\x61\x74\x65\x20"
        "\x41\x75\x74\x68\x6F\x72\x69\x74\x79\x02\x08\x01\x95\x00\x71\x02"
        "\x33\x01\x13\x30\x07\x06\x05\x2B\x0E\x03\x02\x1A\x30\x0D\x06\x09"
        "\x2A\x86\x48\x86\xF7\x0D\x01\x01\x01\x05\x00\x04\x81\x80\x8E\xF4"
        "\x66\xF9\x48\xF0\x52\x2D\xD2\xE5\x97\x8E\x9D\x95\xAA\xE9\xF2\xFE"
        "\x15\xA0\x66\x59\x71\x62\x92\xE8\xDA\x2A\xA8\xD8\x35\x0A\x68\xCE"
        "\xFF\xAE\x3C\xBD\x2B\xFF\x16\x75\xDD\xD5\x64\x8E\x59\x3D\xD6\x47"
        "\x28\xF2\x62\x20\xF7\xE9\x41\x74\x9E\x33\x0D\x9A\x15\xED\xAB\xDB"
        "\x93\xD1\x0C\x42\x10\x2E\x7B\x72\x89\xD2\x9C\xC0\xC9\xAE\x2E\xFB"
        "\xC7\xC0\xCF\xF9\x17\x2F\x3B\x02\x7E\x4F\xC0\x27\xE1\x54\x6D\xE4"
        "\xB6\xAA\x3A\xBB\x3E\x66\xCC\xCB\x5D\xD6\xC6\x4B\x83\x83\x14\x9C"
        "\xB8\xE6\xFF\x18\x2D\x94\x4F\xE5\x7B\x65\xBC\x99\xD0\x05"
        "--7a9cbec02ceef655--\r\n">>,
    #sipmsg{
        vias = [
            #via{proto = udp,domain = <<"127.0.0.1">>, port = 5070,
                 opts = [
                    {<<"branch">>,<<"z9hG4bK-d87543-4dade06d0bdb11ee-1--d87543-">>}, <<"rport">>]
            }
        ],
        routes = [
            #uri{
                scheme = sip,user = <<>>, pass = <<>>,
                domain = <<"127.0.0.1">>,port = 5080
            }
        ],
        headers = [
            {<<"Identity">>, <<"r5mwreLuyDRYBi/0TiPwEsY3rEVsk/G2WxhgTV1PF7hHuLIK0YWVKZhKv9Mj8UeXqkMVbnVq37CD+813gvYjcBUaZngQmXc9WNZSDNGCzA+fWl9MEUHWIZo1CeJebdY/XlgKeTa0Olvq0rt70Q5jiSfbqMJmQFteeivUhkMWYUA=">>},
            {<<"Content-Transfer-Encoding">>,<<"binary">>},
            {<<"Date">>, Date},
            {<<"User-Agent">>,<<"SIPimp.org/0.2.5 (curses)">>}
        ],
        content_type = 
            {<<"multipart/mixed">>,
               [{<<"boundary">>, <<"7a9cbec02ceef655">>}]
            },
        body = <<"--7a9cbec02ceef655\r\nContent-Type: text/plain\r\nCo", _/binary>>
    } = parse(Msg),
    [{{2005,10,15},{4,44,56}}] = nksip_parse:dates(Date),
    ok.


valid_12_test() ->
    Msg = 
        <<"SIP/2.0 200 = 2**3 * 5**2 \xD0\xBD\xD0\xBE\x20\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD0\xBD\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD1\x82\xD1\x8C\x20\x2D\x20\xD0\xBF\xD1\x80\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\xD0\xB5\r\n"
        "Via: SIP/2.0/UDP 192.0.2.198;branch=z9hG4bK1324923\r\n"
        "Call-ID: unreason.1234ksdfak3j2erwedfsASdf\r\n"
        "CSeq: 35 INVITE\r\n"
        "From: sip:user@example.com;tag=11141343\r\n"
        "To: sip:user@example.edu;tag=2229\r\n"
        "Content-Length: 154\r\n"
        "Content-Type: application/sdp\r\n"
        "Contact: <sip:user@host198.example.com>\r\n"
        "\r\n"
        "v=0\r\n"
        "o=mhandley 29739 7272939 IN IP4 192.0.2.198\r\n"
        "s=-\r\n"
        "c=IN IP4 192.0.2.198\r\n"
        "t=0 0\r\n"
        "m=audio 49217 RTP/AVP 0 12\r\n"
        "m=video 3227 RTP/AVP 31\r\n"
        "a=rtpmap:31 LPC\r\n">>,
    #sipmsg{
        class = {resp, 200, <<"= 2**3 * 5**2 \xD0\xBD\xD0\xBE\x20\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD0\xBD\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\x20\xD0\xB4\xD0\xB5\xD0\xB2\xD1\x8F\xD1\x82\xD1\x8C\x20\x2D\x20\xD0\xBF\xD1\x80\xD0\xBE\xD1\x81\xD1\x82\xD0\xBE\xD0\xB5">>}
    } = parse(Msg),
    ok.


valid_13_test() ->
    Msg = 
        <<"SIP/2.0 100\x20\r\n"
        "Via: SIP/2.0/UDP 192.0.2.105;branch=z9hG4bK2398ndaoe\r\n"
        "Call-ID: noreason.asndj203insdf99223ndf\r\n"
        "CSeq: 35 INVITE\r\n"
        "From: <sip:user@example.com>;tag=39ansfi3\r\n"
        "To: <sip:user@example.edu>;tag=902jndnke3\r\n"
        "Content-Length: 0\r\n"
        "Contact: <sip:user@host105.example.com>\r\n"
        "\r\n">>,
    #sipmsg{class={resp, 100, <<>>}} = parse(Msg),
    ok.




%% Internal

parse(Msg) ->
    case nksip_parse:packet(test, #transport{proto=udp}, Msg) of
        {ok, Raw, <<>>} -> nksip_parse:raw_sipmsg(Raw);
        {ok, Raw, Tail} -> {tail, nksip_parse:raw_sipmsg(Raw), Tail}
    end.


