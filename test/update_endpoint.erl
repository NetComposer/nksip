%% -------------------------------------------------------------------
%%
%% update_endpoint: Endpoint callback module for update_test
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

-module(update_endpoint).
-behaviour(nksip_sipapp).

-export([get_sessions/2]).
-export([init/1, invite/4, ack/4, update/4]).
-export([dialog_update/3, session_update/3, handle_call/3]).

-include("../include/nksip.hrl").

get_sessions(AppId, DialogId) ->
    nksip:call(AppId, {get_sessions, DialogId}).


%%%%%%%%%%%%%%%%%%%%%%%  NkSipCore CallBack %%%%%%%%%%%%%%%%%%%%%


-record(state, {
    id,
    dialogs = [],
    sessions = []
}).


init([Id]) ->
    {ok, #state{id=Id}}.


% INVITE for basic, uac, uas, invite and proxy_test
% Gets the operation from Nk-Op header, time to sleep from Nk-Sleep,
% if to send provisional response from Nk-Prov
% Copies all received Nk-Id headers adding our own Id
invite(ReqId, Meta, From, #state{id=Id, dialogs=Dialogs}=State) ->
    AppId = {update, Id},
    DialogId = nksip_lib:get_value(dialog_id, Meta),
    Op = case nksip_request:header(AppId, ReqId, <<"Nk-Op">>) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    case nksip_request:header(AppId, ReqId, <<"Nk-Reply">>) of
        [RepBin] ->
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            State1 = State#state{dialogs=[{DialogId, Ref, Pid}|Dialogs]};
        _ ->
            State1 = State
    end,
    proc_lib:spawn(
        fun() ->
            case Op of
                <<"basic">> ->
                    Body = nksip_lib:get_value(body, Meta),
                    SDP1 = nksip_sdp:increment(Body),
                    ok = nksip_request:reply(AppId, ReqId, 
                                                {rel_ringing, SDP1}),
                    timer:sleep(500),
                    nksip:reply(From, ok);
                <<"pending1">> ->
                    ok = nksip_request:reply(AppId, ReqId, ringing),
                    timer:sleep(100),
                    nksip:reply(From, ok);
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State1}.


ack(ReqId, Meta, _From, #state{id=Id, dialogs=Dialogs}=State) ->
    AppId = {update, Id},
    DialogId = nksip_lib:get_value(dialog_id, Meta),
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            case nksip_request:header(AppId, ReqId, <<"Nk-Reply">>) of
                [RepBin] -> 
                    {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
                    Pid ! {Ref, {Id, ack}};
                _ ->
                    ok
            end;
        {DialogId, Ref, Pid} -> 
            Pid ! {Ref, {Id, ack}}
    end,
    {reply, ok, State}.


update(_ReqId, Meta, _From, #state{id=Id, dialogs=Dialogs}=State) ->
    DialogId = nksip_lib:get_value(dialog_id, Meta),
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> ok;
        {DialogId, Ref, Pid} -> Pid ! {Ref, {Id, update}}
    end,
    Body = case nksip_lib:get_value(body, Meta) of
        #sdp{} = SDP -> nksip_sdp:increment(SDP);
        _ -> <<>>
    end,        
    {reply, {ok, [], Body}, State}.


dialog_update(DialogId, Update, State) ->
    #state{id=Id, dialogs=Dialogs} = State,
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            none;
        {DialogId, Ref, Pid} ->
            case Update of
                start -> ok;
                {invite_status, confirmed} -> Pid ! {Ref, {Id, dialog_confirmed}};
                {invite_status, {stop, Reason}} -> Pid ! {Ref, {Id, {dialog_stop, Reason}}};
                {invite_status, _} -> ok;
                target_update -> Pid ! {Ref, {Id, target_update}};
                stop -> ok
            end
    end,
    {noreply, State}.


session_update(DialogId, Update, State) ->
    #state{id=Id, dialogs=Dialogs, sessions=Sessions} = State,
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            {noreply, State};
        {DialogId, Ref, Pid} ->
            case Update of
                {start, Local, Remote} ->
                    Pid ! {Ref, {Id, sdp_start}},
                    Sessions1 = [{DialogId, Local, Remote}|Sessions],
                    {noreply, State#state{sessions=Sessions1}};
                {update, Local, Remote} ->
                    Pid ! {Ref, {Id, sdp_update}},
                    Sessions1 = [{DialogId, Local, Remote}|Sessions],
                    {noreply, State#state{sessions=Sessions1}};
                stop ->
                    Pid ! {Ref, {Id, sdp_stop}},
                    {noreply, State}
            end
    end.


handle_call({get_sessions, DialogId}, _From, #state{sessions=Sessions}=State) ->
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {reply, {Local, Remote}, State};
        false -> {reply, not_found, State}
    end.

