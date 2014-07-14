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


-export([get_handle/1, app_id/1, app_name/1, method/1, body/1, call_id/1]).
-export([meta/2, metas/2, header/2, reply/2, is_local_route/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets request's id
-spec get_handle(nksip:request()|nksip:handle()) ->
    {ok, nksip:handle()}.

get_handle(Term) ->
    case nksip_sipmsg:get_handle(Term) of
        <<"R_", _/binary>> = Handle -> {ok, Handle};
        _ -> error(invalid_request)
    end.


%% @doc Gets internal app's id
-spec app_id(nksip:request()|nksip:handle()) -> 
    {ok, nksip:app_id()}.

app_id(#sipmsg{class={req, _}, app_id=AppId}) ->
    {ok, AppId};
app_id(Handle) ->
    case nksip_sipmsg:parse_handle(Handle) of
        {req, AppId, _Id, _CallId} -> {ok, AppId};
        _ -> error(invalid_request)
    end.


%% @doc Gets app's name
-spec app_name(nksip:request()|nksip:handle()) -> 
    {ok, nksip:app_name()}.

app_name(Req) -> 
    {ok, AppId} = app_id(Req),
    {ok, AppId:name()}.


%% @doc Gets the calls's id of a request id
-spec call_id(nksip:request()|nksip:handle()) ->
    {ok, nksip:call_id()}.

call_id(#sipmsg{class={req, _}, call_id=CallId}) ->
    {ok, CallId};
call_id(Handle) ->
    case nksip_sipmsg:parse_handle(Handle) of
        {req, _AppId, _Id, CallId} -> {ok, CallId};
        _ -> error(invalid_request)
    end.


%% @doc Gets the method of the request
-spec method(nksip:request()|nksip:handle()) ->
    {ok, nksip:method()} | {error, term()}.

method(#sipmsg{class={req, Method}}) ->
    {ok, Method};
method(Handle) ->
    meta(method, Handle).


%% @doc Gets the body of the request
-spec body(nksip:request()|nksip:handle()) ->
    {ok, nksip:body()} | {error, term()}.

body(#sipmsg{class={req, _}, body=Body}) -> 
    {ok, Body};
body(Handle) ->
    meta(body, Handle).


%% @doc Get a specific metadata
-spec meta(nksip_sipmsg:field(), nksip:request()|nksip:handle()) ->
    {ok, term()} | {error, term()}.

meta(Field, #sipmsg{class={req, _}}=Req) -> 
    {ok, nksip_sipmsg:meta(Field, Req)};
meta(Field, Handle) ->
    nksip_sipmsg:remote_meta(Field, Handle).


%% @doc Get a group of specific metadata
-spec metas([nksip_sipmsg:field()], nksip:request()|nksip:handle()) ->
    {ok, [{nksip_sipmsg:field(), term()}]} | {error, term()}.

metas(Fields, #sipmsg{class={req, _}}=Req) when is_list(Fields) ->
    {ok, nksip_sipmsg:metas(Fields, Req)};
metas(Fields, Handle) when is_list(Fields) ->
    nksip_sipmsg:remote_metas(Fields, Handle).


%% @doc Gets values for a header in a request.
-spec header(string()|binary(), nksip:request()|nksip:handle()) -> 
    {ok, [binary()]} | {error, term()}.

header(Name, #sipmsg{class={req, _}}=Req) -> 
    {ok, nksip_sipmsg:header(Name, Req)};
header(Name, Handle) when is_binary(Handle) ->
    meta(nksip_lib:to_binary(Name), Handle).


%% @doc Sends a reply to a request. Must get the request's id before, and
%% be called outside of the callback function.
-spec reply(nksip:sipreply(), nksip:handle()) -> 
    ok | {error, term()}.

reply(SipReply, Handle) ->
    nksip_call:send_reply(Handle, SipReply).


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

