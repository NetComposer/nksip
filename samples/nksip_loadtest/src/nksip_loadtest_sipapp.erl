%% -------------------------------------------------------------------
%%
%% Sipapp callback for high load tests
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

%% @doc SipApp callback module

-module(nksip_loadtest_sipapp).
-behaviour(nksip_sipapp).

-export([init/1, route/6, invite/3]).

-define(PROXY_URI, "sip:127.0.0.1:5061;transport=tcp").


-record(state, {
	app_id
}).


%% @doc SipApp initialization
init([AppId]) ->
    {ok, #state{app_id=AppId}}.


%% @doc Request routing callback
route(_, <<"stateless">>, _, _, _, SD) ->
    {reply, {process, [stateless]}, SD};

route(_, <<"stateful">>, _, _, _, SD) ->
    {reply, process, SD};

route(_, <<"proxy_stateful">>, _, _, _, SD) ->
    {reply, {proxy, ?PROXY_URI}, SD};
        
route(_, <<"proxy_stateless">>, _, _, _, SD) ->
    {reply, {proxy, ?PROXY_URI, [stateless]}, SD};

route(_Scheme, _User, _Domain, _Request, _From, SD) ->
    {reply, process, SD}.

%% @doc Answer the call with the same SDP body
invite(ReqId, _From, #state{app_id=AppId}=SD) ->
	Body = nksip_request:body(AppId, ReqId),
    {reply, {ok, [], Body}, SD}.

