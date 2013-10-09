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

%% @private SipApp core process
%%
%% This module contains the actual implementation of the SipApp's core process, which is
%% a standard `gen_server'
%%

-module(nksip_sipapp_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get_opts/1, reply/2]).
-export([try_sipapp_call_sync/4, try_sipapp_call_async/5, try_sipapp_cast/4]).
-export([sipapp_call_sync/3, sipapp_call_async/4, sipapp_cast/3]).
-export([register/2, get_registered/2, put_opts/2, allowed/1, pending_msgs/0]).
-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nksip.hrl").

-define(CALLBACK_TIMEOUT, 30000).
-define(TIMER, 5000).

-type nksip_from() :: from() | {'fun', atom(), atom(), list()} | 
                      {pid, pid(), reference()}.


%% ===================================================================
%% Private
%% ===================================================================

%% @private Registers a started process with the core
-spec register(nksip:app_id(), term()) ->
    ok.

register(AppId, Type) ->
    nksip:cast(AppId, {'$nksip_register', Type, self()}).


%% @private Gets all registered processes
-spec get_registered(nksip:app_id(), term()) ->
    [pid()].

get_registered(AppId, Type) ->
    nksip:call(AppId, {'$nksip_get_registered', Type}).


%% @doc Gets SipApp's module, options and pid
-spec get_opts(nksip:app_id()) -> 
    {ok, atom(), nksip_lib:proplist(), pid()} | {error, not_found}.

get_opts(AppId) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> {error, not_found};
        Pid -> gen_server:call(Pid, '$nksip_get_opts', ?SRV_TIMEOUT)
    end.


%% @private
-spec put_opts(nksip:app_id(), nksip_lib:proplist()) -> 
    ok | {error, not_found}.

put_opts(AppId, Opts) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> {error, not_found};
        Pid -> gen_server:call(Pid, {'$nksip_put_opts', Opts}, ?SRV_TIMEOUT)
    end.


%% @private Get the allowed methods for this SipApp
-spec allowed(nksip_lib:proplist()) -> 
    binary().

allowed(AppOpts) ->
    case lists:member(registrar, AppOpts) of
        true -> <<(?ALLOW)/binary, ", REGISTER">>;
        false -> ?ALLOW
    end.


%% @private Calls to a function in the SipApp's callback module synchronously
-spec try_sipapp_call_sync(nksip:app_id(), atom(), atom(), list()) -> 
    any().

try_sipapp_call_sync(AppId, Module, Fun, Args) ->
    case erlang:function_exported(Module, Fun, length(Args)+2) of
        true -> sipapp_call_sync(AppId, Fun, Args);
        false -> not_exported
    end.


%% @private Calls to a function in the SipApp's callback module synchronously
-spec sipapp_call_sync(nksip:app_id(), atom(), list()) -> 
    any().

sipapp_call_sync(AppId, Fun, Args) ->
    Ref = make_ref(),
    From = {pid, self(), Ref},
    case sipapp_call_async(AppId, Fun, Args, From) of
        ok ->
            receive
                {Ref, Reply} -> Reply
            after 180000 ->
                {internal_error, <<"SipApp Timeout">>}  
            end;
        error ->
            {internal_error, <<"Unknown SipApp">>}
    end.


%% @private Calls to a function in the siapp's callback module asynchronously
-spec try_sipapp_call_async(nksip:app_id(), atom(), atom(), list(), nksip_from()) ->
    ok | not_found | not_exported.

try_sipapp_call_async(AppId, Module, Fun, Args, From) ->
    case erlang:function_exported(Module, Fun, length(Args)+2) of
        true -> sipapp_call_async(AppId, Fun, Args, From);
        false -> not_exported
    end.


%% @private Calls to a function in the siapp's callback module asynchronously
-spec sipapp_call_async(nksip:app_id(), atom(), list(), nksip_from()) ->
    ok | not_found. 

sipapp_call_async(AppId, Fun, Args, From) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> 
            ?error(AppId, "SipApp is not available calling ~p", [Fun]),
            not_found;
        Pid -> 
            gen_server:cast(Pid, {'$nksip_callback', Fun, Args, From})
    end.


%% @private Calls a function in the SipApp's callback module asynchronously
-spec try_sipapp_cast(nksip:app_id(), atom(), atom(), list()) -> 
    ok | not_found | not_exported.

try_sipapp_cast(AppId, Module, Fun, Args) ->
    case erlang:function_exported(Module, Fun, length(Args)+1) of
        true -> sipapp_cast(AppId, Fun, Args);
        false -> not_exported
    end.


%% @private Calls a function in the SipApp's callback module asynchronously
-spec sipapp_cast(nksip:app_id(), atom(), list()) -> 
    ok.

sipapp_cast(AppId, Fun, Args) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> not_found;
        Pid -> gen_server:cast(Pid, {'$nksip_cast', Fun, Args})
    end.


%% @private
-spec reply(nksip_from(), term()) -> 
    term().

reply({'fun', Module, Fun, Args}, Reply) ->
    apply(Module, Fun, Args++[Reply]);

reply({pid, Pid, Ref}, Reply) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {Ref, Reply};

reply(From, Reply) ->
    gen_server:reply(From, Reply).

pending_msgs() ->
    lists:map(
        fun({Name, Pid}) ->
            {_, Len} = erlang:process_info(Pid, message_queue_len),
            {Name, Len}
        end,
        nksip_proc:values(nksip_sipapps)).




%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: nksip:app_id(),
    module :: atom(),
    opts :: nksip_lib:proplist(),
    procs :: dict(),
    reg_state :: term(),
    mod_state :: term()
}).


%% @private
start_link(AppId, Module, Args, Opts) -> 
    Name = {nksip_sipapp, AppId},
    nksip_proc:start_link(server, Name, ?MODULE, [AppId, Module, Args, Opts]).
        

%% @private
init([AppId, Module, Args, Opts]) ->
    process_flag(trap_exit, true),
    nksip_proc:put(nksip_sipapps, AppId),    
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    RegState = nksip_sipapp_auto:init(AppId, Module, Args, Opts),
    nksip_call_router:remove_app_cache(AppId),
    State1 = #state{
        id = AppId, 
        module = Module, 
        opts = Opts, 
        procs = dict:new(),
        reg_state = RegState
    },
    case Module:init(Args) of
        {ok, ModState} -> {ok, State1#state{mod_state=ModState}};
        {ok, ModState, Timeout} -> {ok, State1#state{mod_state=ModState}, Timeout};
        {stop, Reason} -> {stop, Reason}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({'$nksip_get_registered', Type}, _From, #state{procs=Procs}=State) ->
    Fun = fun(Pid, T, Acc) -> 
        case Type of 
            all -> [Pid|Acc];
            T -> [Pid|Acc];
             _ -> Acc 
         end 
    end,
    {reply, dict:fold(Fun, [], Procs), State};

handle_call('$nksip_get_opts', _From, State) ->
    #state{module=Module, opts=Opts} = State,
    {reply, {ok, Module, Opts, self()}, State};

handle_call({'$nksip_put_opts', Opts}, _From, #state{id=AppId}=State) ->
    nksip_call_router:remove_app_cache(AppId),
    {reply, ok, State#state{opts=Opts}};

handle_call({'$nksip_call', Fun, Args}, From, State) ->
    mod_handle_call(Fun, Args, From, State);
    
handle_call(Msg, From, State) ->
    case nksip_sipapp_auto:handle_call(Msg, From, State#state.reg_state) of
        error -> mod_handle_call(handle_call, [Msg], From, State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({'$nksip_register', Type, Pid}, #state{procs=Procs}=State) -> 
    erlang:monitor(process, Pid),
    {noreply, State#state{procs=dict:store(Pid, Type, Procs)}};

handle_cast({'$nksip_cast', Fun, Args}, State) -> 
    mod_handle_cast(Fun, Args, State);

handle_cast({'$nksip_callback', Fun, Args, From}, State) -> 
    mod_handle_call(Fun, Args, From, State);

handle_cast(Msg, State) -> 
    case nksip_sipapp_auto:handle_cast(Msg, State#state.reg_state) of
        error -> mod_handle_cast(handle_cast, [Msg], State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({'DOWN', _Mon, process, Pid, _}=Msg, #state{procs=Procs}=State) ->
    case dict:is_key(Pid, Procs) of
        true -> {noreply, State#state{procs=dict:erase(Pid, Procs)}};
        false -> mod_handle_info(Msg, State)
    end;

handle_info({timeout, _, '$nksip_timer'}, #state{reg_state=RegState}=State) ->
    RegState1 = nksip_sipapp_auto:timer(RegState),
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    {noreply, State#state{reg_state=RegState1}};

handle_info(Info, State) ->
    mod_handle_info(Info, State).


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(OldVsn, #state{module=Module, mod_state=ModState}=State, Extra) ->
    case erlang:function_exported(Module, code_change, 3) of
        true ->
            {ok, ModState1} = Module:code_change(OldVsn, ModState, Extra),
            {ok, State#state{mod_state=ModState1}};
        false -> 
            {ok, State}
    end.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(Reason, #state{module=Module, reg_state=RegState, 
                         mod_state=ModState, procs=Procs}) ->  
    case erlang:function_exported(Module, terminate, 2) of
        true -> Module:terminate(Reason, ModState);
        false -> ok
    end,
    nksip_sipapp_auto:terminate(Reason, RegState),
    lists:foreach(fun(Pid) -> exit(Pid, normal) end, dict:fetch_keys(Procs)),
    ok.
    


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec timeout() -> integer().
timeout() ->
    nksip_config:get(nksip_sipapp_timer, ?TIMER).
        

%% @private
-spec mod_handle_call(atom(), [term()], from(), #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {error, term(), #state{}} |
    not_found.

mod_handle_call(Fun, Args, From, #state{module=Module, mod_state=ModState}=State) ->
    case apply(Module, Fun,  Args ++ [From, ModState]) of
        {reply, Reply, ModState1} -> 
            reply(From, Reply),
            Class = noreply, 
            Timeout = infinity;
        {reply, Reply, ModState1, Timeout} -> 
            reply(From, Reply),
            Class = noreply;
        {noreply, ModState1} -> 
            Class = noreply, 
            Timeout = infinity;
        {noreply, ModState1, Timeout} -> 
            Class = noreply;
        {stop, Reason, ModState1} -> 
            Class = {error, Reason}, 
            Timeout = none
    end,
    State1 = State#state{mod_state=ModState1},
    case Class of
        noreply -> {noreply, State1, Timeout};
        {error, Reason1} -> {error, Reason1, State1}
    end.


%% @private
-spec mod_handle_cast(atom(), [term()], #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {error, term(), #state{}} |
    not_found.

mod_handle_cast(Fun, Args, #state{module=Module, mod_state=ModState}=State) ->
    case apply(Module, Fun, Args++[ModState]) of
        {noreply, ModState1} -> 
            Class = noreply, 
            Timeout = infinity;
        {noreply, ModState1, Timeout} -> 
            Class = noreply;
        {stop, Reason, ModState1} -> 
            Class = {error, Reason}, 
            Timeout = none
    end,
    State1 = State#state{mod_state=ModState1},
    case Class of
        noreply -> {noreply, State1, Timeout};
        {error, Reason1} -> {error, Reason1, State1}
    end.


%% @private
-spec mod_handle_info(term(), #state{}) ->
    {noreply, #state{}, non_neg_integer()} |
    {error, term(), #state{}}.

mod_handle_info(Info, State = #state{module=Module, id=AppId}) ->
    case erlang:function_exported(Module, handle_info, 2) of
        true ->
            mod_handle_cast(handle_info, [Info], State);
        false ->
            ?warning(AppId, "received unexpected message ~p", [Info]),
            {noreply, State}
    end.
