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


-export([app_id/1, app_name/1, method/1, body/1, call_id/1, dialog_id/1]).
-export([meta/2, metas/2, header/2, headers/2]).
-export([is_local_route/1, reply/2]).
-export_type([req/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type req() :: {user_req, nksip_call:trans(), nksip_call:call()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets internal app's id
-spec app_id(req()) -> 
    nksip:app_id().

app_id({user_req, _, #call{app_id=AppId}}) -> 
    AppId.


%% @doc Gets app's name
-spec app_name(req()) -> 
    term().

app_name(UserReq) -> 
    (app_id(UserReq)):name().


%% @doc Gets the method of the request
-spec method(req()) ->
    nksip:method().

method(UserReq) -> 
    meta(method, UserReq).


%% @doc Gets the body of the request
-spec body(req()) ->
    nksip:body().

body(UserReq) -> 
    meta(body, UserReq).


%% @doc Gets the calls's id of a request id
-spec call_id(req()) ->
    nksip:call_id().

call_id({user_req, _, #call{call_id=CallId}}) ->
    CallId.


%% @doc Gets the dialog's id of the request
-spec dialog_id(req()) ->
    nksip_dialog:id().

dialog_id(UserReq) -> 
    meta(dialog_id, UserReq).


%% @doc Get a specific metadata (see {@link field()}) from the request
-spec meta(nksip_sipmsg:field(), req()) ->
    term().

meta(Field, {user_req, #trans{request=Req}, _Call}) -> 
    nksip_sipmsg:meta(Field, Req).


%% @doc Get a specific set of metadatas (see {@link field()}) from the request
-spec metas([nksip_sipmsg:field()], req()) ->
    [{nksip_sipmsg:field(), term()}].

metas(Fields, {user_req, #trans{request=Req}, _Call}) when is_list(Fields) ->
    [{Field, nksip_sipmsg:meta(Field, Req)} || Field <- Fields].


%% @doc Gets values for a header in a request.
-spec header(string()|binary(), req()) -> 
    [binary()].

header(Name, {user_req, #trans{request=Req}, _Call}) -> 
    nksip_sipmsg:header(Name, Req).


%% @doc Gets values for a set of headers in a request.
-spec headers([string()|binary()], req()) -> 
    [{string()|binary(), binary()}].

headers(Names, {user_req, #trans{request=Req}, _Call}) when is_list(Names) ->
    [{Name, nksip_sipmsg:header(Name, Req)} || Name <- Names].


%% @doc Sends a reply to a request.
-spec reply(nksip:sipreply(), nksip:id()|nksip:request()) -> 
    ok | {error, Error}
    when Error :: invalid_call | unknown_call | sipapp_not_found.

reply(SipReply, <<"R_", _/binary>>=Id) ->
    nksip_call:send_reply(Id, SipReply);

reply(#sipmsg{class={req, _}}=Req, SipReply) ->
    reply(nksip_sipmsg:get_id(Req), SipReply).


%% @doc Checks if this request would be sent to a local address in case of beeing proxied.
%% It will return `true' if the first <i>Route</i> header points to a local address
%% or the <i>Request-Uri</i> if there is no <i>Route</i> headers.
-spec is_local_route(nksip:id()|nksip:request()) -> 
    boolean().

is_local_route(#sipmsg{class={req, _}, app_id=AppId, ruri=RUri, routes=Routes}) ->
    case Routes of
        [] -> nksip_transport:is_local(AppId, RUri);
        [Route|_] -> nksip_transport:is_local(AppId, Route)
    end.

