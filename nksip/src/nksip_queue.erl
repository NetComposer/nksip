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

%% @private Received messages queues

-module(nksip_queue).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([insert/1, remove/1, pos2name/1, start_link/1, total/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MSG_QUEUES, 8).

%% If we hace more than MAX_MSGS current running UAC or UAS processes,
%% new UDP requests will be dicarded. Other transports will be queued
%% until the number of processes goes down.
-define(MAX_MSGS, 1024).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Inserts a new received message into processing queue
-spec insert(#raw_sipmsg{}) -> ok.

insert(#raw_sipmsg{call_id=CallId}=RawMsg) ->
    Pos = erlang:phash2(CallId) rem ?MSG_QUEUES,
    gen_server:cast(pos2name(Pos), {insert, RawMsg}).


%% @private Removes a waiting process
-spec remove(nksip:request()) -> ok.

remove(#sipmsg{sipapp_id=AppId, call_id=CallId}) ->
    Pos = erlang:phash2(CallId) rem ?MSG_QUEUES,
    gen_server:cast(pos2name(Pos), {remove, AppId, CallId, self()}).


%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_queue_"++integer_to_list(Pos)).


%% @private
-spec total() ->
    {integer(), integer()}.

total() ->
    lists:foldl(
        fun(Pos, {Acc1, Acc2}) -> 
            {Queued, Dict} = gen_server:call(pos2name(Pos), total),
            {Acc1+Queued, Acc2+Dict}
        end,
        {0, 0}, 
        lists:seq(0, ?MSG_QUEUES-1)).




%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    total :: integer(),
    queue :: queue(),
    pending :: dict(),
    monitors :: dict()
}).


%% @private
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).
        
%% @private
init([]) ->
    {ok, 
        #state{
            total = 0, 
            queue = queue:new(), 
            pending = dict:new(), 
            monitors = dict:new()
        }
    }.


%% @private
handle_call({insert, RawMsg}, From, State) ->
    gen_server:reply(From, ok),
    {noreply, insert(RawMsg, State)};

handle_call(total, _From, #state{total=Total, pending=Pending}=State) -> 
    {reply, {Total, dict:size(Pending)}, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_cast({insert, RawMsg}, State) ->
    {noreply, insert(RawMsg, State)};

handle_cast({remove, AppId, CallId, Pid}, State) ->
    {noreply, process_exit({AppId, CallId}, Pid, State)};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_info({'DOWN', Ref, process, Pid, _Reason}, 
                #state{monitors=Monitors}=State) ->
    State1 = case dict:find(Ref, Monitors) of
        {ok, Key} ->
            Monitors1 = dict:erase(Ref, Monitors),
            process_exit(Key, Pid, State#state{monitors=Monitors1});
        error ->
            State
    end,
    {noreply, process_queue(State1)};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec insert(#raw_sipmsg{}, #state{}) -> 
    #state{}.

insert(#raw_sipmsg{sipapp_id=AppId, class=Class, transport=Transport}=RawMsg, 
        #state{total=Total, queue=Queue}=State) ->
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            ?notice(AppId, "could not process ~p packet: ~p", 
                    [Transport#transport.proto, Class]),
            State;
        #sipmsg{method=Method, transport=#transport{proto=Proto}, 
                to_tag=ToTag, opts=Opts}=SipMsg -> 
            {ok, CoreOpts} = nksip_sipapp_srv:get_opts(AppId),
            CoreOpts1 = nksip_lib:extract(CoreOpts, 
                                          [local_host, registrar, no_100]),
            SipMsg1 = SipMsg#sipmsg{opts=Opts++CoreOpts1},
            case nksip_counters:value(nksip_msgs) of
                Msgs when Msgs > ?MAX_MSGS, ToTag =:= <<>>, Method =/= 'CANCEL' ->
                    case Proto of
                        udp ->
                            nksip_trace:insert(SipMsg, {discarded, msg_sig(SipMsg1)}),
                            State;
                        _ ->
                            nksip_trace:insert(SipMsg1, {queue_in, msg_sig(SipMsg1)}),
                            Queue1 = queue:in(SipMsg1, Queue),
                            State#state{total=Total+1, queue=Queue1}
                    end;
                _ ->
                    process_sipmsg(SipMsg1, State)
            end
    end.


%% @private
-spec process_sipmsg(#sipmsg{}, #state{}) -> 
    #state{}.

process_sipmsg(#sipmsg{class=request, method='CANCEL'}=Req, State) ->
    launch(Req),
    State;

process_sipmsg(#sipmsg{class=response}=SipMsg, State) ->
    nksip_trace:insert(SipMsg, {queue_response, msg_sig(SipMsg)}), 
    nksip_uac_lib:response(SipMsg),
    State;

process_sipmsg(#sipmsg{sipapp_id=AppId, call_id=CallId}=SipMsg,
                #state{pending=Pending, monitors=Monitors}=State) ->
    Key = {AppId, CallId},
    case nksip_transaction_uas:is_retrans(SipMsg) of
        true -> 
            nksip_trace:insert(SipMsg, {is_trans, msg_sig(SipMsg)}),
            State;
        false -> 
            case dict:find(Key, Pending) of
                {ok, [{proc, Pid}|_]} ->
                    nksip_trace:insert(SipMsg, {queue_wait, msg_sig(SipMsg), Pid}),
                    Pending1 = dict:append(Key, SipMsg, Pending),
                    State#state{pending=Pending1};
                Other ->
                    Pid = launch(SipMsg),
                    Pending1 = case Other of
                        error -> dict:store(Key, [{proc, Pid}], Pending);
                        {ok, Old} -> dict:store(Key, [{proc, Pid}|Old], Pending)
                    end,
                    Monitor = erlang:monitor(process, Pid),
                    Monitors1 = dict:store(Monitor, {AppId, CallId}, Monitors),
                    State#state{pending=Pending1, monitors=Monitors1}
            end
    end.


%% @private
-spec launch(#sipmsg{}) -> 
    pid().

launch(SipMsg) ->
    Pid = proc_lib:spawn(fun() -> nksip_uas_fsm:start(SipMsg) end),
    nksip_trace:insert(SipMsg, {queue_launch, msg_sig(SipMsg), Pid}),
    Pid.



%% @private
-spec process_exit({nksip:sipapp_id(), nksip:call_id()}, pid(), #state{}) ->
    #state{}.

process_exit({AppId, CallId}=Key, Pid, #state{pending=Pending}=State) ->
    case dict:find(Key, Pending) of
        {ok, PendList} ->
            nksip_trace:insert(AppId, CallId, {queue_removed, Pid}),
            case PendList -- [{proc, Pid}] of
                [] -> 
                    State#state{pending=dict:erase(Key, Pending)};
                [{proc, _}|_] ->
                    State;
                [#sipmsg{}=SipMsg] ->
                    State1 = State#state{pending=dict:erase(Key, Pending)},
                    process_sipmsg(SipMsg, State1);
                [#sipmsg{}=SipMsg|Rest] ->
                    State1 = State#state{pending=dict:store(Key, Rest, Pending)},
                    process_sipmsg(SipMsg, State1)
            end;
        error ->
            State
    end.



%% @private
-spec process_queue(#state{}) -> 
    #state{}.

process_queue(#state{queue=Queue, total=Total}=State) ->
    case nksip_counters:value(nksip_msgs) of
        Msgs when Msgs > ?MAX_MSGS ->
            State;
        _ ->
            case queue:out(Queue) of
                {{value, SipMsg}, Queue1} ->
                    nksip_trace:insert(SipMsg, {queue_out, msg_sig(SipMsg)}),
                    State1 = State#state{queue=Queue1, total=Total-1},
                    process_sipmsg(SipMsg, State1);
                {empty, Queue1} ->
                    State#state{queue=Queue1, total=0}
            end
    end.


%% @private
msg_sig(#sipmsg{class=request, method=Method}) -> 
    {req, Method};
msg_sig(#sipmsg{class=response, response=Code, cseq_method=Method}) -> 
    {resp, Method, Code}.



