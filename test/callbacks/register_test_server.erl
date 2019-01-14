%% -------------------------------------------------------------------
%%
%% register_test: Register Test Suite
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

-module(register_test_server).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").
-include_lib("nksip/include/nksip_registrar.hrl").
-include_lib("nkserver/include/nkserver_module.hrl").


-export([service_init/2, sip_route/5]).

service_init(_Package, State) ->
    ok =  nkserver:put(?MODULE, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, _Req, _Call) ->
    Opts = [record_route, {insert, "x-nk-server", ?MODULE}],
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            process;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable};
                UriList -> {proxy, UriList, Opts}
            end;
        _ ->
            {proxy, ruri, Opts}
    end.
