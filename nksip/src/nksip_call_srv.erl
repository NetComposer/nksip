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

-define(MSG_KEEP_TIME, 30).   % Time to keep removed sip msgs in memory


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
        msg_keep_time = nksip_lib:get_integer(msg_keep_time, AppOpts, ?MSG_KEEP_TIME),
        next = erlang:phash2(make_ref()),
        trans = [],
        msgs = [],
        dialogs = [],
        msg_queue = queue:new(),
        blocked = false
    },
    ?call_debug("Call process started: ~p", [self()], SD),
    {ok, SD, ?SRV_TIMEOUT}.


%% @private

handle_call(Msg, _From, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
handle_cast({do_check, Now}, #call{dialogs=Dialogs}=SD) ->
    lists:foreach(
        fun(#dialog{id=DialogId, timeout=Timeout}) ->
            case is_integer(Timeout) andalso Timeout=<Now of
                true -> self() ! {timeout, none, {dialog, timeout, DialogId}};
                false -> ok
            end
        end,
        Dialogs),
    SD1 = nksip_call_lib:check(Now, SD),
    next(SD1);

handle_cast({sync, {send, Req}, From}, #call{app_id=AppId, call_id=CallId, next=Id}=SD) ->
    gen_server:reply(From, {ok, {req, AppId, CallId, Id}}),
    nksip_call_uac:send(Req, SD);

handle_cast({sync, {incoming, RawMsg}, From}, SD) ->
    gen_server:reply(From, ok),
    incoming(RawMsg, SD);

handle_cast({async, {incoming, RawMsg}}, SD) ->
    incoming(RawMsg, SD);

handle_cast({sync, {get_cancel, ReqId, Opts}, From}, #call{msgs=Msgs}=SD) ->
    case lists:keyfind(ReqId, #msg.msg_id, Msgs) of
        #msg{msg_class=req, trans_class=uac, trans_id=TransId} ->
            nksip_call_uac:get_cancel(TransId, Opts, From, SD);
        _ ->
            gen_server:reply(From, {error, no_transaction}, SD)
    end;

handle_cast({sync, {make_dialog, Id, Method, Opts}, From}, SD) ->
    nksip_call_uac:make_dialog(Id, Method, Opts, From, SD);

handle_cast({sync, {get_sipmsg, Id}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{} = SipMsg -> {ok, SipMsg};
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_fields, Id, Fields}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{}=SipMsg -> {ok, nksip_sipmsg:fields(Fields, SipMsg)};
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_headers, Id, Name}, From}, SD) ->
    Reply = case get_sipmsg(Id, SD) of
        #sipmsg{}=SipMsg -> {ok, nksip_sipmsg:headers(Name, SipMsg)};
        not_found -> {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_dialog, Id}, From}, SD) ->
    Reply = case get_dialog(Id, SD) of
        #dialog{}=Dialog -> 
            {ok, 
                Dialog#dialog{
                    request = undefined, 
                    response = undefined, 
                    ack = undefined,
                    retrans_timer = undefined
                }
            };
        not_found ->  
            {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, {get_dialog_fields, DialogId, Fields}, From}, SD) ->
    Reply = case get_dialog(DialogId, SD) of
        #dialog{}=Dialog -> {ok, nksip_dialog:get_fields(Fields, Dialog)};
        not_found ->  {error, not_found}
    end,
    gen_server:reply(From, Reply),
    next(SD);

handle_cast({sync, get_sipmsgs, From}, SD) ->
    #call{app_id=AppId, call_id=CallId, msgs=Msgs} = SD,
    Ids = [
        case Class of
            req -> {{req, AppId, CallId, Id}, Expire};
            resp -> {{resp, AppId, CallId, Id}, Expire}
        end
        || #msg{msg_id=Id, msg_class=Class, expire=Expire} <- Msgs
    ],
    gen_server:reply(From, {ok, Ids}),
    next(SD);

handle_cast({sync, get_dialogs, From}, SD) ->
    #call{app_id=AppId, call_id=CallId, dialogs=Dialogs} = SD,
    Ids = [{{dlg, AppId, CallId, Id}, Expire} 
           || #dialog{id=Id, timeout=Expire} <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    next(SD);

handle_cast({async, {stop_dialog, DialogId}}, SD) ->
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

handle_cast({sync, get_data, From}, #call{trans=Trans, dialogs=Dialogs}=SD) ->
    gen_server:reply(From, {ok, Trans, Dialogs}),
    next(SD);

handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.



handle_info({timeout, _, {Class, Tag, TransId}}, #call{trans=Trans}=SD) ->
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=Class}=UAC when Class=:=uac ->
            nksip_call_uac:timer(Tag, UAC, SD);
        #trans{class=Class}=UAS when Class=:=uas ->
            nksip_call_uac:timer(Tag, UAS, SD);
        _ ->
            ?call_warning("UAC ignoring timer (~p, ~p)", [Tag, TransId], SD),
            next(SD)
    end;

handle_info({timeout, _, {dialog, Tag, DialogId}}, #call{dialogs=Dialogs}=SD) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        #dialog{} = Dialog ->
            Dialogs1 = nksip_call_dialog:timer(Tag, Dialog, Dialogs),
            next(SD#call{dialogs=Dialogs1});
        _ ->
            ?call_warning("Dialog ignoring timer (~p, ~p)", [Tag, DialogId], SD),
            next(SD)
    end;

handle_info(timeout, SD) ->
    ?call_warning("Call process timeout", [], SD),
    {stop, normal, SD};


handle_info(Info, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, FsmData}.


%% @private
code_change(_OldVsn, FsmData, _Extra) -> 
    {ok, FsmData}.


%% @private
terminate(_Reason, SD) ->
    ?call_debug("Call process stopped", [], SD),
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


next(#call{blocked=true}=SD) ->
    {noreply, SD};

next(SD) ->
    #call{
        app_id = AppId, 
        call_id = CallId, 
        msg_queue = MsgQueue, 
        trans = Trans,
        dialogs = Dialogs
    } = SD,
    case queue:out(MsgQueue) of
        {{value, {TransId, Req}}, MsgQueue1} ->
            nksip_call_uas:process(TransId, Req, SD#call{msg_queue=MsgQueue1});
        {empty, MsgQueue1} ->
            case Trans=:=[] andalso Dialogs=:=[] of
                true ->
                    nksip_call_proxy:call_unregister(AppId, CallId),
                    {noreply, SD#call{msg_queue=MsgQueue1}, 5000};
                false ->
                    {noreply, SD#call{msg_queue=MsgQueue1}}
            end
    end.


get_sipmsg(Id, #call{msgs=Msgs, trans=Trans}) ->
    case lists:keyfind(Id, #msg.msg_id, Msgs) of
        #msg{msg_class=Class, trans_id=TransId} ->
            case lists:keyfind(TransId, #trans.trans_id, Trans) of
                #trans{request=#sipmsg{id=Id}=Req} when Class=:=req->
                    Req;
                #trans{responses=Resps} when Class=:=resp ->
                    case lists:keyfind(Id, #sipmsg.id, Resps) of
                        #sipmsg{} = Resp -> Resp;
                        false -> not_found
                    end;
                _ ->
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

