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

-export([app_id/1, app_name/1, code/1, body/1, call_id/1]).
-export([meta/2, metas/2, header/2, headers/2]).
-export([wait_491/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets internal app's id
-spec app_id(nksip:response()|nksip:id()) -> 
    nksip:app_id().

app_id(#sipmsg{app_id=AppId}) ->
    AppId;
app_id(Id) when is_binary(Id) ->
    {req, AppId, _Id, _CallId} = nksip_sipmsg:parse_id(Id),
    AppId.


%% @doc Gets app's name
-spec app_name(nksip:response()|nksip:id()) -> 
    term().

app_name(Resp) -> 
    (app_id(Resp)):name().


-spec code(nksip:response()|nksip:id()) ->
    nksip:response_code()|error.

code(#sipmsg{class={resp, Code, _Phrase}}) -> 
    Code;
code(Id) when is_binary(Id) ->
    meta(code, Id).

%% @doc Gets the body of the response
-spec body(nksip:response()|nksip:id()) ->
    nksip:body() | error.

body(#sipmsg{body=Body}) -> 
    Body;
body(Id) when is_binary(Id) ->
    meta(body, Id).


%% @doc Gets the calls's id of a response id
-spec call_id(nksip:response()|nksip:id()) ->
    nksip:call_id().

call_id(#sipmsg{call_id=CallId}) ->
    CallId;
call_id(Id) when is_binary(Id) ->
    {req, _AppId, _Id, CallId} = nksip_sipmsg:parse_id(Id),
    CallId.


%% @doc Get a specific metadata (see {@link field()}) from the response
-spec meta(nksip_sipmsg:field(), nksip:response()|nksip:id()) ->
    term() | error.

meta(Field, #sipmsg{}=Resp) -> 
    nksip_sipmsg:meta(Field, Resp);
meta(Field, Id) when is_binary(Id) ->
    case metas([Field], Id) of
        [Value] -> Value;
        _ -> error
    end.


%% @doc Get a specific set of metadatas (see {@link field()}) from the response
-spec metas([nksip_sipmsg:field()], nksip:response()|nksip:id()) ->
    [{nksip_sipmsg:field(), term()}] | error.

metas(Fields, #sipmsg{}=Resp) when is_list(Fields) ->
    [{Field, nksip_sipmsg:meta(Field, Resp)} || Field <- Fields];
metas(Fields, Id) when is_list(Fields), is_binary(Id) ->
    Fun = fun(Resp) -> {ok, metas(Fields, Resp)} end,
    case nksip_call_router:apply_sipmsg(Id, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end.


%% @doc Gets values for a header in a response.
-spec header(string()|binary(), nksip:response()|nksip:id()) -> 
    [binary()] | error.

header(Name, #sipmsg{}=Resp) -> 
    nksip_sipmsg:header(Name, Resp);
header(Name, Id) when is_binary(Id) ->
    meta(nksip_lib:to_binary(Name), Id).


%% @doc Gets values for a set of headers in a response.
-spec headers([string()|binary()], nksip:response()|nksip:id()) -> 
    [{binary(), binary()}] | error.

headers(Names, #sipmsg{}=Resp) when is_list(Names) ->
    [{nksip_lib:to_binary(Name), nksip_sipmsg:header(Name, Resp)} || Name <- Names];
headers(Names, Id) when is_list(Names), is_binary(Id) ->
    metas([nksip_lib:to_binary(Name) || Name<-Names], Id).


%% @doc Sleeps a random time between 2.1 and 4 secs. It should be called after
%% receiving a 491 response and before trying the response again.
-spec wait_491() -> 
    ok.
wait_491() ->
    timer:sleep(10*crypto:rand_uniform(210, 400)).



