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
-export([scheme/1, uri2ruri/1, aors/1, uris/1, vias/1, tokens/1, transport/1]).
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
        Other -> list_to_binary(Other) 
    end.


%% @doc Parses all `Name' headers of a request or response and gets a list 
%% of `nksip:uri()'. Non-valid entries will be skipped.
-spec header_uris(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [nksip:uri()].

header_uris(Name, #sipmsg{headers=Headers}) ->
    header_uris(Name, Headers);

header_uris(Name, Headers) when is_list(Headers) ->
    uris(nksip_lib:bjoin(header_values(Name, Headers))).


%% @doc Parse all `Name' headers of a request or response and get a list of `integer()'.
%% Non-valid entries will be skipped.
-spec header_integers(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [integer()].

header_integers(Name, #sipmsg{headers=Headers}) ->
    header_integers(Name, Headers);

header_integers(Name, Headers) when is_list(Headers) ->
    integers(header_values(Name, Headers)).


%% @doc Parse all `Name' headers of a request or response and get a list of dates. 
%% Non-valid entries will be skipped.
-spec header_dates(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [calendar:datetime()].

header_dates(Name, #sipmsg{headers=Headers}) ->
    header_dates(Name, Headers);

header_dates(Name, Headers) when is_list(Headers) ->
    dates(header_values(Name, Headers)).


%% @doc Parse all `Name' headers of a request or response and get a list of tokens.
%% If any of them is not recognized it will return `error'.
-spec header_tokens(binary(), nksip:request()|nksip:response()|[nksip:header()]) -> 
    [nksip_lib:token()] | error.

header_tokens(Name, #sipmsg{headers=Headers}) ->
    header_tokens(Name, Headers);

header_tokens(Name, Headers) when is_list(Headers) ->
    tokens(header_values(Name, Headers)).


%% @doc Cleans any `nksip:uri()' into a valid request-uri.
%% Remove all headers and parameters out of the uri.
-spec uri2ruri(nksip:uri()) -> 
    nksip:uri().

uri2ruri(#uri{opts=Opts}=RUri) ->
    _Opts1 = [{N, V} || {N, V} <- Opts, N=/=ob],
    RUri#uri{headers=[], ext_opts=[], ext_headers=[]}.


%% @doc Parses all AORs found in `Term'.
-spec aors(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:aor()].
                
aors(Term) ->
    [{Scheme, User, Domain} || 
     #uri{scheme=Scheme, user=User, domain=Domain} <- uris(Term)].


%% @doc Parses all URis found in `Term'.
-spec uris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()].
                
uris(#uri{}=Uri) ->
    [Uri];

uris([]) ->
    [];

uris([Other|Rest]) when is_record(Other, uri); is_binary(Other); is_list(Other) ->
    uris([Other|Rest], []);

uris(Uris) ->
    parse_uris(nksip_lib:tokenize(Uris, uri), []).


%% @doc Extracts all `via()' found in `Term'
-spec vias(Term :: binary() | string()) -> 
    [nksip:via()].

vias(Text) ->
    parse_vias(nksip_lib:tokenize(Text, via), []).


%% @doc Gets a list of `tokens()' from `Term'
-spec tokens([binary()]) ->
    [nksip_lib:token()].

tokens(Term) ->
    Term1 = case is_binary(Term) of
        true -> Term;
        _ -> nksip_lib:bjoin(Term)
    end,
    parse_tokens(lists:flatten(nksip_lib:tokenize(Term1, token)), []).


%% @doc Parses a list of values as integers
-spec integers([binary()]) ->
    [integer()].

integers(Values) ->
    List = lists:foldl(
        fun(Value, Acc) ->
            case catch list_to_integer(string:strip(binary_to_list(Value))) of
                {'EXIT', _} -> Acc;
                Integer -> [Integer|Acc]
            end
        end,
        [], 
        Values),
    lists:reverse(List).


%% @doc Parses a list of values as dates
-spec dates([binary()]) ->
    [calendar:datetime()].

dates(Values) ->
    List = lists:foldl(
        fun(Value, Acc) ->
            case catch 
                httpd_util:convert_request_date(string:strip(binary_to_list(Value)))
            of
                {D, H} -> [{D, H}|Acc];
                _ -> Acc
            end
        end,
        [],
        Values),
    lists:reverse(List).




%% @private Gets the scheme, host and port from an `nksip:uri()' or `via()'
-spec transport(nksip:uri()|nksip:via()) -> 
    {Proto::nksip:protocol(), Host::binary(), Port::inet:port_number()}.

transport(#uri{scheme=Scheme, domain=Host, port=Port, opts=Opts}) ->
    {Class, DefPort} = case Scheme of
        sips -> 
            {tls, 5061};
        sip ->
            case nksip_lib:get_list(transport, Opts) of
                [] -> 
                    {udp, 5060};
                T0 ->
                    case string:to_lower(T0) of
                        "udp" -> {udp, 5060};
                        "tcp" -> {tcp, 5060};
                        "tls" -> {tls, 5061};
                        "sctp" -> {sctp, 5060}
                    end
            end;
        _ ->
            {unknown, 0}
    end,
    {Class, Host, if Port =:= 0 -> DefPort; true -> Port end};

transport(#via{proto=Proto, domain=Host, port=Port}) ->
    DefPort = case Proto of
        udp -> 5060;
        tcp -> 5060;
        tls -> 5061
    end,
    {Proto, Host, if Port=:=0 -> DefPort; true -> Port end}.


%% ===================================================================
%% Internal
%% ===================================================================

% @private
-spec header_values(binary(), [nksip:header()]) -> 
    [binary()].

header_values(Name, Headers) when is_list(Headers) ->
    proplists:get_all_values(Name, Headers).


%% @private First-stage SIP message parser
%% 50K/sec on i7
-spec packet(nksip:app_id(), nksip_transport:transport(), binary()) ->
    {ok, #raw_sipmsg{}, binary()} | {more, binary()} | {rnrn, binary()}.

packet(AppId, Transport, Packet) ->
    Start = nksip_lib:l_timestamp(),
    case parse_packet(Packet) of
        {ok, Class, Headers, Body, Rest} ->
            CallId = nksip_lib:get_value(<<"Call-ID">>, Headers),
            Msg = #raw_sipmsg{
                id = erlang:phash2(make_ref()), 
                class = Class,
                app_id = AppId,
                call_id = CallId,
                start = Start,
                headers = Headers,
                body = Body,
                transport = Transport
            },
            {ok, Msg, Rest};
        {more, More} ->
            {more, More};
        {rnrn, More} ->
            {rnrn, More}
    end.


%% @private
-spec parse_packet(binary()) ->
    {ok, Class, Headers, Body, Rest} | {more, binary()} | {rnrn, binary()}
    when Class :: msg_class(), Headers :: [nksip:header()], 
         Body::binary(), Rest::binary().

parse_packet(Packet) ->
    case binary:match(Packet, <<"\r\n\r\n">>) of
        nomatch when byte_size(Packet) < 65535 ->
            {more, Packet};
        nomatch ->
            lager:error("Skipping unrecognized big chunk parsing message"),
            {more, <<>>};
        _ ->
            case binary:split(Packet, <<"\r\n">>) of
                [<<>>, <<"\r\n", Rest/binary>>] ->
                    {rnrn, Rest};
                [First, Rest] ->
                    case binary:split(First, <<" ">>, [global]) of
                        [Method, RUri, <<"SIP/2.0">>] ->
                            Method1 = method(Method),
                            parse_packet(Packet, {req, Method1, RUri}, Rest);
                        [<<"SIP/2.0">>, Code | TextList] -> 
                            CodeText = nksip_lib:bjoin(TextList, <<" ">>),
                            case catch list_to_integer(binary_to_list(Code)) of
                                Code1 when is_integer(Code1) -> 
                                    parse_packet(Packet, {resp, Code1, CodeText}, Rest);
                                _ ->
                                    lager:notice("Skipping unrecognized line ~p "
                                                 "parsing message", [First]),
                                    parse_packet(Rest)
                            end;
                        _ ->
                            lager:notice("Skipping unrecognized line ~p "
                                         "parsing message", [First]),
                            parse_packet(Rest)
                    end
            end
    end.


%% @private 
-spec parse_packet(binary(), msg_class(), binary()) ->
    {ok, Class, Headers, Body, Rest} | {more, binary()} | {rnrn, binary()}
    when Class :: msg_class(), Headers :: [nksip:header()], 
         Body::binary(), Rest::binary().
    
parse_packet(Packet, Class, Rest) ->
    {Headers, Rest2} = get_raw_headers(Rest, []),
    CL = nksip_lib:get_integer(<<"Content-Length">>, Headers),
    case byte_size(Rest2) of
        CL -> 
            {ok, Class, Headers, Rest2, <<>>};
        BS when BS < CL -> 
            {more, Packet};
        _ when CL > 0 -> 
            {Body, Rest3} = split_binary(Rest2, CL),
            {ok, Class, Headers, Body, Rest3};
        _ -> 
            {ok, Class, Headers, <<>>, Rest2}
    end.


%% @private Second-stage SIP message parser
%% 15K/sec on i7
-spec raw_sipmsg(#raw_sipmsg{}) -> #sipmsg{} | error.
raw_sipmsg(Raw) ->
    #raw_sipmsg{
        id = Id,
        class = Class, 
        app_id = AppId, 
        start = Start,
        headers = Headers, 
        body = Body, 
        transport = Transport
    } = Raw,
    case Class of
        {req, Method, RequestUri} ->
            case uris(RequestUri) of
                [RUri] ->
                    case get_sipmsg(Headers, Body) of
                        error ->
                            error;
                        Request ->
                            Request#sipmsg{
                                id = Id,
                                class = req,
                                app_id = AppId,
                                method = Method,
                                ruri = RUri,
                                response = undefined,
                                transport = Transport,
                                start = Start,
                                data = []
                            }
                    end;
                _ ->
                    error
            end;
        {resp, Code, CodeText} ->
            case get_sipmsg(Headers, Body) of
                error ->
                    error;
                Response ->
                    Response#sipmsg{
                        id = Id,
                        class = resp,
                        app_id = AppId,
                        response = Code,
                        transport = Transport,
                        start = Start,
                        data = [{reason, CodeText}]
                    }
            end
    end.
    

%% @private
-spec get_sipmsg([nksip:header()], binary()) -> 
    #sipmsg{} | error.

get_sipmsg(Headers, Body) ->
    try
        case header_uris(<<"From">>, Headers) of
            [#uri{} = From] -> ok;
            _ -> From = throw("Could not parse From")
        end,
        case header_uris(<<"To">>, Headers) of
            [#uri{} = To] -> ok;
            _ -> To = throw("Could not parse To")
        end,
        case header_values(<<"Call-ID">>, Headers) of
            [CallId] when is_binary(CallId) -> CallId;
            _ -> CallId = throw("Could not parse Call-ID")
        end,
        case vias(nksip_lib:bjoin(header_values(<<"Via">>, Headers))) of
            [_|_] = Vias -> ok;
            _ -> Vias = throw("Could not parse Via")
        end,
        case header_values(<<"CSeq">>, Headers) of
            [CSeqHeader] ->
                case nksip_lib:tokenize(CSeqHeader, none) of
                    [[{CSeqInt0}, {CSeqMethod0}]] ->                
                        CSeqMethod = method(CSeqMethod0),
                        case (catch list_to_integer(CSeqInt0)) of
                            CSeqInt when is_integer(CSeqInt) -> ok;
                            true -> CSeqInt = throw("Invalid CSeq")
                        end;
                    _ -> 
                        CSeqInt=CSeqMethod=throw("Could not parse CSeq")
                end;
            _ ->
                CSeqInt=CSeqMethod=throw("Invalid CSeq")
        end,
        case header_integers(<<"Max-Forwards">>, Headers) of
            [] -> Forwards = 70;
            [Forwards] when is_integer(Forwards) -> ok;
            _ -> Forwards = throw("Could not parse Max-Forwards")
        end,
        ContentType = header_tokens(<<"Content-Type">>, Headers),
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
        }
    catch
        throw:ErrMsg ->
            lager:warning("Error parsing message: ~s", [ErrMsg]),
            error
    end.


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
                        "VIA" -> <<"Via">>;
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
    Tokens = nksip_lib:tokenize(Other, uri),
    uris(Rest, [lists:reverse(parse_uris(Tokens, []))|Acc]);

uris([], Acc) ->
    lists:reverse(lists:flatten(Acc)).


%% @private
-spec parse_uris([nksip_lib:token_list()], list()) -> 
    [nksip:uri()].

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
                {UriOpts, R3} = parse_opts(R2),
                {UriHds, R4} = parse_headers(R3),
                case R4 of
                    [$> | R5] -> 
                        {HdOpts, R6} = parse_opts(R5),
                        {HdHds, _} = parse_headers(R6);
                    _ -> 
                        HdOpts=HdHds=throw(error4)
                end;
            false ->
                HdOpts = HdHds = [],
                {UriOpts, R3} = parse_opts(R2),
                {UriHds, _} = parse_headers(R3)
        end,
        Uri = #uri{
            scheme = scheme(Scheme),
            disp = list_to_binary(Disp),
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
        throw:_ -> parse_uris(Rest, Acc)
    end;
parse_uris([], Acc) ->
    lists:reverse(Acc).


%% @private
-spec parse_vias([nksip_lib:token_list()], list()) -> 
    [nksip:via()] | error.

parse_vias([Tokens|Rest], Acc) ->
    try
        case Tokens of
            [{"SIP"}, $/, {"2.0"}, $/, {Transport}, {Host}, $:, {Port} | R] -> ok;
            [{"SIP"}, $/, {"2.0"}, $/, {Transport}, {Host} | R] -> Port="0";
            _ -> Transport=Host=Port=R=throw(error)
        end,
        {Opts, _} = parse_opts(R),
        Via = #via{
            proto = 
                case string:to_upper(Transport) of
                    "UDP" -> udp;
                    "TCP" -> tcp;
                    "TLS" -> tls;
                    "SCTP" -> sctp;
                    _ -> list_to_binary(Transport)
                end,
            domain = list_to_binary(Host), 
            port = 
                case catch list_to_integer(Port) of
                    Port1 when is_integer(Port1) -> Port1;
                    _ -> throw(error)
                end,
            opts = Opts},
        parse_vias(Rest, [Via|Acc])
    catch
        throw:_ -> parse_vias(Rest, Acc)
    end;
parse_vias([], Acc) ->
    lists:reverse(Acc).


%% @private
-spec parse_tokens(nksip_lib:token_list(), list()) -> 
    [nksip_lib:token()].

parse_tokens([{Name}|R1], Acc) ->
    {Opts, R2} = parse_opts(R1),
    parse_tokens(R2, [{list_to_binary(string:to_lower(Name)), Opts}|Acc]);
parse_tokens(_O, Acc) ->
    lists:reverse(Acc).


% @private
-spec parse_opts(nksip_lib:token_list()) -> 
    {Opts::nksip_lib:proplist(), Rest::nksip_lib:token_list()}.

parse_opts(TokenList) ->
    parse_opts(TokenList, []).

parse_opts(TokenList, Acc) ->
    case TokenList of
        [$;, {Key0}, $=, {Value0} | Rest] -> ok; 
        [$;, {Key0} | Rest] -> Value0 = none; 
        Rest -> Key0 = none, Value0 = none
    end,
    case Key0 of
        none -> 
            {lists:reverse(Acc), Rest};
        _ ->
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
    end.


%% @private
-spec parse_headers(nksip_lib:token_list()) ->
    {Headers::nksip_lib:proplist(), Rest::nksip_lib:token_list()}.

parse_headers([$?|Rest]) ->
    parse_headers([$&|Rest], []);
parse_headers(Rest) ->
    {[], Rest}.

parse_headers(TokenList, Acc) ->
    case TokenList of
        [$&, {Key0}, $=, {Value0} | Rest] -> ok; 
        [$&, {Key0} | Rest] -> Value0 = none; 
        Rest -> Key0 = none, Value0 = none
    end,
    case Key0 of
        none -> 
            {lists:reverse(Acc), Rest};
        _ ->
            Key = list_to_binary(Key0),
            case Value0 of
                none -> parse_headers(Rest, [Key|Acc]);
                _ -> parse_headers(Rest, [{Key, list_to_binary(Value0)}|Acc])
            end
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
        [#uri{disp=(<<"\"My name\"">>), user=(<<"user">>), pass=(<<"pass">>), 
            domain= <<"host">>, port=5061, opts=[{transport,<<"tcp">>}],
            headers=[<<"head1">>], ext_opts=[{<<"op1">>,<<"\"1\"">>}]}],
        uris(" \"My name\" <sip:user:pass@host:5061;transport=tcp?head1> ; op1=\"1\"")),
    ?assertMatch(
        [#uri{disp=(<<"Name">>), domain= <<"host">>, port=5061,
            ext_headers=[{<<"hd2">>,<<"2">>},{<<"hd3">>,<<"a">>}]}],
        uris(" Name   < sips : host:  5061 > ?hd2=2&hd3=a")),
    ?assertMatch(
        [#uri{user=(<<"user">>), domain= <<"host">>, opts=[lr,{<<"t">>,<<"1">>},<<"d">>]}],
        uris(" < sip : user@host ;lr; t=1 ;d ? a=1 >")),
    ?assertMatch(
        [
            #uri{user=(<<"user">>), domain= <<"host">>, opts=[lr,{<<"t">>,<<"1">>},<<"d">>],
                headers=[{<<"a">>,<<"1">>}]},
            #uri{domain= <<"host2">>, opts=[rport], ext_opts=[{<<"ttl">>,<<"5">>}], 
                ext_headers=[<<"a">>]}
        ],
        uris("  sip : user@host ;lr; t=1 ;d ? a=1, <sip:host2;rport>;ttl=5?a>")).

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
            {<<"a">>, []},
            {<<"b">>, []},
            {<<"c">>, [{<<"cc">>,<<"a">>},{<<"cb">>,<<"\"ocb\"">>}]},
            {<<"e">>, []},
            {<<"f">>, [lr]}
        ],
        tokens("a b c ; cc=a;cb  = \"ocb\", e, f;lr")).

-endif.


