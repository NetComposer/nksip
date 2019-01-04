%% -------------------------------------------------------------------
%%
%% fork_test: Forking Proxy Suite Test
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

-module(fork_test_server1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([package_srv_init/2, sip_route/5]).

package_srv_init(_Package, State) ->
    ok = nkserver:put(?MODULE, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(_Scheme, _User, Domain, _Req, _Call) ->
    % Route for the rest of servers in fork test
    % Adds x-nk-id header. serverA is stateless, rest are stateful
    % Always Record-Route
    % If domain is "nksip" routes to fork_test_serverR
    Opts = [record_route, {insert, "x-nk-id", ?MODULE}],
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when Domain==<<"nksip">> ->
            {proxy_stateless, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]};
        true ->
            {proxy_stateless, ruri, Opts};
        false ->
            {reply, forbidden}
    end.

