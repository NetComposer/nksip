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

%% @private Call Distribution Router
-module(nksip_router).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([incoming_sync/1, incoming_sync/4]).
-export([get_all_calls/0]).
-export([pending_msgs/0, pending_work/0]).
-export([send_work_sync/3, send_work_async/3]).
-export([pos2name/1, start_link/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a synchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_sync(nkservice:id(), nksip:call_id(), nksip_call_worker:work()) ->
    any() | {error, too_many_calls | looped_process | timeout}.

send_work_sync(SrvId, CallId, Work) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    WorkSpec = {send_work_sync, SrvId, CallId, Work, self()},
    case catch gen_server:call(Name, WorkSpec, Timeout) of
        {'EXIT', Error} ->
            ?warning(SrvId, CallId, "error calling send_work_sync (~p): ~p",
                     [work_id(Work), Error]),
            {error, timeout};
        Other ->
            Other
    end.


%% @doc Called when a new request or response has been received.
-spec incoming_sync(nksip:request()|nksip:response()) ->
    ok | {error, too_many_calls | looped_process | timeout}.

incoming_sync(#sipmsg{srv_id=SrvId, call_id=CallId}=SipMsg) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    case catch gen_server:call(Name, {incoming, SipMsg}, Timeout) of
        {'EXIT', Error} -> 
            ?warning(SrvId, CallId, "error calling incoming_sync: ~p", [Error]),
            {error, timeout};
        Result -> 
            Result
    end.


%% @doc Called when a new request or response has been received.
-spec incoming_sync(nkservice:id(), nksip:call_id(), nksip:transport(), binary()) ->
    ok | {error, too_many_calls | looped_process | timeout}.

incoming_sync(SrvId, CallId, Transp, Msg) ->
    Name = name(CallId),
    Timeout = nksip_config_cache:sync_call_time(),
    case catch gen_server:call(Name, {incoming, SrvId, CallId, Transp, Msg}, Timeout) of
        {'EXIT', Error} -> 
            ?warning(SrvId, CallId, "error calling incoming_sync: ~p", [Error]),
            {error, timeout};
        Result -> 
            Result
    end.



%% @doc Get all started calls.
-spec get_all_calls() ->
    [{nkservice:id(), nksip:call_id(), pid()}].

get_all_calls() ->
    Fun = fun(Name, Acc) -> [call_fold(Name)|Acc] end,
    lists:flatten(router_fold(Fun)).


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

-ifdef(old_types).
-type dict_type() :: dict().
-else.
-type dict_type() :: dict:dict().
-endif.

-record(state, {
    pos :: integer(),
    name :: atom(),
    pending :: dict_type()
}).


%% @private
start_link(Pos, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pos, Name], []).
        
%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([Pos, Name]) ->
    Name = ets:new(Name, [named_table, protected]),
    SD = #state{
        pos = Pos, 
        name = Name, 
        pending = dict:new()
    },
    {ok, SD}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call({send_work_sync, SrvId, CallId, Work, Caller}, From, SD) ->
    case send_work_sync(SrvId, CallId, Work, Caller, From, SD) of
        {ok, SD1} -> 
            {noreply, SD1};
        {error, Error} ->
            ?error(SrvId, CallId, "error sending work ~p: ~p", [Work, Error]),
            {reply, {error, Error}, SD}
    end;

handle_call({incoming, SipMsg}, _From, SD) ->
    #sipmsg{srv_id=SrvId, call_id=CallId} = SipMsg,
    case send_work_sync(SrvId, CallId, {incoming, SipMsg}, none, none, SD) of
        {ok, SD1} -> 
            {reply, ok, SD1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {reply, {error, Error}, SD}
    end;

handle_call({incoming, SrvId, CallId, Transp, Msg}, _From, SD) ->
    case send_work_sync(SrvId, CallId, {incoming, SrvId, CallId, Transp, Msg}, none, none, SD) of
        {ok, SD1} -> 
            {reply, ok, SD1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {reply, {error, Error}, SD}
    end;


handle_call(pending, _From, #state{pending=Pending}=SD) ->
    {reply, dict:size(Pending), SD};

handle_call(Msg, _From, SD) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({incoming, SipMsg}, SD) ->
    #sipmsg{srv_id=SrvId, call_id=CallId} = SipMsg,
    case send_work_sync(SrvId, CallId, {incoming, SipMsg}, none, none, SD) of
        {ok, SD1} -> 
            {noreply, SD1};
        {error, Error} ->
            ?error(SrvId, CallId, "error processing incoming message: ~p", [Error]),
            {noreply, SD}
    end;

handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({sync_work_ok, Ref, Pid}, #state{pending=Pending}=SD) ->
    Pending1 = case dict:find(Pid, Pending) of
        {ok, {_SrvId, _CallId, [{Ref, _From, _Work}]}} ->
            dict:erase(Pid, Pending);
        {ok, {SrvId, CallId, WorkList}} ->
            WorkList1 = lists:keydelete(Ref, 1, WorkList),
            dict:store(Pid, {SrvId, CallId, WorkList1}, Pending);
        error ->
            lager:warning("Receiving sync_work_ok for unknown work"),
            Pending
    end,
    {noreply, SD#state{pending=Pending1}};

handle_info({'DOWN', _MRef, process, Pid, _Reason}, SD) ->
    #state{pos=Pos, name=Name, pending=Pending} = SD,
    case ets:lookup(Name, Pid) of
        [{Pid, Id}] ->
            {_, SrvId0, CallId0} = Id,
            ?debug(SrvId0, CallId0, "Router ~p unregistering call", [Pos]),
            ets:delete(Name, Pid), 
            ets:delete(Name, Id);
        [] ->
            ok
    end,
    case dict:find(Pid, Pending) of
        {ok, {SrvId, CallId, WorkList}} -> 
            % We had pending work for this process.
            % Actually, we know the process has stopped normally before processing
            % these requests (it hasn't failed due to an error).
            % If the process had failed due to an error processing the work,
            % the "received work" message would have been received an the work will
            % not be present in Pending.
            SD1 = SD#state{pending=dict:erase(Pid, Pending)},
            SD2 = resend_worklist(SrvId, CallId, lists:reverse(WorkList), SD1),
            {noreply, SD2};
        error ->
            {noreply, SD}
    end;

handle_info(Info, SD) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, SD}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _SD) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private 
-spec name(nksip:call_id()) ->
    atom().

name(CallId) ->
    Pos = erlang:phash2(CallId) rem nksip_config_cache:msg_routers(),
    pos2name(Pos).


%% @private
-spec send_work_sync(nkservice:id(), nksip:call_id(), nksip_call_worker:work(), 
                     pid() | none, {pid(), term()}, #state{}) ->
    {ok, #state{}} | {error, looped_process | too_many_calls}.

send_work_sync(SrvId, CallId, Work, Caller, From, #state{name=Name}=SD) ->
    case find(Name, SrvId, CallId) of
        {ok, Caller} ->
            {error, looped_process};
        {ok, Pid} -> 
            {ok, do_send_work_sync(Pid, SrvId, CallId, Work, From, SD)};
        not_found ->
            case do_call_start(SrvId, CallId, SD) of
                {ok, Pid} -> 
                    {ok, do_send_work_sync(Pid, SrvId, CallId, Work, From, SD)};
                {error, Error} -> 
                    {error, Error}
            end
   end.


%% @private
-spec do_send_work_sync(pid(), nkservice:id(), nksip:call_id(), nksip_call_worker:work(), 
                        {pid(), term()}, #state{}) ->
    #state{}.

do_send_work_sync(Pid, SrvId, CallId, Work, From, #state{pending=Pending}=SD) ->
    Ref = make_ref(),
    nksip_call_srv:sync_work(Pid, Ref, self(), Work, From),
    Pending1 = case dict:find(Pid, Pending) of
        {ok, {_, _, WorkList}} ->
            dict:store(Pid, {SrvId, CallId, [{Ref, From, Work}|WorkList]}, Pending);
        error ->
            dict:store(Pid, {SrvId, CallId, [{Ref, From, Work}]}, Pending)
    end,
    SD#state{pending=Pending1}.
    

%% @private
-spec do_call_start(nkservice:id(), nksip:call_id(), #state{}) ->
    {ok, pid()} | {error, too_many_calls}.

do_call_start(SrvId, CallId, SD) ->
    #state{name=Name} = SD,
    Max = nksip_config_cache:global_max_calls(),
    case nklib_counters:value(nksip_calls) < Max of
        true ->
            AppMax = SrvId:cache_sip_max_calls(),
            case nklib_counters:value({nksip_calls, SrvId}) < AppMax of
                true ->
                    {ok, Pid} = nksip_call_srv:start(SrvId, CallId),
                    erlang:monitor(process, Pid),
                    Id = {call, SrvId, CallId},
                    true = ets:insert(Name, [{Id, Pid}, {Pid, Id}]),
                    {ok, Pid};
                false ->
                    {error, too_many_calls}
            end;
        false ->
            {error, too_many_calls}
    end.


%% @doc Sends an asynchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_async(nkservice:id(), nksip:call_id(), nksip_call_worker:work()) ->
    ok.

send_work_async(SrvId, CallId, Work) ->
    send_work_async(name(CallId), SrvId, CallId, Work).


%% @private Sends an asynchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work_async(atom(), nkservice:id(), nksip:call_id(), nksip_call_worker:work()) ->
    ok.

send_work_async(Name, SrvId, CallId, Work) ->
    case find(Name, SrvId, CallId) of
        {ok, Pid} -> 
            nksip_call_srv:async_work(Pid, Work);
        not_found -> 
            ?info(SrvId, CallId, "trying to send work ~p to deleted call", 
                  [work_id(Work)])
   end.


%% @private
-spec resend_worklist(nkservice:id(), nksip:call_id(), 
                      [{reference(), {pid(), term()}|none, nksip_call_worker:work()}], #state{}) ->
    #state{}.

resend_worklist(_SrvId, _CallId, [], SD) ->
    SD;

resend_worklist(SrvId, CallId, [{_Ref, From, Work}|Rest], SD) ->
    case send_work_sync(SrvId, CallId, Work, none, From, SD) of
        {ok, SD1} -> 
            ?debug(SrvId, CallId, "resending work ~p from ~p", 
                   [work_id(Work), From]),
            resend_worklist(SrvId, CallId, Rest, SD1);
        {error, Error} ->
            case From of
                {Pid, Ref} when is_pid(Pid), is_reference(Ref) ->
                    gen_server:reply(From, {error, Error});
                _ ->
                    ok
            end,
            resend_worklist(SrvId, CallId, Rest, SD)
    end.




%% @private
-spec find(atom(), nkservice:id(), nksip:call_id()) ->
    {ok, pid()} | not_found.

find(Name, SrvId, CallId) ->
    case ets:lookup(Name, {call, SrvId, CallId}) of
        [{_, Pid}] -> {ok, Pid};
        [] -> not_found
    end.

%% @private
work_id(Tuple) when is_tuple(Tuple) -> element(1, Tuple);
work_id(Other) -> Other.


%% @private
router_fold(Fun) ->
    router_fold(Fun, []).

router_fold(Fun, Init) ->
    lists:foldl(
        fun(Pos, Acc) -> Fun(pos2name(Pos), Acc) end,
        Init,
        lists:seq(0, nksip_config_cache:msg_routers()-1)).

%% @private
call_fold(Name) ->
    ets:foldl(
        fun(Record, Acc) ->
            case Record of
                {{call, SrvId, CallId}, Pid} when is_pid(Pid) ->
                    [{SrvId, CallId, Pid}|Acc];
                _ ->
                    Acc
            end
        end,
        [],
        Name).



%% @private
-spec pos2name(integer()) -> 
    atom().

% Urgly but speedy
pos2name(0) -> nksip_router_0;
pos2name(1) -> nksip_router_1;
pos2name(2) -> nksip_router_2;
pos2name(3) -> nksip_router_3;
pos2name(4) -> nksip_router_4;
pos2name(5) -> nksip_router_5;
pos2name(6) -> nksip_router_6;
pos2name(7) -> nksip_router_7;
pos2name(8) -> nksip_router_8;
pos2name(9) -> nksip_router_9;
pos2name(10) -> nksip_router_10;
pos2name(11) -> nksip_router_11;
pos2name(12) -> nksip_router_12;
pos2name(13) -> nksip_router_13;
pos2name(14) -> nksip_router_14;
pos2name(15) -> nksip_router_15;
pos2name(16) -> nksip_router_16;
pos2name(17) -> nksip_router_17;
pos2name(18) -> nksip_router_18;
pos2name(19) -> nksip_router_19;
pos2name(20) -> nksip_router_20;
pos2name(21) -> nksip_router_21;
pos2name(22) -> nksip_router_22;
pos2name(23) -> nksip_router_23;
pos2name(24) -> nksip_router_24;
pos2name(25) -> nksip_router_25;
pos2name(26) -> nksip_router_26;
pos2name(27) -> nksip_router_27;
pos2name(28) -> nksip_router_28;
pos2name(29) -> nksip_router_29;
pos2name(30) -> nksip_router_30;
pos2name(31) -> nksip_router_31;
pos2name(P) -> list_to_atom("nksip_router_"++integer_to_list(P)).

