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

-module(nksip_parse_headers).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([parse_headers/2, parse_headers/3, header_name/1]).
-export([get_sipmsg/4, uri_request/2]).


%% ===================================================================
%% Private
%% ===================================================================


%% @private
parse_headers(Name, Values) ->
    parse_headers(Name, Values, throw).


%% @private
parse_headers(Name, Values, Default) ->
    try
        case do_parse_headers(Name, Values) of
            undefined when Default==throw -> {error, <<"Invalid ", Name/binary>>};
            undefined -> Default;
            Result -> Result
        end
    catch
        throw:invalid -> {error, <<"Invalid", Name/binary>>}
    end.


%% @private
%% single uri
do_parse_headers(Name, Data) when Name == <<"From">>; Name == <<"To">> ->
    case nksip_parse:uris(Data) of
        [#uri{} = Uri] -> Uri;
        _ -> throw(<<"Invalid ", Name/binary>>)
    end;

%% binary, size > 0 
do_parse_headers(<<"Call-ID">>, Data) ->
    case Data of
        [CallId] when is_binary(CallId), byte_size(CallId)>0 -> CallId;
        _ -> throw(<<"Invalid Call-ID">>)
    end;

do_parse_headers(<<"Via">>, Data) ->
    case nksip_parse:vias(Data) of
        [_|_] = Vias -> Vias;
        _ -> throw(<<"Invalid Via">>)
    end;
    
do_parse_headers(<<"CSeq">>, Data) ->
    case Data of
        [CSeqHeader] ->
            case nksip_lib:tokens(CSeqHeader) of
                [CSeqInt0, CSeqMethod0] ->                
                    CSeqMethod = nksip_parse:method(CSeqMethod0),
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

do_parse_headers(<<"Max-Forwards">>, Data) ->
    case Data of
        [] ->
            undefined;
        [Forwards0] ->
            case catch list_to_integer(nksip_lib:to_list(Forwards0)) of
                F when is_integer(F), F>=0, F<300 -> F;
                _ -> throw(<<"Invalid Max-Forwards">>)
            end;
        _ -> 
            throw(<<"Invalid Max-Forwards">>)
    end;

%% uris
do_parse_headers(Name, Data) when Name == <<"Route">>; Name == <<"Contact">>;
                                Name == <<"Path">>; Name == <<"Record-Route">> ->
    case nksip_parse:uris(Data) of
        error -> throw(<<"Invalid ", Name/binary>>);
        Uris -> Uris
    end;

%% integer >= 0
do_parse_headers(Name, Data) when Name == <<"Content-Length">>; Name == <<"Expires">> ->
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
do_parse_headers(<<"Content-Type">>, Data) ->
    case nksip_parse:tokens(Data) of
        [] -> undefined;
        [ContentType] -> ContentType;
        _ -> throw(<<"Invalid Content-Type">>)
    end;

%% multiple tokens without args
do_parse_headers(Name, Data) when Name == <<"Require">>; Name == <<"Supported">> ->
    case nksip_parse:tokens(Data) of
        [] -> undefined;
        error -> throw(<<"Invalid ", Name/binary>>);
        Tokens0 -> [Token || {Token, _} <- Tokens0]
    end;

%% multiple tokens
do_parse_headers(Name, Data) when Name == <<"Event">> ->
    case nksip_parse:tokens(Data) of
        [] -> undefined;
        [Token] -> Token;
        _ -> throw(<<"Invalid ", Name/binary>>)
    end;

do_parse_headers(_Name, Data) ->
    Data.



%% @private
parse_all_headers(Name, Headers) ->
    parse_all_headers(Name, Headers, throw).

%% @private
parse_all_headers(Name, Headers, Default) ->
    Headers = proplists:get_all_values(Name, Headers),
    parse_headers(Name, Headers, Default).



%% @private
-spec get_sipmsg(nksip_parse:msg_class(), [nksip:header()], binary(), nksip:protocol()) -> 
    #sipmsg{}.

get_sipmsg(Class, Headers, Body, Proto) ->
    try
        case Class of
            {req, ReqMethod, _} -> ok;
            _ -> ReqMethod = undefined
        end,
        Event = parse_all_headers(<<"Event">>, Headers, undefined),
        case
            (ReqMethod=='SUBSCRIBE' orelse ReqMethod=='NOTIFY' orelse
            ReqMethod=='PUBLISH') andalso Event == undefined
        of
            true -> throw(<<"Invalid Event">>);
            false -> ok
        end,
        ContentLength = parse_all_headers(<<"Content-Length">>, Headers, 0),
        case ContentLength of
            0 when Proto/=tcp, Proto/=tls -> ok;
            _ when ContentLength == byte_size(Body) -> ok;
            _ -> throw(<<"Invalid Content-Length">>)
        end,
        ContentType = parse_all_headers(<<"Content-Type">>, Headers, undefined),
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
            from = From,
            to = To,
            call_id = parse_all_headers(<<"Call-ID">>, Headers), 
            vias = parse_all_headers(<<"Via">>, Headers),
            cseq = CSeqInt,
            cseq_method = CSeqMethod,
            forwards = parse_all_headers(<<"Max-Forwards">>, Headers, 70),
            routes = parse_all_headers(<<"Route">>, Headers, []),
            contacts = parse_all_headers(<<"Contact">>, Headers, []),
            expires = parse_all_headers(<<"Expires">>, Headers, undefined),
            content_type = ContentType,
            require = parse_all_headers(<<"Require">>, Headers, []),
            supported = parse_all_headers(<<"Supported">>, Headers, []),
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
-spec header_name(atom()|list()|binary()) ->
    binary().

header_name(Name) when is_atom(Name) ->
    case raw_header_name(my_atom_to_list(Name)) of
        same -> nksip_lib:to_binary(Name);
        Name1 -> Name1
    end;

header_name(Name) when is_binary(Name) ->
    case raw_header_name(string:to_lower(binary_to_list(Name))) of
        same -> Name;
        Name1 -> Name1
    end;

header_name(Name) when is_list(Name) ->
    case raw_header_name(string:to_lower(Name)) of
        same -> nksip_lib:to_binary(Name);
        Name1 -> Name1
    end.


%% @private
my_atom_to_list(Atom) ->
    lists:map(
        fun
            ($_) -> $-;
            (Ch) -> Ch
        end,
        atom_to_list(Atom)).


%% @private
raw_header_name(Name) ->
    case Name of
        "a" -> <<"Accept-Contact">>;
        "b" -> <<"Referred-By">>;
        "c" -> <<"Content-Type">>;
        "d" -> <<"Request-Disposition">>;
        "e" -> <<"Content-Encoding">>;
        "f" -> <<"From">>;
        "i" -> <<"Call-ID">>;
        "j" -> <<"Reject-Contact">>;
        "k" -> <<"Supported">>;
        "l" -> <<"Content-Length">>;
        "m" -> <<"Contact">>;
        "n" -> <<"Identity-Info">>;
        "o" -> <<"Event">>;
        "r" -> <<"Refer-To">>;
        "s" -> <<"Subject">>;
        "t" -> <<"To">>;
        "u" -> <<"Allow-Events">>;
        "v" -> <<"Via">>;
        "x" -> <<"Session-Expires">>;
        "y" -> <<"Identity">>;

        "x-"++_ -> unknown;

        "accept" -> <<"Accept">>;
        "allow" -> <<"Allow">>;
        "allow-events" -> <<"Allow-Events">>;
        "authorization" -> <<"Authorization">>;
        "call-id" -> <<"Call-ID">>;
        "contact" -> <<"Contact">>;
        "content-length" -> <<"Content-Length">>;
        "content-type" -> <<"Content-Type">>;
        "cseq" -> <<"CSeq">>;
        "event" -> <<"Event">>;
        "expires" -> <<"Expires">>;
        "from" -> <<"From">>;
        "path" -> <<"Path">>;
        "proxy-authenticate" -> <<"Proxy-Authenticate">>;
        "proxy-authorization" -> <<"Proxy-Authorization">>;
        "rack" -> <<"RAck">>;
        "record-route" -> <<"Record-Route">>;
        "require" -> <<"Require">>;
        "route" -> <<"Route">>;
        "rseq" -> <<"RSeq">>;
        "session-expires" -> <<"Session-Expires">>;
        "subscription-state" -> <<"Subscription-State">>;
        "supported" -> <<"Supported">>;
        "to" -> <<"To">>;
        "user-agent" -> <<"User-Agent">>;
        "via" -> <<"Via">>;
        "www-authenticate" -> <<"WWW-Authenticate">>;

        "accept-contact" -> <<"Accept-Contact">>;
        "accept-encoding" -> <<"Accept-Encoding">>;
        "accept-language" -> <<"Accept-Language">>;
        "accept-resource-priority" -> <<"Accept-Resource-Priority">>;
        "alert-info" -> <<"Alert-Info">>;
        "answer-mode" -> <<"Answer-Mode">>;
        "authentication-info" -> <<"Authentication-Info">>;
        "call-info" ->  <<"Call-Info">>;
        "content-disposition" -> <<"Content-Disposition">>;
        "content-encoding" -> <<"Content-Encoding">>;
        "date" -> <<"Date">>;
        "encryption" -> <<"Encryption">>;
        "error-info" -> <<"Error-Info">>;
        "feature-caps" -> <<"Feature-Caps">>;
        "flow-timer" -> <<"Flow-Timer">>;
        "geolocation" -> <<"Geolocation">>;
        "geolocation-error" -> <<"Geolocation-Error">>;
        "geolocation-routing" -> <<"Geolocation-Routing">>;
        "hide" -> <<"Hide">>;
        "history-info" -> <<"History-Info">>;
        "identity" -> <<"Identity">>;
        "identity-info" -> <<"Identity-Info">>;
        "info-package" -> <<"Info-Package">>;
        "in-reply-to" -> <<"In-Reply-To">>;
        "join" -> <<"Join">>;
        "max-breadth" -> <<"Max-Breadth">>;
        "max-forwards" -> <<"Max-Forwards">>;
        "mime-version" -> <<"MIME-Version">>;
        "min-expires" -> <<"Min-Expires">>;
        "min-se" -> <<"Min-SE">>;
        "organization" -> <<"Organization">>;
        "permission-missing" -> <<"Permission-Missing">>;
        "policy-contact" -> <<"Policy-Contact">>;
        "policy-id" -> <<"Policy-ID">>;
        "priority" -> <<"Priority">>;
        "proxy-require" -> <<"Proxy-Require">>;
        "reason" -> <<"Reason">>;
        "reason-phrase" -> <<"Reason-Phrase">>;
        "recv-info" -> <<"Recv-Info">>;
        "refer-sub" -> <<"Refer-Sub">>;
        "refer-to" -> <<"Refer-To">>;
        "referred-by" -> <<"Referred-By">>;
        "reject-contact" -> <<"Reject-Contact">>;
        "replaces" -> <<"Replaces">>;
        "reply-TO" -> <<"Reply-To">>;
        "request-disposition" -> <<"Request-Disposition">>;
        "resource-priority" -> <<"Resource-Priority">>;
        "response-key" -> <<"Response-Key">>;
        "retry-after" -> <<"Retry-After">>;
        "security-client" -> <<"Security-Client">>;
        "security-server" -> <<"Security-Server">>;
        "security-verify" -> <<"Security-Verify">>;
        "server" -> <<"Server">>;
        "service-route" -> <<"Service-Route">>;
        "sip-etag" -> <<"SIP-ETag">>;
        "sip-if-match" -> <<"SIP-If-Match">>;
        "subject" -> <<"Subject">>;
        "timestamp" -> <<"Timestamp">>;
        "trigger-consent" -> <<"Trigger-Consent">>;
        "unsupported" -> <<"Unsupported">>;
        "warning" -> <<"Warning">>;

        "p-access-network-info" -> <<"P-Access-Network-Info">>;
        "p-answer-state" -> <<"P-Answer-State">>;
        "p-asserted-identity" -> <<"P-Asserted-Identity">>;
        "p-asserted-service" -> <<"P-Asserted-Service">>;
        "p-associated-uri" -> <<"P-Associated-URI">>;
        "p-called-party-id" -> <<"P-Called-Party-ID">>;
        "p-charging-function-addresses" -> <<"P-Charging-Function-Addresses">>;
        "p-charging-vector" -> <<"P-Charging-Vector">>;
        "p-dcs-trace-party-id" -> <<"P-DCS-Trace-Party-ID">>;
        "p-dcs-osps" -> <<"P-DCS-OSPS">>;
        "p-dcs-billing-info" -> <<"P-DCS-Billing-Info">>;
        "p-dcs-laes" -> <<"P-DCS-LAES">>;
        "p-dcs-redirect" -> <<"P-DCS-Redirect">>;
        "p-early-media" -> <<"P-Early-Media">>;
        "p-media-authorization" -> <<"P-Media-Authorization">>;
        "p-preferred-identity" -> <<"P-Preferred-Identity">>;
        "p-preferred-service" -> <<"P-Preferred-Service">>;
        "p-profile-key" -> <<"P-Profile-Key">>;
        "p-refused-uri-list" -> <<"P-Refused-URI-List">>;
        "p-served-user" -> <<"P-Served-User">>;
        "p-user-database" -> <<"P-User-Database">>;
        "p-visited-network-id" -> <<"P-Visited-Network-ID">>;

        _ -> unknown
    end.




%% @doc Modifies a request based on uri options
-spec uri_request(nksip:user_uri(), nksip:request()) ->
    {nksip:request(), nksip:uri()} | {error, binary()}.

uri_request(RawUri, Req) ->
    try
        case nksip_parse:uris(RawUri) of
            [#uri{headers=[]}=Uri] ->
                {Req, Uri};
            [#uri{headers=Headers}=Uri] ->
                {uri_request_header(Headers, Req), Uri#uri{headers=[]}};
            _ ->
                throw(<<"Invalid URI">>)
        end
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private
uri_request_header([], Req) ->
    Req;

uri_request_header([{<<"body">>, Value}|Rest], Req) ->
    uri_request_header(Rest, Req#sipmsg{body=Value});

% From, To, Max-Forwards, Call-ID, CSeq, Content-Type, Require, Supported,
% Expires, Event and Contact replace existing headers.
% Via and Content-Length are ignored.
% Route and any other headers are inserted before existing headers.
uri_request_header([{Name, Value}|Rest], Req) ->
    #sipmsg{routes=Routes, contacts=Contacts, headers=Headers} = Req,
    Value1 = list_to_binary(http_uri:decode(nksip_lib:to_list(Value))), 
    Req1 = case nksip_parse_header:header_name(Name) of
        <<"From">> -> 
            Req#sipmsg{from=parse_headers(<<"From">>, [Value1])};
        <<"To">> -> 
            Req#sipmsg{to=parse_headers(<<"To">>, [Value1])};
        <<"Max-Forwards">> -> 
            Req#sipmsg{forwards=parse_headers(<<"Max-Forwards">>, [Value1])};
        <<"Call-ID">> -> 
            Req#sipmsg{call_id=parse_headers(<<"Call-ID">>, [Value1])};
        <<"CSeq">> -> 
            {CSeqInt, CSeqMethod} = parse_headers(<<"CSeq">>, [Value1]),
            Req#sipmsg{cseq=CSeqInt, cseq_method=CSeqMethod};
        <<"Via">> -> 
            Req;
        <<"Content-Type">> -> 
            Req#sipmsg{content_type=parse_headers(<<"Content-Type">>, [Value1])};
        <<"Require">> -> 
            Req#sipmsg{require=parse_headers(<<"Require">>, [Value1])};
        <<"Supported">> -> 
            Req#sipmsg{supported=parse_headers(<<"Supported">>, [Value1])};
        <<"Expires">> -> 
            Req#sipmsg{expires=parse_headers(<<"Expires">>, [Value1])};
        <<"Event">> -> 
            Req#sipmsg{event=parse_headers(<<"Event">>, [Value1])};
        <<"Content-Length">> -> 
            Req;
        <<"Route">> -> 
            % Routes in URL are inserted before existing
            Req#sipmsg{routes=parse_headers(<<"Route">>, [Value1])++Routes};
        <<"Contact">> -> 
            % Contacts in URL replaces previous contacts
            Req#sipmsg{contacts=Contacts++parse_headers(<<"Contact">>, [Value1])};
        unknown ->
            Req#sipmsg{headers=[{Name, Value1}|Headers]};
        Name1 -> 
            Req#sipmsg{headers=[{Name1, Value1}|Headers]}
    end,
    uri_request_header(Rest, Req1);

uri_request_header(_, _) ->
    throw(<<"Invalid URI">>).


