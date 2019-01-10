%% -------------------------------------------------------------------
%%
%% websocket_test: Websocket Test Suite
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

-module(websocket_test_server).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([srv_init/2, sip_route/5]).


srv_init(_Package, _State) ->
    ok =  nkserver:put(?MODULE, domains, [<<"localhost">>, <<"127.0.0.1">>, <<"nksip">>]),
    continue.


sip_route(_Scheme, User, Domain, Req, _Call) ->
    Opts = [record_route, {insert, "x-nk-server", "websocket_test_server"}],
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            process;
        true when Domain =:= <<"nksip">> ->
            {ok, RUri} = nksip_request:get_meta(ruri, Req),
            case nksip_gruu:registrar_find(?MODULE, RUri) of
                [] ->
                    {reply, temporarily_unavailable};
                UriList ->
                    {proxy, UriList, Opts}
            end;
        _ ->
            {proxy, ruri, Opts}
    end.


