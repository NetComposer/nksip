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

-export([create/3, status_update/3, timer/3]).
-export([find/2, update/2]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================

%% @private Creates a new dialog
-spec create(uac|uas, nksip:request(), nksip:response()) ->
    nksip:dialog().

create(Class, Req, Resp) ->
    #sipmsg{
        app_id = AppId, 
        call_id = CallId, 
        from = From, 
        ruri = #uri{scheme=Scheme},
        cseq = CSeq,
        transport = #transport{proto=Proto, remote_ip=_Ip, remote_port=_Port},
        from_tag = FromTag
    } = Req,
    #sipmsg{to=To} = Resp,
    {dlg, _, _, DialogId} = nksip_dialog:id(Resp),
    ?debug(AppId, CallId, "Dialog ~p (~p) created", [DialogId, Class]),
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
        stop_reason = undefined
        % remotes = [{Ip, Port}]
    },
    if 
        Class=:=uac ->
            Dialog#dialog{
                local_seq = CSeq,
                remote_seq = 0,
                local_uri = From,
                remote_uri = To
            };
        Class=:=uas ->
            Dialog#dialog{
                local_seq = 0,
                remote_seq = CSeq,
                local_uri = To,
                remote_uri = From
            }
    end.


%% @private
-spec status_update(uac|uas, nksip_dialog:status(), nksip:dialog()) ->
    nksip:dialog().

status_update(Class, Status, Dialog) ->
    #dialog{
        id = DialogId, 
        app_id = AppId, 
        call_id = CallId,
        status = OldStatus, 
        media_started = Media,
        retrans_timer = RetransTimer,
        timeout_timer = TimeoutTimer
    } = Dialog,
    case OldStatus of
        init -> cast(dialog_update, start, Dialog);
        _ -> ok
    end,
    cancel_timer(RetransTimer),
    cancel_timer(TimeoutTimer),
    Dialog1 = case Status of
        {stop, Reason} -> 
            cast(dialog_update, {stop, reason(Reason)}, Dialog),
            Dialog#dialog{status=Status};
        _ ->
            case Status=:=OldStatus of
                true -> 
                    ok;
                false -> 
                    ?debug(AppId, CallId, "Dialog ~p ~p -> ~p", 
                           [DialogId, OldStatus, Status]),
                    cast(dialog_update, {status, Status}, Dialog)
            end,
            Timeout = case Status of
                confirmed -> nksip_config:get(dialog_timeout);
                _ -> 64*nksip_config:get(timer_t1)
            end,
            Dialog#dialog{
                status = Status, 
                retrans_timer = undefined,
                timeout_timer = start_timer(Timeout, timeout, Dialog)
            }
    end,
    Dialog2 = case Media of
        true when Status=:=bye; element(1, Status)=:=stop ->
            cast(session_update, stop, Dialog),
            Dialog1#dialog{media_started=false};
        _ -> 
            Dialog1
    end,
    case Status of
        proceeding_uac ->
            Dialog3 = target_update(Class, Dialog2),
            session_update(Class, Dialog3);
        accepted_uac ->
            Dialog3 = target_update(Class, Dialog2),
            session_update(Class, Dialog3);
        proceeding_uas ->
            Dialog3 = target_update(Class, Dialog2),
            session_update(Class, Dialog3);
        accepted_uas ->    
            Dialog3 = target_update(Class, Dialog2),
            Dialog4 = session_update(Class, Dialog3),
            T1 = nksip_config:get(timer_t1),
            Dialog4#dialog{
                retrans_timer = start_timer(T1, retrans, Dialog),
                next_retrans = 2*T1
            };
        confirmed ->
            Dialog3 = session_update(Class, Dialog2),
            Dialog3#dialog{request=undefined, response=undefined, 
                           ack=undefined};
        bye ->
            Dialog2;
        {stop, StopReason} -> 
            ?debug(AppId, CallId, "Dialog ~p (~p) stopped: ~p", 
                   [DialogId, OldStatus, StopReason]),
            nksip_counters:async([{nksip_dialogs, -1}]),
            Dialog2
    end.


%% @private Performs a target update
-spec target_update(uac|uas, nksip:dialog()) ->
    nksip:dialog().

target_update(Class, #dialog{response=#sipmsg{}}=Dialog) ->
    #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        early = Early, 
        secure = Secure,
        answered = Answered,
        remote_target = RemoteTarget,
        local_target = LocalTarget,
        route_set = RouteSet,
        request = Req,
        response = Resp
    } = Dialog,
    #sipmsg{contacts=ReqContacts} = Req,
    #sipmsg{response=Code, contacts=RespContacts} = Resp,
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
            ?notice(AppId, CallId, "Dialog ~p: no Contact in remote target",
                    [DialogId]),
            RemoteTarget;
        RTOther -> 
            ?notice(AppId, CallId, "Dialog ~p: invalid Contact in remote rarget: ~p",
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
    RouteSet1 = case Answered of
        undefined when Class=:=uac-> 
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
        undefined when Class=:=uas ->
            RR = nksip_sipmsg:header(Req, <<"Record-Route">>, uris),
            case RR of
                [] ->
                    [];
                [FirstRS|RestRS] ->
                    case nksip_transport:is_local(AppId, FirstRS) of
                        true -> RestRS;
                        false -> [FirstRS|RestRS]
                    end
            end;
        _ ->
            RouteSet
    end,
    case RemoteTarget of
        #uri{} -> ok;
        RemoteTarget1 -> ok;
        _ -> cast(dialog_update, target_update, Dialog)
    end,
    Dialog#dialog{
        updated = Now,
        answered = Answered1,
        local_target = LocalTarget1,
        remote_target = RemoteTarget1,
        early = Early1,
        route_set = RouteSet1
    };

target_update(_, Dialog) ->
    Dialog.


%% @private Performs a session update
-spec session_update(uac|uas, nksip:dialog()) ->
    nksip:dialog().

session_update(Class, 
                #dialog{
                    answered = Answered, 
                    response = #sipmsg{body=RespBody, response=Code}
                } = Dialog) 
                when 
                    (Code>100 andalso Code<200 andalso Answered=:=undefined)
                    orelse
                    (Code>=200 andalso Code<300) ->
    #dialog{
        request = #sipmsg{body=ReqBody0},
        ack = Ack,
        local_sdp = DLocalSDP, 
        remote_sdp = DRemoteSDP, 
        media_started = Started
    } = Dialog, 
    ReqBody = case ReqBody0 of
        #sdp{} -> ReqBody0;
        _ when is_record(Ack, sipmsg) -> Ack#sipmsg.body;
        _ -> <<>>
    end,
    case Class of
        uac ->
            LocalSDP = case ReqBody of #sdp{} -> ReqBody; _ -> undefined end,
            RemoteSDP = case RespBody of #sdp{} -> RespBody; _ -> undefined end;
        uas ->
            LocalSDP = case RespBody of #sdp{} -> RespBody; _ -> undefined end,
            RemoteSDP = case ReqBody of #sdp{} -> ReqBody; _ -> undefined end
    end,
    case {Started, LocalSDP, RemoteSDP} of
        {false, #sdp{}, #sdp{}} ->
            cast(session_update, {start, LocalSDP, RemoteSDP}, Dialog),
            Dialog#dialog{local_sdp=LocalSDP, remote_sdp=RemoteSDP, media_started=true};
        {false, _, _} ->
            Dialog;
        {true, #sdp{}, #sdp{}} ->
            case 
                nksip_sdp:is_new(RemoteSDP, DRemoteSDP) orelse
                nksip_sdp:is_new(LocalSDP, DLocalSDP)
            of
                true -> 
                    cast(session_update, {update, LocalSDP, RemoteSDP}, Dialog),
                    Dialog#dialog{local_sdp=LocalSDP, remote_sdp=RemoteSDP};
                false ->
                    Dialog
            end;
        {true, _, _} ->
            Dialog
    end;

session_update(_, Dialog) ->
    Dialog.


%% @private Called when a dialog timer is fired
-spec timer(retrans|timeout, nksip:dialog(), call()) ->
    call().

timer(retrans, #dialog{status=accepted_uas}=Dialog, Call) ->
    #dialog{
        id = DialogId, 
        response = Resp, 
        next_retrans = Next
    } = Dialog,
    ?call_info("Dialog ~p resending response", [DialogId], Call),
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            Dialog1 = Dialog#dialog{
                retrans_timer = start_timer(Next, retrans, Dialog),
                next_retrans = min(2*Next, nksip_config:get(timer_t2))
            },
            update(Dialog1, Call);
        error ->
            ?call_notice("Dialog ~p could not resend response", [DialogId], Call),
            Dialog1 = status_update(uas, {stop, ack_timeout}, Dialog),
            update(Dialog1, Call)
    end;
    
timer(retrans, #dialog{id=DialogId, status=Status}, Call) ->
    ?call_notice("Dialog ~p retrans timer fired in ~p", [DialogId, Status], Call),
    Call;

timer(timeout, #dialog{id=DialogId, status=Status}=Dialog, Call) ->
    ?call_notice("Dialog ~p (~p) timeout timer fired", [DialogId, Status], Call),
    Reason = case Status of
        accepted_uac -> ack_timeout;
        accepted_uas -> ack_timeout;
        _ -> timeout
    end,
    Dialog1 = status_update(uas, {stop, Reason}, Dialog),
    update(Dialog1, Call).



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
-spec update(nksip:dialog(), call()) ->
    call().

update(#dialog{id=Id}=Dialog, #call{dialogs=[#dialog{id=Id}|Rest]}=Call) ->
    case Dialog#dialog.status of
        {stop, _} -> Call#call{dialogs=Rest, hibernate=dialog_stop};
        confirmed -> Call#call{dialogs=[Dialog|Rest], hibernate=dialog_confirmed};
        _ -> Call#call{dialogs=[Dialog|Rest]}
    end;

update(#dialog{id=Id}=Dialog, #call{dialogs=Dialogs}=Call) ->
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


% %% @private
% -spec remotes_update(nksip:request()|nksip:response(), nksip:dialog()) ->
%     nksip:dialog().

% remotes_update(#sipmsg{transport=#transport{remote_ip=Ip, remote_port=Port}}, Dialog) ->
%     #dialog{
%         id = DialogId, 
%         status = Status,
%         remotes = Remotes, 
%         app_id = AppId, 
%         call_id = CallId
%     } = Dialog,
%     case lists:member({Ip, Port}, Remotes) of
%         true ->
%             Dialog;
%         false ->
%             Remotes1 = [{Ip, Port}|Remotes],
%             ?debug(AppId, CallId, "Dialog ~p (~p) updated remotes: ~p", 
%                    [DialogId, Status, Remotes1]),
%             Dialog#dialog{remotes=Remotes1}
%     end;

% remotes_update(_, Dialog) ->
%     Dialog.


%% @private
-spec cast(atom(), term(), nksip:dialog()) ->
    ok.

cast(Fun, Arg, #dialog{id=DialogId, app_id=AppId, call_id=CallId}) ->
    Id ={dlg, AppId, CallId, DialogId},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, [Id, Arg]).


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

