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

-export([init/1, route/5, invite/3]).

-define(PROXY_URI, "<sip:127.0.0.1:5061;transport=tcp>").

 
%% All callback functions are "inline"

%% @doc SipApp initialization
init([_AppId]) ->
    {ok, {}}.


%% @doc Request routing callback
route(_, <<"stateless">>, _, _, _) ->
    {process, [stateless]};

route(_, <<"stateful">>, _, _, _) ->
    process;

route(_, <<"proxy_stateful">>, _, _, _) ->
    {proxy, ?PROXY_URI};
        
route(_, <<"proxy_stateless">>, _, _, _) ->
    {proxy, ?PROXY_URI, [stateless]};

route(_Request, _Scheme, _User, _Domain, _From) ->
    process.

%% @doc Answer the call with the same SDP body
invite(Req, _Meta, _From) ->
    {ok, [], nksip_sipmsg:field(Req, body)}.

