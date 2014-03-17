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

-module(nksip_parse_header).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([parse/2, parse/3, name/1]).


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Parses a header value. 
%% If Name is binary(), it will is supposed it is canonical; if not sure, 
%% call `name(Name)`. If it is a string() or atom(), it is  converted to canonical form.
%% Throws {invalid, Name} in case of invalid header.
-spec parse(binary()|string()|atom(), term()) ->
    {binary(), term()}.

parse(Name, Value) ->
    parse(Name, Value, undefined).
    

%% @doc Parses a header value. 
%% Similar to `parse/2', but updates the #sipmsg{}.
-spec parse(binary(), term(), #sipmsg{}|undefined) ->
    {binary(), term()} | #sipmsg{}.

parse(Name, Value, Req) when is_binary(Name) ->
    try
        {Result, Update} = header(Name, Value),
        case Update of
            Pos when is_integer(Pos), is_record(Req, sipmsg) -> 
                setelement(Pos, Req, Result);
            {append, Pos} when is_record(Req, sipmsg) -> 
                setelement(Pos, Req, element(Pos, Req)++Result);
            headers when is_record(Req, sipmsg) ->
                Req#sipmsg{headers=Req#sipmsg.headers++[{Name, Result}]};
            _ ->
                {Name, Result}
        end
    catch
        throw:invalid -> throw({invalid, Name});
        throw:{empty, EmptyName} -> throw({empty, EmptyName})
    end;

parse(Name, Value, Req) when is_list(Name); is_atom(Name) ->
    Name1 = case name(Name) of 
        unknown -> nksip_lib:to_binary(Name);
        CanName -> CanName
    end,
    parse(Name1, Value, Req).


%% @private
header(<<"From">>, Value) -> 
    {single_uri(Value), #sipmsg.from};

header(<<"To">>, Value) -> 
    {single_uri(Value), #sipmsg.to};

header(<<"Via">>, Value) -> 
    {vias(Value), #sipmsg.vias};

header(<<"CSeq">>, Value) -> 
    {cseq(Value), #sipmsg.cseq};

header(<<"Max-Forwards">>, Value) -> 
    {integer(Value, 300), #sipmsg.forwards};

header(<<"Call-ID">>, Value) -> 
    case nksip_lib:to_binary(Value) of
        <<>> -> throw(invalid);
        CallId -> {CallId, #sipmsg.call_id}
    end;

header(<<"Route">>, Value) ->
    {uris(Value), {append, #sipmsg.routes}};

header(<<"Contact">>, Value) ->
    {uris(Value), {append, #sipmsg.contacts}};

header(<<"Record-Route">>, Value) ->
    {uris(Value), headers};

header(<<"Path">>, Value) ->
    {uris(Value), headers};

header(<<"Content-Length">>, Value) ->
    {integer(Value), none};

header(<<"Expires">>, Value) ->
    {integer(Value), #sipmsg.expires};

header(<<"Content-Type">>, Value) ->
    {single_token(Value), #sipmsg.content_type};
    
header(<<"Require">>, Value) ->
    {names(Value), #sipmsg.require};

header(<<"Supported">>, Value) ->
    {names(Value), #sipmsg.supported};

header(<<"Event">>, Value) ->
    {tokens(Value), #sipmsg.event};

header(<<"Session-Expires">>, Value) ->
    case single_token(Value) of
        undefined ->
            undefined;
        [{SE, Opts}] ->
            case nksip_lib:to_integer(SE) of
                SE1 when is_integer(SE1), SE1>0 -> 
                    case nksip_lib:get_binary(<<"refresher">>, Opts) of
                        <<"uac">> -> {{SE1, uac}, headers};
                        <<"uas">> -> {{SE1, uas}, headers};
                        _ -> {{SE1, undefined}, headers}
                    end;
                _ ->
                    throw(invalid)
            end;
        _ ->
            throw(invalid)
    end;

header(_Name, Value) ->
    {nksip_lib:to_binary(Value), headers}.


%% @private
-spec name(atom()|list()|binary()) ->
    binary() | unknown.

name(Name) when is_atom(Name) ->
    List = [case Ch of $_ -> $-; _ -> Ch end || Ch <- atom_to_list(Name)],
    raw_name(List);

name(Name) when is_binary(Name) ->
    raw_name(string:to_lower(binary_to_list(Name)));

name(Name) when is_list(Name) ->
    raw_name(string:to_lower(Name)).


%% @private
raw_name(Name) ->
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
        "max-forwards" -> <<"Max-Forwards">>;
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
        "reply-to" -> <<"Reply-To">>;
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


%% Parsers


single_uri(Data) ->
    case nksip_parse:uris(Data) of
        [#uri{} = Uri] -> Uri;
        _ -> throw(invalid)
    end.

uris(Data) ->
    case nksip_parse:uris(Data) of
        error -> throw(invalid);
        Uris -> Uris
    end.

vias(Data) ->
    case nksip_parse:vias(Data) of
        [_|_] = Vias -> Vias;
        _ -> throw(<<"Invalid Via">>)
    end.

single_token(Data) ->
    case nksip_parse:tokens(Data) of
        [ContentType] -> ContentType;
        _ -> throw(invalid)
    end.

tokens(Data) ->
    case nksip_parse:tokens(Data) of
        error -> throw(invalid);
        Tokens -> Tokens
    end.

names(Data) ->
    case nksip_parse:tokens(Data) of
        error -> throw(invalid);
        Tokens -> [Token || {Token, _} <- Tokens]
    end.

cseq(Data) ->
    case nksip_lib:tokens(Data) of
        [CSeq, Method] ->                
            case nksip_lib:to_integer(CSeq) of
                Int when is_integer(Int), Int>=0 andalso Int<4294967296 ->
                    {Int, nksip_parse:method(Method)};
                _ ->
                    throw(invalid)
            end;
        _ -> 
            throw(invalid)
    end.

integer(Data) ->
    integer(Data, 4294967296).

integer(Data, Max) ->
    case nksip_lib:to_integer(Data) of
        Int when is_integer(Int), Int>=0, Int=<Max -> Int;
        _ -> throw(invalid)
    end.





