%% -------------------------------------------------------------------
%%
%% ipv6_test: IPv6 Tests and RFC5118 Torture Tests
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

-module(ipv6_test_server1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([package_srv_init/2, sip_route/5]).


package_srv_init(_Package, State) ->
    ok = nkserver:put(?MODULE, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, _Req, _Call) ->
    Opts = [
        {insert, "x-nk-id", "ipv6_test_server1"},
        {route, "<sip:[::1]:5061;lr;transport=tcp>"}
    ],
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            process;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable};
                UriList -> {proxy_stateless, UriList, Opts}
            end;
        _ ->
            {proxy_stateless, ruri, Opts}
    end.
