%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @private Call Management Module
%%
%% A new {@link nksip_call_srv} process is started for every different
%% Call-ID request or response, incoming or outcoming.
%% This module offers an interface to this process.

-module(nksip_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([srv_id/1, call_id/1]).
-export([send/2, send/5, send/6, send_dialog/6, send_cancel/5]).
-export([send_reply/5]).
-export([get_all/0, get_info/0, clear_all/0]).
-export([get_all_dialogs/0, get_all_dialogs/3, apply_dialog/5, stop_dialog/4]).
-export([get_authorized_list/4, clear_authorized_list/4]).
-export([get_all_transactions/0, get_all_transactions/3, apply_transaction/5]).
-export([apply_sipmsg/5]).
-export([check_call/1]).
-export_type([call/0, trans/0, trans_id/0, fork/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(LLOG(Type, Txt, Args), lager:Type("NkSIP Call: "++Txt, Args)).


%% ===================================================================
%% Types
%% ===================================================================


-type call() :: #call{}.

-type trans() :: #trans{}.

-type trans_id() :: integer().

-type fork() :: #fork{}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets the SrvId
-spec srv_id(call()) ->
    nkservice:id().

srv_id(#call{srv=SrvId}) ->
    SrvId.


%% @doc Gets the CallId
-spec call_id(call()) ->
    nksip:call_id().

call_id(#call{call_id=CallId}) ->
    CallId.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private Sends a new request.
-spec send(nksip:request(), [nksip_uac:req_option()]) ->
    nksip_uac:uac_result() | nksip_uac:uac_ack_result().

send(#sipmsg{srv=SrvId, package=PkgId, call_id=CallId}=Req, Opts) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {send, Req, Opts}).


%% @private Generates and sends a new request.
-spec send(nkservice:id(), nksip:call_id(), nksip:method(),
           nksip:user_uri(), [nksip_uac:req_option()]) ->
    nksip_uac:uac_result() | nksip_uac:uac_ack_result().

send(SrvId, CallId, Method, Uri, Opts) ->
    send(SrvId, ?PACKAGE_CLASS_SIP, CallId, Method, Uri, Opts).


%% @private Generates and sends a new request.
-spec send(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip:method(),
    nksip:user_uri(), [nksip_uac:req_option()]) ->
    nksip_uac:uac_result() | nksip_uac:uac_ack_result().

send(SrvId, PkgId, CallId, Method, Uri, Opts) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {send, Method, Uri, Opts}).



%% @private Generates and sends a new in-dialog request.
-spec send_dialog(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip:method(),
                  nksip_dialog_lib:id(), [nksip_uac:req_option()]) ->
    nksip_uac:uac_result() | nksip_uac:uac_ack_result().

send_dialog(SrvId, PkgId, CallId, Method, DialogId, Opts) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {send_dialog, DialogId, Method, Opts}).


%% @private Cancels an ongoing INVITE request.
-spec send_cancel(nkservice:id(), nkservice:package_id(), nksip:call_id(),
                  nksip_sipmsg:id(), [nksip_uac:req_option()]) ->
    nksip_uac:uac_cancel_result().

send_cancel(SrvId, PkgId, CallId, RequestId, Opts) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {send_cancel, RequestId, Opts}).


%% @private Sends a synchronous request reply.
-spec send_reply(nkservice:id(), nkservice:package_id(), nksip:call_id(),
                 nksip_sipmsg:id(), nksip:sipreply()) ->
    {ok, nksip:response()} | {error, term()}.

send_reply(SrvId, PkgId, CallId, ReqId, SipReply) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {send_reply, ReqId, SipReply}).


%% @private Get all started calls (dangerous in production with many calls)
-spec get_all() ->
    [{nkservice:id(), nkservice:package_id(), nksip:call_id(), pid()}].

get_all() ->
    [
        {SrvId, PkgId, CallId, Pid} ||
        {{CallId, SrvId, PkgId}, Pid} <- nklib_proc:values(?MODULE)
    ].

%% @private Get information about all started calls (dangerous in production with many calls)
-spec get_info() ->
    [term()].

get_info() ->
    lists:sort(lists:flatten([nksip_router:send_work(SrvId, PkgId, CallId, info)
        || {SrvId, PkgId, CallId, _} <- get_all()])).


%% @private Deletes all started calls
-spec clear_all() ->
    pos_integer().

clear_all() ->
    lists:foldl(
        fun({_, _, _, Pid}, Acc) -> nksip_call_srv:stop(Pid), Acc+1 end,
        0,
        get_all()).


%% @private Gets all started dialog handles (dangerous in production with many calls)
-spec get_all_dialogs() ->
    [nksip:handle()].

get_all_dialogs() ->
    lists:flatten([
        case get_all_dialogs(SrvId, PkgId, CallId) of
            {ok, Handles} -> Handles;
            {error, _} -> []
        end
        || 
        {SrvId, PkgId, CallId, _} <- get_all()
    ]).


%% @private Finds all started dialogs handles having a `Call-ID'.
-spec get_all_dialogs(nkservice:id(), nkservice:package_id(), nksip:call_id()) ->
    {ok, [nksip:handle()]} | {error, term()}.

get_all_dialogs(SrvId, PkgId, CallId) ->
    nksip_router:send_work(SrvId, PkgId, CallId, get_all_dialogs).


%% @private Deletes a dialog
-spec stop_dialog(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_dialog_lib:id()) ->
    ok | {error, term()}.
 
stop_dialog(SrvId, PkgId, CallId, DialogId) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {stop_dialog, DialogId}).


%% @private
-spec apply_dialog(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_dialog_lib:id(), function()) ->
    {apply, term()} | {error, term()}.

apply_dialog(SrvId, PkgId, CallId, DialogId, Fun) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {apply_dialog, DialogId, Fun}).


%% @private Gets authorized list of transport, ip and ports for a dialog.
-spec get_authorized_list(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_dialog_lib:id()) ->
    {ok, [{nkpacket:transport(), inet:ip_address(), inet:port_number()}]} | {error, term()}.

get_authorized_list(SrvId, PkgId, CallId, DialogId) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {get_authorized_list, DialogId}).


%% @private Gets authorized list of transport, ip and ports for a dialog.
-spec clear_authorized_list(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_dialog_lib:id()) ->
    ok | {error, term()}.

clear_authorized_list(SrvId, PkgId, CallId, DialogId) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {clear_authorized_list, DialogId}).


%% @private Get all active transactions for all calls.
-spec get_all_transactions() ->
    [{nkservice:id(), nkservice:package_id(), nksip:call_id(), uac, nksip_call:trans_id()} |
     {nkservice:id(), nkservice:package_id(), nksip:call_id(), uas, nksip_call:trans_id()}].
    
get_all_transactions() ->
    lists:flatten(
        [
            case get_all_transactions(SrvId, PkgId, CallId) of
                {ok, List} ->
                    [{SrvId, PkgId, CallId, Class, Id} || {Class, Id} <- List];
                {error, _} ->
                    []
            end
            || {SrvId, PkgId, CallId, _} <- get_all()
        ]).


%% @private Get all active transactions for this Service, having CallId.
-spec get_all_transactions(nkservice:id(), nkservice:package_id(), nksip:call_id()) ->
    {ok, [{uac|uas, nksip_call:trans_id()}]} | {error, term()}.

get_all_transactions(SrvId, PkgId, CallId) ->
    nksip_router:send_work(SrvId, PkgId, CallId, get_all_transactions).


%% @private Applies a fun to a transaction and returns the result.
-spec apply_transaction(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_sipmsg:id(), function()) ->
    {apply, term()} | {error, term()}.

apply_transaction(SrvId, PkgId, CallId, MsgId, Fun) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {apply_transaction, MsgId, Fun}).


%% @private
-spec apply_sipmsg(nkservice:id(), nkservice:package_id(), nksip:call_id(), nksip_sipmsg:id(), function()) ->
    {apply, term()} | {error, term()}.

apply_sipmsg(SrvId, PkgId, CallId, MsgId, Fun) ->
    nksip_router:send_work(SrvId, PkgId, CallId, {apply_sipmsg, MsgId, Fun}).


%% @private Checks if the call has expired elements
-spec check_call(call()) ->
    call().

check_call(#call{times=#call_times{trans=TransTime, dialog=DialogTime}} = Call) ->
    Now = nklib_util:timestamp(),
    Trans1 = check_call_trans(Now, 2*TransTime, Call),
    Forks1 = check_call_forks(Now, 2*TransTime, Call),
    Dialogs1 = check_call_dialogs(Now, 2*DialogTime, Call),
    Call#call{trans=Trans1, forks=Forks1, dialogs=Dialogs1}.


%% @private
-spec check_call_trans(nklib_util:timestamp(), integer(), call()) ->
    [trans()].

check_call_trans(Now, MaxTime, #call{trans=Trans}=Call) ->
    lists:filter(
        fun(T) ->
            #trans{start=Start} = T,
            case Now - Start < MaxTime of
                true ->
                    true;
                false ->
                    ?CALL_LOG(error, "removing expired transaction ~p", [T#trans.id], Call),
                    false
            end
        end,
        Trans).


%% @private
-spec check_call_forks(nklib_util:timestamp(), integer(), call()) ->
    [fork()].

check_call_forks(Now, MaxTime, #call{forks=Forks}=Call) ->
    lists:filter(
        fun(F) ->
            #fork{start=Start} = F,
            case Now - Start < MaxTime of
                true ->
                    true;
                false ->
                    ?CALL_LOG(error, "removing expired fork ~p", [F#fork.id], Call),
                    false
            end
        end,
        Forks).


%% @private
-spec check_call_dialogs(nklib_util:timestamp(), integer(), call()) ->
    [nksip:dialog()].

check_call_dialogs(Now, MaxTime, #call{dialogs=Dialogs}=Call) ->
    lists:filter(
        fun(D) ->
            #dialog{updated=Updated} = D,
            case Now - Updated < MaxTime of
                true ->
                    true;
                false ->
                    ?CALL_LOG(error, "removing expired dialog ~p", [D#dialog.id], Call),
                    false
            end
        end,
        Dialogs).


