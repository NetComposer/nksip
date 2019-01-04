
%% -------------------------------------------------------------------
%%
%% uas_test: Basic Test Suite
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

-module(uas_test_server1).

-export([package_srv_init/2, sip_route/5]).

-include_lib("nkserver/include/nkserver_module.hrl").

package_srv_init(#{id:=Id}, State) ->
    ok =  nkserver:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    % server1
    Opts = [record_route, {insert, "x-nk-server", ?MODULE}],
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            case nksip_request:header(<<"x-nk-op">>, Req) of
                {ok, [<<"reply-request">>]} ->
                    Body = base64:encode(term_to_binary(Req)),
                    {reply, {ok, [{body, Body}, contact]}};
                {ok, [<<"reply-stateless">>]} ->
                    {reply_stateless, ok};
                {ok, [<<"reply-stateful">>]} ->
                    {reply, ok};
                {ok, [<<"reply-invalid">>]} ->
                    {reply, 'INVALID'};
                {ok, [<<"force-error">>]} ->
                    error(test_error);
                {ok, _} ->
                    process
            end;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable};
                UriList -> {reply, {proxy, UriList, Opts}}
            end;
        _ ->
            {proxy, ruri, Opts}
    end.



