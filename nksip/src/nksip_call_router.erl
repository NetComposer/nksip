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

%% @private Call generation and distribution
-module(nksip_call_router).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([send/1, send/4, send_dialog/3, cancel/1, sync_reply/2]).
-export([apply_dialog/2, get_all_dialogs/0, get_all_dialogs/2, stop_dialog/1]).
-export([apply_sipmsg/2, get_all_sipmsgs/0, get_all_sipmsgs/2]).
-export([get_all_calls/0, get_all_data/0]).
-export([incoming/1, pending_msgs/0, pending_work/0]).
-export([app_reply/5, clear_calls/0]).
-export([pos2name/1, start_link/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).
-export_type([send_common/0, send_error/0, make_error/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type sync_error() :: unknown_sipapp | too_many_calls | timeout.

-type send_common() ::  
        {ok, nksip:response_code(), nksip:response_id()} |
        {resp, nksip:response()} |
        {async, nksip:request_id()} |
        ok | {ok, nksip:request()}.     % For ACKs

-type send_error() :: unknown_dialog | request_pending | network_error | sync_error().

-type make_error() :: invalid_uri | invalid_from | invalid_to | invalid_route |
                      invalid_contact | invalid_cseq | send_error().



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new request
-spec send(nksip:request()) ->
    send_common() | {error, send_error()}.

send(#sipmsg{app_id=AppId, call_id=CallId}=Req) ->
    send_work_sync(AppId, CallId, {send, Req}).


%% @doc Generates and sends a new request
-spec send(nksip:app_id(), nksip:method(), nksip:user_uri(), nksip_lib:proplist()) ->
    send_common() | {error, make_error()}.

send(AppId, Method, Uri, Opts) ->
    case nksip_lib:get_binary(call_id, Opts) of
        <<>> -> 
            CallId = nksip_lib:luid(),
            Opts1 = [{call_id, CallId}|Opts];
        CallId -> 
            Opts1 = Opts
    end,
    send_work_sync(AppId, CallId, {send, Method, Uri, Opts1}).


%% @doc Generates and sends a new in-dialog request
-spec send_dialog(nksip_dialog:spec(), nksip:method(), nksip_lib:proplist()) ->
    send_common() | {error, send_error()}.

send_dialog(DialogSpec, Method, Opts) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, Id} ->
            send_work_sync(AppId, CallId, {send_dialog, Id, Method, Opts});
        undefined ->
            {error, unknown_dialog}
    end.


%% @doc Cancels an ongoing INVITE request
-spec cancel(nksip:request_id()) ->
    ok | {error, Error}
    when Error :: unknown_request | sync_error().

cancel(ReqSpec) ->
    {req, AppId, CallId, Id, _DlgId} = nksip_request:id(ReqSpec),
    send_work_sync(AppId, CallId, {cancel, Id}).


%% @doc Sends a callback SipApp response
-spec app_reply(nksip:app_id(), nksip:call_id(), atom(), nksip_call_uas:id(), term()) ->
    ok.

app_reply(AppId, CallId, Fun, TransId, Reply) ->
    send_work_async(AppId, CallId, {app_reply, Fun, TransId, Reply}).


%% @doc Sends a synchronous request reply
-spec sync_reply(nksip:request_id(), nksip:sipreply()) ->
    {ok, nksip:response()} | {error, Error}
    when Error :: invalid_call | sync_error().

sync_reply({req, AppId, CallId, MsgId, _DlgId}, Reply) ->
    send_work_sync(AppId, CallId, {sync_reply, MsgId, Reply}).


%% @doc Applies a fun to a dialog and returns the result
-spec apply_dialog(nksip_dialog:spec(), function()) ->
    term() | {error, Error}
    when Error :: unknown_dialog | sync_error().

apply_dialog(DialogSpec, Fun) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_sync(AppId, CallId, {apply_dialog, DialogId, Fun});
        undefined ->
            {error, unknown_dialog}
    end.


%% @doc Get all dialog ids for all calls
-spec get_all_dialogs() ->
    [nksip:dialog_id()].

get_all_dialogs() ->
    lists:flatten([get_all_dialogs(AppId, CallId)
        ||{AppId, CallId, _} <- get_all_calls()]).


%% @doc Get all dialog for this SipApp and having CallId
-spec get_all_dialogs(nksip:app_id(), nksip:call_id()) ->
    [nksip:dialog_id()].

get_all_dialogs(AppId, CallId) ->
    case send_work_sync(AppId, CallId, get_all_dialogs) of
        {ok, Ids} -> Ids;
        _ -> []
    end.


%% @doc Stops (deletes) a dialog
-spec stop_dialog(nksip_dialog:spec()) ->
    ok | {error, unknown_dialog}.
 
stop_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_async(AppId, CallId, {stop_dialog, DialogId});
        undefined ->
            {error, unknown_dialog}
    end.


%% @doc Applies a fun to a SipMsg and returns the result
-spec apply_sipmsg(nksip:request_id() | nksip:response_id(), function()) ->
    term() | {error, Error}
    when Error :: unknown_sipmsg | sync_error().

apply_sipmsg({Class, AppId, CallId, MsgId, _DlgId}, Fun)
             when Class=:=req; Class=:=resp ->
    send_work_sync(AppId, CallId, {apply_sipmsg, MsgId, Fun}).


%% @doc Get all stored SipMsgs for all calls
-spec get_all_sipmsgs() ->
    [nksip:request_id() | nksip:response_id()].

get_all_sipmsgs() ->
    lists:flatten([get_all_sipmsgs(AppId, CallId)
        ||{AppId, CallId, _} <- get_all_calls()]).


%% @doc Get all SipMsgs for this SipApp and having CallId
-spec get_all_sipmsgs(nksip:app_id(), nksip:call_id()) ->
    [nksip:request_id() | nksip:response_id()].

get_all_sipmsgs(AppId, CallId) ->
    case send_work_sync(AppId, CallId, get_all_sipmsgs) of
        {ok, Ids} -> Ids;
        _ -> []
    end.


%% @doc Get all started calls
-spec get_all_calls() ->
    [{nksip:app_id(), nksip:call_id(), pid()}].

get_all_calls() ->
    Fun = fun(Name, Acc) -> [call_fold(Name)|Acc] end,
    lists:flatten(router_fold(Fun)).


%% @private 
clear_calls() ->
    lists:foreach(fun({_, _, Pid}) -> nksip_call:stop(Pid) end, get_all_calls()).    


%% @private
get_all_data() ->
    [
        {AppId, CallId, nksip_call:get_data(Pid)}
        || {AppId, CallId, Pid} <- get_all_calls()
    ].


%% @private
incoming(#raw_sipmsg{call_id=CallId}=RawMsg) ->
    gen_server:cast(name(CallId), {incoming, RawMsg}).


%% @private
pending_work() ->
    router_fold(fun(Name, Acc) -> Acc+gen_server:call(Name, pending) end, 0).


%% @private
pending_msgs() ->
    router_fold(
        fun(Name, Acc) ->
            Pid = whereis(Name),
            {_, Len} = erlang:process_info(Pid, message_queue_len),
            Acc + Len
        end,
        0).


%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    pos :: integer(),
    name :: atom(),
    opts_dict :: dict(),
    pending :: dict(),
    max_calls :: integer()
}).


%% @private
start_link(Pos, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pos, Name], []).
        
% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([Pos, Name]) ->
    Name = ets:new(Name, [named_table, protected]),
    SD = #state{
        pos = Pos, 
        name = Name, 
        max_calls = nksip_config:get(max_calls),
        opts_dict = dict:new(), 
        pending = dict:new()
    },
    {ok, SD}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send_work_sync, AppId, CallId, Work}, From, SD) ->
    case send_work_sync(AppId, CallId, Work, From, SD) of
        {ok, SD1} -> 
            {noreply, SD1};
        {error, Error} ->
            ?error(AppId, CallId, "Error sending work ~p: ~p", [Work, Error]),
            {reply, {error, Error}, SD}
    end;


handle_call(pending, _From, #state{pending=Pending}=SD) ->
    {reply, dict:size(Pending), SD};

handle_call(Msg, _From, SD) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({incoming, RawMsg}, SD) ->
    #raw_sipmsg{class=Class, sipapp_id=AppId, call_id=CallId} = RawMsg,
    case Class of
        {req, _,  _} ->
            case send_work_sync(AppId, CallId, {incoming, RawMsg}, none, SD) of
                {ok, SD1} -> 
                    {noreply, SD1};
                {error, Error} ->
                    ?error(AppId, CallId, 
                           "Error processing incoming message: ~p", [Error]),
                    {noreply, SD}
            end;
        {resp, _, _} ->
            send_work_async(AppId, CallId, {incoming, RawMsg}, SD),
            {noreply, SD}
    end;

handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({sync_work_ok, Ref}, #state{pending=Pending}=SD) ->
    erlang:demonitor(Ref),
    Pending1 = dict:erase(Ref, Pending),
    {noreply, SD#state{pending=Pending1}};

handle_info({'DOWN', MRef, process, Pid, _Reason}, SD) ->
    #state{pos=Pos, name=Name, pending=Pending} = SD,
    case ets:lookup(Name, Pid) of
        [{Pid, Id}] ->
            ?debug(element(2, Id), element(3, Id),
                   "Router ~p unregistering call", [Pos]),
            ets:delete(Name, Pid), 
            ets:delete(Name, Id);
        [] ->
            ok
    end,
    case dict:find(MRef, Pending) of
        {ok, {AppId, CallId, Work}} -> 
            Pending1 = dict:erase(MRef, Pending),
            SD1 = SD#state{pending=Pending1},
            case send_work_sync(AppId, CallId, Work, none, SD1) of
                {ok, SD2} -> 
                    ?info(AppId, CallId, "Retargeting work ~p", [Work]),
                    {noreply, SD2};
                {error, Error} ->
                    ?error(AppId, CallId, 
                           "Error retargeting work ~p: ~p", [Work, Error]),
                    {noreply, SD}
            end;
        error ->
            {noreply, SD}
    end;

handle_info(Info, SD) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, SD}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _SD) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private 
-spec name(nksip:call_id()) ->
    atom().

name(CallId) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    pos2name(Pos).


%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_call_router_"++integer_to_list(Pos)).


%% @private
-spec send_work_sync(nksip:app_id(), nksip:call_id(), any()) ->
    any() | {error, sync_error()}.

send_work_sync(AppId, CallId, Work) ->
    WorkSpec = {send_work_sync, AppId, CallId, Work},
    case catch gen_server:call(name(CallId), WorkSpec, 5000) of
    % case catch gen_server:call(name(CallId), WorkSpec, ?SRV_TIMEOUT) of
        {'EXIT', Error} ->
            ?warning(AppId, CallId, "Error calling send_work_sync (~p): ~p",
                     [Work, Error]),
            {error, timeout};
        Other ->
            Other
    end.



%% @private
-spec send_work_sync(nksip:app_id(), nksip:call_id(), nksip_call:work(), 
                     from(), #state{}) ->
    {ok, #state{}} | {error, sync_error()}.

send_work_sync(AppId, CallId, Work, From, #state{name=Name, pending=Pending}=SD) ->
    case find(Name, AppId, CallId) of
        {ok, Pid} -> 
            Ref = erlang:monitor(process, Pid),
            Self = self(),
            nksip_call:sync_work(Pid, Ref, Self, Work, From),
            Pending1 = dict:store(Ref, {AppId, CallId, Work}, Pending),
            {ok, SD#state{pending=Pending1}};
        not_found ->
            case do_call_start(AppId, CallId, SD) of
                {ok, SD1} -> send_work_sync(AppId, CallId, Work, From, SD1);
                {error, Error} -> {error, Error}
            end
   end.


%% @private
-spec send_work_async(nksip:app_id(), nksip:call_id(), nksip_call:work(), #state{}) ->
    ok.

send_work_async(AppId, CallId, Work, #state{name=Name}) ->
    case find(Name, AppId, CallId) of
        {ok, Pid} -> 
            nksip_call:async_work(Pid, Work);
        not_found -> 
            ?info(AppId, CallId, "Trying to send work ~p to deleted call", [Work])
   end.


%% @private
-spec send_work_async(nksip:app_id(), nksip:call_id(), nksip_call:work()) ->
    ok.

send_work_async(AppId, CallId, Work) ->
    case find(AppId, CallId) of
        {ok, Pid} -> 
            nksip_call:async_work(Pid, Work);
        not_found -> 
            ?info(AppId, CallId, "Trying to send work ~p to deleted call", [Work])
   end.


%% @private
-spec do_call_start(nksip:app_id(), nksip:call_id(), #state{}) ->
    {ok, #state{}} | {error, unknown_sipapp | too_many_calls}.

do_call_start(AppId, CallId, #state{pos=Pos, name=Name, max_calls=MaxCalls}=SD) ->
    case nksip_counters:value(nksip_calls) < MaxCalls of
        true ->
            case get_opts(AppId, SD) of
                {ok, Opts, SD1} ->
                    ?debug(AppId, CallId, "Router ~p launching call", [Pos]),
                    {ok, Pid} = nksip_call:start(AppId, CallId, Opts),
                    erlang:monitor(process, Pid),
                    Id = {call, AppId, CallId},
                    true = ets:insert(Name, [{Id, Pid}, {Pid, Id}]),
                    {ok, SD1};
                {error, not_found} ->
                    {error, unknown_sipapp}
            end;
        false ->
            {error, too_many_calls}
    end.


%% @private
-spec get_opts(nksip:app_id(), #state{}) ->
    {ok, nksip_lib:proplist(), #state{}} | {error, not_found}.

get_opts(AppId, #state{opts_dict=OptsDict}=SD) ->
    case dict:find(AppId, OptsDict) of
        {ok, Opts} ->
            {ok, Opts, SD};
        error ->
            case nksip_sipapp_srv:get_opts(AppId) of
                {ok, Opts} ->
                    OptsDict1 = dict:store(AppId, Opts, OptsDict),
                    {ok, Opts, SD#state{opts_dict=OptsDict1}};
                {error, not_found} ->
                    {error, not_found}
            end
    end.


%% @private
-spec find(nksip:app_id(), nksip:call_id()) ->
    {ok, pid()} | not_found.

find(AppId, CallId) ->
    find(name(CallId), AppId, CallId).


%% @private
-spec find(atom(), nksip:app_id(), nksip:call_id()) ->
    {ok, pid()} | not_found.

find(Name, AppId, CallId) ->
    case ets:lookup(Name, {call, AppId, CallId}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.


%% @private
router_fold(Fun) ->
    router_fold(Fun, []).

router_fold(Fun, Init) ->
    lists:foldl(
        fun(Pos, Acc) -> Fun(pos2name(Pos), Acc) end,
        Init,
        lists:seq(0, ?MSG_PROCESSORS-1)).

%% @private
call_fold(Name) ->
    ets:foldl(
        fun(Record, Acc) ->
            case Record of
                {{call, AppId, CallId}, Pid} when is_pid(Pid) ->
                    [{AppId, CallId, Pid}|Acc];
                _ ->
                    Acc
            end
        end,
        [],
        Name).