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

%% @doc NkSIP Event State Compositor Plgugin utilities
-module(nksip_event_compositor_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([store_get/3, store_put/5, store_del/3, store_del_all/1]).

-include("nksip.hrl").
-include("nksip_event_compositor.hrl").


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec store_get(nkserver:id(), nksip:aor(), binary()) ->
    {ok, #reg_publish{}} | not_found | {error, term()}.

store_get(SrvId, AOR, Tag) ->
    case callback(SrvId, {get, AOR, Tag}) of
        {ok, #reg_publish{} = Reg} ->
            {ok, Reg};
        {ok, not_found} ->
            not_found;
        {ok, Res} ->
            {error, {invalid_callback_response, Res}};
        error ->
            {error, invalid_callback}
    end.


%% @private
-spec store_put(nkserver:id(), nksip:aor(), integer(), integer(),
                #reg_publish{}|nksip:body()) ->
    nksip:sipreply().

store_put(SrvId, AOR, Tag, Expires, Reg) ->
    Reg1 = case is_record(Reg, reg_publish) of
        true ->
            Reg;
        false ->
            #reg_publish{data=Reg}
    end,
    Now = nklib_util:timestamp(),
    Reg2 = Reg1#reg_publish{expires=Now+Expires},
    case callback(SrvId, {put, AOR, Tag, Reg2, Expires}) of
        {ok, ok} ->
            reply(Tag, Expires);
        {ok, Resp} ->
            ?SIP_LOG(warning, "invalid callback response: ~p", [Resp]),
            {internal_error, "Callback Invalid Response"};
        error ->
            ?SIP_LOG(warning, "invalid callback response", []),
            {internal_error, "Callback Invalid Response"}
    end.


%% @private
-spec store_del(nkserver:id(), nksip:aor(), binary()) ->
    nksip:sipreply().

store_del(SrvId, AOR, Tag) ->
    case callback(SrvId, {del, AOR, Tag}) of
        {ok, ok} ->
            reply(Tag, 0);
        {ok, Resp} ->
            ?SIP_LOG(warning, "invalid callback response: ~p", [Resp]),
            {internal_error, "Callback Invalid Response"};
        error ->
            ?SIP_LOG(warning, "invalid callback response", []),
            {internal_error, "Callback Invalid Response"}
    end.




%% @private
-spec store_del_all(nkserver:id()) ->
    ok | {error, term()}.

store_del_all(SrvId) ->
    case callback(SrvId, del_all) of
        {ok, ok} ->
            ok;
        {ok, _Resp} ->
            {error, invalid_callback};
        error ->
            {error, invalid_callback}
    end.


%% @private
reply(Tag, Expires) ->
    {ok, [{sip_etag, Tag}, {expires, Expires}]}.


%% @private 
-spec callback(nkserver:id(), term()) ->
    term() | error.

callback(SrvId, Op) ->
    nksip_util:user_callback(SrvId, sip_event_compositor_store, [Op, SrvId]).









