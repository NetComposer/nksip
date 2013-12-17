%% -------------------------------------------------------------------
%%
%% path_server: Server Callback module for path test
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

-module(path_server).
-behaviour(nksip_sipapp).

-export([start/2, stop/1]).
-export([init/1, route/6]).

-include("../include/nksip.hrl").


start(Id, Opts) ->
    nksip:start(Id, ?MODULE, Id, Opts).

stop(Id) ->
    nksip:stop(Id).



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks %%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    id
}).

init(Id) ->
   {ok, #state{id=Id}}.


% P1 is UA1's outbound proxy.
% It sends everything to P2, inserting Path header
route(_, _, _, Domain, _, #state{id={path, p1}}=State) ->
    OptsA = [{headers, [{"Nk-Id", "p1"}]}],
    OptsB = [{route, "<sip:127.0.0.1:5071;lr;transport=tls>"}, make_path|OptsA],
    case Domain of 
        <<"nksip">> -> {reply, {proxy, ruri, OptsB}, State};
        _ -> {reply, {proxy, ruri, OptsA}, State}
    end;

% P2 is an intermediate proxy.
% It sends everything to P3
% It sends everything to P2, inserting Path header
route(_, _, _, Domain, _, #state{id={path, p2}}=State) ->
    OptsA = [{headers, [{"Nk-Id", "p2"}]}],
    OptsB = [{route, "<sip:127.0.0.1:5080;lr;transport=tcp>"}|OptsA],
    case Domain of 
        <<"nksip">> -> {reply, {proxy, ruri, OptsB}, State};
        _ -> {reply, {proxy, ruri, OptsA}, State}
    end;


% P3 is the SBC. 
% It sends everything to the registrar, inserting Path header
route(_, _, _, Domain, _, #state{id={path, p3}}=State) ->
    OptsA = [{headers, [{"Nk-Id", "p3"}]}],
    OptsB = [{route, "<sip:127.0.0.1:5090;lr>"}, make_path|OptsA],
    case Domain of 
        <<"nksip">> -> {reply, {proxy, ruri, OptsB}, State};
        _ -> {reply, {proxy, ruri, OptsA}, State}
    end;


% Registrar is the registrar proxy for "nksip" domain
route(_ReqId, Scheme, User, Domain, _From, #state{id={path, registrar}}=State) ->
    case Domain of
        <<"nksip">> when User == <<>> ->
            {reply, process, State};
        <<"nksip">> ->
            case nksip_registrar:find({path, registrar}, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList}, State}
            end;
        _ ->
            {reply, {proxy, ruri, []}, State}
    end.

