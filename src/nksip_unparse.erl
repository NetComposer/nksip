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

%% @doc General SIP message generation functions
-module(nksip_unparse).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([uri/1, uri2proplist/1, via/1, token/1, packet/1, raw_packet/3]).
-export([error_reason/1]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Serializes an `uri()' or list of `uri()' into a `binary()'
-spec uri(nksip:uri() | [nksip:uri()]) ->
    binary().

uri(UriList) when is_list(UriList)->
    nksip_lib:bjoin([uri(Uri) || Uri <- UriList]);

uri(#uri{}=Uri) ->
    list_to_binary(raw_uri(Uri)).


%% @doc Serializes an `uri()' into a `proplist()'.
%% The first options in the list will be `scheme', `user' and `domain'.
%% The rest will be present only if they are present in the Uri
-spec uri2proplist(nksip:uri()) -> [Opts] when
    Opts :: {scheme, nksip:scheme()} | {user, binary()} | {domain, binary()} | 
            {disp, binary()} | {pass, binary()} | {port, inet:port_number()} |
            {opts, nksip_lib:proplist()} | {headers, [binary()|nksip:header()]} |
            {ext_opts, nksip_lib:proplist()} | {ext_headers, [binary()|nksip:header()]}.

uri2proplist(#uri{
                disp = Disp, 
                scheme = Scheme,
                user = User,
                pass = Pass,
                domain = Domain,
                port = Port,
                opts = Opts, 
                headers = Headers,
                ext_opts = ExtOpts, 
                ext_headers = ExtHeaders}) ->
    lists:flatten([
        {scheme, Scheme},
        {user, User},
        {domain, Domain},       
        case Disp of <<>> -> []; _ -> {disp, Disp} end,
        case Pass of <<>> -> []; _ -> {pass, Pass} end,
        case Port of 0 -> []; _ -> {port, Port} end,
        case Opts of [] -> []; _ -> {opts, Opts} end,
        case Headers of [] -> []; _ -> {headers, Headers} end,
        case ExtOpts of [] -> []; _ -> {ext_opts, ExtOpts} end,
        case ExtHeaders of [] -> []; _ -> {ext_headers, Headers} end
    ]).


%% @doc Serializes a `nksip:via()'
-spec via(nksip:via()) -> 
    binary().

via(#via{}=Via) ->
    list_to_binary(raw_via(Via)).


%% @doc Serializes a list of `token()'
-spec token(nksip:token() | [nksip:token()]) ->
    binary().

token({Token, Opts}) ->
    token([{Token, Opts}]);

token(Tokens) when is_list(Tokens) ->
    list_to_binary(raw_tokens(Tokens)).


%% @doc Serializes a 'reason' header
-spec error_reason(nksip:error_reason()) ->
    binary() | error.

error_reason({sip, Code}) ->
    error_reason({sip, Code, response_phrase(Code)});

error_reason({q850, Code}) ->
    error_reason({q850, Code, q850_prase(Code)});

error_reason({sip, Code, Text}) ->
    error_reason({<<"SIP">>, Code, Text});

error_reason({q850, Code, Text}) ->
    error_reason({<<"Q.850">>, Code, Text});

error_reason({Name, Code, Text}) ->
    Token = {nksip_lib:to_binary(Name), [
        {<<"cause">>, nksip_lib:to_binary(Code)},
        {<<"text">>, <<$", (nksip_lib:to_binary(Text))/binary, $">>}
    ]},
    nksip_unparse:token(Token);

error_reason(_) ->
    error.




%% ===================================================================
%% Private
%% ===================================================================


%% @private Generates a binary packet for a request or response
-spec packet(nksip:request() | nksip:response()) -> 
    binary().

packet(#sipmsg{class={resp, Code, Reason}}=Response) ->
    list_to_binary([<<"SIP/2.0 ">>, nksip_lib:to_binary(Code), 32, 
        case Reason of
            <<>> -> response_phrase(Code);
            RespText -> RespText
        end,
        <<"\r\n">>, serialize(Response)]);

packet(#sipmsg{class={req, Method}, ruri=RUri}=Request)  ->
    list_to_binary([
        nksip_lib:to_binary(Method), 
        32, raw_ruri(RUri), <<" SIP/2.0\r\n">>,
        serialize(Request)
    ]).


%% @private Generates a binary packet for a request or response
-spec raw_packet(#raw_sipmsg{}, nksip:response_code(), binary()) -> 
    binary().

raw_packet(#raw_sipmsg{headers=Hds}, Code, Reason) ->
    Hds1 = [{string:to_lower(nksip_lib:to_list(N)), V} || {N, V} <- Hds],
    list_to_binary([
        "SIP/2.0 ", nksip_lib:to_list(Code), 32,
            case Reason of
                <<>> -> response_phrase(Code);
                _ -> Reason
            end,
            "\r\n",
        "Via: ", nksip_lib:get_binary("via", Hds1), "\r\n",
        "From: ", nksip_lib:get_binary("from", Hds1), "\r\n",
        "To: ", nksip_lib:get_binary("to", Hds1), "\r\n",
        "Call-ID: ", nksip_lib:get_binary("call-id", Hds1), "\r\n",
        "CSeq: ", nksip_lib:get_binary("cseq", Hds1), "\r\n",
        "Max-Forwards: ", nksip_lib:get_binary("max-forwards", Hds1), "\r\n",
        "Content-Length: 0", nksip_lib:get_binary("contentlLength", Hds1), "\r\n",
        "\r\n"
    ]).




%% @private Serializes an `nksip:uri()', using `<' and `>' as delimiters
-spec raw_uri(nksip:uri()) -> 
    iolist().

raw_uri(#uri{domain=(<<"*">>)}) ->
    [<<"*">>];

raw_uri(#uri{}=Uri) ->
    [
        Uri#uri.disp, $<, nksip_lib:to_binary(Uri#uri.scheme), $:,
        case Uri#uri.user of
            <<>> -> <<>>;
            User ->
                case Uri#uri.pass of
                    <<>> -> [User, $@];
                    Pass -> [User, $:, Pass, $@]
                end
        end,
        Uri#uri.domain, 
        case Uri#uri.port of
            0 -> [];
            Port -> [$:, integer_to_list(Port)]
        end,
        gen_opts(Uri#uri.opts),
        gen_headers(Uri#uri.headers),
        $>,
        gen_opts(Uri#uri.ext_opts),
        gen_headers(Uri#uri.ext_headers)
    ].


%% @private Serializes an `nksip:uri()'  without `<' and `>' as delimiters
-spec raw_ruri(nksip:uri()) -> 
    iolist().

raw_ruri(#uri{}=Uri) ->
    [
        nksip_lib:to_binary(Uri#uri.scheme), $:,
        case Uri#uri.user of
            <<>> -> <<>>;
            User ->
                case Uri#uri.pass of
                    <<>> -> [User, $@];
                    Pass -> [User, $:, Pass, $@]
                end
        end,
        Uri#uri.domain, 
        case Uri#uri.port of
            0 -> [];
            Port -> [$:, integer_to_list(Port)]
        end,
        gen_opts(Uri#uri.opts)
    ].


%% @private Serializes a `nksip:via()'
-spec raw_via(nksip:via()) -> 
    iolist().

raw_via(#via{}=Via) ->
    [
        <<"SIP/2.0/">>, string:to_upper(nksip_lib:to_list(Via#via.proto)), 
        32, Via#via.domain, 
        case Via#via.port of
            0 -> [];
            Port -> [$:, integer_to_list(Port)]
        end,
        gen_opts(Via#via.opts)
    ].

%% @private Serializes a list of `token()'
-spec raw_tokens(nksip:token() | [nksip:token()]) ->
    iolist().

raw_tokens([]) ->
    [];

raw_tokens({Name, Opts}) ->
    raw_tokens([{Name, Opts}]);

raw_tokens(Tokens) ->
    raw_tokens(Tokens, []).


%% @private
-spec raw_tokens([nksip:token()], iolist()) ->
    iolist().

raw_tokens([{Head, Opts}, Second | Rest], Acc) ->
    Head1 = nksip_lib:to_binary(Head),
    raw_tokens([Second|Rest], [[Head1, gen_opts(Opts), $,]|Acc]);

raw_tokens([{Head, Opts}], Acc) ->
    Head1 = nksip_lib:to_binary(Head),
    lists:reverse([[Head1, gen_opts(Opts)]|Acc]).


%% @private Serializes a request or response. If `body' is a `nksip_sdp:sdp()' it will be
%% serialized also.
-spec serialize(nksip:request() | nksip:response()) -> 
    iolist().

serialize(#sipmsg{
            vias = Vias, 
            from = From, 
            to = To, 
            call_id = CallId, 
            cseq = CSeq, 
            cseq_method = Method, 
            forwards = Forwards, 
            routes = Routes, 
            contacts = Contacts, 
            headers = Headers, 
            content_type = ContentType, 
            require = Require, 
            supported = Supported,
            expires = Expires,
            event = Event,
            body = Body
        }) ->
    Body1 = case Body of
        _ when is_binary(Body) -> Body;
        #sdp{} -> nksip_sdp:unparse(Body);
        _ -> base64:encode(term_to_binary(Body))
    end,
    Headers1 = [
        [{<<"Via">>, raw_via(Via)} || Via <- Vias],
        {<<"From">>, raw_uri(From)},
        {<<"To">>, raw_uri(To)},
        {<<"Call-ID">>, CallId},
        {<<"CSeq">>, [nksip_lib:to_binary(CSeq), <<" ">>, nksip_lib:to_binary(Method)]},
        {<<"Max-Forwards">>, nksip_lib:to_binary(Forwards)},
        {<<"Content-Length">>, nksip_lib:to_binary(byte_size(Body1))},
        case Routes of 
            [] -> []; 
            _ -> [{<<"Route">>, raw_uri(Route)} || Route <- Routes]
        end,
        case Contacts of
            [] -> [];
            _ -> [{<<"Contact">>, raw_uri(Contact)} || Contact <- Contacts]
        end,
        case ContentType of
            undefined -> [];
            _ -> {<<"Content-Type">>, raw_tokens(ContentType)}
        end,
        case Require of
            [] -> [];
            _ -> {<<"Require">>, raw_tokens(Require)}
        end,
        case Supported of
            [] -> [];
            _ -> {<<"Supported">>, raw_tokens(Supported)}
        end,
        case Expires of
            undefined -> [];
            _ -> {<<"Expires">>, nksip_lib:to_binary(Expires)}
        end,
        case Event of
            undefined -> [];
            _ -> {<<"Event">>, raw_tokens(Event)}
        end,
        Headers
    ],
    [
        [[nksip_lib:to_binary(Name), $:, 32, nksip_lib:to_binary(Value), 13, 10] 
            || {Name, Value} <- lists:flatten(Headers1), Value/=empty],
        "\r\n", Body1
    ].


%% @private
-spec response_phrase(nksip:response_code()) -> 
    binary().

response_phrase(Code) ->
    case Code of
        100 -> <<"Trying">>;
        180 -> <<"Ringing">>;
        182 -> <<"Queued">>;
        183 -> <<"Session Progress">>;
        200 -> <<"OK">>;
        202 -> <<"Accepted">>;
        300 -> <<"Multiple Choices">>;
        301 -> <<"Moved Permanently">>;
        302 -> <<"Moved Temporarily">>;
        305 -> <<"Use Proxy">>;
        380 -> <<"Alternative Service">>;
        400 -> <<"Bad Request">>;
        401 -> <<"Unauthorized">>;
        402 -> <<"Payment Required">>;
        403 -> <<"Forbidden">>;
        404 -> <<"Not Found">>;
        405 -> <<"Method Not Allowed">>;
        406 -> <<"Not Acceptable">>;
        407 -> <<"Proxy Authentication Required">>;
        408 -> <<"Request Timeout">>;
        410 -> <<"Gone">>;
        412 -> <<"Conditional Request Failed">>;
        413 -> <<"Request Entity Too Large">>;
        414 -> <<"Request-URI Too Long">>;
        415 -> <<"Unsupported Media Type">>;
        416 -> <<"Unsupported URI Scheme">>;
        417 -> <<"Unknown Resource Priority">>;
        420 -> <<"Bad Extension">>;
        421 -> <<"Extension Required">>;
        422 -> <<"Session Interval Too Small">>;
        423 -> <<"Interval Too Brief">>;
        428 -> <<"Use Identity Header">>;
        429 -> <<"Provide Referrer Identity">>;
        436 -> <<"Bad Indentity-Info">>;
        437 -> <<"Unsupported Certificate">>;
        438 -> <<"Invalid Identity Header">>;
        480 -> <<"Temporarily Unavailable">>;
        481 -> <<"Call/Transaction Does Not Exist">>;
        482 -> <<"Loop Detected">>;
        483 -> <<"Too Many Hops">>;
        484 -> <<"Address Incomplete">>;
        485 -> <<"Ambiguous">>;
        486 -> <<"Busy Here">>;
        487 -> <<"Request Terminated">>;
        488 -> <<"Not Acceptable Here">>;
        489 -> <<"Bad Event">>;
        491 -> <<"Request Pending">>;
        493 -> <<"Undecipherable">>;
        494 -> <<"Security Agreement Required">>;
        500 -> <<"Server Internal Error">>;
        501 -> <<"Not Implemented">>;
        502 -> <<"Bad Gateway">>;
        503 -> <<"Service Unavailable">>;       % Network error
        504 -> <<"Server Time-out">>;
        505 -> <<"Version Not Supported">>;
        513 -> <<"Message Too Large">>;
        580 -> <<"Precondition Faillure">>;
        600 -> <<"Busy Everywhere">>;
        603 -> <<"Decline">>;
        604 -> <<"Does Not Exist Anywhere">>;
        606 -> <<"Not Acceptable">>;
        _   -> <<"Unknown Code">>
    end.


%% @private
gen_opts(Opts) ->
    gen_opts(Opts, []).


%% @private
gen_opts([], Acc) ->
    lists:reverse(Acc);
gen_opts([{K, V}|Rest], Acc) ->
    gen_opts(Rest, [[$;, nksip_lib:to_binary(K), 
                        $=, nksip_lib:to_binary(V)] | Acc]);
gen_opts([K|Rest], Acc) ->
    gen_opts(Rest, [[$;, nksip_lib:to_binary(K)] | Acc]).


%% @private
gen_headers(Hds) ->
    gen_headers(Hds, []).


%% @private
gen_headers([], []) ->
    [];
gen_headers([], Acc) ->
    [[_|R1]|R2] = lists:reverse(Acc),
    [$?, R1|R2];
gen_headers([{K, V}|Rest], Acc) ->
    gen_headers(Rest, [[$&, nksip_lib:to_binary(K), 
                        $=, nksip_lib:to_binary(V)] | Acc]);
gen_headers([K|Rest], Acc) ->
    gen_headers(Rest, [[$&, nksip_lib:to_binary(K)] | Acc]).



%% @private
%% http://wiki.freeswitch.org/wiki/Hangup_Causes
q850_prase(Code) ->
    case Code of
        0 -> <<"UNSPECIFIED">>;
        1 -> <<"UNALLOCATED_NUMBER">>;      
        2 -> <<"NO_ROUTE_TRANSIT_NET">>;
        3 -> <<"NO_ROUTE_DESTINATION">>;
        6 -> <<"CHANNEL_UNACCEPTABLE">>;
        7 -> <<"CALL_AWARDED_DELIVERED">>;
        16 -> <<"NORMAL_CLEARING">>;
        17 -> <<"USER_BUSY">>;
        18 -> <<"NO_USER_RESPONSE">>;
        19 -> <<"NO_ANSWER">>;
        20 -> <<"SUBSCRIBER_ABSENT">>;
        21 -> <<"CALL_REJECTED">>;
        22 -> <<"NUMBER_CHANGED">>;
        23 -> <<"REDIRECTION_TO_NEW_DESTINATION">>;
        25 -> <<"EXCHANGE_ROUTING_ERROR">>;
        27 -> <<"DESTINATION_OUT_OF_ORDER">>;
        28 -> <<"INVALID_NUMBER_FORMAT">>;
        29 -> <<"FACILITY_REJECTED">>;
        30 -> <<"RESPONSE_TO_STATUS_ENQUIRY">>;
        31 -> <<"NORMAL_UNSPECIFIED">>;
        34 -> <<"NORMAL_CIRCUIT_CONGESTION">>;
        38 -> <<"NETWORK_OUT_OF_ORDER">>;
        41 -> <<"NORMAL_TEMPORARY_FAILURE">>;
        42 -> <<"SWITCH_CONGESTION">>;
        43 -> <<"ACCESS_INFO_DISCARDED">>;
        44 -> <<"REQUESTED_CHAN_UNAVAIL">>;
        45 -> <<"PRE_EMPTED">>;
        47 -> <<"RESOURCE_UNAVAILABLE">>;
        50 -> <<"FACILITY_NOT_SUBSCRIBED">>;
        52 -> <<"OUTGOING_CALL_BARRED">>;
        54 -> <<"INCOMING_CALL_BARRED">>;
        57 -> <<"BEARERCAPABILITY_NOTAUTH">>;
        58 -> <<"BEARERCAPABILITY_NOTAVAIL">>;
        63 -> <<"SERVICE_UNAVAILABLE">>;
        65 -> <<"BEARERCAPABILITY_NOTIMPL">>;
        66 -> <<"CHAN_NOT_IMPLEMENTED">>;
        69 -> <<"FACILITY_NOT_IMPLEMENTED">>;
        79 -> <<"SERVICE_NOT_IMPLEMENTED">>;
        81 -> <<"INVALID_CALL_REFERENCE">>;
        88 -> <<"INCOMPATIBLE_DESTINATION">>;
        95 -> <<"INVALID_MSG_UNSPECIFIED">>;
        96 -> <<"MANDATORY_IE_MISSING">>;
        97 -> <<"MESSAGE_TYPE_NONEXIST">>;
        99 -> <<"IE_NONEXIST">>;
        100 -> <<"INVALID_IE_CONTENTS">>;
        101 -> <<"WRONG_CALL_STATE">>;
        102 -> <<"RECOVERY_ON_TIMER_EXPIRE">>;
        103 -> <<"MANDATORY_IE_LENGTH_ERROR">>;
        111 -> <<"PROTOCOL_ERROR">>;
        127 -> <<"INTERWORKING">>;
        487 -> <<"ORIGINATOR_CANCEL">>;
        500 -> <<"CRASH">>;
        501 -> <<"SYSTEM_SHUTDOWN">>;
        502 -> <<"LOSE_RACE">>;
        503 -> <<"MANAGER_REQUEST">>;
        600 -> <<"BLIND_TRANSFER">>;
        601 -> <<"ATTENDED_TRANSFER">>;
        602 -> <<"ALLOTTED_TIMEOUT">>;
        603 -> <<"USER_CHALLENGE">>;
        604 -> <<"MEDIA_TIMEOUT">>;
        605 -> <<"PICKED_OFF">>;
        606 -> <<"USER_NOT_REGISTERED">>;
        607 -> <<"PROGRESS_TIMEOUT">>;
        609 -> <<"GATEWAY_DOWN">>;
        _ -> <<"UNDEFINED">>
    end.
