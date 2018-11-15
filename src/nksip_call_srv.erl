%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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
-export([get_data/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-type call() :: nksip_call:call().

%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call process.
-spec start(nksip:srv_id(), nksip:call_id()) ->
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

sync_work(Pid, Ref, Sender, Work, From) ->
    gen_server:cast(Pid, {sync_work, Ref, Sender, Work, From}).


%% @doc Sends an asynchronous piece of {@link nksip_call_worker:work()} to the call.
-spec async_work(pid(), nksip_call_worker:work()) ->
    ok.

async_work(Pid, Work) ->
    gen_server:cast(Pid, {async_work, Work}).


%% @private
get_data(Pid) ->
    gen_server:call(Pid, get_data).
 

%% ===================================================================
%% gen_server
%% ===================================================================


%% @private 
-spec init(term()) ->
    {ok, call()}.

init([SrvId, CallId]) ->
    nklib_counters:async([nksip_calls, {nksip_calls, SrvId}]),
    Id = erlang:phash2(make_ref()) * 1000,
    #call_times{trans=TransTime} = Times = ?GET_CONFIG(SrvId, times),
    Call = #call{
        srv_id = SrvId, 
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
    nksip_util:put_log_cache(SrvId, CallId),
    erlang:start_timer(2000 * TransTime, self(), check_call),
    ?call_debug("call process ~p started (~p)", [Id, self()]),
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
    Pid ! {sync_work_received, Ref, self()},
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
    Call1 = nksip_call:check_call(Call),
    Timeout = 2000*(Call#call.times)#call_times.trans,
    erlang:start_timer(Timeout, self(), check_call),
    next(Call1);

handle_info({timeout, Ref, Type}, Call) ->
    next(nksip_call_worker:timeout(Type, Ref, Call));

% handle_info({'DOWN', _Ref, process, Pid, _Reason}=Info, #call{srv_id=SrvId}=Call) ->
%     case whereis(SrvId) of
%         undefined ->
%             lager:warning("Srv ~p down1", [SrvId]),
%             {stop, normal, Call};
%         Pid ->
%             lager:warning("Srv ~p down2", [SrvId]),
%             {stop, normal, Call};
%         _ ->
%             lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
%             next(Call)
%     end;

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

terminate(_Reason, #call{}) ->
    ?call_debug("call process stopped", []).



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
            ?call_debug("call hibernating: ~p", [Hibernate]),
            {noreply, Call#call{hibernate=false}, hibernate}
    end.







