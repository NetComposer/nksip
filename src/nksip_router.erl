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

%% @private Call Distribution Router
-module(nksip_router).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([send_work/3, incoming/4]).
-export([work_received/3, pending_msgs/0, pending_work/0]).
-export([pos2name/1, start_link/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(LLOG(Type, Txt, Args), lager:Type("NkSIP Router: "++Txt, Args)).


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a synchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work(nkserver:id(), nksip:call_id(), nksip_call_worker:work()) ->
    any() | {error, too_many_calls | looped_process | {exit, term()}}.

send_work(SrvId, CallId, Work) ->
    send_work(SrvId, CallId, Work, self()).


%% @doc Called when a new request or response has been received.
-spec incoming(nkserver:id(), nksip:call_id(), nkpacket:nkport(), binary()) ->
    ok | {error, too_many_calls | looped_process | {exit, term()}}.

incoming(SrvId, CallId, NkPort, Msg) ->
    Work = {incoming, NkPort, Msg},
    send_work(SrvId, CallId, Work, none).


%% @doc Sends a synchronous piece of {@link nksip_call_worker:work()} to a call.
-spec send_work(nkserver:id(), nksip:call_id(), nksip_call_worker:work(), pid()) ->
    any() | {error, too_many_calls | looped_process | {exit, term()}}.

send_work(SrvId, CallId, Work, Caller) ->
    case whereis(SrvId) of
        Pid when is_pid(Pid) ->
            Name = worker_name(CallId),
            Timeout = nksip_config:get_config(sync_call_time),
            case nklib_util:call(Name, {work, SrvId, CallId, Work, Caller}, Timeout) of
                {error, {exit, {{timeout, _}, _StackTrace}}} ->
                    {error, {exit, timeout}};
                {error, {exit, Exit}} ->
                    ?LLOG(warning, "error calling send_work_sync (~p): ~p", [work_id(Work), Exit]),
                    {error, {exit, Exit}};
                Other ->
                    Other
            end;
        undefined ->
            {error, service_not_started}
    end.


%% @private
work_received(WorkerPid, CallPid, Ref) ->
    gen_server:cast(WorkerPid, {work_received, CallPid, Ref}).


%% @private
pending_work() ->
    router_fold(fun(Name, Acc) -> Acc+gen_server:call(Name, size) end, 0).


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

-type work_item() :: 
    {reference(), {pid(), term()}, nksip_call_worker:work()}.

-type call_item() ::
    {nkserver:id(), nksip:call_id(), [work_item()]}.

-record(state, {
    pos :: integer(),
    name :: atom(),
    calls = #{} :: #{CallPid::pid() => call_item()}
}).


%% @private
start_link(Pos, Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Pos, Name], []).
        
%% @private 
-spec init(term()) ->
    {ok, #state{}}.

init([Pos, Name]) ->
    {ok, #state{pos=Pos, name=Name}}.


%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.

handle_call({work, SrvId, CallId, Work, Caller}, From, State) ->
    case send_work_sync(SrvId, CallId, Work, Caller, From, State) of
        {ok, State2} when Caller==none ->
            {reply, ok, State2};
        {ok, State2} ->
            {noreply, State2};
        {error, Error} ->
            ?LLOG(error, "error sending work ~p: ~p", [Work, Error]),
            {reply, {error, Error}, State}
    end;

handle_call(size, _From, #state{calls=Calls}=State) ->
    {reply, maps:size(Calls), State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    {noreply, #state{}}.

handle_cast({work_received, CallPid, WorkRef}, #state{calls=Calls}=State) ->
    Calls2 = case maps:find(CallPid, Calls) of
        {ok, {SrvId, CallId, WorkList}} ->
            WorkList2 = lists:keydelete(WorkRef, 1, WorkList),
            maps:put(CallPid, {SrvId, CallId, WorkList2}, Calls);
        error ->
            lager:warning("Receiving sync_work_received for unknown work"),
            Calls
    end,
    {noreply, State#state{calls=Calls2}};

handle_cast(Msg, State) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    {noreply, #state{}}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}=Info, #state{calls=Calls}=State) ->
    case maps:find(Pid, Calls) of
        {ok, {SrvId, CallId, WorkList}} ->
            % We had pending work for this process.
            % Actually, we know the process has stopped normally before processing
            % these requests (it hasn't failed due to an error).
            % If the process had failed due to an error processing the work,
            % the "received work" message would have been received an the work will
            % not be present in Works.
            State2 = State#state{calls=maps:remove(Pid, Calls)},
            State3 = resend_worklist(SrvId, CallId, lists:reverse(WorkList), State2),
            {noreply, State3};
        error ->
            lager:error("NKLOG PP ~p ~p", [Pid, Calls]),


            lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
            {noreply, State}
    end;

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    {ok, #state{}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    ok.

terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private 
-spec worker_name(nksip:call_id()) ->
    atom().

worker_name(CallId) ->
    Pos = erlang:phash2(CallId) rem nksip_config:get_config(msg_routers),
    pos2name(Pos).


%% @private
-spec send_work_sync(nkserver:id(), nksip:call_id(), nksip_call_worker:work(),
                     pid() | none, {pid(), term()}, #state{}) ->
    {ok, #state{}} | {error, looped_process | service_not_found | too_many_calls}.

send_work_sync(SrvId, CallId, Work, Caller, From, State) ->
    case nksip_call_srv:find_call(SrvId, CallId) of
        Caller ->
            {error, looped_process};
        CallPid when is_pid(CallPid) ->
            do_send_work_sync(SrvId, CallId, CallPid, Work, From, State);
        undefined ->
            do_call_start(SrvId, CallId, Work, From, State)
    end.

%% @private
-spec do_send_work_sync(nkserver:id(),nksip:call_id(), pid(), nksip_call_worker:work(),
                        {pid(), term()}, #state{}) ->
    {ok, #state{}}.

do_send_work_sync(SrvId, CallId, CallPid, Work, From, #state{calls=Calls}=State) ->
    WorkRef = make_ref(),
    nksip_call_srv:sync_work(CallPid, WorkRef, self(), Work, From),
    WorkList1 = case maps:find(CallPid, Calls) of
        {ok, {SrvId, CallId, WorkList0}} ->
            WorkList0;
        {ok, {PkgId2, CallId, WorkList0}} ->
            ?LLOG(warning, "invalid stored work piece: ~p", [{SrvId, PkgId2}]),
            WorkList0;
        error ->
            []
    end,
    WorkList2 = [{WorkRef, From, Work}|WorkList1],
    Calls2 = maps:put(CallPid, {SrvId, CallId, WorkList2}, Calls),
    {ok, State#state{calls=Calls2}}.
    

%% @private
-spec do_call_start(nkserver:id(), nksip:call_id(), nksip_call_worker:work(),
                    {pid(), term()}, #state{}) ->
    {ok, #state{}} | {error, too_many_calls}.

do_call_start(SrvId, CallId, Work, From, State) ->
    Max = nksip_config:get_config(max_calls),
    case nklib_counters:value(nksip_calls) < Max of
        true ->
            Config = nksip_config:srv_config(SrvId),
            #config{max_calls=SrvMax} = Config,
            case nklib_counters:value({nksip_calls, SrvId}) < SrvMax of
                true ->
                    {ok, CallPid} = nksip_call_srv:start(SrvId, CallId),
                    CallPid = nksip_call_srv:find_call(SrvId, CallId),
                    erlang:monitor(process, CallPid),
                    do_send_work_sync(SrvId, CallId, CallPid, Work, From, State);
                false ->
                    {error, too_many_calls}
            end;
        false ->
            {error, too_many_calls}
    end.


%% @private
-spec resend_worklist(nkserver:id(), nksip:call_id(),
                      [{reference(), {pid(), term()}|none, nksip_call_worker:work()}], 
                      #state{}) ->
    #state{}.

resend_worklist(_PkgId, _CallId, [], State) ->
    State;

resend_worklist(SrvId, CallId, [{_Ref, From, Work}|Rest], State) ->
    case send_work_sync(SrvId, CallId, Work, none, From, State) of
        {ok, State1} -> 
            ?LLOG(notice, "resending work ~p from ~p", [work_id(Work), From]),
            resend_worklist(SrvId, CallId, Rest, State1);
        {error, Error} ->
            case From of
                {Pid, Ref} when is_pid(Pid), is_reference(Ref) ->
                    gen_server:reply(From, {error, Error});
                _ ->
                    ok
            end,
            resend_worklist(SrvId, CallId, Rest, State)
    end.


%% @private
work_id(Tuple) when is_tuple(Tuple) -> element(1, Tuple);
work_id(Other) -> Other.


%% @private
router_fold(Fun, Init) ->
    lists:foldl(
        fun(Pos, Acc) -> Fun(pos2name(Pos), Acc) end,
        Init,
        lists:seq(0, nksip_config:get_config(msg_routers)-1)).



%% @private
-spec pos2name(integer()) -> 
    atom().

% Ugly but speedy
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

