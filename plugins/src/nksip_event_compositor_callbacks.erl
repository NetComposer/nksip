%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_event_compositor_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_event_compositor.hrl").

-export([sip_event_compositor_store/2]).
-export([nks_sip_method/2]).

% @doc Called when a operation database must be done on the compositor database.
%% This default implementation uses the built-in memory database.
-spec sip_event_compositor_store(StoreOp, SrvId) ->
    [RegPublish] | ok | not_found when
        StoreOp :: {get, AOR, Tag} | {put, AOR, Tag, RegPublish, TTL} | 
                   {del, AOR, Tag} | del_all,
        SrvId :: nksip:srv_id(),
        AOR :: nksip:aor(),
        Tag :: binary(),
        RegPublish :: nksip_event_compositor:reg_publish(),
        TTL :: integer().

sip_event_compositor_store(Op, SrvId) ->
    case Op of
        {get, AOR, Tag} ->
            nklib_store:get({nksip_event_compositor, SrvId, AOR, Tag}, not_found);
        {put, AOR, Tag, Record, TTL} -> 
            nklib_store:put({nksip_event_compositor, SrvId, AOR, Tag}, Record, [{ttl, TTL}]);
        {del, AOR, Tag} ->
            nklib_store:del({nksip_event_compositor, SrvId, AOR, Tag});
        del_all ->
            FoldFun = fun(Key, _Value, Acc) ->
                case Key of
                    {nksip_event_compositor, SrvId, AOR, Tag} -> 
                        nklib_store:del({nksip_event_compositor, SrvId, AOR, Tag});
                    _ -> 
                        Acc
                end
            end,
            nklib_store:fold(FoldFun, none)
    end.



%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%


%% @private This plugin callback is called when a call to one of the method specific
%% application-level Service callbacks is needed.
-spec nks_sip_method(nksip_call:trans(), nksip_call:call()) ->
    {reply, nksip:sipreply()} | noreply.


nks_sip_method(#trans{method='PUBLISH', request=Req}, #call{srv_id=SrvId}) ->
    Module = SrvId:callback(),
    case erlang:function_exported(Module, sip_publish, 2) of
        true ->
            continue;
        false ->
            {reply, nksip_event_compositor:request(Req)}
    end;
nks_sip_method(_Trans, _Call) ->
    continue.


