%% -------------------------------------------------------------------
%%
%% sipapp_inline_server: Inline Test Suite Server
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

-module(sipapp_inline_server).
-behaviour(nksip_sipapp).

-export([start/2, stop/1]).
-export([init/1, get_user_pass/2, authorize/3, route/5]).

-include("../include/nksip.hrl").


start(AppId, Opts) ->
    nksip:start(AppId, ?MODULE, [], Opts).

stop(AppId) ->
    nksip:stop(AppId).



%%%%%%%%% Inline functions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
    {ok, []}.


get_user_pass(<<"client1">>, <<"nksip">>) -> <<"1234">>;
get_user_pass(<<"client2">>, <<"nksip">>) -> <<"4321">>;
get_user_pass(_, _) -> false.

authorize(Req, Auth, From) ->
    Reply = case nksip_sipmsg:header(Req, <<"Nksip-Auth">>) of
        [<<"true">>] ->
            case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
                true ->
                    true;
                false ->
                    case nksip_lib:get_value({digest, <<"nksip">>}, Auth) of
                        true -> true;
                        false -> false;
                        undefined -> {proxy_authenticate, <<"nksip">>}
                    end
            end;
        _ ->
            ok
    end,
    % Test asynchronus response in inline
    spawn(fun() -> nksip:reply(From, Reply) end),
    async.


route(Req, Scheme, User, Domain, _From) ->
    {inline, Id} = AppId = nksip_sipmsg:field(Req, app_id),
    send_reply(Req, route),
    Opts = [
        record_route,
        {headers, [{"Nk-Id", Id}]}
    ],
    case lists:member(Domain, [<<"127.0.0.1">>, <<"nksip">>]) of
        true when User =:= <<>> ->
            process;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> temporarily_unavailable;
                UriList -> {proxy, UriList, Opts}
            end;
        true ->
            % It is for 127.0.0.1 domain, route
            {proxy, ruri, Opts};
        false ->
            {proxy, ruri, Opts}
    end.



%%%%%%%%%%% Util %%%%%%%%%%%%%%%%%%%%

send_reply(Elem, Msg) ->
    AppId = case Elem of
        #sipmsg{} -> nksip_sipmsg:field(Elem, app_id);
        #dialog{} -> nksip_dialog:field(Elem, app_id)
    end,
    case nksip_config:get(inline_test) of
        {Ref, Pid} -> Pid ! {Ref, {AppId, Msg}};
        _ -> ok
    end.


