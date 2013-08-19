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

%% @doc User Request management functions.

-module(nksip_request).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([field/2, fields/2, headers/2, body/1, method/1]).
-export([is_local_route/1, provisional_reply/2]).
-export([reply/2, get_sipmsg/1]).
-export_type([id/0, field/0]).

-include("nksip.hrl").



%% ===================================================================
%% Types
%% ===================================================================

-type id() :: {req, nksip:sipapp_id(), nksip:call_id(), integer()}.

-type field() :: local | remote | method | ruri | parsed_ruri | aor | call_id | vias | 
                  parsed_vias | from | parsed_from | to | parsed_to | cseq | parsed_cseq |
                  cseq_num | cseq_method | forwards | routes | parsed_routes | 
                  contacts | parsed_contacts | content_type | parsed_content_type | 
                  headers | body | dialog_id | sipapp_id.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets specific information from the `Request'. 
%% The available fields are:
%%  
%% <table border="1">
%%      <tr><th>Field</th><th>Type</th><th>Description</th></tr>
%%      <tr>
%%          <td>`sipapp_id'</td>
%%          <td>{@link nksip:sipapp_id()}</td>
%%          <td>SipApp's Id</td>
%%      </tr>
%%      <tr>
%%          <td>`method'</td>
%%          <td>{@link nksip:method()}</td>
%%          <td>Method</td>
%%      </tr>
%%      <tr>
%%          <td>`ruri'</td>
%%          <td>`binary()'</td>
%%          <td>Request-Uri</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_ruri'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>Request-Uri</td>
%%      </tr>
%%      <tr>
%%          <td>`aor'</td>
%%          <td>{@link nksip:aor()}</td>
%%          <td>Address-Of-Record of the Request-Uri</td>
%%      </tr>
%%      <tr>
%%          <td>`call_id'</td>
%%          <td>{@link nksip:call_id()}</td>
%%          <td>Call-ID Header</td>
%%      </tr>
%%      <tr>
%%          <td>`vias'</td>
%%          <td>`[binary()]'</td>
%%          <td>Via Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_vias'</td>
%%          <td>`['{@link nksip:via()}`]'</td>
%%          <td>Via Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`from'</td>
%%          <td>`binary()'</td>
%%          <td>From Header</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_from'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>From Header</td>
%%      </tr>
%%      <tr>
%%          <td>`to'</td>
%%          <td>`binary()'</td>
%%          <td>To Header</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_to'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>To Header</td>
%%      </tr>
%%      <tr>
%%          <td>`cseq'</td>
%%          <td>`binary()'</td>
%%          <td>CSeq Header</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_cseq'</td>
%%          <td>`{integer(), '{@link nksip:method()}`}'</td>
%%          <td>CSeq Header</td>
%%      </tr>
%%      <tr>
%%          <td>`forwards'</td>
%%          <td>`integer()'</td>
%%          <td>Forwards</td>
%%      </tr>
%%      <tr>
%%          <td>`routes'</td>
%%          <td>`[binary()]'</td>
%%          <td>Route Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_routes'</td>
%%          <td>`['{@link nksip:uri()}`]'</td>
%%          <td>Route Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`contacts'</td>
%%          <td>`[binary()]'</td>
%%          <td>Contact Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_contacts'</td>
%%          <td>`['{@link nksip:uri()}`]'</td>
%%          <td>Contact Headers</td>
%%      </tr>
%%      <tr>
%%          <td>`content_type'</td>
%%          <td>`binary()'</td>
%%          <td>Content-Type Header</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_content_type'</td>
%%          <td>`['{@link nksip_lib:token()}`]'</td>
%%          <td>Content-Type Header</td>
%%      </tr>
%%      <tr>
%%          <td>`headers'</td>
%%          <td>`[{binary(), binary()}]'</td>
%%          <td>User headers (not listed above)</td>
%%      </tr>
%%      <tr>
%%          <td>`body'</td>
%%          <td>{@link nksip:body()}</td>
%%          <td>Parsed Body</td>
%%      </tr>
%%      <tr>
%%          <td>`dialog_id'</td>
%%          <td>{@link nksip_dialog:id()}</td>
%%          <td>Dialog's Id (if the request has To Tag)</td>
%%      </tr>
%%      <tr>
%%          <td>`local'</td>
%%          <td>`{'{@link nksip:protocol()}, {@link inet:ip_address()}, 
%%                  {@link inet:port_number()}`}'</td>
%%          <td>Local transport protocol, ip and port of a request</td>
%%      </tr>
%%      <tr>
%%          <td>`remote'</td>
%%          <td>`{'{@link nksip:protocol()}, {@link inet:ip_address()}, 
%%                  {@link inet:port_number()}`}'</td>
%%          <td>Remote transport protocol, ip and port of a request</td>
%%      </tr>
%% </table>
-spec field(field(), Input::id()|nksip:request()) -> any().

field(Field, Request) -> 
    case fields([Field], Request) of
        [Value|_] -> Value;
        Error -> Error
    end.


%% @doc Gets a number of fields from the `Request' as described in {@link field/2}.
-spec fields([field()], Input::id()|nksip:request()) -> [any()].

fields(Fields, #sipmsg{}=Request) ->
    nksip_sipmsg:fields(Fields, Request);

fields(Fields, Request) ->
    case nksip_call:get_fields(Request, Fields) of
        {ok, Fields} -> Fields;
        {error, Error} -> {error, Error}
    end.


%% @doc Gets all `Name' headers from the request.
-spec headers(string()|binary(), Input::id()|nksip:request()) -> [binary()].

headers(Name, #sipmsg{}=Request) ->
    nksip_sipmsg:headers(Name, Request);

headers(Name, Request) ->
    case nksip_call:get_headers(Request, Name) of
        {ok, Values} -> Values;
        {error, Error} -> {error, Error}
    end.



%% @doc Gets the <i>method</i> of a `Request'.
-spec method(id()|nksip:request()) -> nksip:method().

method(Request) -> 
    field(method, Request).


%% @doc Gets the <i>body</i> of a `Request'.
-spec body(id()|nksip:request()) -> nksip:body().

body(Request) -> 
    field(body, Request).



%% @doc Sends a <i>provisional response</i> to a request.
-spec provisional_reply(id(), nksip:sipreply()) -> 
    ok | {error, Error}
    when Error :: unknown_request | invalid_response | network_error | invalid_request.

provisional_reply(Request, SipReply) ->
    case nksip_reply:reqreply(SipReply) of
        #reqreply{code=Code} = Response when Code > 100, Code < 200 ->
            reply(Request, Response);
        _ ->
            {error, invalid_response}
    end.


%% @private Gets the full #sipmsg{} record.
-spec get_sipmsg(id()) -> nksip:request().

get_sipmsg(Request) -> 
    nksip_call:get_sipmsg(Request).


%% @doc Checks if this request would be sent to a local address in case of beeing proxied.
%% It will return `true' if the first <i>Route</i> header points to a local address
%% or the <i>Request-Uri</i> if there is no <i>Route</i> headers.
-spec is_local_route(id()|nksip:request()) -> boolean().

is_local_route(Request) ->
    case fields([sipapp_id, parsed_ruri, parsed_routes], Request) of
        [AppId, RUri, []] -> nksip_transport:is_local(AppId, RUri);
        [AppId, _, [Route|_]] -> nksip_transport:is_local(AppId, Route);
        Error -> Error
    end.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec reply(id(), nksip:sipreply()|#reqreply{}) -> 
    {ok, nksip:response()} | {error, Error}
    when Error :: unknown_request | network_error | invalid_request.

reply({req, AppId, CallId, Id}, SipReply) ->
    nksip_call:app_reply(AppId, CallId, Id, SipReply);
reply(_, _) ->
    {error, unknown_request}.






