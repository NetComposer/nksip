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

%% @private Dialog Process FSM.

-module(nksip_dialog_fsm).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_fsm).

-export([total/0, total/1]).
-export([start/2, call/2, cast/2]).
-export([init/1, terminate/3, handle_event/3, handle_info/3, 
         handle_sync_event/4, code_change/4]).
-export([init/2, proceeding_uac/2, proceeding_uas/2, accepted_uac/2, accepted_uas/2, 
         confirmed/2, bye/2]).


-include("nksip.hrl").
-include("nksip_internal.hrl").

-define(REQUEST_TIMEOUT, 30000).
-define(BYE_TIMEOUT, 5000).
-define(ACCEPTED_UAS_TIMEOUT, 30000).


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets the total number of active dialogs
-spec total() -> 
    integer().

total() -> 
    nksip_counters:value(nksip_dialogs).


%% @doc Gets the total number of active dialogs for a specific SipApp
-spec total(nksip:sipapp_id()) -> 
    integer().

total(AppId) -> 
    nksip_counters:value({nksip_dialogs, AppId}).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new dialog process
-spec start(uac|uas|proxy, nksip:request() | nksip:response()) ->
    pid().

start(Class, #sipmsg{sipapp_id=AppId, call_id=CallId}=SipMsg) ->
    DialogId = nksip_dialog:id(SipMsg),
    false = (DialogId =:= <<>>),
    Name = {nksip_dialog, DialogId},
    case nksip_proc:start(fsm, Name, ?MODULE, [DialogId, Class, SipMsg]) of
        {ok, Pid} -> 
            ok;
        {error, {already_started, Pid}} -> 
            ?notice(AppId, CallId, "Dialog ~s already started", [DialogId]),
            ok = gen_fsm:sync_send_all_state_event(Pid, wait_start)
    end,
    Pid.


%% @private Sends a sync message to dialog process
-spec call(nksip_dialog:spec()|pid(), term()) -> any() | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog.

call(Pid, Msg) when is_pid(Pid) ->
    case catch gen_fsm:sync_send_all_state_event(Pid, Msg, ?REQUEST_TIMEOUT) of
        {'EXIT', {timeout, _}} -> 
            % Dialog is not going to be in sync any more
            exit(Pid, normal),
            {error, timeout_dialog};
        {'EXIT', {noproc, _}} -> 
            {error, unknown_dialog};
        {'EXIT', {shutdown, _}} -> 
            {error, terminated_dialog};
        {'EXIT', {normal, _}} -> 
            {error, terminated_dialog};
        {'EXIT', Fatal} -> 
            lager:error("Error calling nksip_dialog_fsm:call/2: ~p", [Fatal]),
            error(Fatal);
        Other -> 
            Other
    end;

call(DialogSpec, Msg) ->
    case nksip_dialog:find(DialogSpec) of
        not_found -> {error, unknown_dialog};
        Pid -> call(Pid, Msg)
    end.


%% @private Sends an async message to dialog process
-spec cast(nksip_dialog:spec()|pid(), term()) ->
    ok | {error, unknown_dialog}.

cast(Pid, Msg) when is_pid(Pid) ->
    gen_fsm:send_all_state_event(Pid, Msg);

cast(DialogSpec, Msg) ->
    case nksip_dialog:find(DialogSpec) of
        not_found -> {error, unknown_dialog};
        Pid -> cast(Pid, Msg)
    end.



%% ===================================================================
%% gen_fsm
%% ===================================================================

%% @private
init([DialogId, Class, SipMsg]) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, from=From, to=To, cseq=CSeq} = SipMsg,
    ClassStr = case Class of 
        uac -> "UAC"; 
        uas -> "UAS";
        proxy -> "Proxy" 
    end, 
    nksip_sipapp_srv:register(AppId, dialog),
    ?debug(AppId, CallId, "Dialog ~s (~s) created", [DialogId, ClassStr]),
    {Dialog0, SD0} = do_init(DialogId, SipMsg),
    Dialog = if 
        Class=:=uac; Class=:=proxy ->
            Dialog0#dialog{
                local_seq = CSeq,
                remote_seq = 0,
                local_uri = From,
                remote_uri = To
            };
        Class=:=uas ->
            Dialog0#dialog{
                local_seq = 0,
                remote_seq = CSeq,
                local_uri = To,
                remote_uri = From
            }
    end,
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, [DialogId, start]),
    {ok, init, SD0#dlg_state{dialog=Dialog}}.



%% ------------- States -----------------------

%% @private
init({timeout, _, init_timeout}, SD) ->
    {stop, init_timeout, SD}.

%% @private
-spec to_proceeding_uac(#dlg_state{}) -> #dlg_state{}.

to_proceeding_uac(#dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s switched to proceeding_uac", [DialogId]),
    cancel_timers(SD),
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, 
                                 [DialogId, {status, proceeding_uac}]),
    Timeout = 1000 * nksip_config:get(ringing_timeout),
    SD#dlg_state{timer=gen_fsm:start_timer(Timeout, proceeding)}.

%% @private
proceeding_uac({timeout, _, proceeding}, #dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, answered=Answered} = Dialog,
    ?notice(AppId, CallId, "UAC Dialog ~s did not receive INVITE response", [DialogId]),
    case Answered of
        undefined -> {stop, normal, to_stop(proceeding_timeout, SD)};
        _ -> {next_state, confirmed, to_confirmed(SD)}
    end.


%% @private 
-spec to_proceeding_uas(#dlg_state{}) -> #dlg_state{}.

to_proceeding_uas(#dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s switched to proceeding_uas", [DialogId]),
    cancel_timers(SD),
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, 
                                 [DialogId, {status, proceeding_uas}]),
    Timeout = 1000 * nksip_config:get(ringing_timeout),
    SD#dlg_state{timer=gen_fsm:start_timer(Timeout, proceeding)}.

%% @private
proceeding_uas({timeout, _, proceeding}, 
                #dlg_state{dialog=#dialog{id=DialogId, app_id=AppId, call_id=CallId, 
                                            answered=Answered}}=SD) ->
    ?notice(AppId, CallId, "UAS Dialog ~s did not receive INVITE response", [DialogId]),
    case Answered of
        undefined -> {stop, normal, to_stop(proceeding_timeout, SD)};
        _ -> {next_state, confirmed, to_confirmed(SD)}
    end.


%% @private
-spec to_accepted_uac(#dlg_state{}) -> #dlg_state{}.

to_accepted_uac(#dlg_state{dialog=Dialog, t1=T1}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s switched to accepted_uac", [DialogId]),
    cancel_timers(SD),
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, 
                                 [DialogId, {status, accepted_uac}]),
    SD#dlg_state{timer=gen_fsm:start_timer(64*T1, accepted_uac)}.

%% @private
accepted_uac({timeout, _, accepted_uac}, #dlg_state{is_first=true, dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId, "UAC Dialog ~s didn't see the ACK, stopping", [DialogId]),
    {stop, normal, to_stop(accepted_timeout, SD)};

accepted_uac({timeout, _, accepted_uac}, #dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId, 
            "UAC Dialog ~s didn't see the ACK, switched to confirmed", [DialogId]),
    {next_state, confirmed, to_confirmed(SD)}.


%% @private
-spec to_accepted_uas(#dlg_state{}) -> #dlg_state{}.

to_accepted_uas(#dlg_state{dialog=Dialog, t1=T1, t2=T2}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s switched to accepted_uas", [DialogId]),
    cancel_timers(SD),
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, 
                                 [DialogId, {status, accepted_uas}]),
    Timer1 = gen_fsm:start_timer(?ACCEPTED_UAS_TIMEOUT, accepted_uas),
    RetransTimer = gen_fsm:start_timer(T1, retrans),
    Next = min(2*T1, T2),
    SD#dlg_state{timer=Timer1, retrans_timer=RetransTimer, retrans_next=Next}.


%% @private
accepted_uas({timeout, _, accepted_uas}, #dlg_state{is_first=true, dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId, 
            "UAS Dialog ~s didn't receive the ACK, stopping", [DialogId]),
    {stop, normal, to_stop(accepted_timeout, SD)};

accepted_uas({timeout, _, accepted_uas}, #dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId,
            "UAS Dialog ~s didn't receive the ACK, switched to confirmed", [DialogId]),
    {next_state, confirmed, to_confirmed(SD)};

accepted_uas({timeout, _, retrans}, SD) ->
    #dlg_state{dialog=Dialog, is_first=IsFirst, invite_response=Resp, 
               retrans_next=Next, t2=T2} = SD,
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} -> 
            ?info(AppId, CallId, "Dialog ~s retransmitting 2xx response", [DialogId]),
            SD1 = SD#dlg_state{
                retrans_timer = gen_fsm:start_timer(Next, retrans),
                retrans_next = min(2*Next, T2)
            },
            {next_state, accepted_uas, SD1};
        error -> 
            ?notice(AppId, CallId, 
                    "Dialog ~s could not retransmit 2xx response", [DialogId]),
            case IsFirst of
                true -> {stop, normal, to_stop(service_unavailable, SD)};
                false -> {next_state, confirmed, to_confirmed(SD)}
            end
    end.


%% @private
-spec to_confirmed(#dlg_state{}) -> #dlg_state{}.

to_confirmed(#dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s switched to confirmed", [DialogId]),
    cancel_timers(SD),
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, [DialogId, {status, confirmed}]),
    Timeout = 1000 * nksip_config:get(dialog_timeout),
    SD#dlg_state{timer=gen_fsm:start_timer(Timeout, confirmed)}.    

%% @private
confirmed({timeout, _, confirmed}, #dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId, "Dialog ~s confirmed timeout", [DialogId]),
    {stop, normal, to_stop(confirmed_timeout, SD)}.


%% @private
-spec to_bye(#dlg_state{}) -> #dlg_state{}.

to_bye(#dlg_state{dialog=Dialog, started_media=StartedMedia}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    cancel_timers(SD),
    ?debug(AppId, CallId, "Dialog ~s switched to bye", [DialogId]),
    Dialog1 = Dialog#dialog{updated=nksip_lib:timestamp()},
    if 
        StartedMedia -> 
            nksip_sipapp_srv:sipapp_cast(AppId, session_update, 
                                         [DialogId, stop]);
        true -> 
            ok
    end,
    nksip_proc:del({nksip_dialog_call_id, {AppId, CallId}}),
    SD#dlg_state{
        started_media = false, 
        dialog = Dialog1,
        timer = gen_fsm:start_timer(?BYE_TIMEOUT, bye)
    }.


%% @private
bye({timeout, _, bye}, #dlg_state{dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, stop_reason=Reason} = Dialog,
    if
        Reason=:=caller_bye; Reason=:=callee_bye -> 
            ?debug(AppId, CallId, "Dialog ~s didn't receive BYE response", [DialogId]);
        true ->
            ok
    end,
    {stop, normal, SD}.


%% @private
-spec to_stop(nksip_dialog:stop_reason(), #dlg_state{}) -> #dlg_state{}.

to_stop(Reason, #dlg_state{dialog=Dialog}=SD) ->
    Dialog1 = Dialog#dialog{stop_reason=Reason},
    SD#dlg_state{dialog=Dialog1}.


%% ------------- Common -----------------------

%% @private
handle_sync_event({make, Method, Opts}, From, StateName, SD) ->
    SD1 = nksip_dialog_uac:proc_make(Method, Opts, From, StateName, SD),
    {next_state, StateName, SD1};

handle_sync_event(new_cseq, _From, StateName, 
                  #dlg_state{dialog=#dialog{local_seq=LSeq}=Dialog}=SD) ->
    SD1 = SD#dlg_state{dialog=Dialog#dialog{local_seq=LSeq+1}},
    {reply, {ok, LSeq+1}, StateName, SD1};

handle_sync_event({pre_request, CSeq}, From, StateName, SD) ->
    case nksip_dialog_uac:proc_pre_request(CSeq, From, StateName, SD) of
        {StateName, SD1} -> {next_state, StateName, SD1};
        {NewState, SD1} -> update(NewState, SD1)
    end;

handle_sync_event({pre_request_error, CSeq}, From, StateName, SD) ->
    case nksip_dialog_uac:proc_pre_request_error(CSeq, From, StateName, SD) of
        {StateName, SD1} -> {next_state, StateName, SD1};
        {NewState, SD1} -> update(NewState, SD1)
    end;

handle_sync_event({request, _Class, _}, _From, bye, SD) ->
    {reply, {error, terminated_dialog}, bye, SD};

handle_sync_event({request, uac, Req}, From, StateName, SD) ->
    case nksip_dialog_uac:proc_request(Req, From, StateName, SD) of
        {StateName, SD1} -> {next_state, StateName, SD1};
        {NewState, SD1} -> update(NewState, SD1)
    end;

handle_sync_event({request, uas, Req}, From, StateName, SD) ->
    SDR = update_remotes(Req, SD),
    case nksip_dialog_uas:proc_request(Req, From, StateName, SDR) of
        {StateName, SD1} -> {next_state, StateName, SD1};
        {NewState, SD1} -> update(NewState, SD1)
    end;

handle_sync_event({request, proxy, Req}, From, StateName, SD) ->
    gen_fsm:reply(From, ok),
    SDR = update_remotes(Req, SD),
    case nksip_dialog_proxy:proc_request(Req, StateName, SDR) of
        {StateName, SD1} -> {next_state, StateName, SD1};
        {NewState, SD1} -> update(NewState, SD1)
    end;

handle_sync_event({response, uac, #sipmsg{response=Code}=Resp}, 
                  From, StateName, SD) ->
    gen_fsm:reply(From, ok),
    SDR = update_remotes(Resp, SD),
    case nksip_dialog_uac:proc_response(Resp, StateName, SDR) of
        {_, SD1} when Code=:=408; Code=:=481 -> 
            {stop, normal, to_stop({code, Code}, SD1)};
        {StateName, SD1} -> 
            {next_state, StateName, SD1};
        {NewStateName, SD1} -> 
            update(NewStateName, SD1)
    end;

handle_sync_event({response, uas, Resp}, From, StateName, SD) ->
    gen_fsm:reply(From, ok),
    case nksip_dialog_uas:proc_response(Resp, StateName, SD) of
        {StateName, SD1} -> 
            {next_state, StateName, SD1};
        {NewStateName, SD1} ->
            update(NewStateName, SD1)
    end;

handle_sync_event({response, proxy, #sipmsg{response=Code}=Resp}, 
                  From, StateName, SD) ->
    gen_fsm:reply(From, ok),
    SDR = update_remotes(Resp, SD),
    case nksip_dialog_proxy:proc_response(Resp, StateName, SDR) of
        {_, SD1} when Code=:=408; Code=:=481 -> 
            {stop, normal, to_stop({code, Code}, SD1)};
        {StateName, SD1} -> 
            {next_state, StateName, SD1};
        {NewStateName, SD1} ->
            update(NewStateName, SD1)
    end;

handle_sync_event(get_dialog, _From, StateName, SD) ->
    #dlg_state{dialog=Dialog, timer=Timer} = SD,
    case catch round(erlang:read_timer(Timer)/1000) of
        {'EXIT', _} -> _Timeout = 0;
        _Timeout -> ok
    end,
    % Dialog1 = Dialog#dialog{state=StateName, expires=Timeout},
    Dialog1 = Dialog#dialog{state=StateName},
    {reply, Dialog1, StateName, SD};

handle_sync_event({fields, Fields}, _From, StateName, SD) ->
    #dlg_state{dialog=Dialog, timer=Timer} = SD,
    case catch round(erlang:read_timer(Timer)/1000) of
        {'EXIT', _} -> _Timeout = 0;
        _Timeout -> ok
    end,
    % Dialog1 = Dialog#dialog{state=StateName, expires=Timeout},
    Dialog1 = Dialog#dialog{state=StateName},
    {reply, nksip_dialog_lib:fields(Fields, Dialog1), StateName, SD};

handle_sync_event(wait_start, _From, StateName, SD) ->
    {reply, ok, StateName, SD};

%% Only for testing
handle_sync_event(forget_remote_ip_port, _From, StateName, SD) ->
    #dlg_state{dialog=#dialog{id=DialogId}} = SD,
    nksip_proc:del({nksip_dialog_auth, DialogId}),
    {reply, ok, StateName, SD#dlg_state{remotes=[]}};

handle_sync_event(Msg, _From, StateName, SD) ->
    lager:error("Module ~p received unexpected sync event ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_event(stop, _StateName, #dlg_state{dialog=Dialog}=SD) ->
    Dialog1 = Dialog#dialog{stop_reason=forced_stop},
    {stop, normal, SD#dlg_state{dialog=Dialog1}};

% Used to try a sync event later (see ACK in UAS)
handle_event({retry, Msg, From}, StateName, SD) ->
    handle_sync_event(Msg, From, StateName, SD);

handle_event(Msg, StateName, SD) ->
    lager:error("Module ~p received unexpected event ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_info(Info, StateName, SD) ->
    lager:warning("Module ~p received unexpected info ~p (~p)", 
        [?MODULE, Info, StateName]),
    {next_state, StateName, SD}.


%% @private
code_change(_OldVsn, StateName, SD, _Extra) -> 
    {ok, StateName, SD}.


%% @private
terminate(_Reason, _StateName, SD) ->
    #dlg_state{dialog=Dialog, started_media=StartedMedia, invite_queue=WaitInvites} = SD,
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, stop_reason=Reason} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s deleted", [DialogId]),
    lists:foreach(fun({From, _CSeq}) -> gen_fsm:reply(From, {error, terminated}) end, 
                    WaitInvites),
    if 
        StartedMedia -> 
            nksip_sipapp_srv:sipapp_cast(AppId, session_update, [DialogId, stop]);
        true -> 
            ok
    end,
    nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, [DialogId, {stop, Reason}]).


%% ===================================================================
%% Internal
%% ===================================================================

do_init(DialogId, SipMsg) ->
    #sipmsg{sipapp_id=AppId, transport=Transport, ruri=RUri, call_id=CallId, 
            headers=_Headers, from_tag=FromTag} = SipMsg,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    nksip_proc:put({nksip_dialog_call_id, {AppId, CallId}}, DialogId),
    nksip_proc:put({nksip_dialog_auth, DialogId}, [{Ip, Port}]),
    nksip_counters:async([nksip_dialogs, {nksip_dialogs, AppId}]),
    Now = nksip_lib:timestamp(),
    Dialog = #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        created = Now,
        updated = Now,
        answered = undefined,
        local_target = #uri{},
        remote_target = #uri{},
        route_set = [],
        secure = Proto =:= tls andalso RUri#uri.scheme =:= sips,
        early = true,
        local_sdp = undefined,
        remote_sdp = undefined,
        stop_reason = unknown
        % opts = case Headers of [] -> []; _ -> [{headers, Headers}] end
    },
    SD = #dlg_state{
        dialog = Dialog,
        from_tag = FromTag,
        proto = Proto,
        invite_request = undefined,
        invite_response = undefined,
        is_first = true,
        started_media = false,
        remotes = [{Ip, Port}],
        timer = gen_fsm:start_timer(5000, init_timeout),
        t1 = nksip_config:get(timer_t1),
        t2 = nksip_config:get(timer_t2),
        invite_queue = []
    },
    {Dialog, SD}.


%% @private
-spec update(nksip_dialog:state(), #dlg_state{}) ->
    {next_state, #dlg_state{}} | {stop, normal, #dlg_state{}}.

update(proceeding_uac, SD) -> 
    {next_state, proceeding_uac, to_proceeding_uac(SD)};
update(proceeding_uas, SD) ->
    {next_state, proceeding_uas, to_proceeding_uas(SD)};
update(accepted_uac, SD) ->
    {next_state, accepted_uac, to_accepted_uac(SD)};
update(accepted_uas, SD)    ->
    {next_state, accepted_uas, to_accepted_uas(SD)};
update(confirmed, #dlg_state{invite_queue=[{From1, CSeq1}|Rest]}=SD) ->
    SD1 = to_confirmed(SD#dlg_state{invite_queue=Rest}),
    handle_sync_event({pre_request, CSeq1}, From1, confirmed, SD1);
update(confirmed, SD) ->
    {next_state, confirmed, to_confirmed(SD), hibernate};
update(bye, SD) ->
    {next_state, bye, to_bye(SD), hibernate};
update(stop, SD) ->
    {stop, normal, SD}.


%% @private
-spec update_remotes(#sipmsg{}, #dlg_state{}) ->
    #dlg_state{}.

update_remotes(SipMsg, #dlg_state{dialog=#dialog{id=DialogId}, remotes=Remotes}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, transport=Transport} = SipMsg,
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    case lists:member({Ip, Port}, Remotes) of
        true ->
            SD;
        false ->
            Remotes1 = [{Ip, Port}|Remotes],
            ?debug(AppId, CallId, "dialog ~s updated remotes: ~p", 
                   [DialogId, Remotes1]),
            nksip_proc:put({nksip_dialog_auth, DialogId}, Remotes1),
            SD#dlg_state{remotes=Remotes1}
    end.

%% @private
-spec cancel_timers(#dlg_state{}) -> ok.

cancel_timers(#dlg_state{timer=Timer, retrans_timer=Retrans}) ->
    case is_reference(Timer) of
        true -> gen_fsm:cancel_timer(Timer);
        false -> ok
    end,
    case is_reference(Retrans) of
        true -> gen_fsm:cancel_timer(Retrans);
        false -> ok
    end.




