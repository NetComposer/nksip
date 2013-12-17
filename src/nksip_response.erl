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

%% @doc User Response Management Functions
-module(nksip_response).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([field/3, fields/3, header/3]).
-export([body/2, code/2, dialog_id/2, call_id/1, get_response/2, wait_491/0]).
-export_type([id/0, field/0]).



%% ===================================================================
%% Types
%% ===================================================================

-type id() :: binary().

-type field() ::  app_id | code | reason_phrase | call_id | vias | parsed_vias | 
                  ruri | ruri_scheme | ruri_user | ruri_domain | parsed_ruri | aor |
                  from | from_scheme | from_user | from_domain | parsed_from | 
                  to | to_scheme | to_user | to_domain | parsed_to | 
                  cseq | parsed_cseq | cseq_num | cseq_method | forwards |
                  routes | parsed_routes | contacts | parsed_contacts | 
                  content_type | parsed_content_type | 
                  expires | parsed_expires | event | parsed_event |
                  all_headers | body | dialog_id | local | remote |
                  binary().


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
%%          <td>`reason_phrase'</td>
%%          <td>`binary()'</td>
%%          <td>Reason Phrase</td>
%%      </tr>
%% </table>
-spec field(nksip:app_id(), id(), field()) ->
    term() | error.

field(AppId, RespId, Field) -> 
    case fields(AppId, RespId, [Field]) of
        [{_, Value}] -> Value;
        error -> error
    end.


%% @doc Get some fields from a response.
-spec fields(nksip:app_id(), id(), [field()]) ->
    [{atom(), term()}] | error.

fields(AppId, <<"S_", _/binary>>=RespId, Fields) -> 
    Fun = fun(Resp) -> {ok, lists:zip(Fields, nksip_sipmsg:fields(Resp, Fields))} end,
    case nksip_call_router:apply_sipmsg(AppId, RespId, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end.


%% @doc Get header values from a response.
-spec header(nksip:app_id(), id(), binary()) ->
    [binary()] | error.

header(AppId, <<"S_", _/binary>>=RespId, Name) -> 
    Fun = fun(Resp) -> {ok, nksip_sipmsg:header(Resp, Name)} end,
    case nksip_call_router:apply_sipmsg(AppId, RespId, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end.


%% @doc Gets the <i>response code</i> of a response.
-spec code(nksip:app_id(), id()) ->
    nksip:response_code() | error.

code(AppId, RespId) -> 
    field(AppId, RespId, code).


%% @doc Gets the <i>body</i> of a response.
-spec body(nksip:app_id(), id()) ->
    nksip:body() | error.

body(AppId, RespId) -> 
    field(AppId, RespId, body).


%% @doc Gets the <i>dialog_id</i> of a request.
-spec dialog_id(nksip:app_id(), id()) ->
    nksip_dialog:id() | error.

dialog_id(AppId, ReqId) -> 
    field(AppId, ReqId, dialog_id).


%% @doc Gets the calls's id of a response id
-spec call_id(id()) ->
    nksip:call_id().

call_id(<<"S_", Bin/binary>>) ->
    nksip_lib:bin_last($_, Bin).


%% @private
-spec get_response(nksip:app_id(), id()) ->
    nksip:response() | error.

get_response(AppId, <<"S_", _/binary>>=RespId) ->
    Fun = fun(Resp) -> {ok, Resp} end,
    case nksip_call_router:apply_sipmsg(AppId, RespId, Fun) of
        {ok, Resp} -> Resp;
        _ -> error
    end.


%% @doc Sleeps a random time between 2.1 and 4 secs. It should be called after
%% receiving a 491 response and before trying the request again.
-spec wait_491() -> 
    ok.
wait_491() ->
    timer:sleep(10*crypto:rand_uniform(210, 400)).



