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

%% @doc User Response management functions
-module(nksip_response).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([field/2, fields/2, header/2, body/1, code/1, reason/1, dialog_id/1]).
-export([wait_491/0]).
-export_type([id/0, field/0]).



%% ===================================================================
%% Types
%% ===================================================================

-type id() :: integer().

-type field() ::  sipapp_id | code | reason | call_id | vias | parsed_vias | 
                  ruri | ruri_scheme | ruri_user | ruri_domain | parsed_ruri | aor |
                  from | from_scheme | from_user | from_domain | parsed_from | 
                  to | to_scheme | to_user | to_domain | parsed_to | 
                  cseq | parsed_cseq | cseq_num | cseq_method | forwards |
                  routes | parsed_routes | contacts | parsed_contacts | 
                  content_type | parsed_content_type | 
                  headers | body | dialog_id | local | remote.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets specific information from the `Response'. 
%% The available fields are the same as {@link nksip_request:field/2}, 
%% and also:
%%  
%% <table border="1">
%%      <tr><th>Field</th><th>Type</th><th>Description</th></tr>
%%      <tr>
%%          <td>`code'</td>
%%          <td>{@link nksip:response_code()}</td>
%%          <td>Response Code</td>
%%      </tr>
%%      <tr>
%%          <td>`response'</td>
%%          <td>`binary()'</td>
%%          <td>Reason Phrase</td>
%%      </tr>
%% </table>

%% @doc Get a field from a response
-spec field(nksip:response()|nksip:response_id(), field()) ->
    term() | error.

field(#sipmsg{class=resp}=Resp, Field) -> 
    nksip_sipmsg:field(Resp, Field);

field({resp, _, _, _}=RespId, Field) -> 
    nksip_sipmsg:field(RespId, Field).


%% @doc Get some fields from a response
-spec fields(nksip:response()|nksip:response_id(), [field()]) ->
    [term()] | error.

fields(#sipmsg{class=resp}=Resp, Fields) -> 
    nksip_sipmsg:fields(Resp, Fields);

fields({resp, _, _, _}=RespId, Fields) -> 
    nksip_sipmsg:fields(RespId, Fields).


%% @doc Get header values from a response
-spec header(nksip:response()|nksip:response_id(), binary()) ->
    [binary()] | error.

header(#sipmsg{class=resp}=Resp, Name) -> 
    nksip_sipmsg:header(Resp, Name);

header({resp, _, _, _}=RespId, Name) -> 
    nksip_sipmsg:header(RespId, Name).



%% @doc Gets the <i>response code</i> of a response.
-spec code(nksip:response()|nksip:response_id()) ->
    nksip:response_code() | error.

code(Resp) -> 
    field(Resp, code).


%% @doc Gets the <i>reason</i> of a response.
-spec reason(nksip:response()|nksip:response_id()) ->
    binary() | error.

reason(Resp) ->  
    field(Resp, reason).


%% @doc Gets the <i>dialog id</i> of a response.
-spec dialog_id(nksip:response()|nksip:response_id()) ->
    nksip:dialog_id().

dialog_id(Resp) -> 
    nksip_dialog:id(Resp).


%% @doc Gets the <i>body</i> of a response.
-spec body(nksip:response()|nksip:response_id()) ->
    nksip:body() | error.

body(Resp) -> 
    field(Resp, body).


%% @doc Sleeps a random time between 2.1 and 4 secs. It should be called after
%% receiving a 491 response and before trying the request again.
-spec wait_491() -> 
    ok.
wait_491() ->
    timer:sleep(10*crypto:rand_uniform(210, 400)).



