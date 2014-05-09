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

%% @doc User Request Management Functions.

-module(nksip_request).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').


-export([get_id/1, app_id/1, app_name/1, method/1, body/1, call_id/1]).
-export([meta/2, header/2]).
-export([is_local_route/1, reply/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets request's id
-spec get_id(nksip:request()|nksip:id()) ->
    nksip:id().

get_id(#sipmsg{}=Req) ->
    nksip_sipmsg:get_id(Req);
get_id(<<Ch, _/binary>>=Id) when Ch==$R, Ch==$S ->
    Id.


%% @doc Gets internal app's id
-spec app_id(nksip:request()|nksip:id()) -> 
    nksip:app_id().

app_id(#sipmsg{app_id=AppId}) ->
    AppId;
app_id(Id) when is_binary(Id) ->
    {req, AppId, _Id, _CallId} = nksip_sipmsg:parse_id(Id),
    AppId.


%% @doc Gets app's name
-spec app_name(nksip:request()|nksip:id()) -> 
    term().

app_name(Req) -> 
    (app_id(Req)):name().


%% @doc Gets the method of the request
-spec method(nksip:request()|nksip:id()) ->
    nksip:method() | error.

method(#sipmsg{class={req, Method}}) ->
    Method;
method(Id) when is_binary(Id) ->
    meta(method, Id).


%% @doc Gets the body of the request
-spec body(nksip:request()|nksip:id()) ->
    nksip:body() | error.

body(#sipmsg{body=Body}) -> 
    Body;
body(Id) when is_binary(Id) ->
    meta(body, Id).


%% @doc Gets the calls's id of a request id
-spec call_id(nksip:request()|nksip:id()) ->
    nksip:call_id().

call_id(#sipmsg{call_id=CallId}) ->
    CallId;
call_id(Id) when is_binary(Id) ->
    {req, _AppId, _Id, CallId} = nksip_sipmsg:parse_id(Id),
    CallId.


%% @doc Get a specific metadata (see {@link field()}) from the request
-spec meta(nksip_sipmsg:field(), nksip:request()|nksip:id()) ->
    term() | [{nksip_sipmsg:field(), term()}] | error.

meta(Fields, #sipmsg{}=Req) when is_list(Fields), not is_integer(hd(Fields)) ->
    [{Field, nksip_sipmsg:meta(Field, Req)} || Field <- Fields];
meta(Fields, Id) when is_list(Fields), not is_integer(hd(Fields)), is_binary(Id) ->
    Fun = fun(Req) -> {ok, meta(Fields, Req)} end,
    case nksip_call_router:apply_sipmsg(Id, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end;
meta(Field, #sipmsg{}=Req) -> 
    nksip_sipmsg:meta(Field, Req);
meta(Field, Id) when is_binary(Id) ->
    case meta([Field], Id) of
        [{_, Value}] -> Value;
        _ -> error
    end.


%% @doc Gets values for a header in a request.
-spec header(string()|binary()|[string()|binary()], nksip:request()|nksip:id()) -> 
    [binary()] | [{binary(), binary()}] | error.

header(Names, #sipmsg{}=Req) when is_list(Names), not is_integer(hd(Names)) ->
    [{nksip_lib:to_binary(Name), nksip_sipmsg:header(Name, Req)} || Name <- Names];
header(Names, Id) when is_list(Names), not is_integer(hd(Names)), is_binary(Id) ->
    meta([nksip_lib:to_binary(Name) || Name<-Names], Id);
header(Name, #sipmsg{}=Req) -> 
    nksip_sipmsg:header(Name, Req);
header(Name, Id) when is_binary(Id) ->
    meta(nksip_lib:to_binary(Name), Id).


%% @doc Sends a reply to a request. Must get the request's id before, and
%% be called outside of the callback function.
-spec reply(nksip:sipreply(), nksip:id()) -> 
    ok | {error, Error}
    when Error :: invalid_call | invalid_request | nksip_call_router:sync_error().

reply(SipReply, <<"R_", _/binary>>=Id) ->
    nksip_call:send_reply(Id, SipReply).


%% @doc Checks if this request would be sent to a local address in case of beeing proxied.
%% It will return `true' if the first <i>Route</i> header points to a local address
%% or the <i>Request-Uri</i> if there is no <i>Route</i> headers.
-spec is_local_route(nksip:request()) -> 
    boolean().

is_local_route(#sipmsg{class={req, _}, app_id=AppId, ruri=RUri, routes=Routes}) ->
    case Routes of
        [] -> nksip_transport:is_local(AppId, RUri);
        [Route|_] -> nksip_transport:is_local(AppId, Route)
    end.

