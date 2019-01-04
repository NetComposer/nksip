%% -------------------------------------------------------------------
%%
%% auth_test: Authentication Tests
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

-module(auth_test_server2).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-include_lib("nkserver/include/nkserver_module.hrl").


-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5]).


sip_get_user_pass(User, _Realm, _Req, _Call) ->
    % Password for user "client1", any realm, is "1234"
    % For user "client2", any realm, is "4321"
    case User of
        <<"auth_test_client1">> -> "1234";
        <<"auth_test_client2">> -> "4321";
        _ -> false
    end.


% Authorization is only used for "auth" suite
sip_authorize(Auth, _Req, _Call) ->
    IsDialog = lists:member(dialog, Auth),
    IsRegister = lists:member(register, Auth),
    case IsDialog orelse IsRegister of
        true ->
            ok;
        false ->
            BinId = nklib_util:to_binary(?MODULE) ,
            case nklib_util:get_value({digest, BinId}, Auth) of
                true -> ok;
                false -> forbidden;
                undefined -> {proxy_authenticate, BinId}
            end
    end.


sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    {proxy, ruri, [record_route]}.

