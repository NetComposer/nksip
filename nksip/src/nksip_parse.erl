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

-export([method/1, header_uris/2, header_dates/2, header_integers/2]).
-export([header_tokens/2]).
-export([scheme/1, uri2ruri/1, aors/1, uris/1, ruris/1, vias/1, tokens/1, transport/1]).
-export([integers/1, dates/1]).
-export([packet/3, raw_sipmsg/1]).

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

method(Method) when is_binary(Method) ->
    method(binary_to_list(Method));
method(Method) when is_atom(Method) ->
    method(atom_to_list(Method));
method(Method) ->
    case string:to_upper(Method) of
        "INVITE" -> 'INVITE';
        "REGISTER" -> 'REGISTER';
        "BYE" -> 'BYE';
        "ACK" -> 'ACK';
        "CANCEL" -> 'CANCEL';
        "OPTIONS" -> 'OPTIONS';
        "SUBSCRIBE" -> 'SUBSCRIBE';
        "NOTIFY" -> 'NOTIFY';
        "PUBLISH" -> 'PUBLISH';
        "REFER" -> 'REFER';
        "MESSAGE" -> 'MESSAGE';
        "INFO" -> 'INFO';
        "PRACK" -> 'PRACK';
        "UPDATE" -> 'UPDATE';
        _ -> list_to_binary(Method) 
    end.


%% @doc Parses all `Name' headers of a request or response and gets a list 
%% of `nksip:uri()'. If non-valid values are found, `[]' is returned.
-spec header_uris(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [nksip:uri()].

header_uris(Name, #sipmsg{headers=Headers}) ->
    header_uris(Name, Headers);

header_uris(Name, Headers) when is_list(Headers) ->
    case uris(nksip_lib:bjoin(header_values(Name, Headers))) of
        error -> [];
        UriList -> UriList
    end.


%% @doc Parse all `Name' headers of a request or response and get a list of `integer()'.
%% If non-valid values are found, `[]' is returned.
-spec header_integers(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [integer()].

header_integers(Name, #sipmsg{headers=Headers}) ->
    header_integers(Name, Headers);

header_integers(Name, Headers) when is_list(Headers) ->
    case integers(header_values(Name, Headers)) of
        error -> [];
        Integers -> Integers
    end.


%% @doc Parse all `Name' headers of a request or response and get a list of dates. 
%% If non-valid values are found, `[]' is returned.
-spec header_dates(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [calendar:datetime()].

header_dates(Name, #sipmsg{headers=Headers}) ->
    header_dates(Name, Headers);

header_dates(Name, Headers) when is_list(Headers) ->
    case dates(header_values(Name, Headers)) of
        error -> [];
        Dates -> Dates
    end.


%% @doc Parse all `Name' headers of a request or response and get a list of tokens.
%% If non-valid values are found, `[]' is returned.
-spec header_tokens(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [nksip_tokenizer:token()].

header_tokens(Name, #sipmsg{headers=Headers}) ->
    header_tokens(Name, Headers);

header_tokens(Name, Headers) when is_list(Headers) ->
    case tokens(header_values(Name, Headers)) of
        error -> [];
        Tokens -> Tokens
    end.


%% @doc Cleans any `nksip:uri()' into a valid request-uri.
%% Remove all headers and parameters out of the uri.
-spec uri2ruri(nksip:uri()) -> 
    nksip:uri().

uri2ruri(#uri{}=RUri) ->
    RUri#uri{headers=[], ext_opts=[], ext_headers=[]}.


%% @doc Parses all AORs found in `Term'.
-spec aors(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:aor()].
                
aors(Term) ->
    [{Scheme, User, Domain} || 
     #uri{scheme=Scheme, user=User, domain=Domain} <- uris(Term)].


%% @doc Parses all URIs found in `Term'.
-spec uris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.
                
uris(#uri{}=Uri) ->
    [Uri];

uris([]) ->
    [];

uris([Other|Rest]) when is_record(Other, uri); is_binary(Other); is_list(Other) ->
    uris([Other|Rest], []);

uris(Uris) ->
    parse_uris(nksip_tokenizer:tokenize(Uris, uri), []).


%% @doc Parses all URIs found in `Term' as <i>Request Uris</i>.
-spec ruris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.

ruris(Term) ->
    case uris(Term) of
        error -> error;
        UriList -> [uri2ruri(Uri) || Uri <- UriList]
    end.


%% @doc Extracts all `via()' found in `Term'
-spec vias(Term :: binary() | string()) -> 
    [nksip:via()] | error.

vias(Text) ->
    parse_vias(nksip_tokenizer:tokenize(Text, via), []).


%% @doc Gets a list of `tokens()' from `Term'
-spec tokens(binary() | [binary()]) ->
    [nksip_tokenizer:token()] | error.

tokens(Term) when is_binary(Term) -> 
    parse_tokens(nksip_tokenizer:tokenize(Term, token), []);

tokens(Term) -> 
    tokens(nksip_lib:bjoin(Term)).


%% @doc Parses a list of values as integers
-spec integers(binary() | [binary()]) ->
    [integer()] | error.

integers(Value) when is_binary(Value) -> 
    parse_integers([Value]);

integers(Values) when is_list(Values) ->
    parse_integers(Values).


%% @doc Parses a list of values as dates
-spec dates(binary() | [binary()]) ->
    [calendar:datetime()] | error.

dates(Value) when is_binary(Value) ->
    parse_dates([Value]);

dates(Values) when is_list(Values) ->
    parse_dates(Values).


%% @private Gets the scheme, host and port from an `nksip:uri()' or `via()'
-spec transport(nksip:uri()|nksip:via()) -> 
    {Proto::nksip:protocol(), Host::binary(), Port::inet:port_number()}.

transport(#uri{scheme=Scheme, domain=Host, port=Port, opts=Opts}) ->
    Proto1 = case nksip_lib:get_value(transport, Opts) of
        Atom when is_atom(Atom) -> 
            Atom;
        Other ->
            case catch list_to_existing_atom(nksip_lib:to_list(Other)) of
                {'EXIT', _} -> nksip_lib:to_binary(Other);
                Atom -> Atom
            end
    end,
    Proto2 = case Proto1 of
        undefined when Scheme=:=sips -> tls;
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
-spec header_values(binary(), [nksip:header()]) -> 
    [binary()].

header_values(Name, Headers) when is_list(Headers) ->
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
                [First, Rest] ->
                    case binary:split(First, <<" ">>, [global]) of
                        [Method, RUri, <<"SIP/2.0">>] ->
                            Class = {req, method(Method), RUri},
                            parse_packet2(Packet, Proto, Class, Rest);
                        [<<"SIP/2.0">>, Code | TextList] -> 
                            CodeText = nksip_lib:bjoin(TextList, <<" ">>),
                            case catch list_to_integer(binary_to_list(Code)) of
                                Code1 when is_integer(Code1) ->
                                    Class= {resp, Code1, CodeText},
                                    parse_packet2(Packet, Proto, Class, Rest);
                                _ ->
                                    {error, message_unrecognized}
                            end;
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


parse_packet2(Packet, Proto, Class, Rest) when Proto=:=tcp; Proto=:=tls ->
    {Headers, Rest1} = get_raw_headers(Rest, []),
    CL = case nksip_lib:get_list(<<"Content-Length">>, Headers) of
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
                BS when BS < CL -> 
                    {more, Packet};
                _ ->
                    {Body, Rest3} = split_binary(Rest1, CL),
                    {ok, Class, Headers, Body, Rest3}
            end
    end;

parse_packet2(_Packet, _Proto, Class, Rest) ->
    {Headers, Rest1} = get_raw_headers(Rest, []),
    {ok, Class, Headers, Rest1, <<>>}.
    


% parse_packet2(Packet, Class, Rest) ->
%     {Headers, Rest1} = get_raw_headers(Rest, []),
%     case nksip_lib:get_list(<<"Content-Length">>, Headers) of
%         "" ->
%             {ok, Class, Headers, Rest1, <<>>};
%         String ->
%             case catch list_to_integer(String) of
%                 {'EXIT', _} ->
%                     {error, invalid_content_length};
%                 CL when CL < 0 ->
%                     {error, invalid_content_length};
%                 CL ->
%                     case byte_size(Rest1) of
%                         CL -> 
%                             {ok, Class, Headers, Rest1, <<>>};
%                         BS when BS < CL -> 
%                             {more, Packet};
%                         _ when CL > 0 -> 
%                             {Body, Rest3} = split_binary(Rest1, CL),
%                             {ok, Class, Headers, Body, Rest3};
%                         _ -> 
%                             {ok, Class, Headers, <<>>, Rest1}
%                     end
%             end
%     end.


%% @private Second-stage SIP message parser
%% 15K/sec on i7
-spec raw_sipmsg(#raw_sipmsg{}) -> 
    #sipmsg{} | {error, nksip:response_code(), nksip:reason()}.

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
                        Request = get_sipmsg(Headers, Body, Proto),
                        case Request#sipmsg.cseq_method of
                            Method -> 
                                Request#sipmsg{
                                    id = Id,
                                    class = {req, Method},
                                    app_id = AppId,
                                    ruri = RUri,
                                    transport = Transp,
                                    start = Start,
                                    data = []
                                };
                            _ ->
                                throw({400, <<"Method Mismatch">>})
                        end;
                    _ ->
                        throw({400, <<"Invalid URI">>})
                end;
            {resp, Code, CodeText} when Code>=100, Code=<699 ->
                Response = get_sipmsg(Headers, Body, Proto),
                Response#sipmsg{
                    id = Id,
                    class = {resp, Code},
                    app_id = AppId,
                    transport = Transp,
                    start = Start,
                    data = [{reason, CodeText}]
                };
            {resp, _, _} ->
                throw({400, <<"Invalid Code">>})
        end
    catch
        throw:{ErrCode, ErrReason} -> {error, ErrCode, ErrReason}
    end.

    

%% @private
-spec get_sipmsg([nksip:header()], binary(), nksip:protocol()) -> 
    #sipmsg{} | {error, term()}.

get_sipmsg(Headers, Body, Proto) ->
    case header_uris(<<"From">>, Headers) of
        [#uri{} = From] -> ok;
        _ -> From = throw({400, <<"Invalid From">>})
    end,
    case header_uris(<<"To">>, Headers) of
        [#uri{} = To] -> ok;
        _ -> To = throw({400, <<"Invalid To">>})
    end,
    case header_values(<<"Call-ID">>, Headers) of
        [CallId] when is_binary(CallId), byte_size(CallId)>0 -> CallId;
        _ -> CallId = throw({400, <<"Invalid Call-ID">>})
    end,
    case vias(nksip_lib:bjoin(header_values(<<"Via">>, Headers))) of
        [_|_] = Vias -> ok;
        _ -> Vias = throw({400, <<"Invalid Via">>})
    end,
    case header_values(<<"CSeq">>, Headers) of
        [CSeqHeader] ->
            case nksip_tokenizer:tokenize(CSeqHeader, none) of
                [[{CSeqInt0}, {CSeqMethod0}]] ->                
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
    case CSeqInt > 4294967295 of      % (2^32-1)
        true -> throw({400, <<"Invalid CSeq">>});
        false -> ok
    end,
    case header_integers(<<"Max-Forwards">>, Headers) of
        [] -> Forwards = 70;
        [0] -> Forwards=throw({483, "Too Many Hops"});
        [Forwards] when is_integer(Forwards), Forwards>0, Forwards<300 -> ok;
        _ -> Forwards = throw({400, <<"Invalid Max-Forwards">>})
    end,
    ContentType = header_tokens(<<"Content-Type">>, Headers),
    case header_values(<<"Content-Length">>, Headers) of
        [] when Proto=/=tcp, Proto=/=tls -> 
            ok;
        [CL] ->
            case catch list_to_integer(binary_to_list(CL)) of
                0 when Proto=/=tcp, Proto=/=tls -> 
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
        [{<<"application/sdp">>, _}|_] ->
            case nksip_sdp:parse(Body) of
                error -> Body;
                SDP -> SDP
            end;
        [{<<"application/nksip.ebf.base64">>, _}] ->
            case catch binary_to_term(base64:decode(Body)) of
                {'EXIT', _} -> Body;
                ErlBody -> ErlBody
            end;
        _ ->
            Body
    end,
    Headers1 = nksip_lib:delete(Headers, [
                        <<"From">>, <<"To">>, <<"Call-ID">>, <<"Via">>, <<"CSeq">>,
                        <<"Max-Forwards">>, <<"Content-Type">>, 
                        <<"Content-Length">>, <<"Route">>, <<"Contact">>]),
    #sipmsg{
        from = From,
        to = To,
        call_id = CallId, 
        vias = Vias,
        cseq = CSeqInt,
        cseq_method = CSeqMethod,
        forwards = Forwards,
        routes = header_uris(<<"Route">>, Headers),
        contacts = header_uris(<<"Contact">>, Headers),
        headers = Headers1,
        content_type = ContentType,
        body = Body1,
        from_tag = nksip_lib:get_value(tag, From#uri.ext_opts, <<>>),
        to_tag = nksip_lib:get_value(tag, To#uri.ext_opts, <<>>),
        data = []
    }.


%% @private
-spec get_raw_headers(binary(), list()) -> 
    {[nksip:header()], Rest::binary()}.

get_raw_headers(Packet, Acc) ->
    case erlang:decode_packet(httph, Packet, []) of
        {ok, {http_header, _Int, Name0, _Res, Value0}, Rest} ->
            Header = if
                Name0 =:= 'Www-Authenticate' -> 
                    <<"WWW-Authenticate">>;
                is_atom(Name0) -> 
                    atom_to_binary(Name0, latin1);
                true ->
                    case string:to_upper(Name0) of
                        "ALLOW-EVENTS" -> <<"Allow-Events">>;
                        "AUTHENTICATION-INFO" -> <<"Authentication-Info">>;
                        "CALL-ID" -> <<"Call-ID">>;
                        "I" -> <<"Call-ID">>;
                        "CONTACT" -> <<"Contact">>;
                        "M" -> <<"Contact">>;
                        "CONTENT-DISPOSITION" -> <<"Content-Disposition">>;
                        "CONTENT-ENCODING" -> <<"Content-Encoding">>;
                        "E" -> <<"Content-Encoding">>;
                        "L" -> <<"Content-Length">>;
                        "C" -> <<"Content-Type">>;
                        "CSEQ" -> <<"CSeq">>;
                        "F" -> <<"From">>;
                        "PROXY-REQUIRE" -> <<"Proxy-Require">>;
                        "RECORD-ROUTE" -> <<"Record-Route">>;
                        "REQUIRE" -> <<"Require">>;
                        "ROUTE" -> <<"Route">>;
                        "S" -> <<"Subject">>;
                        "SUPPORTED" -> <<"Supported">>;
                        "UNSUPPORTED" -> <<"Unsupported">>;
                        "TIMESTAMP" -> <<"Timestamp">>;
                        "TO" -> <<"To">>;
                        "T" -> <<"To">>;
                        "VIA" -> <<"Via">>;
                        "V" -> <<"Via">>;
                        _ -> list_to_binary(Name0)
                    end
            end,
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


%% @private Process a list of uris
-spec uris([nksip:user_uri()], [nksip:uri()]) ->
    [nksip:uri()].

uris([#uri{}=Uri|Rest], Acc) ->
    uris(Rest, [Uri|Acc]);

uris([Other|Rest], Acc) ->
    Tokens = nksip_tokenizer:tokenize(Other, uri),
    uris(Rest, [lists:reverse(parse_uris(Tokens, []))|Acc]);

uris([], Acc) ->
    lists:reverse(lists:flatten(Acc)).


%% @private
-spec parse_uris([nksip_tokenizer:token_list()], list()) -> 
    [nksip:uri()] | error.

parse_uris([[{"*"}]], []) ->
    [#uri{domain=(<<"*">>)}];

parse_uris([Tokens|Rest], Acc) ->
    try
        case Tokens of
            [{Disp}, $<, {Scheme}, $: | R1] -> Block=true;
            [$<, {Scheme}, $: | R1 ] -> Disp="", Block=true;
            [{Scheme}, $: | R1] -> Disp="", Block=false;
            _ -> Disp=Scheme=Block=R1=throw(error1)
        end,
        case R1 of
            [{User}, $:, {Pass}, $@, {Host}, $:, {Port0} | R2] -> ok;
            [{User}, $@, {Host}, $:, {Port0} | R2] -> Pass="";
            [{User}, $:, {Pass}, $@, {Host} | R2] -> Port0="0";
            [{User}, $@, {Host} | R2] -> Pass="", Port0="0";
            [{Host}, $:, {Port0} | R2] -> User="", Pass="";
            [{Host} | R2] -> User="", Pass="", Port0="0";
            _ -> User=Pass=Host=Port0=R2=[], throw(error2)
        end,
        Port = case catch list_to_integer(Port0) of
            Port1 when is_integer(Port1) -> Port1;
            _ -> throw(error3)
        end,
        case Block of
            true ->
                case parse_opts(R2) of
                    {UriOpts, R3} -> 
                        % ?P("R3: ~p", [R3]),
                        case parse_headers(R3) of  
                            {UriHds, R4} -> ok;
                            error -> UriHds = R4 = throw(error4)
                        end;
                    error ->
                        UriOpts = UriHds = R4 = throw(error5)
                end,
                case R4 of
                    [$> | R5] -> 
                        case parse_opts(R5) of
                            {HdOpts, R6} ->
                                case parse_headers(R6) of
                                    {HdHds, []} -> ok;
                                    O -> HdHds = throw({error6, O})
                                end;
                            error ->
                                HdOpts = HdHds = throw(error7)
                        end; 
                    _ ->
                        HdOpts=HdHds=throw(error8)
                end;
            false ->
                %% Per section 20 of RFC3261:
                %%
                %% "If the URI is not enclosed in angle brackets, any
                %% semicolon-delimited parameters are
                %% header-parameters, not URI parameters."
                UriOpts = UriHds = [],
                case parse_opts(R2) of
                    {HdOpts, R3} ->
                        case parse_headers(R3) of
                            {HdHds, []} -> ok;
                            _ -> HdHds = throw(error9)
                        end;
                    error ->
                        HdOpts = HdHds = throw(error10)
                end
        end,
        Uri = #uri{
            scheme = scheme(Scheme),
            disp = list_to_binary(string:strip(Disp, left)),
            user = list_to_binary(User),
            pass = list_to_binary(Pass),
            domain = list_to_binary(Host),
            port = Port,
            opts = UriOpts,
            headers = UriHds,
            ext_opts = HdOpts,
            ext_headers = HdHds
        },
        parse_uris(Rest, [Uri|Acc])
    catch
        throw:_E -> 
            % lager:warning("Error processing URI: ~p", [_E]),
            error
    end;

parse_uris([], Acc) ->
    lists:reverse(Acc).


%% @private
-spec parse_vias([nksip_tokenizer:token_list()], list()) -> 
    [nksip:via()] | error.

parse_vias([Tokens|Rest], Acc) ->
    try
        case Tokens of
            [{"SIP"}, $/, {"2.0"}, $/, {Transp}, {Host}, $:, {Port} | R] -> ok;
            [{"SIP"}, $/, {"2.0"}, $/, {Transp}, {Host} | R] -> Port="0";
            O -> Transp=Host=Port=R=throw(error1)
        end,
        case parse_opts(R) of
            {Opts, []} -> ok;
            _ -> Opts = throw(error)
        end,
        Via = #via{
            proto = 
                case string:to_lower(Transp) of
                    "udp" -> udp;
                    "tcp" -> tcp;
                    "tls" -> tls;
                    "sctp" -> sctp;
                    "ws" -> ws;
                    "wss" -> wss;
                    _ -> list_to_binary(Transp)
                end,
            domain = list_to_binary(Host), 
            port = 
                case catch list_to_integer(Port) of
                    Port1 when is_integer(Port1) -> Port1;
                    _ -> throw(error2)
                end,
            opts = Opts},
        parse_vias(Rest, [Via|Acc])
    catch
        throw:_ -> error
    end;

parse_vias([], Acc) ->
    lists:reverse(Acc).


%% @private
parse_tokens([[]], Acc) ->
    lists:reverse(Acc);

parse_tokens([], Acc) ->
    lists:reverse(Acc);

parse_tokens([[{Token}]|Rest], Acc) ->
    Token1 = list_to_binary(string:to_lower(Token)),
    parse_tokens(Rest, [{Token1, []}|Acc]);

parse_tokens([[{Token}|Opts]|Rest], Acc) ->
    Token1 = list_to_binary(string:to_lower(Token)),
    case parse_opts(Opts) of
        {ParsedOpts, []} -> parse_tokens(Rest, [{Token1, ParsedOpts}|Acc]);
        error -> error
    end.


%% @private
-spec parse_opts(nksip_tokenizer:token_list()) -> 
    {Opts::nksip_lib:proplist(), Rest::nksip_tokenizer:token_list()} | error.

parse_opts(TokenList) -> 
    parse_opts(TokenList, []).


%% @private
parse_opts([], Acc) ->
    {lists:reverse(Acc), []};

parse_opts([Char|_]=Rest, Acc) when Char==$?; Char==$>; Char==$, ->
    {lists:reverse(Acc), Rest};

parse_opts(TokenList, Acc) ->
    try
        case TokenList of
            [$;, {Key0}, $=, {Value0} | Rest] -> ok; 
            [$;, {Key0} | Rest] -> Value0 = none; 
            _ -> Key0 = Value0 = Rest = throw(error)
        end,
        Key = case string:to_lower(Key0) of
            "lr" -> lr;
            "maddr" -> maddr;
            "transport" -> transport;
            "tag" -> tag;
            "branch" -> branch;
            "received" -> received;
            "rport" -> rport;
            "expires" -> expires;
            "q" -> q;
            "nksip" -> nksip;
            "nksip_transport" -> nksip_transport;
            "ob" -> ob;
            "reg-id" -> 'reg-id';
            "+sip.instance" -> '+sip.instance';
            _ -> list_to_binary(Key0) 
        end,
        case Value0 of
            none -> parse_opts(Rest, [Key|Acc]);
            _ -> parse_opts(Rest, [{Key, list_to_binary(Value0)}|Acc])
        end
    catch
        throw:error -> error
    end.


%% @private
-spec parse_headers(nksip_tokenizer:token_list()) ->
    {Headers::nksip_lib:proplist(), Rest::nksip_tokenizer:token_list()} | error.

parse_headers([$?|Rest]) -> parse_headers([$&|Rest], []);
parse_headers([$>|_]=Rest) -> {[], Rest};
parse_headers([]) -> {[], []};
parse_headers(_) -> error.


%% @private
parse_headers([], Acc) ->
    {lists:reverse(Acc), []};

parse_headers([$>|_]=Rest, Acc) ->
    {lists:reverse(Acc), Rest};

parse_headers(TokenList, Acc) ->
    try
        case TokenList of
            [$&, {Key0}, $=, {Value0} | Rest] -> ok; 
            [$&, {Key0} | Rest] -> Value0 = none; 
            _ -> Key0 = Value0 = Rest = throw(error)
        end,
        Key = list_to_binary(Key0),
        case Value0 of
            none -> parse_headers(Rest, [Key|Acc]);
            _ -> parse_headers(Rest, [{Key, list_to_binary(Value0)}|Acc])
        end
    catch
        throw:error -> error
    end.


%% @private
parse_integers(List) ->
    parse_integers(List, []).


%% @private
parse_integers([], Acc) ->
    lists:reverse(Acc);

parse_integers([Value|Rest], Acc) ->
    case catch list_to_integer(string:strip(binary_to_list(Value))) of
        {'EXIT', _} -> error;
        Integer -> parse_integers(Rest, [Integer|Acc])
    end.


%% @private
parse_dates(List) ->
    parse_dates(List, []).


%% @private
parse_dates([], Acc) ->
    lists:reverse(Acc);

parse_dates([Value|Rest], Acc) ->
    Base = string:strip(binary_to_list(Value)),
    case lists:reverse(Base) of
        "TMG " ++ _ ->               % Should en in "GMT"
            case catch httpd_util:convert_request_date(Base) of
                {_, _} = Date -> parse_dates(Rest, [Date|Acc]);
                _ -> error
            end;
        _ ->
            error
    end.




%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

uri_test() ->
    ?assertMatch([#uri{domain= <<"host">>}], uris("sip:host")),
    ?assertMatch(
        [#uri{scheme=sips, domain= <<"host">>, port=5061}],
        uris("  sips  :  host  :  5061  ")),
    ?assertMatch(
        [#uri{disp=(<<"\"My name\" ">>), user=(<<"user">>), pass=(<<"pass">>), 
            domain= <<"host">>, port=5061, opts=[{transport,<<"tcp">>}],
            headers=[<<"head1">>], ext_opts=[{<<"op1">>,<<"\"1\"">>}]}],
        uris(" \"My name\" <sip:user:pass@host:5061;transport=tcp?head1> ; op1=\"1\"")),
    ?assertMatch(
        [#uri{disp=(<<"Name   ">>), domain= <<"host">>, port=5061,
            ext_headers=[{<<"hd2">>,<<"2">>},{<<"hd3">>,<<"a">>}]}],
        uris(" Name   < sips : host:  5061 > ?hd2=2&hd3=a")),
    ?assertMatch(
        [#uri{user=(<<"user">>), domain= <<"host">>, opts=[lr,{<<"t">>,<<"1">>},<<"d">>]}],
        uris(" < sip : user@host ;lr; t=1 ;d ? a=1 >")),
    ?assertMatch(
       [#uri{ext_opts = [{tag, <<"a48s">>}]}],
       uris("\"A. G. Bell\" <sip:agb@bell-telephone.com> ;tag=a48s")),
    ?assertMatch(
       [#uri{scheme = sip,
             user = <<"+12125551212">>,
             domain = <<"server.phone2net.com">>,
             ext_opts = [{tag, <<"887s">>}]}],
       uris("sip:+12125551212@server.phone2net.com;tag=887s")),
    ?assertMatch(
        [
            #uri{user=(<<"user">>), domain= <<"host">>, ext_opts=[lr,{<<"t">>,<<"1">>},<<"d">>],
                ext_headers=[{<<"a">>,<<"1">>}]},
            #uri{domain= <<"host2">>, opts=[rport], ext_opts=[{<<"ttl">>,<<"5">>}], 
                ext_headers=[<<"a">>]}
        ],
        uris("  sip : user@host ;lr; t=1 ;d ? a=1, <sip:host2;rport>;ttl=5?a")).

via_test() ->
    ?assertMatch([#via{domain= <<"host">>, port=12}], vias("  SIP / 2.0/TCP host:12")),
    ?assertMatch(
        [
            #via{proto=tls, domain= <<"host">>, port=0},
            #via{domain= <<"host2">>, port=5061, 
                opts=[maddr, {received, <<"1.2.3.4">>}, <<"a">>]}
        ],
        vias("SIP/2.0/TLS  host  ,  SIP / 2.0 / UDP host2 : 5061  "
                "; maddr; received = 1.2.3.4 ; a")).

token_test() ->
    ?assertMatch(
        [
            {<<"abc">>, [{<<"cc">>,<<"a">>},{<<"cb">>,<<"\"ocb\"">>}]},
            {<<"e">>, []},
            {<<"f">>, [lr]}
        ],
        tokens(<<"abc ; cc=a;cb  = \"ocb\", e, f;lr">>)).

-endif.


