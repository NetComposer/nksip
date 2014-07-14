%% -------------------------------------------------------------------
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

%% @doc Call Management Module
%%
%% A new {@link nksip_call_srv} process is started for every different
%% Call-ID request or response, incoming or outcoming.
%% This module offers an interface to this process.

-module(nksip_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([app_id/1, call_id/1]).
-export([send/2, send/4, send_dialog/3, cancel/1, send_reply/2]).
-export([find_dialog/1, stop_dialog/1]).
-export([get_authorized_list/1, clear_authorized_list/1]).
-export([get_all/0, get_info/0, clear_all/0]).
-export([get_all_dialogs/0, get_all_dialogs/2, apply_dialog/4]).
-export([apply_sipmsg/4]).
-export([get_all_transactions/0, get_all_transactions/2, apply_transaction/2]).
-export([sync_send_dialog/4, make_dialog/4, check_call/1]).
-import(nksip_router, [send_work_sync/3, send_work_async/3]).
-export_type([call/0, trans/0, trans_id/0, fork/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type call() :: #call{}.

-type trans() :: #trans{}.

-type trans_id() :: binary().

-type fork() :: #fork{}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets the AppId
-spec app_id(call()) ->
    nksip:app_id().

app_id(#call{app_id=AppId}) ->
    AppId.


%% @doc Gets the CallId
-spec call_id(call()) ->
    nksip:call_id().

call_id(#call{call_id=CallId}) ->
    CallId.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private Sends a new request.
-spec send(nksip:request(), nksip:optslist()) ->
    nksip_uac:result() | nksip_uac:ack_result().

send(#sipmsg{app_id=AppId, call_id=CallId}=Req, Opts) ->
    send_work_sync(AppId, CallId, {send, Req, Opts}).


%% @private Generates and sends a new request.
-spec send(nksip:app_id(), nksip:method(), nksip:user_uri(), nksip:optslist()) ->
    nksip_uac:result() | nksip_uac:ack_result().

send(AppId, Method, Uri, Opts) ->
    case nksip_lib:get_binary(call_id, Opts) of
        <<>> -> CallId = nksip_lib:luid();
        CallId -> ok
    end,
    send_work_sync(AppId, CallId, {send, Method, Uri, Opts}).


%% @private Generates and sends a new in-dialog request.
-spec send_dialog(nksip:dialog()|nksip:request()|nksip:response()|nksip:handle(),
                  nksip:method(), nksip:optslist()) ->
    nksip_uac:result() | nksip_uac:ack_result().

send_dialog(Term, Method, Opts) ->
    case nksip_dialog:get_handle(Term) of
        {ok, Handle} ->
            {AppId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Handle),
            send_work_sync(AppId, CallId, {send_dialog, DialogId, Method, Opts});
        {error, Error} -> 
            {error, Error}
    end.


%% @doc Cancels an ongoing INVITE request.
-spec cancel(nksip:request()|nksip:handle()) ->
    nksip_uac:uac_cancel_result().

cancel(Term) ->
    Handle = nksip_sipmsg:get_handle(Term),
    case nksip_sipmsg:parse_handle(Handle) of
        {req, AppId, ReqId, CallId} ->
            send_work_sync(AppId, CallId, {cancel, ReqId});
        _ ->
            {error, invalid_request}
    end.



%% @doc Sends a synchronous request reply.
-spec send_reply(nksip:request()|nksip:handle(), nksip:sipreply()) ->
    {ok, nksip:response()} | {error, term()}.

send_reply(Term, Reply) ->
    Handle = nksip_sipmsg:get_handle(Term),
    case nksip_sipmsg:parse_handle(Handle) of
        {req, AppId, ReqId, CallId} ->
            send_work_sync(AppId, CallId, {send_reply, ReqId, Reply});
        _ ->
            {error, invalid_request}
    end.
    












%% @doc Gets the Dialog Id of a request or response id
-spec find_dialog(nksip:handle()) ->
    {ok, nksip:handle()} | {error, term()}.

find_dialog(Id) ->
    {_Class, AppId, MsgId, CallId} = nksip_sipmsg:parse_handle(Id),
    send_work_sync(AppId, CallId, {find_dialog, MsgId}).


%% @doc Stops (deletes) a dialog.
-spec stop_dialog(nksip:handle()) ->
    ok | {error, term()}.
 
stop_dialog(Id) ->
    {AppId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Id),
    send_work_sync(AppId, CallId, {stop_dialog, DialogId}).


%% @doc Gets authorized list of transport, ip and ports for a dialog.
-spec get_authorized_list(nksip:handle()) ->
    [{nksip:protocol(), inet:ip_address(), inet:port_number()}].

get_authorized_list(Id) ->
    {AppId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Id),
    case send_work_sync(AppId, CallId, {get_authorized_list, DialogId}) of
        {ok, List} -> List;
        _ -> []
    end.


%% @doc Clears authorized list of transport, ip and ports for a dialog.
-spec clear_authorized_list(nksip:handle()) ->
    ok | error.

clear_authorized_list(Id) ->
    {AppId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Id),
    case send_work_sync(AppId, CallId, {clear_authorized_list, DialogId}) of
        ok -> ok;
        _ -> error
    end.


%% @doc Get all started calls.
-spec get_all() ->
    [{nksip:app_id(), nksip:call_id(), pid()}].

get_all() ->
    nksip_router:get_all_calls().


%% @doc Get information about all started calls.
-spec get_info() ->
    [term()].

get_info() ->
    lists:sort(lists:flatten([send_work_sync(AppId, CallId, info)
        || {AppId, CallId, _} <- nksip_router:get_all_calls()])).

%% @private 
clear_all() ->
    lists:foreach(
        fun({_, _, Pid}) -> nksip_call_srv:stop(Pid) end, 
        nksip_router:get_all_calls()).    


%% @doc Gets all started dialog ids.
-spec get_all_dialogs() ->
    [nksip:handle()].

get_all_dialogs() ->
    lists:flatten([
        get_all_dialogs(AppId, CallId)
        || 
        {AppId, CallId, _} <- nksip_router:get_all_calls()
    ]).


%% @doc Finds all existing dialogs having a `Call-ID'.
-spec get_all_dialogs(nksip:app_id(), nksip:call_id()) ->
    [nksip:handle()].

get_all_dialogs(AppId, CallId) ->
    case send_work_sync(AppId, CallId, get_all_dialogs) of
        {ok, Ids} -> Ids;
        _ -> []
    end.


%% @doc Get all active transactions for all calls.
-spec get_all_transactions() ->
    [{nksip:app_id(), nksip:call_id(), uac, nksip_call:trans_id()} |
     {nksip:app_id(), nksip:call_id(), uas, nksip_call:trans_id()}].

get_all_transactions() ->
    lists:flatten(
        [
            [{AppId, CallId, Class, Id} 
                || {Class, Id} <- get_all_transactions(AppId, CallId)]
            || {AppId, CallId, _} <- nksip_router:get_all_calls()
        ]).


%% @doc Get all active transactions for this SipApp, having CallId.
-spec get_all_transactions(nksip:app_id(), nksip:call_id()) ->
    [{uac, nksip_call:trans_id()} | {uas, nksip_call:trans_id()}].

get_all_transactions(AppId, CallId) ->
    case send_work_sync(AppId, CallId, get_all_transactions) of
        {ok, Ids} -> Ids;
        _ -> []
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private Sends a new in-dialog request from inside the call process
-spec sync_send_dialog(nksip_dialog_lib:id(), nksip:method(), nksip:optslist(), call()) ->
    {ok, call()} | {error, term()}.

sync_send_dialog(DialogId, Method, Opts, Call) ->
    case make_dialog(DialogId, Method, Opts, Call) of
        {ok, Req, ReqOpts, Call1} ->
            {ok, nksip_call_uac_req:request(Req, ReqOpts, none, Call1)};
        {error, Error} ->
            {error, Error}
    end.


%% @private Generates a new in-dialog request from inside the call process
-spec make_dialog(nksip_dialog_lib:id(), nksip:method(), nksip:optslist(), call()) ->
    {ok, nksip:request(), nksip:optslist(), call()} | {error, term()}.

make_dialog(DialogId, Method, Opts, Call) ->
    #call{app_id=AppId, call_id=CallId} = Call,
    case nksip_call_uac_dialog:make(DialogId, Method, Opts, Call) of
        {ok, RUri, Opts1, Call1} -> 
            Opts2 = [{call_id, CallId} | Opts1],
            case nksip_uac_lib:make(AppId, Method, RUri, Opts2) of
                {ok, Req, ReqOpts} ->
                    {ok, Req, ReqOpts, Call1};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec apply_sipmsg(nksip:app_id(), nksip:call_id(), nksip_sipmsg:id(), function()) ->
    {ok, term()} | {error, term()}.

apply_sipmsg(AppId, CallId, MsgId, Fun) ->
    nksip_router:send_work_sync(AppId, CallId, {apply_sipmsg, MsgId, Fun}).


%% @private Applies a fun to a transaction and returns the result.
-spec apply_transaction(nksip:handle(), function()) ->
    term() | {error, term()}.

apply_transaction(Id, Fun) ->
    {_Class, AppId, MsgId, CallId} = nksip_sipmsg:parse_handle(Id),
    send_work_sync(AppId, CallId, {apply_transaction, MsgId, Fun}).
            


%% @private
-spec apply_dialog(nksip:app_id(), nksip:call_id(), nksip_dialog_lib:id(), function()) ->
    {ok, [nksip:handle()]} | {error, term()}.

apply_dialog(AppId, CallId, DialogId, Fun) ->
    nksip_router:send_work_sync(AppId, CallId, {apply_dialog, DialogId, Fun}).



%% @private Checks if the call has expired elements
-spec check_call(call()) ->
    call().

check_call(#call{timers=#call_timers{trans=TransTime, dialog=DialogTime}} = Call) ->
    Now = nksip_lib:timestamp(),
    Trans1 = check_call_trans(Now, TransTime, Call),
    Forks1 = check_call_forks(Now, TransTime, Call),
    Dialogs1 = check_call_dialogs(Now, DialogTime, Call),
    Call#call{trans=Trans1, forks=Forks1, dialogs=Dialogs1}.


%% @private
-spec check_call_trans(nksip_lib:timestamp(), integer(), call()) ->
    [trans()].

check_call_trans(Now, MaxTime, #call{trans=Trans}) ->
    lists:filter(
        fun(#trans{id=Id, start=Start}) ->
            case Now - Start < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_error("Call removing expired transaction ~p", [Id]),
                    false
            end
        end,
        Trans).


%% @private
-spec check_call_forks(nksip_lib:timestamp(), integer(), call()) ->
    [fork()].

check_call_forks(Now, MaxTime, #call{forks=Forks}) ->
    lists:filter(
        fun(#fork{id=Id, start=Start}) ->
            case Now - Start < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_error("Call removing expired fork ~p", [Id]),
                    false
            end
        end,
        Forks).


%% @private
-spec check_call_dialogs(nksip_lib:timestamp(), integer(), call()) ->
    [nksip:dialog()].

check_call_dialogs(Now, MaxTime, #call{dialogs=Dialogs}) ->
    lists:filter(
        fun(#dialog{id=Id, updated=Updated}) ->
            case Now - Updated < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired dialog ~p", [Id]),
                    false
            end
        end,
        Dialogs).


