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

-export([get/3, put/4, del/3]).
-export([get_module/1, get_uuid/1, get_opts/1, get_pid/1, reply/2]).
-export([get_gruu_pub/1, get_gruu_temp/1]).
-export([sipapp_call/6, sipapp_call_wait/6, sipapp_cast/5, get_app_mod/1]).
-export([register/2, get_registered/2, put_opts/2, pending_msgs/0]).
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


%% @doc Gets a value from SipApp's store
-spec get(nksip:app_id(), term(), sync|async) ->
    {ok, term()} | not_found | error.

get(AppId, Key, async) ->
    case get_app_mod(AppId) of
        error ->
            error;
        AppMod ->
            case catch ets:lookup(AppMod, Key) of
                [{_, Value}] -> {ok, Value};
                [] -> not_found;
                _ -> error
            end
    end;

get(AppId, Key, sync) ->
    case get_pid(AppId) of
        not_found -> errror;
        Pid -> gen_server:call(Pid, {'$nksip_get', Key})
    end.



%% @doc Inserts a value in SipApp's store
-spec put(nksip:app_id(), term(), term(), sync|async) ->
    ok | error.

put(AppId, Key, Value, async) ->
    case get_app_mod(AppId) of
        error -> 
            error;
        AppMod -> 
            case catch ets:insert(AppMod, {Key, Value}) of
                true -> ok;
                _ -> error
            end
    end;

put(AppId, Key, Value, sync) ->
    case get_pid(AppId) of
        not_found -> errror;
        Pid -> gen_server:call(Pid, {'$nksip_put', Key, Value})
    end.


%% @doc Deletes a value from SipApp's store
-spec del(nksip:app_id(), term(), sync|async) ->
    ok | error.

del(AppId, Key, async) ->
    case get_app_mod(AppId) of
        error -> 
            error;
        AppMod -> 
            case catch ets:delete(AppMod, Key) of
                true -> ok;
                _ -> error
            end
    end;

del(AppId, Key, sync) ->
    case get_pid(AppId) of
        not_found -> errror;
        Pid -> gen_server:call(Pid, {'$nksip_del', Key})
    end.


%% @doc Gets the SipApp's process `pid()'.
-spec get_pid(nksip:app_id()) -> 
    pid() | not_found.

get_pid(Id) ->
    case nksip_proc:whereis_name({nksip_sipapp, Id}) of
        undefined -> not_found;
        Pid -> Pid
    end.


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


%% @doc Gets SipApp's module and pid
-spec get_module(nksip:app_id()) -> 
    {ok, atom(), pid()} | {error, not_found}.

get_module(AppId) ->
    case nksip_proc:values({nksip_sipapp, AppId}) of
        [{Module, Pid}] -> {ok, Module, Pid};
        [] -> {error, not_found}
    end.
        

%% @doc Gets SipApp's module and pid
-spec get_uuid(nksip:app_id()) -> 
    {ok, binary()} | {error, not_found}.

get_uuid(AppId) ->
    case nksip_proc:values({nksip_sipapp_uuid, AppId}) of
        [{UUID, _Pid}] -> {ok, <<"<urn:uuid:", UUID/binary, ">">>};
        [] -> {error, not_found}
    end.


%% @doc Gets SipApp's module, options and pid
-spec get_opts(nksip:app_id()) -> 
    {ok, atom(), nksip_lib:optslist(), pid()} | {error, not_found}.

get_opts(AppId) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> {error, not_found};
        Pid -> gen_server:call(Pid, '$nksip_get_opts', ?SRV_TIMEOUT)
    end.


%% @doc Gets the last detected public GRUU
-spec get_gruu_pub(nksip:app_id()) ->
    undefined | nksip:uri().

get_gruu_pub(AppId) ->
    nksip_config:get({nksip_gruu_pub, AppId}).


%% @doc Gets the last detected temporary GRUU
-spec get_gruu_temp(nksip:app_id()) ->
    undefined | nksip:uri().

get_gruu_temp(AppId) ->
    nksip_config:get({nksip_gruu_temp, AppId}).


%% @private
-spec put_opts(nksip:app_id(), nksip_lib:optslist()) -> 
    ok | {error, not_found}.

put_opts(AppId, Opts) ->
    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
        undefined -> {error, not_found};
        Pid -> gen_server:call(Pid, {'$nksip_put_opts', Opts}, ?SRV_TIMEOUT)
    end.


%% @private Calls a function in the siapp's callback module.
%% Args1 are used in case of inline callback. 
%% Args2 in case of normal (with state) callback.
-spec sipapp_call(nksip:app_id(), atom(), atom(), list(), list(), nksip_from()) ->
    {reply, term()} | async | not_exported | error.

sipapp_call(AppId, Module, Fun, Args1, Args2, From) ->
    case erlang:function_exported(Module, Fun, length(Args1)+1) of
        true ->
            case catch apply(Module, Fun, Args1++[From]) of
                {'EXIT', Error} -> 
                    ?error(AppId, "Error calling inline ~p: ~p", [Fun, Error]),
                    error;
                async ->
                    async;
                Reply ->
                    {reply, Reply}
            end;     
        false ->
            case erlang:function_exported(Module, Fun, length(Args2)+2) of
                true -> 
                    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
                        undefined -> 
                            ?error(AppId, "SipApp is not available calling ~p", [Fun]),
                            error;
                        Pid -> 
                            gen_server:cast(Pid, {'$nksip_call', Fun, Args2, From}),
                            async
                    end;
                false ->
                    not_exported
            end
    end.


%% @private Calls a function in the siapp's callback module synchronously,
%% waiting for an answer. The called callback shouldn't have a 'From' parameter.
-spec sipapp_call_wait(nksip:app_id(), atom(), atom(), list(), list(), integer()) ->
    {reply, term()} | not_exported | error.

sipapp_call_wait(AppId, Module, Fun, Args1, Args2, Timeout) ->
    case erlang:function_exported(Module, Fun, length(Args1)) of
        true ->
            case catch apply(Module, Fun, Args1) of
                {'EXIT', Error} -> 
                    ?error(AppId, "Error calling inline ~p: ~p", [Fun, Error]),
                    error;
                Reply ->
                    {reply, Reply}
            end;     
        false ->
            case erlang:function_exported(Module, Fun, length(Args2)+1) of
                true -> 
                    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
                        undefined -> 
                            ?error(AppId, "SipApp is not available calling ~p", [Fun]),
                            error;
                        Pid -> 
                            Msg = {'$nksip_call_nofrom', Fun, Args2},
                            Reply = case catch 
                                gen_server:call(Pid, Msg, Timeout)
                            of
                                {'EXIT', Error} -> 
                                    ?error(AppId, "Error calling callback ~p: ~p", 
                                           [Fun, Error]),
                                    error;
                                Ok -> 
                                    Ok
                            end,
                            {reply, Reply}
                    end;
                false ->
                    not_exported
            end
    end.


%% @private Calls a function in the SipApp's callback module asynchronously
-spec sipapp_cast(nksip:app_id(), atom(), atom(), list(), list()) -> 
    ok | not_exported | error.

sipapp_cast(AppId, Module, Fun, Args1, Args2) ->
    case erlang:function_exported(Module, Fun, length(Args1)) of
        true ->
            case catch apply(Module, Fun, Args1) of
                {'EXIT', Error} -> 
                    ?error(AppId, "Error calling inline ~p: ~p", [Fun, Error]),
                    error;
                _ ->
                    ok
            end;     
        false ->
            case erlang:function_exported(Module, Fun, length(Args2)+1) of
                true -> 
                    case nksip_proc:whereis_name({nksip_sipapp, AppId}) of
                        undefined -> sipapp_not_found;
                        Pid -> gen_server:cast(Pid, {'$nksip_cast', Fun, Args2})
                    end;
                false -> 
                    not_exported
            end
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


%% @private
get_app_mod(AppId) ->
    Bin = nksip_lib:hash36(AppId),
    case catch binary_to_existing_atom(Bin, latin1) of
        {'EXIT', _} -> error;
        Atom -> Atom
    end.






%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: nksip:app_id(),
    module :: atom(),
    appmod :: atom(),
    opts :: nksip_lib:optslist(),
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
    nksip_proc:put({nksip_sipapp, AppId}, Module), 
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    RegState = nksip_sipapp_auto:init(AppId, Module, Args, Opts),
    nksip_call_router:clear_app_cache(AppId),
    AppMod = binary_to_atom(nksip_lib:hash36(AppId), latin1),
    ets:new(AppMod, [named_table, public]),
    case read_uuid(AppId) of
        {ok, UUID} ->
            ok;
        {error, Path} ->
            UUID = nksip_lib:uuid_4122(),
            save_uuid(AppId, Path, UUID)
    end,
    nksip_proc:put({nksip_sipapp_uuid, AppId}, UUID), 
    State1 = #state{
        id = AppId, 
        module = Module, 
        appmod = AppMod,
        opts = Opts, 
        procs = dict:new(),
        reg_state = RegState
    },
    case Module of
        inline ->
            {ok, State1#state{mod_state={}}};
        _ ->
            case Module:init(Args) of
                {ok, ModState} -> 
                    {ok, State1#state{mod_state=ModState}};
                {ok, ModState, Timeout} -> 
                    {ok, State1#state{mod_state=ModState}, Timeout};
                {stop, Reason} -> 
                    {stop, Reason}
            end
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
    nksip_call_router:clear_app_cache(AppId),
    {reply, ok, State#state{opts=Opts}};

handle_call({'$nksip_call_nofrom', Fun, Args}, _From, State) -> 
    mod_handle_call_nofrom(Fun, Args, State);

handle_call({'$nksip_call', Fun, Args}, From, State) ->
    mod_handle_call(Fun, Args, From, State);

handle_call({'$nksip_get', Key}, _From, #state{appmod=AppMod}=State) ->
    case ets:lookup(AppMod, Key) of
        [{_, Value}] -> {reply, {ok, Value}, State};
        [] -> {reply, not_found, State}
    end;

handle_call({'$nksip_put', Key, Value}, _From, #state{appmod=AppMod}=State) ->
    true = ets:insert(AppMod, {Key, Value}),
    {reply, ok, State};

handle_call({'$nksip_del', Key}, _From, #state{appmod=AppMod}=State) ->
    true = ets:delete(AppMod, Key),
    {reply, ok, State};

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

handle_cast({'$nksip_call', Fun, Args, From}, State) -> 
    mod_handle_call(Fun, Args, From, State);

handle_cast({'$nksip_cast', Fun, Args}, State) -> 
    mod_handle_cast(Fun, Args, State);

handle_cast(Msg, State) -> 
    case nksip_sipapp_auto:handle_cast(Msg, State#state.reg_state) of
        error -> mod_handle_cast(handle_cast, [Msg], State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({'DOWN', _Mon, process, Pid, _}=Info, #state{procs=Procs}=State) ->
    case dict:is_key(Pid, Procs) of
        true -> 
            {noreply, State#state{procs=dict:erase(Pid, Procs)}};
        false -> 
            case nksip_sipapp_auto:handle_info(Info, State#state.reg_state) of
                error -> mod_handle_info(Info, State);
                RegState1 -> {noreply, State#state{reg_state=RegState1}}
            end
    end;

handle_info({timeout, _, '$nksip_timer'}, #state{reg_state=RegState}=State) ->
    RegState1 = nksip_sipapp_auto:timer(RegState),
    erlang:start_timer(timeout(), self(), '$nksip_timer'),
    {noreply, State#state{reg_state=RegState1}};

handle_info(Info, State) ->
    case nksip_sipapp_auto:handle_info(Info, State#state.reg_state) of
        error -> 
            mod_handle_info(Info, State);
        RegState1 -> 
            {noreply, State#state{reg_state=RegState1}}
    end.


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
    {stop, term(), #state{}}.
    

mod_handle_call(Fun, Args, From, #state{module=Module, mod_state=ModState}=State) ->
    case apply(Module, Fun,  Args ++ [From, ModState]) of
        {reply, Reply, ModState1} -> 
            reply(From, Reply),
            {noreply, State#state{mod_state=ModState1}};
        {reply, Reply, ModState1, Timeout} -> 
            reply(From, Reply),
            {noreply, State#state{mod_state=ModState1}, Timeout};
        {noreply, ModState1} -> 
            {noreply, State#state{mod_state=ModState1}};
        {noreply, ModState1, Timeout} -> 
            {noreply, State#state{mod_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{mod_state=ModState1}}
    end.


%% @private
-spec mod_handle_call_nofrom(atom(), [term()], #state{}) -> 
    {reply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.

mod_handle_call_nofrom(Fun, Args, #state{module=Module, mod_state=ModState}=State) ->
    case apply(Module, Fun,  Args ++ [ModState]) of
        {reply, Reply, ModState1} -> 
            {reply, Reply, State#state{mod_state=ModState1}};
        {reply, Reply, ModState1, Timeout} -> 
            {reply, Reply, State#state{mod_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{mod_state=ModState1}}
    end.


%% @private
-spec mod_handle_cast(atom(), [term()], #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.

mod_handle_cast(Fun, Args, #state{module=Module, mod_state=ModState}=State) ->
    case apply(Module, Fun, Args++[ModState]) of
        {noreply, ModState1} -> 
            {noreply, State#state{mod_state=ModState1}};
        {noreply, ModState1, Timeout} -> 
            {noreply, State#state{mod_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{mod_state=ModState1}}
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
            case Info of
                {'EXIT', _, normal} -> ok;
                _ -> ?warning(AppId, "received unexpected message ~p", [Info])
            end,
            {noreply, State}
    end.


%% @private
read_uuid(AppId) ->
    BasePath = nksip_config:get(local_data_path),
    File = "uuid_"++integer_to_list(erlang:phash2(AppId)),
    Path = filename:join(BasePath, File),
    case file:read_file(Path) of
        {ok, Binary} ->
            case binary:split(Binary, <<$,>>) of
                [UUID|_] when byte_size(UUID)==36 -> {ok, UUID};
                _ -> {error, Path}
            end;
        _ -> 
            {error, Path}
    end.

%% @private
save_uuid(AppId, Path, UUID) ->
    Content = [UUID, $,, nksip_lib:to_binary(AppId)],
    case file:write_file(Path, Content) of
        ok ->
            ok;
        Error ->
            lager:warning("Could not write file ~s: ~p", [Path, Error]),
            ok
    end.



