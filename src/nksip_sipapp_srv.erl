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
%% This module contains the actual implementation of the SipApp's core process

-module(nksip_sipapp_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([get/2, put/3, put_new/3, del/2]).
-export([get_appid/1, get_name/1, config/1, pending_msgs/0]).
-export([start_link/2, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Private
%% ===================================================================


%% @doc Gets a value from SipApp's store
-spec get(nksip:app_id(), term()) ->
    {ok, term()} | undefined | {error, term()}.

get(AppId, Key) ->
    case catch ets:lookup(AppId, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> undefined;
        _ -> {error, ets_error}
    end.


%% @doc Inserts a value in SipApp's store
-spec put(nksip:app_id(), term(), term()) ->
    ok | {error, term()}.

put(AppId, Key, Value) ->
    case catch ets:insert(AppId, {Key, Value}) of
        true -> ok;
        _ -> {error, ets_error}
    end.


%% @doc Deletes a value from SipApp's store
-spec del(nksip:app_id(), term()) ->
    ok | {error, term()}.

del(AppId, Key) ->
    case catch ets:delete(AppId, Key) of
        true -> ok;
        _ -> {error, ets_error}
    end.


%% @doc Inserts a value in SipApp's store
-spec put_new(nksip:app_id(), term(), term()) ->
    true | false | {error, term()}.

put_new(AppId, Key, Value) ->
    case catch ets:insert_new(AppId, {Key, Value}) of
        true -> true;
        false -> false;
        _ -> {error, ets_error}
    end.


%% @doc Generates a internal name (an atom()) for any term
-spec get_appid(nksip:app_name()) ->
    nksip:app_id().

get_appid(AppName) ->
    list_to_atom(
        string:to_lower(
            case binary_to_list(nksip_lib:hash36(AppName)) of
                [F|Rest] when F>=$0, F=<$9 -> [$A+F-$0|Rest];
                Other -> Other
            end)).


%% @doc Finds the internal name corresponding to any user name
-spec get_name(nksip:app_id()) ->
    nksip:app_name().

get_name(AppId) ->
    AppId:name().


%% @doc Gets the sipapp's configuration
-spec config(nksip:app_id()) ->
    nksip:optslist().

config(AppId) ->
    AppId:config().


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
    app_id :: nksip:app_id(),
    reg_state :: term(),
    mod_state :: term()
}).


%% @private
start_link(AppId, Args) -> 
    gen_server:start_link({local, AppId}, ?MODULE, [AppId, Args], []).


%% @private
init([AppId, Args]) ->
    % process_flag(trap_exit, true),
    nksip_proc:put(nksip_sipapps, AppId),   
    Config = AppId:config(),
    AppName = nksip_lib:get_value(name, Config),
    nksip_proc:put({nksip_sipapp_name, AppName}, AppId), 
    RegState = nksip_sipapp_auto:init(AppId, Args),
    case read_uuid(AppId) of
        {ok, UUID} ->
            ok;
        {error, Path} ->
            UUID = nksip_lib:uuid_4122(),
            save_uuid(Path, AppName, UUID)
    end,
    nksip_proc:put({nksip_sipapp_uuid, AppId}, UUID), 
    Timer = 1000 * nksip_lib:get_value(sipapp_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_timer'),
    State1 = #state{app_id=AppId, reg_state=RegState},
    case erlang:function_exported(AppId, init, 1) andalso AppId:init(Args) of
        {ok, ModState} -> 
            {ok, State1#state{mod_state=ModState}};
        {ok, ModState, Timeout} -> 
            {ok, State1#state{mod_state=ModState}, Timeout};
        {stop, Reason} -> 
            {stop, Reason};
        false ->
            {ok, State1#state{mod_state=undefined}}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(Msg, From, State) ->
    case nksip_sipapp_auto:handle_call(Msg, From, State#state.reg_state) of
        error -> mod_handle_call(handle_call, [Msg], From, State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    case nksip_sipapp_auto:handle_cast(Msg, State#state.reg_state) of
        error -> mod_handle_cast(handle_cast, [Msg], State);
        RegState1 -> {noreply, State#state{reg_state=RegState1}}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({timeout, _, '$nksip_timer'}, State) ->
    #state{app_id=AppId, reg_state = RegState} = State,
    RegState1 = nksip_sipapp_auto:timer(RegState),
    Config = AppId:config(),
    Timer = 1000 * nksip_lib:get_value(sipapp_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_timer'),
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

code_change(OldVsn, #state{app_id=AppId, mod_state=ModState}=State, Extra) ->
    case erlang:function_exported(AppId, code_change, 3) of
        true ->
            {ok, ModState1} = AppId:code_change(OldVsn, ModState, Extra),
            {ok, State#state{mod_state=ModState1}};
        false -> 
            {ok, State}
    end.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(Reason, #state{app_id=AppId, reg_state=RegState, mod_state=ModState}) ->  
    case erlang:function_exported(AppId, terminate, 2) of
        true -> AppId:terminate(Reason, ModState);
        false -> ok
    end,
    nksip_sipapp_auto:terminate(Reason, RegState),
    ok.
    


%% ===================================================================
%% Internal
%% ===================================================================

      

%% @private
-spec mod_handle_call(atom(), [term()], from(), #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.
    

mod_handle_call(Fun, Args, From, #state{app_id=AppId, mod_state=ModState}=State) ->
    case apply(AppId, Fun,  Args ++ [From, ModState]) of
        {reply, Reply, ModState1} -> 
            gen_server:reply(From, Reply),
            {noreply, State#state{mod_state=ModState1}};
        {reply, Reply, ModState1, Timeout} -> 
            gen_server:reply(From, Reply),
            {noreply, State#state{mod_state=ModState1}, Timeout};
        {noreply, ModState1} -> 
            {noreply, State#state{mod_state=ModState1}};
        {noreply, ModState1, Timeout} -> 
            {noreply, State#state{mod_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{mod_state=ModState1}}
    end.


%% @private
-spec mod_handle_cast(atom(), [term()], #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.

mod_handle_cast(Fun, Args, #state{app_id=AppId, mod_state=ModState}=State) ->
    case apply(AppId, Fun, Args++[ModState]) of
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

mod_handle_info(Info, State = #state{app_id=AppId}) ->
    case erlang:function_exported(AppId, handle_info, 2) of
        true ->
            mod_handle_cast(handle_info, [Info], State);
        false ->
            case Info of
                {'EXIT', _, normal} -> ok;
                _ -> ?warning(AppId, <<>>, "received unexpected message ~p", [Info])
            end,
            {noreply, State}
    end.


%% @private
read_uuid(AppId) ->
    BasePath = nksip_config:get(local_data_path),
    Path = filename:join(BasePath, "uuid_"++atom_to_list(AppId)),
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
save_uuid(Path, AppId, UUID) ->
    Content = [UUID, $,, nksip_lib:to_binary(AppId)],
    case file:write_file(Path, Content) of
        ok ->
            ok;
        Error ->
            lager:warning("Could not write file ~s: ~p", [Path, Error]),
            ok
    end.



