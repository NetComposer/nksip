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

-export([fields/2, field/2, headers/2]).
-include("nksip.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec fields([nksip_request:field() | nksip_response:field()], 
              nksip:request() | nksip:response()) -> 
    [any()].

fields(Fields, Req) when is_list(Fields) ->
    [field(Field, Req) || Field <- Fields].


%% @private Extracts a specific field from the request
%% See {@link nksip_request:field/2}.
-spec field(nksip_request:field()|nksip_response:field(), 
            nksip:request() | nksip:response()) -> 
    any().

field(Type, SipMsg) ->
    #sipmsg{
        sipapp_id = AppId,
        method = Method,
        ruri = RUri = #uri{scheme=SipScheme, user=User, domain=Domain},
        vias = Vias,
        call_id = CallId,
        from = From,
        to = To,
        cseq = CSeq,
        cseq_method = CSeqMethod,
        forwards = Forwards,
        routes = Routes,
        contacts = Contacts,
        headers = Headers,
        content_type = ContentType,
        body = Body,
        response = Code,
        opts = Opts,
        transport=#transport{proto=Proto, local_ip=LocalIp, local_port=LocalPort,
                                remote_ip=RemoteIp, remote_port=RemotePort}
    } = SipMsg,
    case Type of
        sipapp_id -> AppId;
        local -> {Proto, LocalIp, LocalPort};
        remote -> {Proto, RemoteIp, RemotePort};
        method -> Method;
        ruri -> nksip_unparse:uri(RUri);
        parsed_ruri -> RUri;
        aor -> {SipScheme, User, Domain};
        call_id -> CallId;
        vias -> [nksip_lib:to_binary(Via) || Via <- Vias];
        parsed_vias -> Vias;
        from -> nksip_unparse:uri(From);
        parsed_from -> From;
        to -> nksip_unparse:uri(To);
        parsed_to -> To;
        cseq -> nksip_lib:bjoin([CSeq, CSeqMethod], <<" ">>);
        parsed_cseq -> {CSeq, CSeqMethod};
        cseq_num -> CSeq;
        cseq_method -> CSeqMethod;
        forwards -> Forwards;
        routes -> [nksip_lib:to_binary(Route) || Route <- Routes];
        parsed_routes -> Routes;
        contacts -> [nksip_lib:to_binary(Contact) || Contact <- Contacts];
        parsed_contacts -> Contacts;
        content_type -> nksip_unparse:tokens(ContentType);
        parsed_content_type -> ContentType;
        headers -> Headers;
        body -> Body;
        code -> Code;   % Only if it is a response
        reason -> nksip_lib:get_binary(reason, Opts);
        dialog_id -> nksip_dialog:id(SipMsg);
        _ -> <<>> 
    end.


%% @private
-spec headers(string() | binary(), 
              nksip:request() | nksip:response()) -> 
    [binary()].

headers(Name, #sipmsg{headers=Headers}=Req) ->
    case nksip_lib:to_binary(Name) of
        <<"Call-ID">> -> [field(call_id, Req)];
        <<"Via">> -> field(vias, Req);
        <<"From">> -> [field(from, Req)];
        <<"To">> -> [field(to, Req)];
        <<"CSeq">> -> [field(cseq, Req)];
        <<"Forwards">> -> [nksip_lib:to_binary(field(forwards, Req))];
        <<"Route">> -> field(routes, Req);
        <<"Contact">> -> field(contacts, Req);
        <<"Content-Type">> -> [field(content_type, Req)];
        Name1 -> proplists:get_all_values(Name1, Headers)
    end.

