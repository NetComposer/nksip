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

-export([create/4, invite_update/3, event_update/4, stop/3]).
-export([find/2, store/2, find_event/2, timer/3]).
-export_type([sdp_offer/0]).

-type sdp_offer() ::
    {local|remote, invite|prack|update|ack, nksip_sdp:sdp()} | undefined.


%% ===================================================================
%% Private
%% ===================================================================

%% @private Creates a new dialog
-spec create(uac|uas, nksip:request(), nksip:response(), nksip_call:call()) ->
    nksip:dialog().

create(Class, Req, Resp, Call) ->
    #sipmsg{ruri=#uri{scheme=Scheme}} = Req,
    #sipmsg{
        app_id = AppId,
        call_id = CallId, 
        dialog_id = DialogId,
        from = From, 
        to = To,
        cseq = CSeq,
        transport = #transport{proto=Proto},
        from_tag = FromTag
    } = Resp,
    ?debug(AppId, CallId, "Dialog ~s (~p) created", [DialogId, Class]),
    nksip_counters:async([nksip_dialogs]),
    Now = nksip_lib:timestamp(),
    Dialog = #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId, 
        created = Now,
        updated = Now,
        local_target = #uri{},
        remote_target = #uri{},
        route_set = [],
        secure = Proto==tls andalso Scheme==sips,
        early = true,
        caller_tag = FromTag,
        invite = undefined,
        events = []
    },
    cast(dialog_update, start, Dialog, Call),
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
-spec invite_update(nksip_dialog:invite_status(), nksip:dialog(), nksip:call()) ->
    nksip:dialog().

invite_update(prack, Dialog, Call) ->
    session_update(Dialog, Call);

invite_update({update, Class, Req, Resp}, #dialog{invite=Invite}=Dialog, Call) ->
    #call{opts=#call_opts{max_dialog_time=Timeout}} = Call,
    Invite1 = Invite#dialog_invite{
        timeout_timer = start_timer(Timeout, timeout, Dialog)
    },
    Dialog1 = Dialog#dialog{invite=Invite1},
    Dialog2 = target_update(Class, Req, Resp, Dialog1, Call),
    session_update(Dialog2, Call);

invite_update({stop, Reason}, #dialog{invite=Invite}=Dialog, Call) ->
    cast(dialog_update, {invite_status, {stop, reason(Reason)}}, Dialog, Call),
    case Invite#dialog_invite.media_started of
        true -> cast(session_update, stop, Dialog, Call);
        _ ->ok
    end,
    Dialog#dialog{invite=undefined};

invite_update(Status, Dialog, Call) ->
    #dialog{
        id = DialogId, 
        app_id = AppId,
        call_id = CallId,
        invite = #dialog_invite{
            status = OldStatus, 
            media_started = Media,
            retrans_timer = RetransTimer,
            timeout_timer = TimeoutTimer,
            class = Class,
            request = Req, 
            response = Resp, 
            answered = Answered
        } = Invite
    } = Dialog,
    #call{opts=#call_opts{timer_t1=T1, max_dialog_time=Timeout}} = Call,
    cancel_timer(RetransTimer),
    cancel_timer(TimeoutTimer),
    ?debug(AppId, CallId, "Dialog ~s ~p -> ~p", [DialogId, OldStatus, Status]),
    case Status of
        OldStatus -> ok;
        _ -> cast(dialog_update, {invite_status, Status}, Dialog, Call)
    end,
    Invite1 = Invite#dialog_invite{
        status = Status,
        retrans_timer = undefined,
        timeout_timer = start_timer(Timeout, invite_timeout, Dialog)
    },
    case Status of
        _ when Status==proceeding_uac; Status==accepted_uac; Status==proceeding_uas ->
            Dialog1 = Dialog#dialog{invite=Invite1},
            Dialog2 = route_update(Class, Req, Resp, is_integer(Answered), Dialog1),
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            session_update(Dialog3, Call);
        accepted_uas ->    
            Invite2 = Invite1#dialog_invite{
                retrans_timer = start_timer(T1, invite_retrans, Dialog),
                next_retrans = 2*T1
            },
            Dialog1 = Dialog#dialog{invite=Invite2},
            Dialog2 = route_update(Class, Req, Resp, is_integer(Answered), Dialog1),
            Dialog3 = target_update(Class, Req, Resp, Dialog2, Call),
            session_update(Dialog3, Call);
        confirmed ->
            Invite2 = Invite1#dialog_invite{
                class = undefined,
                request = undefined, 
                response = undefined
            },
            
            session_update(Dialog#dialog{invite=Invite2}, Call);
        bye ->
            case Media of
                true -> cast(session_update, stop, Dialog, Call);
                _ -> ok
            end,
            Dialog#dialog{invite=Invite1#dialog_invite{media_started=false}}
    end.


%% @private Performs a target update
-spec target_update(uac|uas, nksip:request(), nksip:response(), 
                    nksip:dialog(), nksip:call()) ->
    nksip:dialog().

target_update(Class, Req, Resp, Dialog, Call) ->
    #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        early = Early, 
        secure = Secure,
        remote_target = RemoteTarget,
        local_target = LocalTarget,
        invite = Invite
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
    case RemoteTarget of
        #uri{domain = <<"invalid.invalid">>} -> ok;
        RemoteTarget1 -> ok;
        _ -> cast(dialog_update, target_update, Dialog, Call)
    end,
    Invite1 = case Invite of
        #dialog_invite{answered=InvAnswered, class=InvClass, request=InvReq} ->
            InvAnswered1 = case InvAnswered of
                undefined when Code >= 200 -> Now;
                _ -> InvAnswered
            end,
            % If we are updating the remote target inside an uncompleted INVITE UAS
            % transaction, update original INVITE so that, when the final
            % response is sent, we don't use the old remote target but the new one.
            InvReq1 = case InvClass of
                uas ->
                    case InvReq of
                        #sipmsg{contacts=[RemoteTarget1]} -> InvReq; 
                        #sipmsg{} -> InvReq#sipmsg{contacts=[RemoteTarget1]}
                    end;
                uac ->
                    case InvReq of
                        #sipmsg{contacts=[LocalTarget1]} -> InvReq; 
                        #sipmsg{} -> InvReq#sipmsg{contacts=[LocalTarget1]}
                    end
            end,
            Invite#dialog_invite{answered=InvAnswered1, request=InvReq1};
        undefined ->
            undefined
    end,
    Dialog#dialog{
        updated = Now,
        local_target = LocalTarget1,
        remote_target = RemoteTarget1,
        early = Early1,
        invite = Invite1
    }.


%% @private
-spec route_update(uac|uas, nksip:request(), nksip:response(), boolean(), 
                   nksip:dialog()) ->
    nksip:dialog().

route_update(Class, Req, Resp, Answered, Dialog) ->
    #dialog{app_id=AppId} = Dialog,
    case Answered of
        false when Class==uac ->
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
        false when Class==uas ->
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
        true ->
            Dialog
    end.


% %% @private Performs a session update
-spec session_update(nksip:dialog(), nksip:call()) ->
    nksip:dialog().

session_update(
            #dialog{
                invite = #dialog_invite{
                    sdp_offer = {OfferParty, _, #sdp{}=OfferSDP},
                    sdp_answer = {AnswerParty, _, #sdp{}=AnswerSDP},
                    local_sdp = LocalSDP,
                    remote_sdp = RemoteSDP,
                    media_started = Started
                } = Invite
            } = Dialog,
            Call) ->
    {LocalSDP1, RemoteSDP1} = case OfferParty of
        local when AnswerParty==remote -> {OfferSDP, AnswerSDP};
        remote when AnswerParty==local -> {AnswerSDP, OfferSDP}
    end,
    case Started of
        true ->
            case 
                nksip_sdp:is_new(RemoteSDP1, RemoteSDP) orelse
                nksip_sdp:is_new(LocalSDP1, LocalSDP) 
            of
                true -> 
                    cast(session_update, {update, LocalSDP1, RemoteSDP1}, Dialog, Call);
                false ->
                    ok
            end;
        _ ->
            cast(session_update, {start, LocalSDP1, RemoteSDP1}, Dialog, Call)
    end,
    Invite1 = Invite#dialog_invite{
        local_sdp = LocalSDP1, 
        remote_sdp = RemoteSDP1, 
        media_started = true,
        sdp_offer = undefined,
        sdp_answer = undefined
    },
    Dialog#dialog{invite=Invite1};
            
session_update(Dialog, _Call) ->
    Dialog.


%% @private
-spec event_update(nksip_dialog:event_status(), #dialog_event{}, 
                          nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

event_update(Status, Event, Dialog, Call) ->
    #dialog_event{
        id = EventId, 
        status = OldStatus,
        class = Class,
        answered = Answered,
        request = Req,
        response = Resp,
        expires = Expires,
        timer = OldTimer
    } = Event,
    #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
    cancel_timer(OldTimer),
    case Status==OldStatus of
        true -> 
            ok;
        false -> 
            ?debug(AppId, CallId, "Dialog ~s event ~p ~p -> ~p", 
                   [DialogId, EventId, OldStatus, Status]),
            Notice = {event_status, Status, nksip_unparse:event(EventId)},
            cast(dialog_update, Notice, Dialog, Call)
    end,
    case Status of
        neutral ->
            #call{opts=#call_opts{timer_t1=T1}} = Call,
            Event1 = Event#dialog_event{
                status = neutral,
                timer = start_timer(64*T1, {event_timeout, EventId}, Dialog)
            },
            Dialog1 = route_update(Class, Req, Resp, is_integer(Answered), Dialog),
            Dialog2 = target_update(Class, Req, Resp, Dialog1, Call),
            store_event(Event1, Dialog2, Call);
        _ when Status==active; Status==pending ->
            Answered1 = case Answered of
                undefined -> nksip_lib:timestamp();
                _ -> Answered
            end,
            Event1 = Event#dialog_event{
                status = Status,
                answered = Answered1,
                timer = start_timer(1000*Expires, {event_timeout, EventId}, Dialog)
            },
            Dialog1 = route_update(Class, Req, Resp, is_integer(Answered), Dialog),
            Dialog2 = target_update(Class, Req, Resp, Dialog1, Call),
            store_event(Event1, Dialog2, Call);
        {terminated, Reason} ->
            ?debug(AppId, CallId, "Dialog ~s subs ~p (~p) stopped: ~p", 
                   [DialogId, EventId, OldStatus, Reason]),
            Event1 = Event#dialog_event{status=Status},
            store_event(Event1, Dialog, Call);
        _ ->
            event_update({terminated, Status}, Event, Dialog, Call)
    end.


%% @private Fully stops a dialog
-spec stop(term(), nksip:dialog(), nksip_call:call()) ->
    nksip:dialog(). 

stop(Reason, #dialog{events=Events}=Dialog, Call) ->
    Dialog1 = lists:foldl(
        fun(Event, D) -> event_update({terminated, noresource}, Event, D, Call) end,
        Dialog,
        Events),
    invite_update({stop, reason(Reason)}, Dialog1, Call).


%% @private Called when a dialog timer is fired
-spec timer(invite_retrans | invite_timeout, nksip:dialog(), nksip:call()) ->
    nksip:call().

timer(invite_retrans, #dialog{id=DialogId, invite=Invite}=Dialog, Call) ->
    #call{opts=#call_opts{app_opts=Opts, global_id=GlobalId, timer_t2=T2}} = Call,
    case Invite of
        #dialog_invite{status=Status, response=Resp, next_retrans=Next} ->
            case Status of
                accepted_uas ->
                    case nksip_transport_uas:resend_response(Resp, GlobalId, Opts) of
                        {ok, _} ->
                            ?call_info("Dialog ~s resent response", [DialogId], Call),
                            Invite1 = Invite#dialog_invite{
                                retrans_timer = start_timer(Next, invite_retrans, Dialog),
                                next_retrans = min(2*Next, T2)
                            },
                            store(Dialog#dialog{invite=Invite1}, Call);
                        error ->
                            ?call_notice("Dialog ~s could not resend response", 
                                         [DialogId], Call),
                            Dialog1 = invite_update({stop, ack_timeout}, Dialog, Call),
                            store(Dialog1, Call)
                    end;
                _ ->
                    ?call_notice("Dialog ~s retrans timer fired in ~p", 
                                [DialogId, Status], Call),
                    Call
            end;
        _ ->
            ?call_notice("Dialog ~s retrans timer fired with no INVITE", 
                         [DialogId], Call),
            Call
    end;

timer(invite_timeout, #dialog{id=DialogId, invite=Invite}=Dialog, Call) ->
    case Invite of
        #dialog_invite{status=Status} ->
            ?call_notice("Dialog ~s (~p) timeout timer fired", 
                         [DialogId, Status], Call),
            Reason = case Status of
                accepted_uac -> ack_timeout;
                accepted_uas -> ack_timeout;
                _ -> timeout
            end,
            Dialog1 = invite_update({stop, Reason}, Dialog, Call),
            store(Dialog1, Call);
        _ ->
            ?call_notice("Dialog ~s unknown INVITE timeout timer", 
                         [DialogId], Call),
            Call
    end;

timer({event_timeout, EventId}, #dialog{id=DialogId}=Dialog, Call) ->
    case find_event(EventId, Dialog) of
        #dialog_event{} = Event ->
            Dialog1 = event_update({terminated, timeout}, Event, Dialog, Call),
            store(Dialog1, Call);
        not_found ->
            ?call_notice("Dialog ~s unknown EVENT ~p timeout timer", 
                         [DialogId, EventId], Call),
            Call
    end.





%% ===================================================================
%% Util
%% ===================================================================

%% @private
-spec find(nksip_dialog:id(), nksip:call()) ->
    nksip:dialog() | not_found.

find(Id, #call{dialogs=Dialogs}) ->
    do_find(Id, Dialogs).


%% @private
-spec do_find(nksip_dialog:id(), [nksip:dialog()]) ->
    nksip:dialog() | not_found.

do_find(_, []) -> not_found;
do_find(Id, [#dialog{id=Id}=Dialog|_]) -> Dialog;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).


%% @private Updates a dialog into the call
-spec store(nksip:dialog(), nksip:call()) ->
    nksip:call().

store(Dialog, #call{dialogs=Dialogs}=Call) ->
    #dialog{id=Id, invite=Invite, events=Events} = Dialog,
    case Dialogs of
        [#dialog{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest=[], IsFirst = false
    end,
    case Invite==undefined andalso Events==[] of
        true ->
            cast(dialog_update, stop, Dialog, Call),
            Dialogs1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #dialog.id, Dialogs)
            end,
            Call#call{dialogs=Dialogs1, hibernate=dialog_stop};
        false ->
            Hibernate = case Invite of
                #dialog_invite{status=confirmed} -> dialog_confirmed;
                _ -> Call#call.hibernate
            end,
            Dialogs1 = case IsFirst of
                true -> [Dialog|Rest];
                false -> lists:keystore(Id, #dialog.id, Dialogs, Dialog)
            end,
            Call#call{dialogs=Dialogs1, hibernate=Hibernate}
    end.


%% @private Finds a event
-spec find_event(nksip_dialog:event_id(), nksip:dialog()) ->
    #dialog_event{} | not_found.

find_event(EventId, #dialog{events=Events}) ->
    do_find_event(EventId, Events).


%% @private 
do_find_event(_EventId, []) -> not_found;
do_find_event(EventId, [#dialog_event{id=EventId}=Event|_]) -> Event;
do_find_event(EventId, [_|Rest]) -> do_find_event(EventId, Rest).


%% @private Updates an updated event into dialog
-spec store_event(#dialog_event{}, nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

store_event(Event, Dialog, Call) ->
    #dialog_event{id=Id, status=Status} = Event,
    #dialog{events=Events} = Dialog,
    case Events of
        [#dialog_event{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest = [], IsFirst = false
    end,
    Events1 = case Status of
        {terminated, Reason} ->
            CastId = nksip_unparse:event(Id),
            cast(dialog_update, {event_update, {stop, Reason, CastId}}, Dialog, Call),
            case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #dialog_event.id, Events)
            end;
        _ when IsFirst -> 
            [Event|Rest];
        _ -> 
            lists:keystore(Id, #dialog_event.id, Event, Events)
    end,
    Dialog#dialog{events=Events1}.


%% @private
-spec cast(atom(), term(), nksip:dialog(), nksip:call()) ->
    ok.

cast(Fun, Arg, Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    Args1 = [Dialog, Arg],
    Args2 = [DialogId, Arg],
    ?call_debug("called dialog ~s ~p: ~p", [DialogId, Fun, Arg], Call),
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

