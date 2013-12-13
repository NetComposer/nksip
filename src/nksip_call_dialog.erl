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

-export([create/4, update/3, stop/3, find/2, store/2]).
-export([timer/3, cast/4]).
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
    UA = case Class of uac -> "UAC"; uas -> "UAS" end,
    ?call_debug("Dialog ~s ~s created", [DialogId, UA], Call),
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
        blocked_route_set = false,
        secure = Proto==tls andalso Scheme==sips,
        early = true,
        caller_tag = FromTag,
        invite = undefined,
        subscriptions = []
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
-spec update(term(), nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

update(prack, Dialog, Call) ->
    Dialog1 = session_update(Dialog, Call),
    store(Dialog1, Call);

update({update, Class, Req, Resp}, Dialog, Call) ->
    Dialog1 = target_update(Class, Req, Resp, Dialog, Call),
    Dialog2 = session_update(Dialog1, Call),
    store(Dialog2, Call);

update({subscribe, Class, Req, Resp}, Dialog, Call) ->
    Dialog1 = route_update(Class, Req, Resp, Dialog),
    Dialog2 = target_update(Class, Req, Resp, Dialog1, Call),
    store(Dialog2, Call);

update({notify, Class, Req, Resp}, Dialog, Call) ->
    Dialog1 = route_update(Class, Req, Resp, Dialog),
    Dialog2 = target_update(Class, Req, Resp, Dialog1, Call),
    Dialog3 = case Dialog2#dialog.blocked_route_set of
        true -> Dialog2;
        false -> Dialog2#dialog{blocked_route_set=true}
    end,
    store(Dialog3, Call);

update({invite, {stop, Reason}}, #dialog{invite=Invite}=Dialog, Call) ->
    #invite{
        media_started = Media,
        retrans_timer = RetransTimer,
        timeout_timer = TimeoutTimer
    } = Invite,    
    cancel_timer(RetransTimer),
    cancel_timer(TimeoutTimer),
    cast(dialog_update, {invite_status, {stop, reason(Reason)}}, Dialog, Call),
    case Media of
        true -> cast(session_update, stop, Dialog, Call);
        _ -> ok
    end,
    store(Dialog#dialog{invite=undefined}, Call);

update({invite, Status}, Dialog, Call) ->
    #dialog{
        id = DialogId, 
        blocked_route_set = BlockedRouteSet,
        invite = #invite{
            status = OldStatus, 
            media_started = Media,
            retrans_timer = RetransTimer,
            timeout_timer = TimeoutTimer,
            class = Class,
            request = Req, 
            response = Resp
        } = Invite
    } = Dialog,
    cancel_timer(RetransTimer),
    cancel_timer(TimeoutTimer),
    ?call_debug("Dialog ~s ~p -> ~p", [DialogId, OldStatus, Status], Call),
    Dialog1 = if
        Status==proceeding_uac; Status==proceeding_uas; 
        Status==accepted_uac; Status==accepted_uas ->
            D1 = route_update(Class, Req, Resp, Dialog),
            D2 = target_update(Class, Req, Resp, D1, Call),
            session_update(D2, Call);
        Status==confirmed ->
            session_update(Dialog, Call);
        Status==bye ->
            case Media of
                true -> cast(session_update, stop, Dialog, Call);
                _ -> ok
            end,
            Dialog#dialog{invite=Invite#invite{media_started=false}}
    end,
    case Status of
        OldStatus -> ok;
        _ -> cast(dialog_update, {invite_status, Status}, Dialog, Call)
    end,
    #call{opts=#call_opts{timer_t1=T1, max_dialog_time=Timeout}} = Call,
    TimeoutTimer1 = case Status of
        confirmed -> start_timer(Timeout, invite_timeout, DialogId);
        _ -> start_timer(64*T1, invite_timeout, DialogId)
    end,
    {RetransTimer1, NextRetras1} = case Status of
        accepted_uas -> 
            {start_timer(T1, invite_retrans, DialogId), 2*T1};
        _ -> 
            {undefined, undefined}
    end,
    #dialog{invite=Invite1} = Dialog1,
    Invite2 = Invite1#invite{
        status = Status,
        retrans_timer = RetransTimer1,
        next_retrans = NextRetras1,
        timeout_timer = TimeoutTimer1
    },
    BlockedRouteSet1 = if
        Status==accepted_uac; Status==accepted_uas -> true;
        true -> BlockedRouteSet
    end,
    Dialog2 = Dialog1#dialog{invite=Invite2, blocked_route_set=BlockedRouteSet1},
    store(Dialog2, Call);

update(none, Dialog, Call) ->
    store(Dialog, Call).
    

%% @private Performs a target update
-spec target_update(uac|uas, nksip:request(), nksip:response(), 
                    nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

target_update(Class, Req, Resp, Dialog, Call) ->
    #dialog{
        id = DialogId,
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
            ?call_notice("Dialog ~s: no Contact in remote target",
                         [DialogId], Call),
            RemoteTarget;
        RTOther -> 
            ?call_notice("Dialog ~s: invalid Contact in remote rarget: ~p",
                         [DialogId, RTOther], Call),
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
        #invite{answered=InvAnswered, class=InvClass, request=InvReq} ->
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
            Invite#invite{answered=InvAnswered1, request=InvReq1};
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
-spec route_update(uac|uas, nksip:request(), nksip:response(), nksip:dialog()) ->
    nksip:dialog().

route_update(Class, Req, Resp, #dialog{blocked_route_set=false}=Dialog) ->
    #dialog{app_id=AppId} = Dialog,
    RouteSet = case Class of
        uac ->
            RR = nksip_sipmsg:header(Resp, <<"Record-Route">>, uris),
            case lists:reverse(RR) of
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
            end;
        uas ->
            RR = nksip_sipmsg:header(Req, <<"Record-Route">>, uris),
            case RR of
                [] ->
                    [];
                [FirstRS|RestRS] ->
                    case nksip_transport:is_local(AppId, FirstRS) of
                        true -> RestRS;
                        false -> [FirstRS|RestRS]
                    end
            end
    end,
    Dialog#dialog{route_set=RouteSet};

route_update(_Class, _Req, _Resp, Dialog) ->
    Dialog.


% %% @private Performs a session update
-spec session_update(nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

session_update(
            #dialog{
                invite = #invite{
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
    Invite1 = Invite#invite{
        local_sdp = LocalSDP1, 
        remote_sdp = RemoteSDP1, 
        media_started = true,
        sdp_offer = undefined,
        sdp_answer = undefined
    },
    Dialog#dialog{invite=Invite1};
            
session_update(Dialog, _Call) ->
    Dialog.



%% @private Fully stops a dialog
-spec stop(term(), nksip:dialog(), nksip_call:call()) ->
    nksip_call:call(). 

stop(Reason, #dialog{invite=Invite, subscriptions=Subs}=Dialog, Call) ->
    Dialog1 = lists:foldl(
        fun(Sub, Acc) -> nksip_call_event:stop(Sub, Acc, Call) end,
        Dialog,
        Subs),
    case Invite of
        #invite{} -> update({invite, {stop, reason(Reason)}}, Dialog1, Call);
        undefined -> update(none, Dialog1, Call)
    end.



%% @private Called when a dialog timer is fired
-spec timer(invite_retrans | invite_timeout, nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

timer(invite_retrans, #dialog{id=DialogId, invite=Invite}=Dialog, Call) ->
    #call{opts=#call_opts{app_opts=Opts, global_id=GlobalId, timer_t2=T2}} = Call,
    case Invite of
        #invite{status=Status, response=Resp, next_retrans=Next} ->
            case Status of
                accepted_uas ->
                    case nksip_transport_uas:resend_response(Resp, GlobalId, Opts) of
                        {ok, _} ->
                            ?call_info("Dialog ~s resent response", [DialogId], Call),
                            Invite1 = Invite#invite{
                                retrans_timer = start_timer(Next, invite_retrans, DialogId),
                                next_retrans = min(2*Next, T2)
                            },
                            update(none, Dialog#dialog{invite=Invite1}, Call);
                        error ->
                            ?call_notice("Dialog ~s could not resend response", 
                                         [DialogId], Call),
                            update({invite, {stop, ack_timeout}}, Dialog, Call)
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
        #invite{status=Status} ->
            ?call_notice("Dialog ~s (~p) timeout timer fired", 
                         [DialogId, Status], Call),
            Reason = case Status of
                accepted_uac -> ack_timeout;
                accepted_uas -> ack_timeout;
                _ -> timeout
            end,
            update({invite, {stop, Reason}}, Dialog, Call);
        _ ->
            ?call_notice("Dialog ~s unknown INVITE timeout timer", 
                         [DialogId], Call),
            Call
    end;

timer({event, Tag}, Dialog, Call) ->
    nksip_call_event:timer(Tag, Dialog, Call).



%% ===================================================================
%% Util
%% ===================================================================

%% @private
-spec find(nksip_dialog:id(), nksip_call:call()) ->
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
-spec store(nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

store(#dialog{}=Dialog, #call{dialogs=Dialogs}=Call) ->
    #dialog{id=Id, invite=Invite, subscriptions=Subs} = Dialog,
    case Dialogs of
        [] -> Rest = [], IsFirst = true;
        [#dialog{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest=[], IsFirst = false
    end,
    case Invite==undefined andalso Subs==[] of
        true ->
            cast(dialog_update, stop, Dialog, Call),
            Dialogs1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #dialog.id, Dialogs)
            end,
            Call#call{dialogs=Dialogs1, hibernate=dialog_stop};
        false ->
            Hibernate = case Invite of
                #invite{status=confirmed} -> dialog_confirmed;
                _ -> Call#call.hibernate
            end,
            Dialogs1 = case IsFirst of
                true -> [Dialog|Rest];
                false -> lists:keystore(Id, #dialog.id, Dialogs, Dialog)
            end,
            Call#call{dialogs=Dialogs1, hibernate=Hibernate}
    end.


%% @private
-spec cast(atom(), term(), nksip:dialog(), nksip_call:call()) ->
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
-spec start_timer(integer(), atom(), nksip_dialog:id()) ->
    reference().

start_timer(Time, Tag, Id) ->
    erlang:start_timer(Time , self(), {dlg, Tag, Id}).

