%% -------------------------------------------------------------------
%%
%% tests_util: Utilities for the tests
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

-module(tests_util).

-export([start_nksip/0, empty/0, wait/2, log/0, log/1]).

-define(LOG_LEVEL, warning).    % Chage to info or notice to debug
-define(WAIT_TIMEOUT, 10000).

start_nksip() ->
    nksip_app:start(),
    log().

empty() ->
    empty([]).

empty(Acc) -> 
    receive T -> empty([T|Acc]) after 0 -> Acc end.

wait(Ref, []) ->
    receive
        {Ref, Term} -> {error, {unexpected_term, Term, []}}
    after 0 ->
        ok
    end;
wait(Ref, List) ->
    receive 
        {Ref, Term} -> 
            % io:format("-------RECEIVED ~p\n", [Term]),
            case lists:member(Term, List) of
                true -> wait(Ref, List -- [Term]);
                false -> {error, {unexpected_term, Term, List}}
            end
    after   
        ?WAIT_TIMEOUT ->
            % io:format("------- WAIT TIMEOUT ~w\n", [List]),
            {error, {wait_timeout, List}}
    end.


log() ->
    log(?LOG_LEVEL).

log(Level) -> 
    lager:set_loglevel(lager_console_backend, Level).


