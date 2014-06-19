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
-export([get_plugin_state/2, set_plugin_state/3]).
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


%% @private
get_plugin_state(Plugin, [{Plugin, PluginState}|_]) -> 
    PluginState;
get_plugin_state(Plugin, [_|Rest]) -> 
    get_plugin_state(Plugin, Rest).


%% @private
set_plugin_state(Plugin, PluginState, [{Plugin, _}|Rest]) ->
    [{Plugin, PluginState}|Rest];
set_plugin_state(Plugin, PluginState, AllState) ->
    lists:keystore(Plugin, 1, AllState, {Plugin, PluginState}).



%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    app_id :: nksip:app_id(),
    plugin_state :: list(),
    sipapp_state :: term()
}).


%% @private
start_link(AppId, Args) -> 
    gen_server:start_link({local, AppId}, ?MODULE, [AppId, Args], []).


%% @private
init([AppId, Args]) ->
    process_flag(trap_exit, true),  % Allow receiving terminate/2
    nksip_proc:put(nksip_sipapps, AppId),   
    Config = AppId:config(),
    AppName = nksip_lib:get_value(name, Config),
    nksip_proc:put({nksip_sipapp_name, AppName}, AppId), 
    update_uuid(AppId, AppName),
    {ok, PluginState} = AppId:nkcb_init(AppId, []),
    State1 = #state{app_id=AppId, plugin_state=PluginState},
    case erlang:function_exported(AppId, init, 1) andalso AppId:init(Args) of
        {ok, ModState} -> 
            {ok, State1#state{sipapp_state=ModState}};
        {ok, ModState, Timeout} -> 
            {ok, State1#state{sipapp_state=ModState}, Timeout};
        {stop, Reason} -> 
            {stop, Reason};
        false ->
            {ok, State1#state{sipapp_state=undefined}}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(Msg, From, State) ->
    #state{app_id=AppId, plugin_state=PluginState} = State,
    case AppId:nkcb_handle_call(AppId, Msg, From, PluginState) of
        continue -> 
            mod_handle_call(Msg, From, State);
        {ok, PluginState1} -> 
            {noreply, State#state{plugin_state=PluginState1}}
    end.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    #state{app_id=AppId, plugin_state=PluginState} = State,
    case AppId:nkcb_handle_cast(AppId, Msg, PluginState) of
        continue -> 
            mod_handle_cast(Msg, State);
        {ok, PluginState1} -> 
            {noreply, State#state{plugin_state=PluginState1}}
    end.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info(Msg, State) -> 
    #state{app_id=AppId, plugin_state=PluginState} = State,
    case AppId:nkcb_handle_info(AppId, Msg, PluginState) of
        continue -> 
            mod_handle_info(Msg, State);
        {ok, PluginState1} -> 
            {noreply, State#state{plugin_state=PluginState1}}
    end.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(OldVsn, #state{app_id=AppId, sipapp_state=ModState}=State, Extra) ->
    case erlang:function_exported(AppId, code_change, 3) of
        true ->
            {ok, ModState1} = AppId:code_change(OldVsn, ModState, Extra),
            {ok, State#state{sipapp_state=ModState1}};
        false -> 
            {ok, State}
    end.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(Reason, State) ->  
    #state{app_id=AppId, plugin_state=PluginState, sipapp_state=ModState} = State,
    AppId:nkcb_terminate(AppId, Reason, PluginState),
    case erlang:function_exported(AppId, terminate, 2) of
        true -> AppId:terminate(Reason, ModState);
        false -> ok
    end.
    


%% ===================================================================
%% Internal
%% ===================================================================

      

%% @private
-spec mod_handle_call(term(), from(), #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.
    

mod_handle_call(Msg, From, #state{app_id=AppId, sipapp_state=ModState}=State) ->
    case AppId:handle_call(Msg, From, ModState) of
        {reply, Reply, ModState1} -> 
            gen_server:reply(From, Reply),
            {noreply, State#state{sipapp_state=ModState1}};
        {reply, Reply, ModState1, Timeout} -> 
            gen_server:reply(From, Reply),
            {noreply, State#state{sipapp_state=ModState1}, Timeout};
        {noreply, ModState1} -> 
            {noreply, State#state{sipapp_state=ModState1}};
        {noreply, ModState1, Timeout} -> 
            {noreply, State#state{sipapp_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{sipapp_state=ModState1}}
    end.


%% @private
-spec mod_handle_cast(term(), #state{}) -> 
    {noreply, #state{}, non_neg_integer()} |
    {stop, term(), #state{}}.

mod_handle_cast(Msg, #state{app_id=AppId, sipapp_state=ModState}=State) ->
    case AppId:handle_cast(Msg, ModState) of
        {noreply, ModState1} -> 
            {noreply, State#state{sipapp_state=ModState1}};
        {noreply, ModState1, Timeout} -> 
            {noreply, State#state{sipapp_state=ModState1}, Timeout};
        {stop, Reason, ModState1} -> 
            {stop, Reason, State#state{sipapp_state=ModState1}}
    end.


%% @private
-spec mod_handle_info(term(), #state{}) ->
    {noreply, #state{}, non_neg_integer()} |
    {error, term(), #state{}}.

mod_handle_info(Info, #state{app_id=AppId, sipapp_state=ModState}=State) ->
    case erlang:function_exported(AppId, handle_info, 2) of
        true ->
            case AppId:handle_info(Info, ModState) of
                {noreply, ModState1} -> 
                    {noreply, State#state{sipapp_state=ModState1}};
                {noreply, ModState1, Timeout} -> 
                    {noreply, State#state{sipapp_state=ModState1}, Timeout};
                {stop, Reason, ModState1} -> 
                    {stop, Reason, State#state{sipapp_state=ModState1}}
            end;
        false ->
            case Info of
                {'EXIT', _, normal} -> ok;
                _ -> ?warning(AppId, <<>>, "received unexpected message ~p", [Info])
            end,
            {noreply, State}
    end.




%% @private
update_uuid(AppId, AppName) ->
    case read_uuid(AppId) of
        {ok, UUID} ->
            ok;
        {error, Path} ->
            UUID = nksip_lib:uuid_4122(),
            save_uuid(Path, AppName, UUID)
    end,
    nksip_proc:put({nksip_sipapp_uuid, AppId}, UUID).


%% @private
read_uuid(AppId) ->
    BasePath = nksip_config:get(local_data_path),
    Path = filename:join(BasePath, atom_to_list(AppId)++".uuid"),
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



