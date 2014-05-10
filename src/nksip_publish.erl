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

%% @doc NkSIP Event State Compositor
%%
%% This module implements a Event State Compositor, according to RFC3903
%% By default, it uses the RAM-only built-in store, but any SipApp can implement 
%% {@link nksip_sipapp:publisher_store/3} callback to use any external database.
%%

-module(nksip_publish).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([request/1, find/3]).
-export_type([reg_publish/0]).

-define(TIMEOUT, 15000).


%% ===================================================================
%% Types and records
%% ===================================================================


-type reg_publish() :: #reg_publish{}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Finds a stored published information
-spec find(nksip:app_id()|term(), nksip:aor(), binary()) ->
    {ok, reg_publish()} | {error, term()}.

find(App, AOR, Tag) ->
    {ok, AppId} = nksip:find_app(App),
    case callback(AppId, {get, AOR, Tag}) of
        #reg_publish{} = Reg -> {ok, Reg};
        Other -> {error, Other}
    end.

%% @doc Processes a PUBLISH request according to RFC3903
-spec request(nksip:request()) ->
    nksip:sipreply().

request(#sipmsg{class={req, 'PUBLISH'}}=Req) ->
    #sipmsg{app_id=AppId, ruri=RUri, expires=Expires, body=Body} = Req,
    Expires1 = case is_integer(Expires) andalso Expires>0 of
        true -> Expires;
        _ -> ?DEFAULT_PUBLISH_EXPIRES
    end,
    AOR = {RUri#uri.scheme, RUri#uri.user, RUri#uri.domain},
    case nksip_sipmsg:header(<<"sip-etag">>, Req) of
        [] when Body == <<>> ->
            invalid_request;
        [] ->
            store(AppId, AOR, Expires1, make_reg(Body));
        [Tag] ->
            case find(AppId, AOR, Tag) of
                {ok, _Reg} when Expires==0 -> remove(AppId, AOR, Tag);
                {ok, Reg} when Body == <<>> -> update(AppId, AOR, Tag, Expires1, Reg);
                {ok, _} -> update(AppId, AOR, Tag, Expires1, make_reg(Body));
                _ -> conditional_request_failed
            end;
        _ ->
            invalid_request
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
store(AppId, AOR, Expires, Reg) ->
    Tag = nksip_lib:uid(),
    update(AppId, AOR, Tag, Expires, Reg).


%% @private
remove(AppId, AOR, Tag) ->
    case callback(AppId, {del, AOR, Tag}) of
        ok -> reply(Tag, 0);
        _ -> internal_error
    end.


%% @private
update(AppId, AOR, Tag, Expires, Reg) ->
    case callback(AppId, {put, AOR, Tag, Reg, Expires}) of
        ok -> reply(Tag, Expires);
        _ -> internal_error
    end.


%% @private
make_reg(Body) ->
    #reg_publish{data=Body}.


%% @private
reply(Tag, Expires) ->
    {ok, [{sip_etag, Tag}, {expires, Expires}]}.


%% @private 
-spec callback(nksip:app_id(), term()) ->
    term() | error.

callback(AppId, Op) -> 
    case nksip_callbacks:app_call(sip_publish_store, [Op, AppId], AppId) of
        {ok, Reply} -> Reply;
        _ -> error
    end.





