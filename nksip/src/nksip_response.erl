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

-export([field/2, fields/2, headers/2, body/1, code/1, reason/1, dialog_id/1]).
-export([wait_491/0, get_sipmsg/1]).
-export_type([id/0, field/0]).



%% ===================================================================
%% Types
%% ===================================================================

-type id() :: {resp, pid()}.

-type field() :: local | remote | ruri | parsed_ruri | aor | call_id | vias | 
                  parsed_vias | from | parsed_from | to | parsed_to | cseq | parsed_cseq |
                  cseq_num | cseq_method | forwards | routes | parsed_routes | 
                  contacts | parsed_contacts | content_type | parsed_content_type | 
                  headers | body  | code | reason | dialog_id | sipapp_id.


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
-spec field(field(), Input::id()|nksip:response()) -> any().

field(Field, Response) -> 
    case fields([Field], Response) of
        [Value|_] -> Value;
        Other -> Other
    end.


%% @doc Gets a number of fields from the `Response' as described in {@link field/2}.
-spec fields([field()], Input::id()|nksip:response()) -> [any()].
fields(Fields, #sipmsg{}=SipMsg) -> nksip_sipmsg:fields(Fields, SipMsg);
fields(Fields, Response) -> call(Response, {get_fields, Fields}).


%% @doc Gets all `Name' headers from the response.
-spec headers(string()|binary(), Input::id()|nksip:response()) -> [binary()].
headers(Name, #sipmsg{}=SipMsg) -> nksip_sipmsg:headers(Name, SipMsg);
headers(Name, Response) -> call(Response, {get_headers, Name}).


%% @doc Gets the <i>response code</i> of a `Response'.
-spec code(Input::id()|nksip:response()) -> nksip:response_code().
code(Response) -> field(code, Response).


%% @doc Gets the <i>reason</i> of a `Response'.
-spec reason(Input::id()|nksip:response()) -> binary.
reason(Response) ->  field(reason, Response).


%% @doc Gets the <i>dialog id</i> of a `Response'.
-spec dialog_id(Input::id()|nksip:response()) -> nksip_dialog:id().
dialog_id(Response) -> field(dialog_id, Response).

%% @doc Gets the <i>body</i> of a `Response'.
-spec body(Input::id()|nksip:response()) -> nksip:body().
body(Response) -> field(body, Response).


%% @doc Sleeps a random time between 2.1 and 4 secs. It should be called after
%% receiving a 491 response and before trying the request again.
-spec wait_491() -> 
    ok.
wait_491() ->
    timer:sleep(10*crypto:rand_uniform(210, 400)).


%% @private Gets the full #sipmsg{} record.
-spec get_sipmsg(id()) -> nksip:response().

get_sipmsg(Response) -> 
    call(Response, get_sipmsg).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec call(id(), term()) -> any().

call({resp, Pid}, Msg) when is_pid(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, Msg, 5000).



