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

%% @doc Internal request and responses management.
%% This module allows to work with raw requests and responses (#sipmsg{} records)

-module(nksip_sipmsg).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([field/2, fields/2, named_fields/2, header/2, header/3, make_id/2]).

-include("nksip.hrl").

-type field() :: nksip_request:field() | nksip_response:field().


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Extracts a specific field from a sipmsg.
%% Valid fields are defined in {@link nksip_request:field()} and 
%% {@link nksip_response:field()}.
-spec field(nksip:request() | nksip:response(), 
            nksip_request:field() | nksip_response:field()) -> 
    term().

field(#sipmsg{class=Class, ruri=RUri, transport=T}=S, Field) ->
    case Field of
        id -> S#sipmsg.id;
        app_id -> S#sipmsg.app_id;
        dialog_id -> S#sipmsg.dialog_id;
        subscription_id -> nksip_subscription:id(S);
        proto -> T#transport.proto;
        local -> {T#transport.proto, T#transport.local_ip, T#transport.local_port};
        remote -> {T#transport.proto, T#transport.remote_ip, T#transport.remote_port};
        method -> case Class of {req, Method} -> Method; _ -> undefined end;
        ruri -> nksip_unparse:uri(RUri);
        ruri_scheme -> (S#sipmsg.ruri)#uri.scheme;
        ruri_user -> (S#sipmsg.ruri)#uri.user;
        ruri_domain -> (S#sipmsg.ruri)#uri.domain;
        parsed_ruri -> S#sipmsg.ruri;
        scheme -> (S#sipmsg.ruri)#uri.scheme;
        aor -> {RUri#uri.scheme, RUri#uri.user, RUri#uri.domain};
        call_id -> S#sipmsg.call_id;
        vias -> [nksip_lib:to_binary(Via) || Via <- S#sipmsg.vias];
        parsed_vias -> S#sipmsg.vias;
        from -> nksip_unparse:uri(S#sipmsg.from);
        from_scheme -> (S#sipmsg.from)#uri.scheme;
        from_user -> (S#sipmsg.from)#uri.user;
        from_domain -> (S#sipmsg.from)#uri.domain;
        parsed_from -> S#sipmsg.from;
        to -> nksip_unparse:uri(S#sipmsg.to);
        to_scheme -> (S#sipmsg.to)#uri.scheme;
        to_user -> (S#sipmsg.to)#uri.user;
        to_domain -> (S#sipmsg.to)#uri.domain;
        parsed_to -> S#sipmsg.to;
        cseq -> nksip_lib:bjoin([S#sipmsg.cseq, S#sipmsg.cseq_method], <<" ">>);
        parsed_cseq -> {S#sipmsg.cseq, S#sipmsg.cseq_method};
        cseq_num -> S#sipmsg.cseq;
        cseq_method -> S#sipmsg.cseq_method;
        forwards -> S#sipmsg.forwards;
        routes -> [nksip_lib:to_binary(Route) || Route <- S#sipmsg.routes];
        parsed_routes -> S#sipmsg.routes;
        contacts -> [nksip_lib:to_binary(Contact) || Contact <- S#sipmsg.contacts];
        parsed_contacts -> S#sipmsg.contacts;
        require -> nksip_unparse:token(S#sipmsg.require);
        parsed_require -> S#sipmsg.require;
        supported -> nksip_unparse:token(S#sipmsg.supported);
        parsed_supported -> S#sipmsg.supported;
        allow -> header(S, <<"Allow">>);
        body -> S#sipmsg.body;
        expires -> case S#sipmsg.expires of undefined -> <<>>; Exp -> Exp end;
        parsed_expires -> S#sipmsg.expires;
        event -> 
            case S#sipmsg.event of undefined -> <<>>; E -> nksip_unparse:token(E) end;
        parsed_event -> S#sipmsg.event;
        all_headers -> all_headers(S);
        code -> case Class of {resp, Code, _Reason} -> Code; _ -> 0 end;
        reason_phrase -> case Class of {resp, _Code, Reason} -> Reason; _ -> <<>> end;
        realms -> nksip_auth:realms(S);
        rseq_num -> 
            case header(S, <<"RSeq">>, integers) of [RSeq] -> RSeq; _ -> undefined end;
        content_type -> 
            case S#sipmsg.content_type of 
                undefined -> <<>>; 
                CT -> nksip_unparse:token(CT)
            end;
        parsed_content_type -> S#sipmsg.content_type;
        parsed_rack ->
            case header(S, <<"RAck">>) of 
                [RAck] ->
                    case nksip_lib:tokens(RAck) of
                        [RSeq, CSeq, Method] ->
                            {
                                nksip_lib:to_integer(RSeq),
                                nksip_lib:to_integer(CSeq),
                                nksip_parse:method(Method)
                            };
                        _ ->
                            undefined
                    end;
                _ ->
                
                    undefined
            end;
        _ when is_binary(Field) -> header(S, Field);
        {value, _Name, Value} -> Value;
        _ -> invalid_field 
    end.



%% @doc Extracts a group of fields from a #sipmsg.
-spec fields(nksip:request()|nksip:response(), [field()]) ->
    [term()].

fields(#sipmsg{}=SipMsg, Fields) when is_list(Fields) ->
    [field(SipMsg, Field) || Field <- Fields].


%% @doc Extracts a group of fields from a #sipmsg.
-spec named_fields(nksip:request()|nksip:response(), [field()]) ->
    [term()].

named_fields(#sipmsg{}=SipMsg, Fields) when is_list(Fields) ->
    [
        {
            case Field of 
                {value, Name, _} -> Name;
                _ -> Field
            end,
            field(SipMsg, Field)
        } 
        || Field <- Fields
    ].


%% @doc Extracts a header from a #sipmsg.
-spec header(nksip:request() | nksip:response(),
                 binary() | string()) -> 
    [binary()].

header(#sipmsg{headers=Headers}=SipMsg, Name) ->
    case nksip_lib:to_binary(Name) of
        <<"Call-ID">> -> [field(SipMsg, call_id)];
        <<"Via">> -> field(SipMsg, vias);
        <<"From">> -> [field(SipMsg, from)];
        <<"To">> -> [field(SipMsg, to)];
        <<"CSeq">> -> [field(SipMsg, cseq)];
        <<"Forwards">> -> [nksip_lib:to_binary(field(SipMsg, forwards))];
        <<"Route">> -> field(SipMsg, routes);
        <<"Contact">> -> field(SipMsg, contacts);
        <<"Content-Type">> -> [field(SipMsg, content_type)];
        <<"Require">> -> [field(SipMsg, require)];
        <<"Supported">> -> [field(SipMsg, supported)];
        <<"Expires">> -> [field(SipMsg, expires)];
        <<"Event">> -> [field(SipMsg, event)];
        Name1 -> proplists:get_all_values(Name1, Headers)
    end.


%% @doc Extracts a header from a #sipmsg and formats it.
-spec header(nksip:request() | nksip:response(), binary(), uris|tokens|integers|dates) ->
    [term()] | error.

header(#sipmsg{}=SipMsg, Name, Type) ->
    Raw = header(SipMsg, Name),
    case Type of
        uris -> nksip_parse:uris(Raw);
        tokens -> nksip_parse:tokens(Raw);
        integers -> nksip_parse:integers(Raw);
        dates -> nksip_parse:dates(Raw)
    end.


%% @private
all_headers(SipMsg) ->
    lists:flatten([
        {<<"Call-ID">>, [field(SipMsg, call_id)]},
        {<<"Via">>, field(SipMsg, vias)},
        {<<"From">>, [field(SipMsg, from)]},
        {<<"To">>, [field(SipMsg, to)]},
        {<<"CSeq">>, [field(SipMsg, cseq)]},
        {<<"Forwards">>, [nksip_lib:to_binary(field(SipMsg, forwards))]},
        case field(SipMsg, routes) of
            [] -> [];
            Routes -> {<<"Route">>, Routes}
        end,
        case field(SipMsg, contacts) of
            [] -> [];
            Contacts -> {<<"Contact">>, Contacts}
        end,
        case field(SipMsg, content_type) of
            <<>> -> [];
            ContentType -> {<<"Content-Type">>, ContentType}
        end,
        case field(SipMsg, require) of
            <<>> -> [];
            Require -> {<<"Require">>, Require}
        end,
        case field(SipMsg, supported) of
            <<>> -> [];
            Supported -> {<<"Supported">>, Supported}
        end,
        case field(SipMsg, expires) of
            <<>> -> [];
            Expires -> {<<"Expires">>, Expires}
        end,
        case field(SipMsg, event) of
            <<>> -> [];
            Event -> {<<"Event">>, Event}
        end,
        SipMsg#sipmsg.headers
    ]).


%% @private
-spec make_id(req|resp, nksip:call_id()) ->
    nksip_request:id() | nksip_response:id().

make_id(Class, CallId) ->
    <<
        case Class of
            req -> $R;
            resp -> $S
        end,
        $_,
        (nksip_lib:uid())/binary,
        $_,
        CallId/binary
    >>.


