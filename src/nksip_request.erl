%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([get_handle/1, srv_id/1, method/1, body/1, call_id/1]).
-export([get_meta/2, get_metas/2, header/2, reply/2, is_local_ruri/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%%----------------------------------------------------------------
%% @doc Gets request's id
%% @end
%%----------------------------------------------------------------
-spec get_handle( Request ) -> Result when
        Request     :: nksip:request()
            | nksip:handle(),
        Result      ::  {ok, nksip:handle()}.

get_handle(Term) ->
    case nksip_sipmsg:get_handle(Term) of
        <<"R_", _/binary>> = Handle ->
            {ok, Handle};
        _ ->
            lager:error("NKLOG IVALID HANDLE ~p", [Term]),
            error(invalid_request)
    end.

%%----------------------------------------------------------------
%% @doc Gets internal app's id
%% @end
%%----------------------------------------------------------------
-spec srv_id( Request ) -> Result when
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, nkserver:id()}.

srv_id(#sipmsg{class={req, _}, srv_id=SrvId}) ->
    {ok, SrvId};
    
srv_id(Handle) ->
    case nksip_sipmsg:parse_handle(Handle) of
        {req, SrvId, _Id, _CallId} ->
            {ok, SrvId};
        _ ->
            error(invalid_request)
    end.



%%----------------------------------------------------------------
%% @doc Gets the calls's id of a request id
%% @end
%%----------------------------------------------------------------
-spec call_id( Request ) -> Result when
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, nksip:call_id()}.

call_id(#sipmsg{class={req, _}, call_id=CallId}) ->
    {ok, CallId};
call_id(Handle) ->
    case nksip_sipmsg:parse_handle(Handle) of
        {req, _PkgId, _Id, CallId} ->
            {ok, CallId};
        _ ->
            error(invalid_request)
    end.


%%----------------------------------------------------------------
%% @doc Gets the method of the request
%% @end
%%----------------------------------------------------------------
-spec method( Request ) -> Result when
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, nksip:method()} 
            | {error, term()}.

method(#sipmsg{class={req, Method}}) ->
    {ok, Method};
method(Handle) ->
    get_meta(method, Handle).

%%----------------------------------------------------------------
%% @doc Gets the body of the request
%% @end
%%----------------------------------------------------------------
-spec body( Request ) -> Result when
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, nksip:body()} 
            | {error, term()}.

body(#sipmsg{class={req, _}, body=Body}) ->
    {ok, Body};
body(Handle) ->
    get_meta(body, Handle).


%%----------------------------------------------------------------
%% @doc Get a specific metadata
%% @end
%%----------------------------------------------------------------
-spec get_meta( Field, Request ) -> Result when
        Field       :: nksip_sipmsg:field(),
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, term()} | {error, term()}.

get_meta(Field, #sipmsg{class={req, _}}=Req) ->
    {ok, nksip_sipmsg:get_meta(Field, Req)};
get_meta(Field, Handle) ->
    nksip_sipmsg:remote_meta(Field, Handle).


%%----------------------------------------------------------------
%% @doc Get a group of specific metadata
%% @end
%%----------------------------------------------------------------
-spec get_metas( FieldList, Request ) -> Result when
        FieldList   :: [ nksip_sipmsg:field() ],
        Request     :: nksip:request()
            | nksip:handle(),
        Result      :: {ok, [ {nksip_sipmsg:field(), term()} ]}
            | {error, term()}.

get_metas(Fields, #sipmsg{class={req, _}}=Req) when is_list(Fields) ->
    {ok, nksip_sipmsg:get_metas(Fields, Req)};
get_metas(Fields, Handle) when is_list(Fields) ->
    nksip_sipmsg:remote_metas(Fields, Handle).


%%----------------------------------------------------------------
%% @doc Gets values for a header in a request.
%% @end
%%----------------------------------------------------------------
-spec header( Name, Request ) -> Result when 
        Name    :: string()|binary(),
        Request :: nksip:request()
            | nksip:handle(),
        Result  :: {ok, [binary()]} 
            | {error, term()}.

header(Name, #sipmsg{class={req, _}}=Req) ->
    {ok, nksip_sipmsg:header(Name, Req)};
header(Name, Handle) when is_binary(Handle) ->
    get_meta(nklib_util:to_binary(Name), Handle).


%%----------------------------------------------------------------
%% @doc Sends a reply to a request. 
%%
%% NOTE: Must get the request's id before, and
%% be called outside of the callback function.
%% @end
%%----------------------------------------------------------------
-spec reply( Reply, Handle ) -> Result when 
        Reply   :: nksip:sipreply(), 
        Handle  :: nksip:handle(), 
        Result  ::  ok 
            | {error, term()}.

reply(SipReply, Handle) ->
    {req, SrvId, ReqId, CallId} = nksip_sipmsg:parse_handle(Handle),
    nksip_call:send_reply(SrvId, CallId, ReqId, SipReply).


%%----------------------------------------------------------------
%% @doc Checks if this R-URI of this request points to a local address
%% @end
%%----------------------------------------------------------------
-spec is_local_ruri( Request ) -> Result when 
        Request :: nksip:request(),
        Result  :: boolean().

is_local_ruri(#sipmsg{class={req, _}, srv_id=SrvId, ruri=RUri}) ->
    nksip_util:is_local(SrvId, RUri).

