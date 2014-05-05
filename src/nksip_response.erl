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

-export([app_id/1, app_name/1, code/1, body/1, call_id/1, dialog_id/1]).
-export([meta/2, metas/2, header/2, headers/2]).
-export([wait_491/0]).
-export_type([resp/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================

-type resp() :: {user_resp, nksip_call:trans(), nksip_call:call()}.


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets internal app's id
-spec app_id(resp()) -> 
    nksip:app_id().

app_id({user_resp, _, #call{app_id=AppId}}) -> 
    AppId.


%% @doc Gets app's name
-spec app_name(resp()) -> 
    term().

app_name(UserResp) -> 
    (app_id(UserResp)):name().


%% @doc Gets the response code of a response.
-spec code(resp()) ->
    nksip:response_code().

code(UserResp) -> 
    meta(code, UserResp).


%% @doc Gets the body of the response
-spec body(resp()) ->
    nksip:body().

body(UserResp) -> 
    meta(body, UserResp).


%% @doc Gets the calls's id of a response id
-spec call_id(resp()) ->
    nksip:call_id().

call_id({user_resp, _, #call{call_id=CallId}}) ->
    CallId.


%% @doc Gets the dialog's id of the response
-spec dialog_id(resp()) ->
    nksip_dialog:id().

dialog_id(UserResp) -> 
    meta(dialog_id, UserResp).


%% @doc Get a specific metadata (see {@link field()}) from the response
-spec meta(nksip_sipmsg:field(), resp()) ->
    term().

meta(Field, {user_resp, #trans{response=Resp}, _Call}) -> 
    nksip_sipmsg:meta(Resp, Field).


%% @doc Get a specific set of metadatas (see {@link field()}) from the response
-spec metas([nksip_sipmsg:field()], resp()) ->
    [{nksip_sipmsg:field(), term()}].

metas(Fields, {user_resp, #trans{response=Resp}, _Call}) when is_list(Fields) ->
    [{Field, nksip_sipmsg:meta(Field, Resp)} || Field <- Fields].


%% @doc Gets values for a header in a response.
-spec header(string()|binary(), resp()) -> 
    [binary()].

header(Name, {user_resp, #trans{response=Resp}, _Call}) -> 
    nksip_sipmsg:header(Name, Resp).


%% @doc Gets values for a set of headers in a response.
-spec headers([string()|binary()], resp()) -> 
    [{string()|binary(), binary()}].

headers(Names, {user_resp, #trans{response=Resp}, _Call}) when is_list(Names) ->
    [{Name, nksip_sipmsg:header(Name, Resp)} || Name <- Names].


%% @doc Sleeps a random time between 2.1 and 4 secs. It should be called after
%% receiving a 491 response and before trying the response again.
-spec wait_491() -> 
    ok.
wait_491() ->
    timer:sleep(10*crypto:rand_uniform(210, 400)).



