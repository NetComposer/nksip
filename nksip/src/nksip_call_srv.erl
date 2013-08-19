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

%% @doc Call Server
-module(nksip_call_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([start/3, app_reply/4, next/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").







%% ===================================================================
%% Private
%% ===================================================================


start(AppId, CallId, AppOpts) ->
    gen_server:start(?MODULE, [AppId, CallId, AppOpts], []).



app_reply(Pid, Type, Id, Reply) ->
    gen_server:cast(Pid, {reply, Type, Id, Reply}).





%% ===================================================================
%% FSM
%% ===================================================================


% @private 
init([AppId, CallId, AppOpts]) ->
    nksip_counters:async([nksip_calls]),
    SD = #call{
        app_id = AppId, 
        call_id = CallId, 
        app_opts = AppOpts,
        next = erlang:phash2(make_ref()),
        uacs = [],
        uass = [],
        sipmsgs = [],
        dialogs = [],
        msg_queue = queue:new(),
        blocked = false
    },
    ?call_debug("CALL SRV started: ~p", [self()], SD),
    {ok, SD, ?SRV_TIMEOUT}.


%% @private

handle_call(get_data, _From, #call{uacs=UACs, uass=UASs, dialogs=Dialogs}=SD) ->
    {reply, {ok, UACs, UASs, Dialogs}, SD};

handle_call(Msg, _From, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


handle_cast({sync, {send, Req}, From}, #call{app_id=AppId, call_id=CallId, next=Id}=SD) ->
    gen_server:reply(From, {ok, {req, AppId, CallId, Id}}),
    nksip_call_uac:send(Req, SD);

handle_cast({sync, {incoming, RawMsg}, From}, SD) ->
    gen_server:reply(From, ok),
    incoming(RawMsg, SD);

handle_cast({async, {incoming, RawMsg}}, SD) ->
    incoming(RawMsg, SD);

handle_cast({sync, {get_cancel, Id, Opts}, From}, #call{sipmsgs=SipMsgs}=SD) ->
    case lists:keyfind(Id, 1, SipMsgs) of
        {Id, TransId} ->
            nksip_call_uac:get_cancel(TransId, Opts, From, SD);
        false ->
            gen_server:reply(From, {error, no_transaction}, SD)
    end;

handle_cast({sync, {make_dialog, Id, Method, Opts}, From}, SD) ->
    case nksip_call_dialog_uac:make(Id, Method, Opts, SD) of
        {ok, Reply, SD1} ->
            ok;
        {error, Error} ->
            Reply = {error, Error},
            SD1 = SD
    end,
    gen_server:reply(From, Reply),
    next(SD1);

handle_cast({sync, {get_sipmsg, Id}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{} = SipMsg -> {ok, SipMsg};
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_fields, Id, Fields}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{}=SipMsg -> nksip_sipmsg:fields(Fields, SipMsg);
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_headers, Id, Name}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{}=SipMsg -> nksip_sipmsg:headers(Name, SipMsg);
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_dialog, Id}, From}, SD) ->
    Reply = case get_dialog(Id, SD) of
        #dialog{}=Dialog -> {ok, Dialog};
        not_found ->  {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_dialogs_fields, Id, Fields}, From}, SD) ->
    Reply = case get_dialog(Id, SD) of
        #dialog{}=Dialog -> {ok, nksip_dialog:get_fields(Fields, Dialog)};
        not_found ->  {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, get_all_dialogs, From}, SD) ->
    #call{app_id=AppId, call_id=CallId, dialogs=Dialogs} = SD,
    Ids = [{dlg, AppId, CallId, Id} || #dialog{id=Id} <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    next(SD);

handle_cast({sync, {stop_dialog, DialogId}}, SD) ->
    #call{dialogs=Dialogs} = SD,
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        {value, Dialog, Rest} ->
            removed = nksip_call_dialog:status_update({stop, forced}, Dialog),
            next(SD#call{dialogs=Rest});
        false ->
            next(SD)
    end;

handle_cast({async, {sipapp_reply, Fun, Id, Reply}}, SD) ->
    nksip_call_uas:sipapp_reply(Fun, Id, Reply, SD);

handle_cast({async, call_unregister}, SD) ->
    {stop, normal, SD};

% handle_cast({reply, Fun, Id, Reply}, SD) ->
%     nksip_call_uas:reply(Fun, Id, Reply, SD);

handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
handle_info({timeout, _, {uac, Tag, TransId}}, #call{uacs=UACs}=SD) ->
    case lists:keyfind(TransId, #uac.trans_id, UACs) of
        #uac{}=UAC ->
            nksip_call_uac:timer(Tag, UAC, SD);
        _ ->
            ?P("IGNORING UAC TIMER ~p", [{Tag, TransId}]),
            {noreply, SD}
    end;

handle_info({timeout, _, {uas, Tag, TransId}}, #call{uass=UASs}=SD) ->
    case lists:keyfind(TransId, #uas.trans_id, UASs) of
        #uas{} = UAS ->
                nksip_call_uas:timer(Tag, UAS, SD);
        _ ->
            ?P("IGNORING UAS TIMER ~p", [{Tag, TransId}]),
            {noreply, SD}
    end;

handle_info({timeout, _, {dialog, Tag, DialogId}}, #call{dialogs=Dialogs}=SD) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        #dialog{} = Dialog ->
            nksip_call_dialog:timer(Tag, Dialog, SD);
        _ ->
            ?P("IGNORING TIMER ~p", [{dialog, Tag, DialogId}]),
            {noreply, SD}
    end;

handle_info(timeout, SD) ->
    ?call_warning("CALL SRV process timeout", [], SD),
    {stop, normal, SD};


handle_info(Info, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, FsmData}.


%% @private
code_change(_OldVsn, FsmData, _Extra) -> 
    {ok, FsmData}.


%% @private
terminate(_Reason, SD) ->
    ?call_debug("CALL SRV stopped", [], SD),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================

incoming(#raw_sipmsg{class={req, _, Binary}}=RawMsg, SD) ->
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            #raw_sipmsg{transport=#transport{proto=Proto}} = RawMsg,
            ?call_notice("could not process ~p packet: ~s", [Proto, Binary], SD),
            next(SD);
        Req ->
            nksip_call_uas:request(Req, SD)
    end;

incoming( #raw_sipmsg{class={resp, _, Binary}}=RawMsg, SD) ->
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            #raw_sipmsg{transport=#transport{proto=Proto}} = RawMsg,
            ?call_notice("could not process ~p packet: ~s", [Proto, Binary], SD),
            next(SD);
        Resp ->
            nksip_call_uac:received(Resp, SD)
    end.


% send(Pid, MsgArgs) when is_pid(Pid) ->
%     case catch gen_server:call(Pid, MsgArgs, ?SRV_TIMEOUT) of
%         {'EXIT', Error} -> {error, Error};
%         Other -> Other
%     end;

% send(Id, MsgArgs) ->
%     case nksip_proc:values(Id) of
%         [] -> {error, call_not_found};
%         [{_, Pid}|_] -> send(Pid, MsgArgs)
%     end.




next(#call{blocked=true}=SD) ->
    {noreply, SD};

next(SD) ->
    #call{
        app_id = AppId, 
        call_id = CallId, 
        msg_queue = MsgQueue, 
        uacs = UACs, 
        uass = UASs, 
        dialogs = Dialogs
    } = SD,
    case queue:out(MsgQueue) of
        {{value, {TransId, Req}}, MsgQueue1} ->
            nksip_call_uas:process(TransId, Req, SD#call{msg_queue=MsgQueue1});
        {empty, MsgQueue1} ->
            case UACs=:=[] andalso UASs=:=[] andalso Dialogs=:=[] of
                true ->
                    ?call_debug("CALL no more work", [], SD),
                    nksip_call:call_unregister(AppId, CallId),
                    {noreply, SD#call{msg_queue=MsgQueue1}, 5000};
                false ->
                    {noreply, SD#call{msg_queue=MsgQueue1}}
            end
    end.


get_sipmsg(Id, #call{sipmsgs=SipMsgs, uacs=UACs, uass=UASs}) ->
    case lists:keyfind(Id, 1, SipMsgs) of
        {Id, uac, TransId} -> 
            case lists:keyfind(TransId, #uac.trans_id, UACs) of
                #uac{request=#sipmsg{id=Id}=Req} ->
                    Req;
                #uac{responses=Resps} ->
                    case lists:keyfind(Id, #sipmsg.id, Resps) of
                        #sipmsg{} = Resp -> Resp;
                        false -> not_found
                    end;
                false ->
                    not_found
            end;
        {Id, uas, TransId} ->
            case lists:keyfind(TransId, #uas.trans_id, UASs) of
                #uas{request=#sipmsg{id=Id}=Req} ->
                    Req;
                #uas{responses=Resps} ->
                    case lists:keyfind(Id, #sipmsg.id, Resps) of
                        #sipmsg{} = Resp -> Resp;
                        false -> not_found
                    end;
                false ->
                    not_found
            end;
        false ->
            not_found
    end.

get_dialog(Id, #call{dialogs=Dialogs}) ->
    case lists:keyfind(Id, #dialog.id, Dialogs) of
        #dialog{}=Dialog -> Dialog;
        false -> not_found
    end.

