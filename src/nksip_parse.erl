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

-export([method/1, scheme/1, aors/1, uris/1, vias/1]).
-export([tokens/1, integers/1, dates/1, transport/1]).
-export([packet/3, raw_sipmsg/1, raw_header/1]).

-export_type([msg_class/0]).

-type msg_class() :: {req, nksip:method(), binary()} | 
                     {resp, nksip:response_code(), binary()}.


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
-spec uris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.
                
uris([]) -> [];
uris([First|_]=String) when is_integer(First) -> uris([String]);    % It's a string
uris(List) when is_list(List) -> parse_uris(List, []);
uris(Term) -> uris([Term]).


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


%% @private Gets the scheme, host and port from an `nksip:uri()' or `via()'
-spec transport(nksip:uri()|nksip:via()) -> 
    {Proto::nksip:protocol(), Host::binary(), Port::inet:port_number()}.

transport(#uri{scheme=Scheme, domain=Host, port=Port, opts=Opts}) ->
    Proto1 = case nksip_lib:get_value(<<"transport">>, Opts) of
        Atom when is_atom(Atom) -> 
            Atom;
        Other ->
            case catch list_to_existing_atom(nksip_lib:to_list(Other)) of
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




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec all_values(binary(), [nksip:header()]) -> 
    [binary()].

all_values(Name, Headers) when is_list(Headers) ->
    proplists:get_all_values(Name, Headers).


%% @private First-stage SIP message parser
%% 50K/sec on i7
-spec packet(nksip:app_id(), nksip_transport:transport(), binary()) ->
    {ok, #raw_sipmsg{}, binary()} | {more, binary()} | {rnrn, binary()} | 
    {error, term()}.

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
    {ok, Class, Headers, Body, Rest} | {more, binary()} | {rnrn, binary()} | 
    {error, term()}
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
                [<<>>, <<"\r\n", Rest/binary>>] ->
                    {rnrn, Rest};
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
-spec get_sipmsg(msg_class(), [nksip:header()], binary(), nksip:protocol()) -> 
    #sipmsg{}.

get_sipmsg(Class, Headers, Body, Proto) ->
    case uris(all_values(<<"From">>, Headers)) of
        [#uri{} = From] -> ok;
        _ -> From = throw({400, <<"Invalid From">>})
    end,
    case uris(all_values(<<"To">>, Headers)) of
        [#uri{} = To] -> ok;
        _ -> To = throw({400, <<"Invalid To">>})
    end,
    case all_values(<<"Call-ID">>, Headers) of
        [CallId] when is_binary(CallId), byte_size(CallId)>0 -> CallId;
        _ -> CallId = throw({400, <<"Invalid Call-ID">>})
    end,
    case vias(all_values(<<"Via">>, Headers)) of
        [_|_] = Vias -> ok;
        _ -> Vias = throw({400, <<"Invalid Via">>})
    end,
    case all_values(<<"CSeq">>, Headers) of
        [CSeqHeader] ->
            case nksip_lib:tokens(CSeqHeader) of
                [CSeqInt0, CSeqMethod0] ->                
                    CSeqMethod = method(CSeqMethod0),
                    case (catch list_to_integer(CSeqInt0)) of
                        CSeqInt when is_integer(CSeqInt) -> ok;
                        true -> CSeqInt = throw({400, <<"Invalid CSeq">>})
                    end;
                _ -> 
                    CSeqInt=CSeqMethod=throw({400, <<"Invalid CSeq">>})
            end;
        _ ->
            CSeqInt=CSeqMethod=throw({400, <<"Invalid CSeq">>})
    end,
    case CSeqInt>=0 andalso CSeqInt<4294967296 of      % (2^32-1)
        true -> ok;
        false -> throw({400, <<"Invalid CSeq">>})
    end,
    case integers(all_values(<<"Max-Forwards">>, Headers)) of
        [] -> Forwards = 70;
        [Forwards] when is_integer(Forwards), Forwards>=0, Forwards<300 -> ok;
        _ -> Forwards = throw({400, <<"Invalid Max-Forwards">>})
    end,
    case uris(all_values(<<"Route">>, Headers)) of
        error -> Routes = throw({400, <<"Invalid Route">>});
        Routes -> ok
    end,
    case uris(all_values(<<"Contact">>, Headers)) of
        error -> Contacts = throw({400, <<"Invalid Contact">>});
        Contacts -> ok
    end,
    case integers(all_values(<<"Expires">>, Headers)) of
        [] -> Expires = undefined;
        [Expires] when is_integer(Expires), Expires>=0 -> ok;
        _ -> Expires = throw({400, <<"Invalid Expires">>})
    end,
    case tokens(all_values(<<"Require">>, Headers)) of
        error -> Require = throw({400, <<"Invalid Require">>});
        Require -> ok
    end,
    case tokens(all_values(<<"Supported">>, Headers)) of
        error -> Supported = throw({400, <<"Invalid Supported">>});
        Supported -> ok
    end,
    case Class of
        {req, ReqMethod, _} -> ok;
        _ -> ReqMethod = undefined
    end,
    Event = case tokens(all_values(<<"Event">>, Headers)) of
        [] -> undefined;
        [EventToken] -> EventToken;
        _ -> throw({400, <<"Invalid Event">>})
    end,
    case 
        ReqMethod=='SUBSCRIBE' orelse ReqMethod=='NOTIFY' orelse
        ReqMethod=='PUBLISH'
    of
        true when Event==undefined -> throw({400, <<"Invalid Event">>});
        _ -> ok
    end,
    case tokens(all_values(<<"Content-Type">>, Headers)) of
        [] -> ContentType = undefined;
        [ContentType] -> ok;
        _ -> ContentType = throw({400, <<"Invalid Content-Type">>})
    end,
    case all_values(<<"Content-Length">>, Headers) of
        [] when Proto/=tcp, Proto/=tls -> 
            ok;
        [CL] ->
            case catch list_to_integer(binary_to_list(CL)) of
                0 when Proto/=tcp, Proto/=tls -> 
                    ok;
                BS ->
                    case byte_size(Body) of
                        BS -> ok;
                        _ -> throw({400, <<"Invalid Content-Length">>})
                    end
            end;
        _ -> 
            throw({400, <<"Invalid Content-Length">>})
    end,
    Body1 = case ContentType of
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
    Headers1 = lists:filter(
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
    #sipmsg{
        from = From,
        to = To,
        call_id = CallId, 
        vias = Vias,
        cseq = CSeqInt,
        cseq_method = CSeqMethod,
        forwards = Forwards,
        routes = Routes,
        contacts = Contacts,
        expires = Expires,
        content_type = ContentType,
        require = Require,
        supported = Supported,
        event = Event,
        headers = Headers1,
        body = Body1,
        from_tag = nksip_lib:get_value(<<"tag">>, From#uri.ext_opts, <<>>),
        to_tag = nksip_lib:get_value(<<"tag">>, To#uri.ext_opts, <<>>),
        to_tag_candidate = <<>>
    }.


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
        "ALLOW-EVENTS" -> <<"Allow-Events">>;
        "U" -> <<"Allow-Events">>;
        "AUTHENTICATION-INFO" -> <<"Authentication-Info">>;
        "CALL-ID" -> <<"Call-ID">>;
        "I" -> <<"Call-ID">>;
        "CONTACT" -> <<"Contact">>;
        "M" -> <<"Contact">>;
        "CONTENT-DISPOSITION" -> <<"Content-Disposition">>;
        "CONTENT-ENCODING" -> <<"Content-Encoding">>;
        "E" -> <<"Content-Encoding">>;
        "CONTENT-LENGTH" -> <<"Content-Length">>;
        "L" -> <<"Content-Length">>;
        "CONTENT-TYPE" -> <<"Content-Type">>;
        "C" -> <<"Content-Type">>;
        "CSEQ" -> <<"CSeq">>;
        "EVENT" -> <<"Event">>;
        "O" -> <<"Event">>;
        "EXPIRES" -> <<"Expires">>;
        "FROM" -> <<"From">>;
        "F" -> <<"From">>;
        "MAX-FORWARDS" -> <<"Max-Forwards">>;
        "PATH" -> <<"Path">>;
        "PROXY-REQUIRE" -> <<"Proxy-Require">>;
        "RACK" -> <<"RAck">>;
        "RECORD-ROUTE" -> <<"Record-Route">>;
        "REFER-TO" -> <<"Refer-To">>;
        "R" -> <<"Refer-To">>;
        "REQUIRE" -> <<"Require">>;
        "ROUTE" -> <<"Route">>;
        "RSEQ" -> <<"RSeq">>;
        "SERVICE-ROUTE" -> <<"Service-Route">>;
        "SIP-IF-MATCH" -> <<"SIP-If-Match">>;
        "SIP-ETAG" -> <<"SIP-ETag">>;
        "SUBJECT" -> <<"Subject">>;
        "S" -> <<"Subject">>;
        "SUBSCRIPTION-STATE" -> <<"Subscription-State">>;
        "SUPPORTED" -> <<"Supported">>;
        "K" -> <<"Supported">>;
        "TIMESTAMP" -> <<"Timestamp">>;
        "TO" -> <<"To">>;
        "T" -> <<"To">>;
        "UNSUPPORTED" -> <<"Unsupported">>;
        "USER-AGENT" -> <<"User-Agent">>;
        "VIA" -> <<"Via">>;
        "V" -> <<"Via">>;
        "WWW-AUTHENTICATE" -> <<"WWW-Authenticate">>;
        "PROXY-AUTHENTICATE" -> <<"PROXY-Authenticate">>;
        <<"BODY">> -> <<"body">>;
        _ -> list_to_binary(Name)
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




