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

-module(auth_test_client3).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_get_user_pass/4, sip_authorize/3]).
-export([sip_invite/2, sip_ack/2, sip_bye/2]).


sip_get_user_pass(User, Realm, _Req, _Call) ->
    case Realm of
        <<"auth_test_client1">> ->
            % A hash can be used instead of the plain password
            nksip_auth:make_ha1(User, "4321", "auth_test_client1");
        <<"auth_test_client2">> ->
            "1234";
        <<"auth_test_client3">> ->
            "abcd";
        _ ->
            false
    end.


% Authorization is only used for "auth" suite
sip_authorize(Auth, _Req, _Call) ->
    BinId = nklib_util:to_binary(?MODULE),
    case nklib_util:get_value({digest, BinId}, Auth) of
        true -> ok;                         % At least one user is authenticated
        false -> forbidden;                 % Failed authentication
        undefined -> {authenticate, BinId}  % No auth header
    end.



sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {reply, ok}.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.





