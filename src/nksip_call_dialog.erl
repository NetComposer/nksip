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

%% @private Call dialog library module.
-module(nksip_call_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([create/3, status_update/4, target_update/5, session_update/2, timer/3]).
-export([find/2, store/2]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================

%% @private Creates a new dialog
-spec create(uac|uas|proxy, nksip:request(), nksip:response()) ->
    nksip:dialog().

create(Class, Req, Resp) ->
    #sipmsg{ruri=#uri{scheme=Scheme}} = Req,
    #sipmsg{
        app_id = AppId,
        call_id = CallId, 
        from = From, 
        to = To,
        cseq = CSeq,
        transport = #transport{proto=Proto},
        from_tag = FromTag
    } = Resp,
    DialogId = nksip_dialog:class_id(Class, Resp),
    ?debug(AppId, CallId, "Dialog ~s (~p) created", [DialogId, Class]),
    nksip_counters:async([nksip_dialogs]),
    Now = nksip_lib:timestamp(),
    Dialog = #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId, 
        created = Now,
        updated = Now,
        answered = undefined,
        status = init,
        local_target = #uri{},
        remote_target = #uri{},
        route_set = [],
        secure = Proto=:=tls andalso Scheme=:=sips,
        early = true,
        caller_tag = FromTag,
        local_sdp = undefined,
        remote_sdp = undefined,
        media_started = false,
        stop_reason = undefined,
        invite_req = undefined,
        invite_resp = undefined,
        ack_req = undefined,
        sdp_offer = undefined,
        sdp_answer = undefined
    },
    case Class of 
        uac ->
            Dialog#dialog{
                local_seq = CSeq,
                remote_seq = 0,
                local_uri = From,
                remote_uri = To
            };
        uas ->
            Dialog#dialog{
                local_seq = 0,
                remote_seq = CSeq,
                local_uri = To,
                remote_uri = From
            }
    end.


%% @private
-spec status_update(uac|uas|proxy, nksip_dialog:status(), nksip:dialog(), call()) ->
    nksip:dialog().

status_update(Class, Status, Dialog, Call) ->
    #dialog{
        id = DialogId, 
        app_id = AppId,
        call_id = CallId,
        status = OldStatus, 
        media_started = Media,
        retrans_timer = RetransTimer,
        timeout_timer = TimeoutTimer,
        invite_req = Req,
        invite_resp = Resp
    } = Dialog,
    #call{opts=#call_opts{timer_t1=T1, max_dialog_time=TDlg}} = Call,
    case OldStatus of
        init -> cast(dialog_update, start, Dialog, Call);
        _ -> ok
    end,
    cancel_timer(RetransTimer),
    cancel_timer(TimeoutTimer),
    Dialog1 = case Status of
        {stop, Reason} -> 
            cast(dialog_update, {stop, reason(Reason)}, Dialog, Call),
            Dialog#dialog{status=Status};
        _ ->
            case Status=:=OldStatus of
                true -> 
                    ok;
                false -> 
                    ?debug(AppId, CallId, "Dialog ~s ~p -> ~p", 
                           [DialogId, OldStatus, Status]),
                    cast(dialog_update, {status, Status}, Dialog, Call)
            end,
            % Testing using only a single timeout time
            Timeout = TDlg,
            % Timeout = case Status of
            %     confirmed -> TDlg;
            %     _ -> 64*T1
            % end,
            Dialog#dialog{
                status = Status, 
                retrans_timer = undefined,
                timeout_timer = start_timer(Timeout, timeout, Dialog)
            }
    end,
    Dialog2 = case Media of
        true when Status=:=bye; element(1, Status)=:=stop ->
            cast(session_update, stop, Dialog, Call),
            Dialog1#dialog{media_started=false};
        _ -> 
            Dialog1
    end,
    case Status of
        proceeding_uac ->
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            Dialog4 = route_update(Class, Req, Resp, Dialog3),
            session_update(Dialog4, Call);
        accepted_uac ->
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            Dialog4 = route_update(Class, Req, Resp, Dialog3),
            session_update(Dialog4, Call);
        proceeding_uas ->
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            Dialog4 = route_update(Class, Req, Resp, Dialog3),
            session_update(Dialog4, Call);
        accepted_uas ->    
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            Dialog4 = route_update(Class, Req, Resp, Dialog3),
            Dialog5 = session_update(Dialog4, Call),
            Dialog5#dialog{
                retrans_timer = start_timer(T1, retrans, Dialog),
                next_retrans = 2*T1
            };
        confirmed ->
            Dialog3 = session_update(Dialog2, Call),
            Dialog3#dialog{invite_req=undefined, invite_resp=undefined};
        bye ->
            Dialog2;
        {stop, StopReason} -> 
            ?debug(AppId, CallId, "Dialog ~s (~p) stopped: ~p", 
                   [DialogId, OldStatus, StopReason]),
            nksip_counters:async([{nksip_dialogs, -1}]),
            Dialog2
    end.

%% @private Performs a target update
-spec target_update(uac|uas|proxy, nksip:request(), nksip:response(),
                    nksip:dialog(), call()) ->
    nksip:dialog().

target_update(Class, Req, #sipmsg{}=Resp, Dialog, Call) ->
    #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        early = Early, 
        secure = Secure,
        answered = Answered,
        remote_target = RemoteTarget,
        local_target = LocalTarget
    } = Dialog,
    #sipmsg{contacts=ReqContacts} = Req,
    #sipmsg{class={resp, Code, _Reason}, contacts=RespContacts} = Resp,
    case Class of
        uac ->
            RemoteTargets = RespContacts,
            LocalTargets = ReqContacts;
        uas -> 
            RemoteTargets = ReqContacts,
            LocalTargets = RespContacts
    end,
    RemoteTarget1 = case RemoteTargets of
        [RT] ->
            case Secure of
                true -> RT#uri{scheme=sips};
                false -> RT
            end;
        [] ->
            ?notice(AppId, CallId, "Dialog ~s: no Contact in remote target",
                    [DialogId]),
            RemoteTarget;
        RTOther -> 
            ?notice(AppId, CallId, "Dialog ~s: invalid Contact in remote rarget: ~p",
                    [DialogId, RTOther]),
            RemoteTarget
    end,
    LocalTarget1 = case LocalTargets of
        [LT] -> LT;
        _ -> LocalTarget
    end,
    Now = nksip_lib:timestamp(),
    Early1 = Early andalso Code >= 100 andalso Code < 200,
    Answered1 = case Answered of
        undefined when Code >= 200 -> Now;
        _ -> Answered
    end,
    case RemoteTarget of
        #uri{} -> ok;
        RemoteTarget1 -> ok;
        _ -> cast(dialog_update, target_update, Dialog, Call)
    end,
    Dialog#dialog{
        updated = Now,
        answered = Answered1,
        local_target = LocalTarget1,
        remote_target = RemoteTarget1,
        early = Early1
    };

target_update(_Class, _Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private Performs a target update
-spec route_update(uac|uas|proxy, nksip:request(), nksip:response(),
                    nksip:dialog()) ->
    nksip:dialog().

route_update(Class, Req, #sipmsg{}=Resp, Dialog) ->
    #dialog{app_id=AppId, answered=Answered} = Dialog,
    case Answered of
        undefined when Class==uac ->
            RR = nksip_sipmsg:header(Resp, <<"Record-Route">>, uris),
            RouteSet = case lists:reverse(RR) of
                [] ->
                    [];
                [FirstRS|RestRS] ->
                    % If this a proxy, it has inserted Record-Route,
                    % and wants to send an in-dialog request (for example to send BYE)
                    % we must remove our own inserted Record-Route
                    case nksip_transport:is_local(AppId, FirstRS) of
                        true -> RestRS;
                        false -> [FirstRS|RestRS]
                    end
            end,
            Dialog#dialog{route_set=RouteSet};
        undefined when Class==uas ->
            RR = nksip_sipmsg:header(Req, <<"Record-Route">>, uris),
            RouteSet = case RR of
                [] ->
                    [];
                [FirstRS|RestRS] ->
                    case nksip_transport:is_local(AppId, FirstRS) of
                        true -> RestRS;
                        false -> [FirstRS|RestRS]
                    end
            end,
            Dialog#dialog{route_set=RouteSet};
        _ ->
            Dialog
    end;

route_update(_Class, _Req, _Resp, Dialog) ->
    Dialog.


% %% @private Performs a session update
-spec session_update(nksip:dialog(), call()) ->
    nksip:dialog().

session_update(
            #dialog{
                sdp_offer = {OfferParty, #sdp{}=OfferSDP},
                sdp_answer = {AnswerParty, #sdp{}=AnswerSDP},
                local_sdp = LocalSDP,
                remote_sdp = RemoteSDP,
                media_started = Started,
                invite_req = _InvReq
            } = Dialog,
            Call) ->
    {LocalSDP1, RemoteSDP1} = case OfferParty of
        local when AnswerParty==remote -> {OfferSDP, AnswerSDP};
        remote when AnswerParty==local -> {AnswerSDP, OfferSDP}
    end,
    case Started of
        false ->
            cast(session_update, {start, LocalSDP1, RemoteSDP1}, Dialog, Call);
        true ->
            case 
                nksip_sdp:is_new(RemoteSDP1, RemoteSDP) orelse
                nksip_sdp:is_new(LocalSDP1, LocalSDP) 
            of
                true -> 
                    cast(session_update, {update, LocalSDP1, RemoteSDP1}, Dialog, Call);
                false ->
                    ok
            end
    end,
    Dialog#dialog{
        local_sdp = LocalSDP1, 
        remote_sdp = RemoteSDP1, 
        media_started = true,
        sdp_offer = undefined,
        sdp_answer = undefined
    };
            
session_update(Dialog, _Call) ->
    Dialog.


%% @private Called when a dialog timer is fired
-spec timer(retrans|timeout, nksip:dialog(), call()) ->
    call().

timer(retrans, #dialog{status=accepted_uas}=Dialog, Call) ->
    #dialog{
        id = DialogId, 
        invite_resp = Resp, 
        next_retrans = Next
    } = Dialog,
    #call{opts=#call_opts{app_opts=Opts, global_id=GlobalId, timer_t2=T2}} = Call,
    case nksip_transport_uas:resend_response(Resp, GlobalId, Opts) of
        {ok, _} ->
            ?call_info("Dialog ~s resent response", [DialogId], Call),
            Dialog1 = Dialog#dialog{
                retrans_timer = start_timer(Next, retrans, Dialog),
                next_retrans = min(2*Next, T2)
            },
            store(Dialog1, Call);
        error ->
            ?call_notice("Dialog ~s could not resend response", [DialogId], Call),
            Dialog1 = status_update(uas, {stop, ack_timeout}, Dialog, Call),
            store(Dialog1, Call)
    end;
    
timer(retrans, #dialog{id=DialogId, status=Status}, Call) ->
    ?call_notice("Dialog ~s retrans timer fired in ~p", [DialogId, Status], Call),
    Call;

timer(timeout, #dialog{id=DialogId, status=Status}=Dialog, Call) ->
    ?call_notice("Dialog ~s (~p) timeout timer fired", [DialogId, Status], Call),
    Reason = case Status of
        accepted_uac -> ack_timeout;
        accepted_uas -> ack_timeout;
        _ -> timeout
    end,
    Dialog1 = status_update(uas, {stop, Reason}, Dialog, Call),
    store(Dialog1, Call).



%% ===================================================================
%% Util
%% ===================================================================

%% @private
-spec find(nksip_dialog:id(), call()) ->
    nksip:dialog() | not_found.

find(Id, #call{dialogs=Dialogs}) ->
    do_find(Id, Dialogs).


%% @private
-spec do_find(nksip_dialog:id(), [nksip:dialog()]) ->
    nksip:dialog() | not_found.

do_find(Id, [#dialog{id=Id}=Dialog|_]) ->
    Dialog;
do_find(Id, [_|Rest]) ->
    do_find(Id, Rest);
do_find(_, []) ->
    not_found.


%% @private Updates a dialog into the call
-spec store(nksip:dialog(), call()) ->
    call().

store(#dialog{id=Id}=Dialog, #call{dialogs=[#dialog{id=Id}|Rest]}=Call) ->
    case Dialog#dialog.status of
        {stop, _} -> Call#call{dialogs=Rest, hibernate=dialog_stop};
        confirmed -> Call#call{dialogs=[Dialog|Rest], hibernate=dialog_confirmed};
        _ -> Call#call{dialogs=[Dialog|Rest]}
    end;

store(#dialog{id=Id}=Dialog, #call{dialogs=Dialogs}=Call) ->
    case Dialog#dialog.status of
        {stop, _} -> 
            Dialogs1 = lists:keydelete(Id, #dialog.id, Dialogs),
            Call#call{dialogs=Dialogs1, hibernate=dialog_stop};
        confirmed ->
            Dialogs1 = lists:keystore(Id, #dialog.id, Dialogs, Dialog),
            Call#call{dialogs=Dialogs1, hibernate=dialog_confirmed};
        _ ->
            Dialogs1 = lists:keystore(Id, #dialog.id, Dialogs, Dialog),
            Call#call{dialogs=Dialogs1}
    end.


%% @private
-spec cast(atom(), term(), nksip:dialog(), call()) ->
    ok.

cast(Fun, Arg, Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    Args1 = [Dialog, Arg],
    Args2 = [DialogId, Arg],
    nksip_sipapp_srv:sipapp_cast(AppId, Module, Fun, Args1, Args2),
    ok.


%% @private
reason(486) -> busy;
reason(487) -> cancelled;
reason(503) -> service_unavailable;
reason(603) -> declined;
reason(Other) -> Other.


%% @private
cancel_timer(Ref) when is_reference(Ref) -> 
    case erlang:cancel_timer(Ref) of
        false -> receive {timeout, Ref, _} -> ok after 0 -> ok end;
        _ -> ok
    end;

cancel_timer(_) ->
    ok.


%% @private
-spec start_timer(integer(), atom(), nksip:dialog()) ->
    reference().

start_timer(Time, Tag, #dialog{id=Id}) ->
    erlang:start_timer(Time , self(), {dlg, Tag, Id}).

