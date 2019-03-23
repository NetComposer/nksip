%% -------------------------------------------------------------------
%%
%% outbound_test: Path (RFC5626) Tests
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

-module(outbound_test_registrar).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_route/5]).

sip_route(Scheme, User, Domain, _Req, _Call) ->
    % Registrar is the registrar proxy for "nksip" domain
    case Domain of
        <<"nksip">> when User == <<>> ->
            process;
        <<"127.0.0.1">> when User == <<>> ->
            process;
        <<"nksip">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable};
                UriList -> {proxy, UriList}
            end;
        _ ->
            {proxy, ruri, []}
    end.
