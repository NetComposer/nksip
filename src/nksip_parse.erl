%% -------------------------------------------------------------------
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

%% @doc SIP message parsing functions
%%
%% This module implements several functions to parse sip requests, responses
%% headers, uris, vias, etc.

-module(nksip_parse).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([method/1, scheme/1, aors/1, uris/1, ruris/1, vias/1]).
-export([tokens/1, integers/1, dates/1, header/1, extract_uri_routes/1]).
-export([transport/1, session_expires/1]).
-export([packet/3, raw_sipmsg/1, raw_header/1]).

-export_type([msg_class/0]).

-type msg_class() :: {req, nksip:method(), binary()} | 
                     {resp, nksip:response_code(), binary()}.

-compile([export_all]).


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Parses any `term()' into a valid `nksip:method()'. If recognized it will be an
%% `atom', or a `binary' if not.
-spec method(binary() | atom() | string()) -> 
    nksip:method() | binary().

method(Method) when is_atom(Method) ->
    Method;
method(Method) when is_list(Method) ->
    method(list_to_binary(Method));
method(Method) when is_binary(Method) ->
    case Method of
        <<"INVITE">> -> 'INVITE';
        <<"REGISTER">> -> 'REGISTER';
        <<"BYE">> -> 'BYE';
        <<"ACK">> -> 'ACK';
        <<"CANCEL">> -> 'CANCEL';
        <<"OPTIONS">> -> 'OPTIONS';
        <<"SUBSCRIBE">> -> 'SUBSCRIBE';
        <<"NOTIFY">> -> 'NOTIFY';
        <<"PUBLISH">> -> 'PUBLISH';
        <<"REFER">> -> 'REFER';
        <<"MESSAGE">> -> 'MESSAGE';
        <<"INFO">> -> 'INFO';
        <<"PRACK">> -> 'PRACK';
        <<"UPDATE">> -> 'UPDATE';
        _ -> Method 
    end.


%% @doc Parses all AORs found in `Term'.
-spec aors(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:aor()].
                
aors(Term) ->
    [{Scheme, User, Domain} || 
     #uri{scheme=Scheme, user=User, domain=Domain} <- uris(Term)].


%% @doc Parses all URIs found in `Term'.
-spec ruris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.
                
uris([]) -> [];
uris([First|_]=String) when is_integer(First) -> uris([String]);    % It's a string
uris(List) when is_list(List) -> parse_uris(List, []);
uris(Term) -> uris([Term]).


%% @doc Parses all URIs found in `Term'.
-spec uris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.
                
ruris(RUris) -> 
    case uris(RUris) of
        error -> error;
        Uris -> parse_ruris(Uris, [])
    end.
          

%% @doc Extracts all `via()' found in `Term'
-spec vias(Term :: binary() | string() | [binary() | string()]) -> 
    [nksip:via()] | error.

vias([]) -> [];
vias([First|_]=String) when is_integer(First) -> vias([String]);    % It's a string
vias(List) when is_list(List) -> parse_vias(List, []);
vias(Term) -> vias([Term]).


%% @doc Gets a list of `tokens()' from `Term'
-spec tokens(Term :: binary() | string() | [binary() | string()]) -> 
    [nksip:token()] | error.

tokens([]) -> [];
tokens([First|_]=String) when is_integer(First) -> tokens([String]);  
tokens(List) when is_list(List) -> parse_tokens(List, []);
tokens(Term) -> tokens([Term]).


%% @doc Gets a list of `integer()' from `Term'
-spec integers(Term :: binary() | string() | [binary() | string()]) -> 
    [integer()] | error.

integers([]) -> [];
integers([First|_]=String) when is_integer(First) -> integers([String]);  
integers(List) when is_list(List) -> parse_integers(List, []);
integers(Term) -> integers([Term]).


%% @doc Gets a list of `calendar:datetime()' from `Term'
-spec dates(Term :: binary() | string() | [binary() | string()]) -> 
    [calendar:datetime()] | error.

dates([]) -> [];
dates([First|_]=String) when is_integer(First) -> dates([String]);  
dates(List) when is_list(List) -> parse_dates(List, []);
dates(Term) -> dates([Term]).


%% @doc
-spec header({binary()|string(), binary()|string()|[binary()|string()]}) ->
    term() | error.

header({Name, Value}) when is_list(Name) ->
    header({list_to_binary(Name), Value});

header({Name, [Ch|_]=Value}) when is_integer(Ch) ->
    header({Name, [list_to_binary(Value)]});

header({Name, Value}) when is_binary(Value) ->
    header({Name, [Value]});

header({Name, Value}) ->
    try 
        parse_headers({Name, Value})
    catch
        throw:_ -> error
    end.


%% @private Gets the scheme, host and port from an `nksip:uri()' or `via()'
-spec transport(nksip:uri()|nksip:via()) -> 
    {Proto::nksip:protocol(), Host::binary(), Port::inet:port_number()}.

transport(#uri{scheme=Scheme, domain=Host, port=Port, opts=Opts}) ->
    Proto1 = case nksip_lib:get_value(<<"transport">>, Opts) of
        Atom when is_atom(Atom) -> 
            Atom;
        Other ->
            LcTransp = string:to_lower(nksip_lib:to_list(Other)),
            case catch list_to_existing_atom(LcTransp) of
                {'EXIT', _} -> nksip_lib:to_binary(Other);
                Atom -> Atom
            end
    end,
    Proto2 = case Proto1 of
        undefined when Scheme==sips -> tls;
        undefined -> udp;
        Other2 -> Other2
    end,
    Port1 = case Port > 0 of
        true -> Port;
        _ -> nksip_transport:default_port(Proto2)
    end,
    {Proto2, Host, Port1};

transport(#via{proto=Proto, domain=Host, port=Port}) ->
    Port1 = case Port > 0 of
        true -> Port;
        _ -> nksip_transport:default_port(Proto)
    end,
    {Proto, Host, Port1}.


%% @doc Extracts the headers from a uri
-spec extract_uri_routes(#uri{}) ->
    {[#uri{}], #uri{}} | error.

extract_uri_routes(#uri{headers=[]}=Uri) ->
    {[], Uri};

extract_uri_routes(#uri{headers=Headers}=Uri) ->
    case extract_uri_routes(Headers, [], []) of
        {Headers1, Routes} -> {Routes, Uri#uri{headers=lists:reverse(Headers1)}};
        error -> error
    end.


extract_uri_routes([], Hds, Routes) ->
    {Hds, Routes};

extract_uri_routes([{Name, Value}|Rest], Hds, Routes) ->
    case raw_header(Name) of
        <<"Route">> -> 
            case uris(http_uri:decode(nksip_lib:to_list(Value))) of
                error -> error;
                Routes1 -> extract_uri_routes(Rest, Hds, Routes++Routes1)
            end;
        _ ->
            extract_uri_routes(Rest, [{Name, Value}|Hds], Routes)
    end.


%% @doc Parses a Session-Expires header in a request or response
-spec session_expires(nksip:request()|nksip:response()) ->
    {ok, integer(), uac|uas|undefined} | undefined | invalid.

session_expires(SipMsg) ->
    case nksip_sipmsg:header(SipMsg, <<"Session-Expires">>, tokens) of
        [] ->
            undefined;
        [{SE, Opts}] ->
            case nksip_lib:to_integer(SE) of
                SE1 when is_integer(SE1), SE1>0 -> 
                    case nksip_lib:get_binary(<<"refresher">>, Opts) of
                        <<"uac">> -> {ok, SE1, uac};
                        <<"uas">> -> {ok, SE1, uas};
                        _ -> {ok, SE1, undefined}
                    end;
                _ ->
                    invalid
            end;
        _ ->
            invalid
    end.


%% ===================================================================
%% Internal
%% ===================================================================

% %% @private
% -spec all_values(binary(), [nksip:header()]) -> 
%     [binary()].

% all_values(Name, Headers) when is_list(Headers) ->
%     proplists:get_all_values(Name, Headers).


%% @private First-stage SIP message parser
%% 50K/sec on i7
-spec packet(nksip:app_id(), nksip_transport:transport(), binary()) ->
    {ok, #raw_sipmsg{}, binary()} | {more, binary()} | {error, term()}.

packet(AppId, #transport{proto=Proto}=Transp, Packet) ->
    Start = nksip_lib:l_timestamp(),
    case parse_packet1(Packet, Proto) of
        {ok, Class, Headers, Body, Rest} ->
            CallId = nksip_lib:get_binary(<<"Call-ID">>, Headers),
            Msg = #raw_sipmsg{
                id = nksip_sipmsg:make_id(element(1, Class), CallId),
                class = Class,
                app_id = AppId,
                call_id = CallId,
                start = Start,
                headers = Headers,
                body = Body,
                transport = Transp
            },
            {ok, Msg, Rest};
        Other ->
            Other
    end.


%% @private
-spec parse_packet1(binary(), nksip:protocol()) ->
    {ok, Class, Headers, Body, Rest} | {more, binary()} | {error, term()}
    when Class :: msg_class(), Headers :: [nksip:header()], 
         Body::binary(), Rest::binary().

parse_packet1(Packet, Proto) ->
    case binary:match(Packet, <<"\r\n\r\n">>) of
        nomatch when byte_size(Packet) < 65535 ->
            {more, Packet};
        nomatch ->
            {error, message_too_large};
        _ ->
            case binary:split(Packet, <<"\r\n">>) of
                % [<<>>, <<"\r\n", Rest/binary>>] ->
                %     {rnrn, Rest};
                % [<<>>, Rest] ->
                %     {rn, Rest};
                [<<"SIP/2.0 ", Resp/binary>>, Rest] ->
                    case binary:split(Resp, <<" ">>) of
                        [CodeB, Reason] -> 
                            case catch list_to_integer(binary_to_list(CodeB)) of
                                Code when is_integer(Code) ->
                                    Class = {resp, Code, Reason},
                                    parse_packet2(Packet, Proto, Class, Rest);
                                _ ->
                                    {error, message_unrecognized}
                            end;
                        _ ->
                            {error, message_unrecognized}
                    end;
                [Req, Rest] ->
                    case binary:split(Req, <<" ">>, [global]) of
                        [Method, RUri, <<"SIP/2.0">>] ->
                            Class = {req, method(Method), RUri},
                            parse_packet2(Packet, Proto, Class, Rest);
                        _ ->
                            {error, message_unrecognized}
                    end
            end
    end.


%% @private 
-spec parse_packet2(binary(), nksip:protocol(), msg_class(), binary()) ->
    {ok, Class, Headers, Body, Rest} | {more, binary()}
    when Class :: msg_class(), Headers :: [nksip:header()], 
         Body::binary(), Rest::binary().


parse_packet2(Packet, Proto, Class, Rest) ->
    {Headers, Rest1} = get_raw_headers(Rest, []),
    CL = case nksip_lib:get_list(<<"Content-Length">>, Headers) of
        "" when Proto==udp; Proto==sctp -> 
            byte_size(Rest1);
        "" ->
            0;
        String ->
            case catch list_to_integer(String) of
                Int when is_integer(Int), Int >= 0 -> Int;
                _ -> -1
            end
    end,
    if 
        CL =< 0 ->
            {ok, Class, Headers, <<>>, Rest1};
        true ->
            case byte_size(Rest1) of
                CL -> 
                    {ok, Class, Headers, Rest1, <<>>};
                BS when BS < CL andalso (Proto==udp orelse Proto==sctp) ->
                    %% Second-stage parser will generate an error
                    {ok, Class, Headers, Rest1, <<>>};
                BS when BS < CL -> 
                    {more, Packet};
                _ ->
                    {Body, Rest3} = split_binary(Rest1, CL),
                    {ok, Class, Headers, Body, Rest3}
            end
    end.
    

%% @private Second-stage SIP message parser
%% 15K/sec on i7
-spec raw_sipmsg(#raw_sipmsg{}) -> 
    #sipmsg{} | {reply_error, nksip:response_code(), binary()} |
    {error, binary()}.

raw_sipmsg(Raw) ->
    #raw_sipmsg{
        id = Id,
        class = Class, 
        app_id = AppId, 
        start = Start,
        headers = Headers, 
        body = Body, 
        transport = #transport{proto=Proto}=Transp
    } = Raw,
    try 
        case Class of
            {req, Method, RequestUri} ->
                %% Request-Uris behave as having < ... >
                case uris(<<$<, RequestUri/binary, $>>>) of
                    [RUri] ->
                        Request = get_sipmsg(Class, Headers, Body, Proto),
                        case Request#sipmsg.cseq_method of
                            Method -> 
                                Request#sipmsg{
                                    id = Id,
                                    class = {req, Method},
                                    app_id = AppId,
                                    ruri = RUri,
                                    transport = Transp,
                                    start = Start
                                };
                            _ ->
                                throw({400, <<"Method Mismatch">>})
                        end;
                    _ ->
                        throw({400, <<"Invalid Request-URI">>})
                end;
            {resp, Code, CodeText} when Code>=100, Code=<699 ->
                Response = get_sipmsg(Class, Headers, Body, Proto),
                Response#sipmsg{
                    id = Id,
                    class = {resp, Code, CodeText},
                    app_id = AppId,
                    transport = Transp,
                    start = Start
                };
            {resp, _, _} ->
                throw({400, <<"Invalid Code">>})
        end
    catch
        throw:{ErrCode, ErrReason} -> 
            case Class of
                {req, _, _} -> {reply_error, ErrCode, ErrReason};
                {resp, _, _} -> {error, ErrReason}
            end
    end.

    
%% @private
-spec get_raw_headers(binary(), list()) -> 
    {[nksip:header()], Rest::binary()}.

get_raw_headers(Packet, Acc) ->
    case erlang:decode_packet(httph, Packet, []) of
        {ok, {http_header, _Int, Name0, _Res, Value0}, Rest} ->
            Header = raw_header(Name0),
            get_raw_headers(Rest, [{Header, list_to_binary(Value0)}|Acc]);
        {ok, http_eoh, Rest} ->
            {lists:reverse(Acc), Rest};
        {ok, {http_error, ErrHeader}, Rest} ->
            lager:warning("Skipping invalid header ~s", [ErrHeader]),
            get_raw_headers(Rest, Acc);
        _ ->
            lager:warning("Error decoding packet headers: ~s", [Packet]),
            {lists:reverse(Acc), <<>>}
    end.


%% @private
-spec raw_header(atom()|list()|binary()) ->
    binary().

raw_header('Www-Authenticate') ->
    <<"WWW-Authenticate">>;

raw_header(Name) when is_atom(Name) ->
    atom_to_binary(Name, latin1);

raw_header(Name) when is_binary(Name) ->
    raw_header(binary_to_list(Name));

raw_header(Name) ->
    case string:to_upper(Name) of
        "A" -> <<"Accept-Contact">>;
        "B" -> <<"Referred-By">>;
        "C" -> <<"Content-Type">>;
        "D" -> <<"Request-Disposition">>;
        "E" -> <<"Content-Encoding">>;
        "F" -> <<"From">>;
        "I" -> <<"Call-ID">>;
        "J" -> <<"Reject-Contact">>;
        "K" -> <<"Supported">>;
        "L" -> <<"Content-Length">>;
        "M" -> <<"Contact">>;
        "N" -> <<"Identity-Info">>;
        "O" -> <<"Event">>;
        "R" -> <<"Refer-To">>;
        "T" -> <<"To">>;
        "U" -> <<"Allow-Events">>;
        "V" -> <<"Via">>;
        "X" -> <<"Session-Expires">>;
        "Y" -> <<"Identity">>;

        "X-"++_ -> list_to_binary(Name);

        "ACCEPT" -> <<"Accept">>;
        "ALLOW" -> <<"Allow">>;
        "ALLOW-EVENTS" -> <<"Allow-Events">>;
        "AUTHORIZATION" -> <<"Authorization">>;
        "CALL-ID" -> <<"Call-ID">>;
        "CONTACT" -> <<"Contact">>;
        "CONTENT-LENGTH" -> <<"Content-Length">>;
        "CONTENT-TYPE" -> <<"Content-Type">>;
        "CSEQ" -> <<"CSeq">>;
        "EVENT" -> <<"Event">>;
        "EXPIRES" -> <<"Expires">>;
        "FROM" -> <<"From">>;
        "PATH" -> <<"Path">>;
        "PROXY-AUTHENTICATE" -> <<"Proxy-Authenticate">>;
        "PROXY-AUTHORIZATION" -> <<"Proxy-Authorization">>;
        "RACK" -> <<"RAck">>;
        "RECORD-ROUTE" -> <<"Record-Route">>;
        "REQUIRE" -> <<"Require">>;
        "ROUTE" -> <<"Route">>;
        "RSEQ" -> <<"RSeq">>;
        "SESSION-EXPIRES" -> <<"Session-Expires">>;
        "SUBSCRIPTION-STATE" -> <<"Subscription-State">>;
        "SUPPORTED" -> <<"Supported">>;
        "TO" -> <<"To">>;
        "USER-AGENT" -> <<"User-Agent">>;
        "VIA" -> <<"Via">>;
        "WWW-AUTHENTICATE" -> <<"WWW-Authenticate">>;

        "ACCEPT-CONTACT" -> <<"Accept-Contact">>;
        "ACCEPT-ENCODING" -> <<"Accept-Encoding">>;
        "ACCEPT-LANGUAGE" -> <<"Accept-Language">>;
        "ACCEPT-RESOURCE-PRIORITY" -> <<"Accept-Resource-Priority">>;
        "ALERT-INFO" -> <<"Alert-Info">>;
        "ANSWER-MODE" -> <<"Answer-Mode">>;
        "AUTHENTICATION-INFO" -> <<"Authentication-Info">>;
        "CALL-INFO" ->  <<"Call-Info">>;
        "CONTENT-DISPOSITION" -> <<"Content-Disposition">>;
        "CONTENT-ENCODING" -> <<"Content-Encoding">>;
        "DATE" -> <<"Date">>;
        "ENCRYPTION" -> <<"Encryption">>;
        "ERROR-INFO" -> <<"Error-Info">>;
        "FEATURE-CAPS" -> <<"Feature-Caps">>;
        "FLOW-TIMER" -> <<"Flow-Timer">>;
        "GEOLOCATION" -> <<"Geolocation">>;
        "GEOLOCATION-ERROR" -> <<"Geolocation-Error">>;
        "GEOLOCATION-ROUTING" -> <<"Geolocation-Routing">>;
        "HIDE" -> <<"Hide">>;
        "HISTORY-INFO" -> <<"History-Info">>;
        "IDENTITY" -> <<"Identity">>;
        "IDENTITY-INFO" -> <<"Identity-Info">>;
        "INFO-PACKAGE" -> <<"Info-Package">>;
        "IN-REPLY-TO" -> <<"In-Reply-To">>;
        "JOIN" -> <<"Join">>;
        "MAX-BREADTH" -> <<"Max-Breadth">>;
        "MAX-FORWARDS" -> <<"Max-Forwards">>;
        "MIME-VERSION" -> <<"MIME-Version">>;
        "MIN-EXPIRES" -> <<"Min-Expires">>;
        "MIN-SE" -> <<"Min-SE">>;
        "ORGANIZATION" -> <<"Organization">>;
        "PERMISSION-MISSING" -> <<"Permission-Missing">>;
        "POLICY-CONTACT" -> <<"Policy-Contact">>;
        "POLICY-ID" -> <<"Policy-ID">>;
        "PRIORITY" -> <<"Priority">>;
        "PROXY-REQUIRE" -> <<"Proxy-Require">>;
        "REASON" -> <<"Reason">>;
        "REASON-PHRASE" -> <<"Reason-Phrase">>;
        "RECV-INFO" -> <<"Recv-Info">>;
        "REFER-SUB" -> <<"Refer-Sub">>;
        "REFER-TO" -> <<"Refer-To">>;
        "REFERRED-BY" -> <<"Referred-By">>;
        "REJECT-CONTACT" -> <<"Reject-Contact">>;
        "REPLACES" -> <<"Replaces">>;
        "REPLY-TO" -> <<"Reply-To">>;
        "REQUEST-DISPOSITION" -> <<"Request-Disposition">>;
        "RESOURCE-PRIORITY" -> <<"Resource-Priority">>;
        "RESPONSE-KEY" -> <<"Response-Key">>;
        "RETRY-AFTER" -> <<"Retry-After">>;
        "SECURITY-CLIENT" -> <<"Security-Client">>;
        "SECURITY-SERVER" -> <<"Security-Server">>;
        "SECURITY-VERIFY" -> <<"Security-Verify">>;
        "SERVER" -> <<"Server">>;
        "SERVICE-ROUTE" -> <<"Service-Route">>;
        "SIP-ETAG" -> <<"SIP-ETag">>;
        "SIP-IF-MATCH" -> <<"SIP-If-Match">>;
        "SUBJECT" -> <<"Subject">>;
        "S" -> <<"Subject">>;
        "TIMESTAMP" -> <<"Timestamp">>;
        "TRIGGER-CONSENT" -> <<"Trigger-Consent">>;
        "UNSUPPORTED" -> <<"Unsupported">>;
        "WARNING" -> <<"Warning">>;

        "P-ACCESS-NETWORK-INFO" -> <<"P-Access-Network-Info">>;
        "P-ANSWER-STATE" -> <<"P-Answer-State">>;
        "P-ASSERTED-IDENTITY" -> <<"P-Asserted-Identity">>;
        "P-ASSERTED-SERVICE" -> <<"P-Asserted-Service">>;
        "P-ASSOCIATED-URI" -> <<"P-Associated-URI">>;
        "P-CALLED-PARTY-ID" -> <<"P-Called-Party-ID">>;
        "P-CHARGING-FUNCTION-ADDRESSES" -> <<"P-Charging-Function-Addresses">>;
        "P-CHARGING-VECTOR" -> <<"P-Charging-Vector">>;
        "P-DCS-TRACE-PARTY-ID" -> <<"P-DCS-Trace-Party-ID">>;
        "P-DCS-OSPS" -> <<"P-DCS-OSPS">>;
        "P-DCS-BILLING-INFO" -> <<"P-DCS-Billing-Info">>;
        "P-DCS-LAES" -> <<"P-DCS-LAES">>;
        "P-DCS-REDIRECT" -> <<"P-DCS-Redirect">>;
        "P-EARLY-MEDIA" -> <<"P-Early-Media">>;
        "P-MEDIA-AUTHORIZATION" -> <<"P-Media-Authorization">>;
        "P-PREFERRED-IDENTITY" -> <<"P-Preferred-Identity">>;
        "P-PREFERRED-SERVICE" -> <<"P-Preferred-Service">>;
        "P-PROFILE-KEY" -> <<"P-Profile-Key">>;
        "P-REFUSED-URI-LIST" -> <<"P-Refused-URI-List">>;
        "P-SERVED-USER" -> <<"P-Served-User">>;
        "P-USER-DATABASE" -> <<"P-User-Database">>;
        "P-VISITED-NETWORK-ID" -> <<"P-Visited-Network-ID">>;

        _ -> list_to_binary(Name)
    end.


%% @private
parse_all_headers(Name, Data) ->
    parse_headers({Name, proplists:get_all_values(Name, Data)}).

%% @private
%% single uri
parse_headers({Name, Data}) when Name == <<"From">>; Name == <<"To">> ->
    case uris(Data) of
        [#uri{} = Uri] -> Uri;
        _ -> throw(<<"Invalid ", Name/binary>>)
    end;

%% binary, size > 0 
parse_headers({<<"Call-ID">>, Data}) ->
    case Data of
        [CallId] when is_binary(CallId), byte_size(CallId)>0 -> CallId;
        _ -> throw(<<"Invalid Call-ID">>)
    end;

parse_headers({<<"Via">>, Data}) ->
    case vias(Data) of
        [_|_] = Vias -> Vias;
        _ -> throw(<<"Invalid Via">>)
    end;
    
parse_headers({<<"CSeq">>, Data}) ->
    case Data of
        [CSeqHeader] ->
            case nksip_lib:tokens(CSeqHeader) of
                [CSeqInt0, CSeqMethod0] ->                
                    CSeqMethod = method(CSeqMethod0),
                    case catch list_to_integer(CSeqInt0) of
                        CSeqInt when is_integer(CSeqInt) -> ok;
                        true -> CSeqInt = throw(<<"Invalid CSeq">>)
                    end;
                _ -> 
                    CSeqInt=CSeqMethod=throw(<<"Invalid CSeq">>)
            end;
        _ ->
            CSeqInt=CSeqMethod=throw(<<"Invalid CSeq">>)
    end,
    case CSeqInt>=0 andalso CSeqInt<4294967296 of      % (2^32-1)
        true -> {CSeqInt, CSeqMethod};
        false -> throw(<<"Invalid CSeq">>)
    end;

parse_headers({<<"Max-Forwards">>, Data}) ->
    case Data of
        [] -> 
            70;
        [Forwards0] ->
            case catch list_to_integer(nksip_lib:to_list(Forwards0)) of
                F when is_integer(F), F>=0, F<300 -> F;
                _ -> throw(<<"Invalid Max-Forwards">>)
            end;
        _ -> 
            throw(<<"Invalid Max-Forwards">>)
    end;

%% uris
parse_headers({Name, Data}) when Name == <<"Route">>; Name == <<"Contact">>;
                                Name == <<"Path">>; Name == <<"Record-Route">> ->
    case uris(Data) of
        error -> throw(<<"Invalid ", Name/binary>>);
        Uris -> Uris
    end;

%% integer >= 0
parse_headers({Name, Data}) when Name == <<"Content-Length">>; Name == <<"Expires">> ->
    case Data of
        [] -> 
            undefined;
        [Bin] ->
            case catch list_to_integer(binary_to_list(Bin)) of
                {'EXIT', _} -> throw(<<"Invalid ", Name/binary>>);
                Int -> Int
            end;
        _ -> 
            throw(<<"Invalid ", Name/binary>>)
    end;

%% single token
parse_headers({<<"Content-Type">>, Data}) ->
    case tokens(Data) of
        [] -> undefined;
        [ContentType] -> ContentType;
        _ -> throw(<<"Invalid Content-Type">>)
    end;

%% multiple tokens without args
parse_headers({Name, Data}) when Name == <<"Require">>; Name == <<"Supported">> ->
    case tokens(Data) of
        error -> throw(<<"Invalid ", Name/binary>>);
        Tokens0 -> [Token || {Token, _} <- Tokens0]
    end;

%% multiple tokens
parse_headers({Name, Data}) when Name == <<"Event">> ->
    case tokens(Data) of
        [] -> undefined;
        [Token] -> Token;
        _ -> throw(<<"Invalid ", Name/binary>>)
    end;

parse_headers({_Name, Data}) ->
    Data.


%% @private
-spec get_sipmsg(msg_class(), [nksip:header()], binary(), nksip:protocol()) -> 
    #sipmsg{}.

get_sipmsg(Class, Headers, Body, Proto) ->
    try
        case Class of
            {req, ReqMethod, _} -> ok;
            _ -> ReqMethod = undefined
        end,
        Event = parse_all_headers(<<"Event">>, Headers),
        case
            (ReqMethod=='SUBSCRIBE' orelse ReqMethod=='NOTIFY' orelse
            ReqMethod=='PUBLISH') andalso
            Event == undefined
        of
            true -> throw(<<"Invalid Event">>);
            false -> ok
        end,
        ContentLength = parse_all_headers(<<"Content-Length">>, Headers),
        case ContentLength of
            undefined when Proto/=tcp, Proto/=tls -> ok;
            % 0 when Proto/=tcp, Proto/=tls -> ok;
            _ when ContentLength == byte_size(Body) -> ok;
            _ -> throw(<<"Invalid Content-Length">>)
        end,
        ContentType = parse_all_headers(<<"Content-Type">>, Headers),
        ParsedBody = case ContentType of
            {<<"application/sdp">>, _} ->
                case nksip_sdp:parse(Body) of
                    error -> Body;
                    SDP -> SDP
                end;
            {<<"application/nksip.ebf.base64">>, _} ->
                case catch binary_to_term(base64:decode(Body)) of
                    {'EXIT', _} -> Body;
                    ErlBody -> ErlBody
                end;
            _ ->
                Body
        end,
        RestHeaders = lists:filter(
            fun({Name, _}) ->
                case Name of
                    <<"From">> -> false;
                    <<"To">> -> false;
                    <<"Call-ID">> -> false;
                    <<"Via">> -> false;
                    <<"CSeq">> -> false;
                    <<"Max-Forwards">> -> false;
                    <<"Route">> -> false;
                    <<"Contact">> -> false;
                    <<"Expires">> -> false;
                    <<"Require">> -> false;
                    <<"Supported">> -> false;
                    <<"Event">> -> false;
                    <<"Content-Type">> -> false;
                    <<"Content-Length">> -> false;
                    _ -> true
                end
            end, Headers),
        From = parse_all_headers(<<"From">>, Headers),
        To = parse_all_headers(<<"To">>, Headers),
        {CSeqInt, CSeqMethod} = parse_all_headers(<<"CSeq">>, Headers),
        #sipmsg{
            from = parse_all_headers(<<"From">>, Headers),
            to = parse_all_headers(<<"To">>, Headers),
            call_id = parse_all_headers(<<"Call-ID">>, Headers), 
            vias = parse_all_headers(<<"Via">>, Headers),
            cseq = CSeqInt,
            cseq_method = CSeqMethod,
            forwards = parse_all_headers(<<"Max-Forwards">>, Headers),
            routes = parse_all_headers(<<"Route">>, Headers),
            contacts = parse_all_headers(<<"Contact">>, Headers),
            expires = parse_all_headers(<<"Expires">>, Headers),
            content_type = ContentType,
            require = parse_all_headers(<<"Require">>, Headers),
            supported = parse_all_headers(<<"Supported">>, Headers),
            event = Event,
            headers = RestHeaders,
            body = ParsedBody,
            from_tag = nksip_lib:get_value(<<"tag">>, From#uri.ext_opts, <<>>),
            to_tag = nksip_lib:get_value(<<"tag">>, To#uri.ext_opts, <<>>),
            to_tag_candidate = <<>>
        }
    catch
        throw:Throw -> throw({400, Throw})
    end.


%% @private
-spec scheme(term()) ->
    nksip:scheme().

scheme(sip) ->
    sip;
scheme(sips) ->
    sips;
scheme(tel) ->
    tel;
scheme(mailto) ->
    mailto;
scheme(Other) ->
    case string:to_lower(nksip_lib:to_list(Other)) of 
        "sip" -> sip;
        "sips" -> sips;
        "tel" -> tel;
        "mailto" -> mailto;
        _ -> list_to_binary(Other)
    end.


%% @private
-spec parse_uris([#uri{}|binary()|string()], [#uri{}]) ->
    [#uri{}] | error.

parse_uris([], Acc) ->
    Acc;

parse_uris([Next|Rest], Acc) ->
    case nksip_parse_uri:uris(Next) of
        error -> error;
        UriList -> parse_uris(Rest, Acc++UriList)
    end.


%% @private
-spec parse_ruris([#uri{}], [#uri{}]) ->
    [#uri{}] | error.

parse_ruris([], Acc) ->
    lists:reverse(Acc);

parse_ruris([#uri{opts=[], headers=[], ext_opts=Opts}=Uri|Rest], Acc) ->
    parse_uris(Rest, [Uri#uri{opts=Opts, ext_opts=[], ext_headers=[]}|Acc]);

parse_ruris(_, _) ->
    error.



%% @private
-spec parse_vias([#via{}|binary()|string()], [#via{}]) ->
    [#via{}] | error.

parse_vias([], Acc) ->
    Acc;

parse_vias([Next|Rest], Acc) ->
    case nksip_parse_via:vias(Next) of
        error -> error;
        UriList -> parse_vias(Rest, Acc++UriList)
    end.


%% @private
-spec parse_tokens([binary()|string()], [nksip:token()]) ->
    [nksip:token()] | error.

parse_tokens([], Acc) ->
    Acc;

parse_tokens([Next|Rest], Acc) ->
    case nksip_parse_tokens:tokens(Next) of
        error -> error;
        TokenList -> parse_tokens(Rest, Acc++TokenList)
    end.


%% @private
-spec parse_integers([binary()|string()], [integer()]) ->
    [integer()] | error.

parse_integers([], Acc) ->
    Acc;

parse_integers([Next|Rest], Acc) ->
    case catch list_to_integer(string:strip(nksip_lib:to_list(Next))) of
        {'EXIT', _} -> error;
        Integer -> parse_integers(Rest, Acc++[Integer])
    end.


%% @private
-spec parse_dates([binary()|string()], [calendar:datetime()]) ->
    [calendar:datetime()] | error.

parse_dates([], Acc) ->
    Acc;

parse_dates([Next|Rest], Acc) ->
    Base = string:strip(nksip_lib:to_list(Next)),
    case lists:reverse(Base) of
        "TMG " ++ _ ->               % Should be in "GMT"
            case catch httpd_util:convert_request_date(Base) of
                {_, _} = Date -> parse_dates(Rest, Acc++[Date]);
                _ -> error
            end;
        _ ->
            error
    end.




