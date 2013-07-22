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

-export([provisional_reply/2, send/1, make_dialog/3, get_cancel/2]).
-export([incoming/1, app_reply/4, next/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================

provisional_reply({req, AppId, CallId, Pos}, Reply) ->
    case nksip_proc:values({nksip_call, AppId, CallId}) of
        [{_, Pid}|_] -> app_reply(Pid, process, Pos, Reply);
        [] -> ok
    end.


send(#sipmsg{sipapp_id=AppId, call_id=CallId, method=Method}=Req) ->
    send_or_start(uac, AppId, CallId, Method, {send, Req}).


make_dialog(DialogSpec, Method, Opts) ->
    DialogId = nksip_dialog:id(DialogSpec),
    send({nksip_dialog, DialogId}, {make_dialog, DialogId, Method, Opts}).


get_cancel(ReqId, Opts) ->
    send({nksip_trans, ReqId}, {get_cancel, ReqId, Opts}).
        

incoming(#raw_sipmsg{sipapp_id=AppId, call_id=CallId, class={req, Method, _}}=RawMsg) ->
    send_or_start(uas, AppId, CallId, Method, {incoming, RawMsg});

incoming(#raw_sipmsg{sipapp_id=AppId, call_id=CallId, class={resp, _Code, _}}=RawMsg) ->
    send({nksip_call, AppId, CallId}, {incoming, RawMsg}).



app_reply(Pid, Type, Pos, Reply) ->
    gen_server:cast(Pid, {reply, Type, Pos, Reply}).






%% ===================================================================
%% FSM
%% ===================================================================


% @private 
init({Class, AppId, CallId, Method}) ->
    ?debug(AppId, CallId, "CALL ~p started for ~p: ~p", [Class, Method, self()]),
    nksip_counters:async([nksip_call]),
    {Module, Pid} = nksip_sipapp_srv:get_module(AppId),
    AppOpts0 = nksip_sipapp_srv:get_opts(AppId),
    AppOpts = nksip_lib:extract(AppOpts0, [local_host, registrar, no_100]),
    SD = #call{
        app_id = AppId, 
        call_id = CallId, 
        module = Module, 
        app_pid = Pid,
        app_opts = AppOpts,
        uass = [],
        dialogs = [],
        msg_queue = queue:new(),
        blocked = false
    },
    {ok, SD, ?SRV_TIMEOUT}.


%% @private
handle_call({send, #sipmsg{}=Req}, From, SD) ->
    UAC = nksip_call_uac:get_uac(Req),
    gen_server:reply(From, {ok, UAC#uac.id}),
    nksip_call_uac:send(UAC, SD);

handle_call({get_cancel, Id, Opts}, From, SD) ->
    nksip_call_uac:get_cancel(Id, Opts, From, SD);

handle_call({make_dialog, Id, Method, Opts}, _From, SD) ->
    nksip_call_uac:make_dialog(Id, Method, Opts, SD);

handle_call({incoming, #raw_sipmsg{class={req, _, Binary}}=RawMsg}, From, SD) ->
    #call{app_id=AppId, call_id=CallId} = SD,
    gen_server:reply(From, ok),
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            #raw_sipmsg{transport=#transport{proto=Proto}} = RawMsg,
            ?notice(AppId, CallId, "could not process ~p packet: ~s", [Proto, Binary]),
            next(SD);
        Req ->
            nksip_call_uas:request(Req, SD)
    end;

handle_call({incoming, #raw_sipmsg{class={resp, _, Binary}}=RawMsg}, From, SD) ->
    #call{app_id=AppId, call_id=CallId} = SD,
    gen_server:reply(From, ok),
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            #raw_sipmsg{transport=#transport{proto=Proto}} = RawMsg,
            ?notice(AppId, CallId, "could not process ~p packet: ~s", [Proto, Binary]),
            next(SD);
        Resp ->
            nksip_call_uac:received(Resp, SD)
    end;


handle_call({get_sipmsg, Pos}, _From, SD) ->
    {reply, get_request(Pos, SD), SD};

handle_call({get_fields, Pos, Fields}, _From, SD) ->
    Reply = case get_request(Pos, SD) of
        {ok, Req} -> nksip_sipmsg:fields(Fields, Req);
        Error -> Error
    end,
    {reply, Reply, SD};

handle_call({get_headers, Pos, Name}, _From, SD) ->
    Reply = case get_request(Pos, SD) of
        {ok, Req} -> nksip_sipmsg:headers(Name, Req);
        Error -> Error
    end,
    {reply, Reply, SD};

handle_call(Msg, _From, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


handle_cast({reply, Fun, Pos, Reply}, SD) ->
    #call{app_id=AppId, call_id=CallId, uass=Trans} = SD,
    case lists:keytake(Pos, #uas.pos, Trans) of
        {value, #uas{call_status=CallStatus}=UAS, RestTrans} ->
            SD1 = SD#call{uass=[UAS|RestTrans]},
            case Fun of
                authorize when CallStatus=:=authorize -> 
                    nksip_call_uas:authorize({reply, Reply}, SD1);
                route when CallStatus=:=route -> 
                    nksip_call_uas:route({reply, Reply}, SD1);
                process when CallStatus=:=process; CallStatus=:=cancel -> 
                    nksip_call_uas:process({reply, Reply}, SD1);
                cancel when CallStatus=:=cancel ->
                    nksip_call_uas:cancel({reply, Reply}, SD1);
                _ ->
                    ?warning(AppId, CallId, 
                             "CALL (~p) received unexpected app reply ~p, ~p, ~p",
                             [CallStatus, Fun, Pos, Reply]),
                    {noreply, SD}

            end;
        false ->
            ?warning(AppId, CallId, "CALL received unexpected app reply ~p, ~p, ~p",
                     [Fun, Pos, Reply]),
            {noreply, SD}
    end;


handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private
handle_info({timeout, _, {uac, Tag, Id}}, #call{uacs=Trans}=SD) ->
    case lists:keytake(Id, #uac.id, Trans) of
        {value, UAC, Rest} ->
                nksip_call_uac:timer(Tag, SD#call{uacs=[UAC|Rest]});
        _ ->
            ?P("IGNORING UAC TIMER ~p", [{Tag, Id}]),
            {noreply, SD}
    end;

handle_info({timeout, _, {uas, Tag, Id}}, #call{uass=Trans}=SD) ->
    case lists:keytake(Id, #uas.id, Trans) of
        {value, UAS, Rest} ->
                nksip_call_uas:timer(Tag, SD#call{uass=[UAS|Rest]});
        _ ->
            ?P("IGNORING UAS TIMER ~p", [{Tag, Id}]),
            {noreply, SD}
    end;

handle_info({timeout, _, {dialog, Tag, DialogId}}, #call{dialogs=Dialogs}=SD) ->
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        {value, Dialog, Rest} ->
            nksip_call_uas:timer_dialog(Tag, SD#call{dialogs=[Dialog|Rest]});
        _ ->
            ?P("IGNORING TIMER ~p", [{dialog, Tag, DialogId}]),
            {noreply, SD}
    end;

handle_info(Info, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, FsmData}.


%% @private
code_change(_OldVsn, FsmData, _Extra) -> 
    {ok, FsmData}.


%% @private
terminate(_Reason, #call{app_id=AppId, call_id=CallId}) ->
    nksip_call:refresh(CallId),
    ?debug(AppId, CallId, "CALL stopped", []),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================


send(Pid, MsgArgs) when is_pid(Pid) ->
    case catch gen_server:call(Pid, MsgArgs, ?SRV_TIMEOUT) of
        {'EXIT', Error} -> {error, Error};
        Other -> Other
    end;

send(Id, MsgArgs) ->
    case nksip_proc:values(Id) of
        [] -> {error, call_not_found};
        [{_, Pid}|_] -> send(Pid, MsgArgs)
    end.


send_or_start(Class, AppId, CallId, Method, MsgArgs) ->
    StartArgs = {Class, AppId, CallId, Method},
    case nksip_proc:values({nksip_call, AppId, CallId}) of
        [] ->
            MaxCalls = nksip_config:get(max_calls),
            case nksip_counters:value(nksip_call) of
                Calls when Calls > MaxCalls -> 
                    {error, max_calls};
                _ ->
                    {ok, Pid} = nksip_proc:start(server, {nksip_call, AppId, CallId}, 
                                                 ?MODULE, StartArgs),
                    case catch gen_server:call(Pid, MsgArgs, ?SRV_TIMEOUT) of
                        {'EXIT', Error} -> {error, Error};
                        Other -> Other
                    end
            end;
        [{_, Pid}|_] ->
            case catch gen_server:call(Pid, MsgArgs, ?SRV_TIMEOUT) of
                {'EXIT', _} ->
                    timer:sleep(100),
                    {ok, Pid} = nksip_proc:start(server, {nksip_call, AppId, CallId}, 
                                                 ?MODULE, StartArgs),
                    case catch gen_server:call(Pid, MsgArgs, ?SRV_TIMEOUT) of
                        {'EXIT', Error} -> {error, Error};
                        Other -> Other
                    end;
                Other ->
                    Other
            end
    end.


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
                    ?debug(AppId, CallId, "CALL no more work", []),
                    {stop, normal, SD};
                _ -> 
                    {noreply, SD#call{msg_queue=MsgQueue1}}
            end
    end.

get_request(Pos, #call{uass=UASList}) ->
    case lists:keyfind(Pos, #uas.pos, UASList) of
        #uas{request=Req} -> {ok, Req};
        _ -> {error, not_found}
    end.


