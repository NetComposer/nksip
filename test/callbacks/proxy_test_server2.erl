%% -------------------------------------------------------------------
%%
%% proxy_test: Stateless and Stateful Proxy Tests
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

-module(proxy_test_server2).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([srv_init/2, sip_route/5]).


srv_init(#{config:=#{test_type:=Test}}, State) ->
    Domains = [<<"nksip2">>, <<"127.0.0.1">>, <<"[::1]">>],
    ok = nkserver:put(?MODULE, domains, Domains),
    ok = nkserver:put(?MODULE, test_type, Test),
    {ok, State}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    Test = nkserver:get(?MODULE, test_type),
    Opts = [
        {insert, "x-nk-id", ?MODULE},
        case nksip_request:header(<<"x-nk-rr">>, Req) of
            {ok, [<<"true">>]} -> record_route;
            {ok, _} -> ignore
        end
    ],
    Proxy = case Test of
        stateful -> proxy;
        stateless -> proxy_stateless
    end,
    Domains = nkserver:get(?MODULE, domains),
    case lists:member(Domain, Domains) of
        true when User == <<>>, Test==stateless ->
            process_stateless;
        true when User == <<>>, Test==stateful ->
            process;
        true when User =:= <<"client2_op">>, Domain =:= <<"nksip">> ->
            UriList = nksip_registrar:find(?MODULE, sip, <<"proxy_test_client2">>, Domain),
            {ok, Body} = nksip_request:body(Req),
            ServerOpts = binary_to_term(base64:decode(Body)),
            {Proxy, UriList, ServerOpts++Opts};
        true when Domain =:= <<"nksip">>; Domain =:= <<"nksip2">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] ->
                    % ?P("FIND ~p: []", [{?MODULE, Scheme, User, Domain}]),
                    {reply, temporarily_unavailable};
                UriList ->
                    {Proxy, UriList, Opts}
            end;
        true ->
            {Proxy, ruri, Opts};
        false when Domain =:= <<"nksip">> ->
            {Proxy, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]};
        false when Domain =:= <<"nksip2">> ->
            {Proxy, ruri, [{route, "<sips:127.0.0.1:5081;lr>"}|Opts]};
        false ->
            {Proxy, ruri, Opts}
    end.
