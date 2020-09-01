%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Call Server Process

-module(nksip_call_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([start/2, stop/1, sync_work/5, async_work/2]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3]).
-export([get_data/1, find_call/2, get_all/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-type call() :: nksip_call:call().

%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call process.
-spec start(nkserver:id(), nksip:call_id()) ->
    {ok, pid()}.

start(SrvId, CallId) ->
    gen_server:start(?MODULE, [SrvId, CallId], []).


%% @doc Stops a call (deleting  all associated transactions, dialogs and forks!).
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Sends a synchronous piece of {@link nksip_call_worker:work()} to the call.
%% After receiving the work, the call will send `{sync_work_received, Ref}' to `Sender'
-spec sync_work(pid(), reference(), pid(), nksip_call_worker:work(), {pid(), term()}|none) ->
    ok.

sync_work(Pid, WorkRef, Sender, Work, From) ->
    gen_server:cast(Pid, {sync_work, WorkRef, Sender, Work, From}).


%% @doc Sends an asynchronous piece of {@link nksip_call_worker:work()} to the call.
-spec async_work(pid(), nksip_call_worker:work()) ->
    ok.

async_work(Pid, Work) ->
    gen_server:cast(Pid, {async_work, Work}).


%% @private
get_data(Pid) ->
    gen_server:call(Pid, get_data).


%% @doc Find a call's pid
-spec find_call(nkserver:id(), nksip:call_id()) ->
    pid() | undefined.

find_call(SrvId, CallId) ->
  validate_process(nklib_proc:values({?MODULE, SrvId, CallId})).


%% @private Get all started calls (dangerous in production with many calls)
-spec get_all() ->
    [{nkserver:id(), nksip:call_id(), pid()}].

get_all() ->
    Fun = fun
        ({?MODULE, SrvId, CallId}, [{val, _, Pid}], Acc) ->
            [{SrvId, CallId, Pid}|Acc];
        (_Name, _Values, Acc) ->
            Acc
    end,
    nklib_proc:fold_names(Fun, []).


%% @private Validate if given Pid is alive process
-spec validate_process(pid()) ->
    pid() | undefined.

validate_process(Pid) when is_pid(Pid) ->
  case is_process_alive(Pid) of
    true ->
      Pid;
    false ->
      undefined
  end;
validate_process(_) ->
  undefined.


%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
-spec init(term()) ->
    {ok, call()}.

init([SrvId, CallId]) ->
    true = nklib_proc:reg({?MODULE, SrvId, CallId}),
    nklib_counters:async([nksip_calls, {nksip_calls, SrvId}]),
    Id = erlang:phash2(make_ref()) * 1000,
    #config{debug=DebugList, times=Times} = nksip_config:srv_config(SrvId),
    #call_times{trans=TransTime} = Times,
    Call = #call{
        srv_id = SrvId,
        srv_ref = monitor(process, whereis(SrvId)),
        call_id = CallId,
        next = Id+1,
        hibernate = false,
        trans = [],
        forks = [],
        dialogs = [],
        auths = [],
        msgs = [],
        events = [],
        times = Times
    },
    Debug = lists:member(call, DebugList),
    erlang:put(nksip_debug, Debug),
    erlang:start_timer(2000 * TransTime, self(), check_call),
    ?CALL_DEBUG("started (~p)", [self()], Call),
    {ok, Call}.


%% @private
-spec handle_call(term(), {pid(), term()}, call()) ->
    {reply, term(), call()} | {noreply, call()}.

handle_call(get_data, _From, Call) ->
    #call{trans=Trans, forks=Forks, dialogs=Dialogs} = Call,
    {reply, {Trans, Forks, Dialogs}, Call};

handle_call(Msg, _From, Call) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, Call}.


%% @private
-spec handle_cast(term(), call()) ->
    {noreply, call()} | {stop, term(), call()}.

handle_cast({sync_work, Ref, Pid, Work, From}, Call) ->
    nksip_router:work_received(Pid, self(), Ref),
    next(nksip_call_worker:work(Work, From, Call));

handle_cast({async_work, Work}, Call) ->
    next(nksip_call_worker:work(Work, none, Call));

handle_cast(stop, Call) ->
    {stop, normal, Call};

handle_cast(Msg, Call) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, Call}.


%% @private
-spec handle_info(term(), call()) ->
    {noreply, call()} | {stop, term(), call()}.

handle_info({timeout, _Ref, check_call}, Call) ->
    Call2 = nksip_call:check_call(Call),
    Timeout = 2000*(Call#call.times)#call_times.trans,
    erlang:start_timer(Timeout, self(), check_call),
    next(Call2);

handle_info({timeout, Ref, Type}, Call) ->
    next(nksip_call_worker:timeout(Type, Ref, Call));

handle_info({'DOWN', Ref, process, _Pid, _Reason}, #call{srv_ref =Ref}=Call) ->
    ?CALL_DEBUG("service stopped, stopping call", [], Call),
    {stop, normal, Call};

handle_info(Info, Call) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, Call}.


%% @private
-spec code_change(term(), call(), term()) ->
    {ok, call()}.

code_change(_OldVsn, Call, _Extra) ->
    {ok, Call}.


%% @private
-spec terminate(term(), call()) ->
    ok.

terminate(_Reason, #call{srv_id=_SrvId, call_id =_CallId}=Call) ->
    %ets:delete(nksip_ets, {SrvId, CallId}),
    ?CALL_DEBUG("stopped", [], Call).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec next(call()) ->
    {noreply, call()} | {stop, normal, call()}.

next(#call{trans=[], forks=[], dialogs=[], events=[]}=Call) ->
    case erlang:process_info(self(), message_queue_len) of
        {_, 0} ->
            {stop, normal, Call};
        _ ->
            {noreply, Call}
    end;

next(#call{hibernate=Hibernate}=Call) ->
    case Hibernate of
        false ->
            {noreply, Call};
        _ ->
            ?CALL_DEBUG("hibernating: ~p", [Hibernate], Call),
            {noreply, Call#call{hibernate=false}, hibernate}
    end.
