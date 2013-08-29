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

-export([fields/2, field/2, header/2, header/3, get_sipmsg/1]).

-include("nksip.hrl").
%-include("nksip_call.hrl").


field(#sipmsg{}=SipMsg, Field) ->
    {ok, get_field(SipMsg, Field)};

field(MsgId, Field) ->
    case fields(MsgId, [Field]) of
        {ok, [Value]} -> {ok, Value};
        {error, Error} -> {error, Error}
    end.


fields(#sipmsg{}=SipMsg, Fields) when is_list(Fields) ->
    {ok, [get_field(Field, SipMsg) || Field <- Fields]};

fields(MsgId, Fields) when is_list(Fields) ->
    nksip_call_router:get_sipmsg_fields(MsgId, Fields).

  
header(#sipmsg{}=SipMsg, Name) ->
    {ok, get_header(SipMsg, Name)};

header(MsgId, Name) ->
    nksip_call_router:get_sipmsg_header(MsgId, Name).

header(MsgId, Name, Type) ->
    case header(MsgId, Name) of
        {ok, Values} ->
            case Type of
                uris -> {ok, nksip_parse:uris(Values)};
                tokens -> {ok, nksip_parse:tokens(Values)};
                integers -> {ok, nksip_parse:integers(Values)};
                dates -> {ok, nksip_parse:dates(Values)}
            end;
        {error, Error} ->
            {error, Error}
    end.

get_sipmsg(MsgId) ->
    nksip_call_router:get_sipmsg(MsgId).



%% ===================================================================
%% Private
%% ===================================================================



%% @private Extracts a specific field from the request
%% See {@link nksip_request:field/2}.
-spec field(nksip_request:field()|nksip_response:field(), 
            nksip:request() | nksip:response()) -> 
    any().

get_field(#sipmsg{ruri=RUri, transport=T}=S, Field) ->
    case Field of
        sipapp_id -> S#sipmsg.sipapp_id;
        proto -> T#transport.proto;
        local -> {T#transport.proto, T#transport.local_ip, T#transport.local_port};
        remote -> {T#transport.proto, T#transport.remote_ip, T#transport.remote_port};
        method -> S#sipmsg.method;
        ruri -> nksip_unparse:uri(RUri);
        parsed_ruri -> S#sipmsg.ruri;
        scheme -> (S#sipmsg.ruri)#uri.scheme;
        aor -> {RUri#uri.scheme, RUri#uri.user, RUri#uri.domain};
        call_id -> S#sipmsg.call_id;
        vias -> [nksip_lib:to_binary(Via) || Via <- S#sipmsg.vias];
        parsed_vias -> S#sipmsg.vias;
        from -> nksip_unparse:uri(S#sipmsg.from);
        parsed_from -> S#sipmsg.from;
        to -> nksip_unparse:uri(S#sipmsg.to);
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
        _ -> invalid_field 
    end.


%% @private
-spec get_header(string() | binary(), 
              nksip:request() | nksip:response()) -> 
    [binary()].

get_header(#sipmsg{headers=Headers}=SipMsg, Name) ->
    case nksip_lib:to_binary(Name) of
        <<"Call-ID">> -> [field(call_id, SipMsg)];
        <<"Via">> -> field(vias, SipMsg);
        <<"From">> -> [field(from, SipMsg)];
        <<"To">> -> [field(to, SipMsg)];
        <<"CSeq">> -> [field(cseq, SipMsg)];
        <<"Forwards">> -> [nksip_lib:to_binary(field(forwards, SipMsg))];
        <<"Route">> -> field(routes, SipMsg);
        <<"Contact">> -> field(contacts, SipMsg);
        <<"Content-Type">> -> [field(content_type, SipMsg)];
        Name1 -> proplists:get_all_values(Name1, Headers)
    end.


