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
-export([get_ref/0, save_ref/1, update_ref/3, send_ref/2, dialog_update/2, session_update/2]).

-define(LOG_LEVEL, warning).    % debug, info, notice, warning, error

-ifdef(is_travis).
-define(WAIT_TIMEOUT, 100000).
-else.
-define(WAIT_TIMEOUT, 10000).
-endif.

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
                true -> 
                    wait(Ref, List -- [Term]);
                false -> 
                    lager:warning("Timer Test Wait unexpected term: ~p", [Term]),
                    wait(Ref, List)
                    % {error, {unexpected_term, Term, List}}
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


get_ref() ->
    Ref = make_ref(),
    Hd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
    {Ref, Hd}.


save_ref(Req) ->
    case nksip_request:header(<<"x-nk-reply">>, Req) of
        {ok, [RepBin]} -> 
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            {ok, AppId} = nksip_request:app_id(Req),
            {ok, Dialogs} = nksip:get(AppId, dialogs, []),
            {ok, DialogId} = nksip_dialog:get_handle(Req),
            ok = nksip:put(AppId, dialogs, [{DialogId, Ref, Pid}|Dialogs]);
        {ok, _} ->
            ok
    end.


update_ref(AppId, Ref, DialogId) ->
    {ok, Dialogs} = nksip:get(AppId, dialogs, []),
    ok = nksip:put(AppId, dialogs, [{DialogId, Ref, self()}|Dialogs]).


send_ref(Msg, Req) ->
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    {ok, AppId} = nksip_request:app_id(Req),
    {ok, Dialogs} = nksip:get(AppId, dialogs, []),
    case lists:keyfind(DialogId, 1, Dialogs) of
        {DialogId, Ref, Pid}=_D -> 
            % lager:warning("FOUND ~p, ~p", [AppId, D]),
            Pid ! {Ref, {AppId:name(), Msg}};
        false ->
            % lager:warning("NOT FOUND: ~p", [AppId]),
            ok
    end.

dialog_update(Update, Dialog) ->
    {ok, App} = nksip_dialog:app_name(Dialog),
    case nksip:get(App, dialogs, []) of
        {ok, Dialogs} ->
            {ok, DialogId} = nksip_dialog:get_handle(Dialog),
            case lists:keyfind(DialogId, 1, Dialogs) of
                {DialogId, Ref, Pid} ->
                    case Update of
                        start -> ok;
                        target_update -> Pid ! {Ref, {App, target_update}};
                        {invite_status, confirmed} -> Pid ! {Ref, {App, dialog_confirmed}};
                        {invite_status, {stop, Reason}} -> Pid ! {Ref, {App, {dialog_stop, Reason}}};
                        {invite_status, _} -> ok;
                        {invite_refresh, SDP} -> Pid ! {Ref, {App, {refresh, SDP}}};
                        invite_timeout -> Pid ! {Ref, {App, timeout}};
                        {subscription_status, Status, Subs} -> 
                            {ok, Handle} = nksip_subscription:get_handle(Subs),
                            Pid ! {Ref, {subs, Status, Handle}};
                        stop -> ok
                    end;
                false -> 
                    none
            end;
        _ ->
            %% Application has already stopped
            ok
    end.


session_update(Update, Dialog) ->
    {ok, App} = nksip_dialog:app_name(Dialog),
    {ok, Dialogs} = nksip:get(App, dialogs, []),
    {ok, DialogId} = nksip_dialog:get_handle(Dialog),
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            ok;
        {DialogId, Ref, Pid} ->
            case Update of
                {start, Local, Remote} ->
                    Pid ! {Ref, {App, sdp_start}},
                    {ok, Sessions} = nksip:get(App, sessions, []),
                    nksip:put(App, sessions, [{DialogId, Local, Remote}|Sessions]),
                    ok;
                {update, Local, Remote} ->
                    Pid ! {Ref, {App, sdp_update}},
                    {ok, Sessions} = nksip:get(App, sessions, []),
                    nksip:put(App, sessions, [{DialogId, Local, Remote}|Sessions]),
                    ok;
                stop ->
                    Pid ! {Ref, {App, sdp_stop}},
                    ok
            end
    end.
