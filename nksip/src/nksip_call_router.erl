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

%% @private 

-module(nksip_call_router).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([send/1, get_cancel/2, make_dialog/3, sync_reply/2]).
-export([get_dialog/1, get_dialog_fields/2, get_all_dialogs/0, get_all_dialogs/2,
         stop_dialog/1]).
-export([get_sipmsg/1, get_sipmsg_fields/2, get_sipmsg_header/2, get_all_sipmsgs/0, 
         get_all_sipmsgs/2]).
-export([get_all_calls/0, get_all_data/0]).
-export([incoming/1, pending_msgs/0, pending_work/0]).
-export([sipapp_reply/5, clear_calls/0]).
-export([pos2name/1, start_link/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_CALLS, 1024000).
-define(CHECK_TIME, 5000).


%% ===================================================================
%% Private
%% ===================================================================


send(#sipmsg{sipapp_id=AppId, call_id=CallId}=Req) ->
    send_work_sync(AppId, CallId, {send, Req}).

get_cancel({req, AppId, CallId, ReqId}, Opts) ->
    send_work_sync(AppId, CallId, {get_cancel, ReqId, Opts}).

make_dialog(DialogSpec, Method, Opts) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_sync(AppId, CallId, {make_dialog, DialogId, Method, Opts});
        undefined ->
            {error, unknown_dialog}
    end.


sipapp_reply(AppId, CallId, Fun, TransId, Reply) ->
    send_work_async(AppId, CallId, {sipapp_reply, Fun, TransId, Reply}).

sync_reply({req, AppId, CallId, ReqId}, Reply) ->
    send_work_sync(AppId, CallId, {sync_reply, ReqId, Reply}).


get_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_sync(AppId, CallId, {get_dialog, DialogId});
        undefined ->
            {error, unknown_dialog}
    end.

get_dialog_fields(DialogSpec, Fields) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_sync(AppId, CallId, {get_dialog_fields, DialogId, Fields});
        undefined ->
            {error, unknown_dialog}
    end.

get_all_dialogs() ->
    lists:flatten([get_all_dialogs(AppId, CallId)
        ||{AppId, CallId, _} <- get_all_calls()]).

get_all_dialogs(AppId, CallId) ->
    send_work_sync(AppId, CallId, get_all_dialogs).

stop_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_async(AppId, CallId, {stop_dialog, DialogId});
        undefined ->
            {error, unknown_dialog}
    end.

get_sipmsg({_, AppId, CallId, MsgId}) ->
    send_work_sync(AppId, CallId, {get_sipmsg, MsgId}).

get_sipmsg_fields({_, AppId, CallId, MsgId}, Fields) ->
    send_work_sync(AppId, CallId, {get_sipmsg_fields, MsgId, Fields}).

get_sipmsg_header({_, AppId, CallId, MsgId}, Name) ->
    send_work_sync(AppId, CallId, {get_sipmsg_header, MsgId, Name}).


get_all_sipmsgs() ->
    lists:flatten([get_all_sipmsgs(AppId, CallId)
        ||{AppId, CallId, _} <- get_all_calls()]).

get_all_sipmsgs(AppId, CallId) ->
    send_work_sync(AppId, CallId, get_all_sipmsgs).


get_all_calls() ->
    Fun = fun(Name, Acc) -> [call_fold(Name)|Acc] end,
    lists:flatten(router_fold(Fun)).

clear_calls() ->
    lists:foreach(fun({_, _, Pid}) -> nksip_call_srv:stop(Pid) end, get_all_calls()).    


get_all_data() ->
    [
        {AppId, CallId, nksip_call_srv:get_data(Pid)}
        || {AppId, CallId, Pid} <- get_all_calls()
    ].

incoming(#raw_sipmsg{call_id=CallId}=RawMsg) ->
    gen_server:cast(name(CallId), {incoming, RawMsg}).


pending_work() ->
    router_fold(fun(Name, Acc) -> Acc+gen_server:call(Name, pending) end, 0).

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
    pending :: [{{nksip:sipapp_id(), nksip:call_id()}, term()}]
}).


%% @private
start_link(Pos, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pos, Name], []).
        
%% @private
init([Pos, Name]) ->
    Name = ets:new(Name, [named_table, protected]),
    {ok, #state{pos=Pos, name=Name, opts_dict=dict:new(), pending=dict:new()}}.


%% @private
handle_call({send_work_sync, AppId, CallId, Work}, From, SD) ->
    case send_work_sync(AppId, CallId, Work, From, SD) of
        {ok, SD1} -> 
            {noreply, SD1};
        {error, Error} ->
            ?error(AppId, CallId, "Error processing semd request: ~p", [Error]),
            {reply, {error, Error}, SD}
    end;


handle_call(pending, _From, #state{pending=Pending}=SD) ->
    {reply, dict:size(Pending), SD};

handle_call(Msg, _From, SD) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
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
            SD1 = send_work_sync(AppId, CallId, Work, none, SD#state{pending=Pending1}),
            {noreply, SD1};
        error ->
            {noreply, SD}
    end;

handle_info(Info, SD) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, SD}.


%% @private
code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% @private
terminate(_Reason, _SD) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

name(CallId) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    pos2name(Pos).

%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_call_router_"++integer_to_list(Pos)).


send_work_sync(AppId, CallId, Work) ->
    gen_server:call(name(CallId), {send_work_sync, AppId, CallId, Work}, ?SRV_TIMEOUT).


send_work_sync(AppId, CallId, Work, From, #state{name=Name, pending=Pending}=SD) ->
    case find(Name, AppId, CallId) of
        {ok, Pid} -> 
            Ref = erlang:monitor(process, Pid),
            Self = self(),
            nksip_call_srv:sync_work(Pid, Ref, Self, Work, From),
            Pending1 = dict:store(Ref, {AppId, CallId, Work}, Pending),
            {ok, SD#state{pending=Pending1}};
        not_found ->
            case do_call_start(AppId, CallId, SD) of
                {ok, SD1} -> send_work_sync(AppId, CallId, Work, From, SD1);
                {error, Error} -> {error, Error}
            end
   end.

send_work_async(AppId, CallId, Work, #state{name=Name}) ->
    case find(Name, AppId, CallId) of
        {ok, Pid} -> 
            nksip_call_srv:async_work(Pid, Work);
        not_found -> 
            ?info(AppId, CallId, "Trying to send work ~p to deleted call", [Work])
   end.


send_work_async(AppId, CallId, Work) ->
    case find(AppId, CallId) of
        {ok, Pid} -> 
            nksip_call_srv:async_work(Pid, Work);
        not_found -> 
            ?info(AppId, CallId, "Trying to send work ~p to deleted call", [Work])
   end.


do_call_start(AppId, CallId, #state{pos=Pos, name=Name}=SD) ->
    case get_opts(AppId, SD) of
        {ok, Opts, SD1} ->
            ?debug(AppId, CallId, "Router ~p launching call", [Pos]),
            {ok, Pid} = nksip_call_srv:start(AppId, CallId, Opts),
            erlang:monitor(process, Pid),
            Id = {call, AppId, CallId},
            true = ets:insert(Name, [{Id, Pid}, {Pid, Id}]),
            {ok, SD1};
        {error, not_found} ->
            {error, sipapp_not_found}
    end.


get_opts(AppId, #state{opts_dict=OptsDict}=SD) ->
    case dict:find(AppId, OptsDict) of
        {ok, Opts} ->
            {ok, Opts, SD};
        error ->
            case nksip_sipapp_srv:get_opts(AppId) of
                {ok, Opts0} ->
                    Opts = nksip_lib:extract(Opts0, 
                                             [local_host, registrar, no_100]),
                    OptsDict1 = dict:store(AppId, Opts, OptsDict),
                    {ok, Opts, SD#state{opts_dict=OptsDict1}};
                {error, not_found} ->
                    {error, not_found}
            end
    end.

find(AppId, CallId) ->
    find(name(CallId), AppId, CallId).

find(Name, AppId, CallId) ->
    case ets:lookup(Name, {call, AppId, CallId}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.



router_fold(Fun) ->
    router_fold(Fun, []).

router_fold(Fun, Init) ->
    lists:foldl(
        fun(Pos, Acc) -> Fun(pos2name(Pos), Acc) end,
        Init,
        lists:seq(0, ?MSG_PROCESSORS-1)).

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