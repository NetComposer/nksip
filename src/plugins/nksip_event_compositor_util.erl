%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP Event State Compositor Plugin Utilities (only for internal storage)
-module(nksip_event_compositor_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip_event_compositor.hrl").

%-compile([export_all]).
-export([get_all/0, clear/0, print_all/0]).


%% ===================================================================
%% Utilities available only using internal store
%% ===================================================================


% @private Get all current registrations. Use it with care.
-spec get_all() ->
    [{nkservice:id(), nksip:aor(), binary(), #reg_publish{}}].

get_all() ->
    [
        {SrvId, AOR, Tag, nklib_store:get({nksip_event_compositor, SrvId, AOR, Tag}, [])}
        || {SrvId, AOR, Tag} <- all()
    ].


%% @private
print_all() ->
    Now = nklib_util:timestamp(),
    Print = fun({SrvId, {Scheme, User, Domain}, Tag, Reg}) ->
        #reg_publish{expires=Expire, data=Data} = Reg,
        io:format("\n --- ~p --- ~p:~s@~s, ~s (~p) ---\n", 
                  [SrvId:name(), Scheme, User, Domain, Tag, Expire-Now]),
        io:format("~p\n", [Data])
    end,
    lists:foreach(Print, get_all()),
    io:format("\n\n").


%% @private Clear all stored records for all Services, only with buil-in database
%% Returns the number of deleted items.
-spec clear() -> 
    integer().

clear() ->
    Fun = fun(SrvId, AOR, Tag, _Val, Acc) ->
        nklib_store:del({nksip_event_compositor, SrvId, AOR, Tag}),
        Acc+1
    end,
    fold(Fun, 0).


%% @private
all() -> 
    fold(fun(SrvId, AOR, Tag, _Value, Acc) -> [{SrvId, AOR, Tag}|Acc] end, []).


%% @private
fold(Fun, Acc0) when is_function(Fun, 5) ->
    FoldFun = fun(Key, Value, Acc) ->
        case Key of
            {nksip_event_compositor, SrvId, AOR, Tag} -> 
                Fun(SrvId, AOR, Tag, Value, Acc);
            _ -> 
                Acc
        end
    end,
    nklib_store:fold(FoldFun, Acc0).


