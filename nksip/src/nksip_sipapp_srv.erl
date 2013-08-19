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

-export([get_module/1, get_opts/1, reply/2]).
-export([sipapp_call_sync/3, sipapp_call_async/4, sipapp_cast/3]).
-export([register/2, get_registered/2, allowed/1]).
-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nksip.hrl").

-define(CALLBACK_TIMEOUT, 30000).

-type nksip_from() :: {reference(), pid()} | {'fun', atom(), atom(), list()}.


%% ===================================================================
%% Private
%% ===================================================================

%% @private Registers a started process with the core
-spec register(nksip:sipapp_id(), term()) ->
    ok.

register(AppId, Type) ->
    nksip:cast(AppId, {'$nksip_register', Type, self()}).


%% @private Gets all registered processes
-spec get_registered(nksip:sipapp_id(), term()) ->
    [pid()].

get_registered(AppId, Type) ->
    nksip:call(AppId, {'$nksip_get_registered', Type}).


%% @private Gets SipApp core's `pid()' and callback module
-spec get_module(nksip:sipapp_id()) -> 
    {ok, atom(), pid()} | {error, not_found}.

get_module(AppId) ->
    case nksip_proc:values({nksip_sipapp_module, AppId}) of
        [{Module, Pid}] -> {ok, Module, Pid};
        _ -> not_found
    end.


%% @private Gets SipApp's core options
-spec get_opts(nksip:sipapp_id()) -> 
    {ok, nksip_lib:proplist()} | {error, not_found}.

get_opts(Id) ->
    case nksip_proc:values({nksip_sipapp_opts, Id}) of
        [{Opts, _Pid}] -> {ok, Opts};
        _ -> {error, not_found}
    end.


%% @private Get the allowed methods for this SipApp
-spec allowed(nksip:sipapp_id()) -> 
    binary().

allowed(AppId) ->
    case get_opts(AppId) of
        {ok, Opts} ->
            case lists:member(registrar, Opts) of
                true -> <<(?ALLOW)/binary, ", REGISTER">>;
                false -> ?ALLOW
            end;
        {error, not_found} ->
            ?ALLOW
    end.


%% @private Calls to a function in the SipApp's callback module synchronously
-spec sipapp_call_sync(nksip:sipapp_id(), atom(), list()) -> 
    any().

sipapp_call_sync(AppId, Fun, Args) ->
    case get_module(AppId) of
        {ok, Module, CorePid} ->
            case erlang:function_exported(Module, Fun, length(Args)+2) of
                true ->
                    Msg = {'$nksip_call', Fun, Args},
                    case catch gen_server:call(CorePid, Msg, ?CALLBACK_TIMEOUT) of
                        {'EXIT', {shutdown, _}} ->
                            {internal_error, <<"SipApp Shutdown">>};
                        {'EXIT', Error} -> 
                            ?error(AppId, "Error calling ~p: ~p", [Fun, Error]),
                            {internal_error, <<"Error Calling SipApp">>};
                        Other -> 
                            Other
                    end;
                false -> 
                    {reply, Reply, none} = apply(nksip_sipapp, Fun, Args++[none, none]),
                    Reply
            end;
        {error, not_found} ->
            {internal_error, <<"Unknown SipApp">>}
    end.


%% @private Calls to a function in the siapp's callback module asynchronously
-spec sipapp_call_async(nksip:sipapp_id(), atom(), list(), nksip_from()) ->
    ok.

sipapp_call_async(AppId, Fun, Args, From) ->
    case get_module(AppId) of
        {ok, Module, CorePid} ->
            case erlang:function_exported(Module, Fun, length(Args)+2) of
                true -> 
                    gen_server:cast(CorePid, {'$nksip_callback', Fun, Args, From});
                false -> 
                    {reply, Reply, none} = apply(nksip_sipapp, Fun, Args++[none, none]),
                    reply(From, Reply)
            end;
        {error, not_found} ->
            reply(From, {internal_error, <<"Unknown SipApp">>})
    end.    


%% @private Calls a function in the SipApp's callback module asynchronously
-spec sipapp_cast(nksip:sipapp_id(), atom(), list()) -> 
    ok.

sipapp_cast(AppId, Fun, Args) ->
    case get_module(AppId) of
        {ok, Module, CorePid} -> 
            case erlang:function_exported(Module, Fun, length(Args)+1) of
                true -> 
                    gen_server:cast(CorePid, {'$nksip_cast', Fun, Args});
                false -> 
                    apply(nksip_sipapp, Fun, Args++[none]),
                    ok
            end;
        {error, not_found} -> 
            ok
    end.


%% @private
-spec reply(nksip_from(), term()) -> 
    term().

reply({'fun', Module, Fun, Args}, Reply) ->
    apply(Module, Fun, Args++[Reply]);

reply(From, Reply) ->
    gen_server:reply(From, Reply).





%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: nksip:sipapp_id(),
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
    nksip_proc:put({nksip_sipapp_module, AppId}, Module),
    nksip_proc:put({nksip_sipapp_opts, AppId}, Opts),
    nksip_proc:put(nksip_sipapps, AppId),    
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    RegState = nksip_sipapp_auto:init(AppId, Module, Args, Opts),
    State1 = #state{
        id=AppId, 
        module=Module, 
        opts=Opts, 
        procs=dict:new(),
        reg_state=RegState
    },
    case Module:init(Args) of
        {ok, ModState} -> {ok, State1#state{mod_state=ModState}};
        {ok, ModState, Timeout} -> {ok, State1#state{mod_state=ModState}, Timeout};
        {stop, Reason} -> {stop, Reason}
    end.


%% @private
handle_call('$nksip_sipapp_state', _From, State) ->
    {reply, State, State};

handle_call({'$nksip_get_registered', Type}, _From, #state{procs=Procs}=State) ->
    Fun = fun(Pid, T, Acc) -> 
        case Type of 
            all -> [Pid|Acc];
            T -> [Pid|Acc];
             _ -> Acc 
         end 
    end,
    {reply, dict:fold(Fun, [], Procs), State};

handle_call({'$nksip_call', Fun, Args}, From, State) ->
    mod_handle_call(Fun, Args, From, State);
    
handle_call(Msg, From, State) ->
    case nksip_sipapp_auto:handle_call(Msg, From, State#state.reg_state) of
        error -> mod_handle_call(handle_call, [Msg], From, State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private

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
handle_info({'DOWN', _Mon, process, Pid, _}=Msg, #state{procs=Procs}=State) ->
    case dict:is_key(Pid, Procs) of
        true -> {noreply, State#state{procs=dict:erase(Pid, Procs)}};
        false -> handle_info(Msg, State)
    end;

handle_info({timeout, _, '$nksip_timer'}, #state{reg_state=RegState}=State) ->
    RegState1 = nksip_sipapp_auto:timer(RegState),
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    {noreply, State#state{reg_state=RegState1}};

handle_info(Info, #state{module=Module, id=AppId}=State) -> 
    case erlang:function_exported(Module, handle_info, 2) of
        true -> 
            mod_handle_cast(handle_info, [Info], State);
        false -> 
            ?warning(AppId, "received unexpected message ~p", [Info]),
            {noreply, State}
    end.


%% @private
code_change(OldVsn, #state{module=Module, mod_state=ModState}=State, Extra) ->
    case erlang:function_exported(Module, code_change, 3) of
        true ->
            {ok, ModState1} = Module:code_change(OldVsn, ModState, Extra),
            {ok, State#state{mod_state=ModState1}};
        false -> 
            {ok, State}
    end.


%% @private
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
    case catch nksip_config:get(nksip_sipapp_timer, 5000) of
        Timeout when is_integer(Timeout) -> Timeout;
        _ -> 5000
    end.


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


