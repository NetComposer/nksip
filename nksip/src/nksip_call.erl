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

-export([send/1, get_cancel/2, make_dialog/3, incoming_async/1, incoming_sync/1]).
-export([get_sipmsg/1, get_fields/2, get_headers/2]).
-export([get_dialog/1, get_dialog_fields/2, get_all_dialogs/2, stop_dialog/1]).
-export([sipapp_reply/5]).
-export([call_unregister/2, pos2name/1, start_link/1, call/3, cast/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
            handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_CALLS, 1024).


%% ===================================================================
%% Private
%% ===================================================================


send(#sipmsg{sipapp_id=AppId, call_id=CallId}=Req) ->
    call_or_start(AppId, CallId, {send, Req}).

get_cancel({req, AppId, CallId, ReqId}, Opts) ->
    call(AppId, CallId, {get_cancel, ReqId, Opts}).

make_dialog(DialogSpec, Method, Opts) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            call(AppId, CallId, {make_dlg, DialogId, Method, Opts});
        undefined ->
            {error, unknown_dialog}
    end.


get_sipmsg({Type, AppId, CallId, Id}) when Type=:=req; Type=:=resp ->
    call(AppId, CallId, {get_sipmsg, Type, Id}).

get_fields({Type, AppId, CallId, Id}, Fields) when Type=:=req; Type=:=resp ->
    call(AppId, CallId, {get_fields, Type, Id, Fields}).    

get_headers({Type, AppId, CallId, Id}, Headers) when Type=:=req; Type=:=resp ->
    call(AppId, CallId, {get_headers, Id, Headers}).    


get_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} -> 
            call(AppId, CallId, {get_dialog, DialogId});
        undefined -> 
            {error, unknown_dialog}
    end.


get_dialog_fields(DialogSpec, Fields) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            call(AppId, CallId, {get_dialog_fields, DialogId, Fields});
        undefined ->
            {error, unknown_dialog}
    end.

get_all_dialogs(AppId, CallId) ->
    call(AppId, CallId, get_all_dialogs).    


stop_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            cast(AppId, CallId, {stop_dialog, DialogId});
        undefined ->
            ok
    end.


%% @private Inserts a new received message into processing queue

incoming_async(#raw_sipmsg{sipapp_id=AppId, call_id=CallId}=RawMsg) ->
    cast_or_start(AppId, CallId, {incoming, RawMsg}).

incoming_sync(#raw_sipmsg{sipapp_id=AppId, call_id=CallId}=RawMsg) ->
    call_or_start(AppId, CallId, {incoming, RawMsg}).


sipapp_reply(AppId, CallId, Fun, Id, Reply) ->
    cast(AppId, CallId, {sipapp_reply, Fun, Id, Reply}).

call_unregister(AppId, CallId) ->
    cast(AppId, CallId, call_unregister).



%% ===================================================================
%% gen_server
%% ===================================================================


-record(state, {
    id :: atom(),
    opts_dict :: dict(),
    max_calls :: integer()
}).


%% @private
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [Name], []).
        
%% @private
init([Id]) ->
    Id = ets:new(Id, [named_table, protected]),
    {ok, #state{id=Id, opts_dict=dict:new(), max_calls=?MAX_CALLS}}.


%% @private
handle_call({call_or_start, AppId, CallId, Msg}, From, SD) ->
    case do_call(AppId, CallId, Msg, From, SD) of
        ok ->
            {noreply, SD};
        not_found ->
            case do_start(AppId, CallId, SD) of
                {ok, SD1} ->
                    do_call(AppId, CallId, Msg, From, SD1),
                    {noreply, SD1};
                {error, Error} ->
                    {reply, {error, Error}, SD}
            end
    end;

handle_call({call, AppId, CallId, Msg}, From, SD) ->
    case do_call(AppId, CallId, Msg, From, SD) of
        ok -> {noreply, SD};
        not_found -> {reply, {error, call_not_found}, SD}
    end;

handle_call(Msg, _From, SD) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
handle_cast({cast_or_start, AppId, CallId, Msg}, SD) ->
    case do_cast(AppId, CallId, Msg, SD) of
        ok ->
            {noreply, SD};
        not_found ->
            case do_start(AppId, CallId, SD) of
                {ok, SD1} -> 
                    do_cast(AppId, CallId, Msg, SD1),
                    {noreply, SD1};
                {error, _Error} -> 
                    {noreply, SD}
            end
    end;


handle_cast({cast, AppId, CallId, call_unregister}, #state{id=Ets}=SD) ->
    case ets:lookup(Ets, {AppId, CallId}) of
        [{_, Pid, MRef}] ->
            gen_server:cast(Pid, {async, call_unregister}),
            erlang:demonitor(MRef),
            ets:delete(Ets, Pid), 
            ets:delete(Ets, {AppId, CallId});
        [] ->
            lager:warning("~p received unexpected call_unregister", [?MODULE])
    end,
    {noreply, SD};


handle_cast({cast, AppId, CallId, Msg}, SD) ->
    do_cast(AppId, CallId, Msg, SD),
    {noreply, SD}.


handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{id=Ets}=SD) ->
    lager:warning("~p received unexpected down from ~p: ~p", [?MODULE, Pid, Reason]),
    case ets:lookup(Ets, Pid) of
        [{Pid, Id}] ->
            ets:delete(Ets, Pid), 
            ets:delete(Ets, Id);
        [] ->
            ok
    end,
    {noreply, SD};

handle_info(Info, SD) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, SD}.


%% @private
code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% @private
terminate(_Reason, _SD) ->  
    ok.


%% ===================================================================
%% Internal
%% ===================================================================

call(AppId, CallId, Msg) ->
    gen_server:call(name(CallId), {call, AppId, CallId, Msg}, ?SRV_TIMEOUT).    

call_or_start(AppId, CallId, Msg) ->
    gen_server:call(name(CallId), {call_or_start, AppId, CallId, Msg}, ?SRV_TIMEOUT).    

cast(AppId, CallId, Msg) ->
    gen_server:cast(name(CallId), {cast, AppId, CallId, Msg}).    

cast_or_start(AppId, CallId, Msg) ->
    gen_server:cast(name(CallId), {cast_or_start, AppId, CallId, Msg}).    

name(CallId) ->
    Pos = erlang:phash2(CallId) rem ?MSG_PROCESSORS,
    pos2name(Pos).

%% @private
-spec pos2name(integer()) -> 
    atom().

pos2name(Pos) ->
    list_to_atom("nksip_call_"++integer_to_list(Pos)).



%% @private
do_call(AppId, CallId, Msg, From, #state{id=Ets}) ->
    case ets:lookup(Ets, {AppId, CallId}) of
        [{_, Pid, _MRef}] ->
            gen_server:cast(Pid, {sync, Msg, From}),
            ok;
        [] ->
            not_found
    end.

do_cast(AppId, CallId, Msg, #state{id=Ets}) ->
    case ets:lookup(Ets, {AppId, CallId}) of
        [{_, Pid, _MRef}] -> gen_server:cast(Pid, {async, Msg});
        [] -> not_found
    end.


do_start(AppId, CallId, #state{id=Ets, opts_dict=OptsDict, max_calls=Max}=SD) ->
    case do_start_check(AppId, CallId, Max) of
        ok ->
            case do_start_get_opts(AppId, OptsDict) of
                {ok, Opts, OptsDict1} ->
                    {ok, Pid} = nksip_call_srv:start(AppId, CallId, Opts),
                    MRef = erlang:monitor(process, Pid),
                    Objs = [
                        {{AppId, CallId}, Pid, MRef},
                        {Pid, {AppId, CallId}}
                    ],
                    true = ets:insert(Ets, Objs),
                    {ok, SD#state{opts_dict=OptsDict1}};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}    
    end.


do_start_check(AppId, CallId, Max) ->
    Calls = nksip_counters:value(nksip_calls),
    case Calls < Max of
        true -> 
            ok;
        false -> 
            nksip_trace:insert(AppId, CallId, max_calls),
            {error, max_calls}
    end.


do_start_get_opts(AppId, OptsDict) ->
    case dict:find(AppId, OptsDict) of
        {ok, Opts} ->
            {ok, Opts, OptsDict};
        error ->
            case nksip_sipapp_srv:get_opts(AppId) of
                {ok, Opts0} ->
                    Opts = nksip_lib:extract(Opts0, 
                                             [local_host, registrar, no_100]),
                    OptsDict1 = dict:store(AppId, Opts, OptsDict),
                    {ok, Opts, OptsDict1};
                {error, not_found} ->
                    {error, core_not_found}
            end
    end.



