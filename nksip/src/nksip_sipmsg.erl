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

%% @private Internal request and responses management.
%% Look at {@link nksip_request} and {@link nksip_response}.

-module(nksip_sipmsg).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([fields/2, field/2, header/2, header/3, dialog_id/1, call_id/1,get_sipmsg/1]).
-export_type([id/0]).

-include("nksip.hrl").

-type id() :: nksip_request:id() | nksip_response:id().

-type input() :: nksip:request() | nksip:request_id() |
                 nksip:response() | nksip:response_id().

-type field() :: nksip_request:field() | nksip_response:field().


%% @private
-spec field(input(), field()) ->
    term() | error.

field(#sipmsg{}=SipMsg, Field) ->
    get_field(SipMsg, Field);

field(MsgId, Field) ->
    case fields(MsgId, [Field]) of
        [Value] -> Value;
        error -> error
    end.


%% @private
-spec fields(input(), [field()]) ->
    [term()] | error.

fields(#sipmsg{}=SipMsg, Fields) when is_list(Fields) ->
    [get_field(SipMsg, Field) || Field <- Fields];

fields(MsgId, Fields) when is_list(Fields) ->
    Fun = fun(#sipmsg{}=SipMsg) -> {ok, fields(SipMsg, Fields)} end,
    case nksip_call_router:apply_sipmsg(MsgId, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end.

  
%% @private
-spec header(input(), binary()) ->
    [binary()] | error.

header(#sipmsg{}=SipMsg, Name) ->
    get_header(SipMsg, Name);

header(MsgId, Name) ->
    Fun = fun(#sipmsg{}=SipMsg) -> {ok, header(SipMsg, Name)} end,
    case nksip_call_router:apply_sipmsg(MsgId, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end.


%% @private
-spec header(input(), binary(), uris|tokens|integers|dates) ->
    [term()] | error.

header(MsgId, Name, Type) ->
    case header(MsgId, Name) of
        error ->
            error;
        Values ->
            case Type of
                uris -> nksip_parse:uris(Values);
                tokens -> nksip_parse:tokens(Values);
                integers -> nksip_parse:integers(Values);
                dates -> nksip_parse:dates(Values)
            end
    end.


%% @doc Gets the dialog's id of a request or response 
-spec dialog_id(input()) ->
    nksip:dialog_id() | undefined.

dialog_id(SipMsg) ->
    nksip_dialog:id(SipMsg).


%% @doc Gets the calls's id of a request or response 
-spec call_id(input()) ->
    nksip:call_id().

call_id({Class, _AppId, CallId, _MsgId, _DialogId})
          when Class=:=req; Class=:=resp ->
    CallId;

call_id(#sipmsg{call_id=CallId}) ->
    CallId.


%% @private
-spec get_sipmsg(input()) ->
    nksip:request() | nksip:response() | error.

get_sipmsg(#sipmsg{}=SipMsg) ->
    SipMsg;

get_sipmsg(MsgId) ->
    Fun = fun(#sipmsg{}=SipMsg) -> {ok, SipMsg} end,
    case nksip_call_router:apply_sipmsg(MsgId, Fun) of
        {ok, SipMsg} -> SipMsg;
        _ -> error
    end.



%% ===================================================================
%% Private
%% ===================================================================


%% @private Extracts a specific field from the request
%% See {@link nksip_request:field/2}.
-spec get_field(nksip:request() | nksip:response(), 
            nksip_request:field() | nksip_response:field()) -> 
    term().

get_field(#sipmsg{ruri=RUri, transport=T}=S, Field) ->
    case Field of
        app_id -> S#sipmsg.app_id;
        proto -> T#transport.proto;
        local -> {T#transport.proto, T#transport.local_ip, T#transport.local_port};
        remote -> {T#transport.proto, T#transport.remote_ip, T#transport.remote_port};
        method -> S#sipmsg.method;
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
        content_type -> nksip_unparse:tokens(S#sipmsg.content_type);
        parsed_content_type -> S#sipmsg.content_type;
        headers -> S#sipmsg.headers;
        body -> S#sipmsg.body;
        code -> S#sipmsg.response;   % Only if it is a response
        reason -> nksip_lib:get_binary(reason, S#sipmsg.opts);
        dialog_id -> nksip_dialog:id(S);
        expire -> S#sipmsg.expire;
        {header, Name} -> get_header(S, Name);
        registrar -> lists:member(registrar, S#sipmsg.opts);
        _ -> invalid_field 
    end.


%% @private
-spec get_header(nksip:request() | nksip:response(),
                 binary() | string()) -> 
    [binary()].

get_header(#sipmsg{headers=Headers}=SipMsg, Name) ->
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
        Name1 -> proplists:get_all_values(Name1, Headers)
    end.


