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

-module(nksip_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([send/1, get_cancel/2, make_dialog/3, incoming/1, refresh/1]).
-export([pos2name/1, start_link/1, total/0]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

%% If we hace more than MAX_MSGS current running UAC or UAS processes,
%% new UDP requests will be dicarded. Other transports will be queued
%% until the number of processes goes down.
-define(MAX_MSGS, 1024).

%% ===================================================================
%% Private
%% ===================================================================


send(#sipmsg{call_id=CallId}=Req) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    gen_server:call(pos2name(Pos), {send, Req}, ?SRV_TIMEOUT).    


get_cancel(ReqId, Opts) ->
    nksip_call_srv:cancel(ReqId, Opts).

make_dialog(DialogSpec, Method, Opts) ->
    nksip_call_srv:cancel(DialogSpec, Method, Opts).    



%% @private Inserts a new received message into processing queue
-spec incoming(#raw_sipmsg{}) -> ok.

incoming(#raw_sipmsg{call_id=CallId}=RawMsg) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    gen_server:cast(pos2name(Pos), {incoming, RawMsg}).



%% @private Inserts a new received message into processing queue
-spec refresh(nksip:call_id()) -> ok.

refresh(CallId) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    gen_server:cast(pos2name(Pos), refresh).


%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_call_"++integer_to_list(Pos)).


%% @private
-spec total() ->
    {integer(), integer()}.

total() ->
    lists:foldl(
        fun(Pos, Acc) -> Acc+gen_server:call(pos2name(Pos), total) end,
        0,
        lists:seq(0, ?MSG_PROCESSORS-1)).




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
handle_call({incoming, RawMsg}, From, State) ->
    gen_server:reply(From, ok),
    {noreply, incoming(RawMsg, State)};

handle_call({send, Req}, _From, State) ->
    Reply = case catch nksip_call_srv:send(Req) of
        {ok, Id} -> {ok, Id};
        {error, Error} -> {error, Error};
        {'EXIT', Error} -> {error, Error}
    end,
    {reply, Reply, State};

handle_call(total, _From, #state{total=Total}=State) -> 
    {reply, Total, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_cast({incoming, RawMsg}, State) ->
    {noreply, incoming(RawMsg, State)};

handle_cast(refresh, State) ->
    {noreply, insert_next(State)};

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
-spec incoming(#raw_sipmsg{}, #state{}) -> 
    #state{}.

incoming(RawMsg, #state{queue=Queue, total=Total}=State) ->
    #raw_sipmsg{sipapp_id=AppId, class=Class, call_id=CallId, transport=Transport}=RawMsg,
    #transport{proto=Proto} = Transport,
    case nksip_call_srv:incoming(RawMsg) of
        ok -> 
            insert_next(State);
        {error, max_calls} ->
            case Proto of
                udp ->
                    nksip_trace:insert(AppId, CallId, {discarded, Class}),
                    State;
                _ ->
                    nksip_trace:insert(AppId, CallId, {queue_in, Class}),
                    Queue1 = queue:in(RawMsg, Queue),
                    State#state{total=Total+1, queue=Queue1}
            end;
        {error, Error} ->
            ?error(AppId, CallId, "Error ~p inserting sip message", [Error]),
            insert_next(State)
    end.


insert_next(#state{total=Total, queue=Queue}=State) ->
    case queue:out(Queue) of
        {{value, RawMsg}, Queue1} ->
            #raw_sipmsg{sipapp_id=AppId, call_id=CallId, class=Class} = RawMsg,
            nksip_trace:insert(AppId, CallId, {queue_out, Class}),
            incoming(RawMsg, State#state{queue=Queue1, total=Total-1});
        {empty, Queue1} ->
            State#state{queue=Queue1, total=0}
    end.
      








