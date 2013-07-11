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

-module(nksip_process).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([insert/1, pos2name/1, start_link/1, total/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_internal.hrl").

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


%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_process_"++integer_to_list(Pos)).


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
    queue :: queue()
}).


%% @private
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).
        
%% @private
init([]) ->
    {ok, #state{total=0, queue=queue:new()}}.


%% @private
handle_call({insert, RawMsg}, From, State) ->
    gen_server:reply(From, ok),
    {noreply, insert(RawMsg, State)};

handle_call(total, _From, #state{total=Total}=State) -> 
    {reply, {Total}, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_cast({insert, RawMsg}, State) ->
    {noreply, insert(RawMsg, State)};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
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

insert(RawMsg, #state{queue=Queue, total=Total}=State) ->
    #raw_sipmsg{sipapp_id=AppId, class=Class, call_id=CallId, transport=Transport}=RawMsg,
    #transport{proto=Proto} = Transport,
    case nksip_proc:values({nksip_process, CallId}) of
        [{_, Pid}|_] ->
            case catch gen_fsm:sync_send_all_state_event(Pid, {insert, RawMsg}, 5000) of
                ok -> 
                    ok;
                Error -> 
                    ?error(AppId, CallId, "Error ~p inserting into process", [Error])
            end,
            insert_next(State);
        [] ->
            case nksip_counters:value(nksip_msgs) of
                Msgs when Msgs > ?MAX_MSGS ->
                    case Proto of
                        udp ->
                            nksip_trace:insert(AppId, CallId, {discarded, Class}),
                            State;
                        _ ->
                            nksip_trace:insert(AppId, CallId, {queue_in, Class}),
                            Queue1 = queue:in(RawMsg, Queue),
                            State#state{total=Total+1, queue=Queue1}
                    end;
                _ ->
                    case Class of
                        {req, Method, _Binary} ->
                            {ok, Pid} = 
                                nksip_proc:start(fsm, {nksip_process, CallId}, 
                                                 nksip_process_fsm, 
                                                 [AppId, CallId, Method]),
                            gen_fsm:send_all_state_event(Pid, {req, RawMsg});
                        {resp, _Code, _Binary} ->
                            ?error(AppId, CallId, 
                                   "Process not found for response code", [])
                    end,
                    insert_next(State)
            end
    end.

insert_next(#state{total=Total, queue=Queue}=State) ->
    case queue:out(Queue) of
        {{value, RawMsg}, Queue1} ->
            #raw_sipmsg{sipapp_id=AppId, call_id=CallId, class=Class} = RawMsg,
            nksip_trace:insert(AppId, CallId, {queue_out, Class}),
            insert(RawMsg, State#state{queue=Queue1, total=Total-1});
        {empty, Queue1} ->
            State#state{queue=Queue1, total=0}
    end.
            
