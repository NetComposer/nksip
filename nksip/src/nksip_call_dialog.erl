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

%% @private Dialog library module.
-module(nksip_call_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([create/4, status_update/2, target_update/1, session_update/1, timer/3]).
-export([find/2, update/2, remotes_update/2, class/1]).


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
create(Class, DialogId, Req, Resp) ->
    #sipmsg{
        sipapp_id = AppId, 
        call_id = CallId, 
        from = From, 
        ruri = #uri{scheme=Scheme},
        cseq = CSeq,
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port},
        from_tag = FromTag
    } = Req,
    #sipmsg{to=To, to_tag=ToTag} = Resp,
    ?debug(AppId, CallId, "Dialog ~p (~p) created", [DialogId, Class]),
    Remotes = [{Ip, Port}],
    nksip_proc:put({nksip_dialog, AppId, CallId, DialogId}, Remotes),
    nksip_counters:async([nksip_dialogs, {nksip_dialogs, AppId}]),
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
        local_sdp = undefined,
        remote_sdp = undefined,
        media_started = false,
        stop_reason = unknown,
        remotes = [{Ip, Port}]
    },
    if 
        Class=:=uac; Class=:=proxy ->
            Dialog#dialog{
                local_seq = CSeq,
                remote_seq = 0,
                local_uri = From,
                local_tag = FromTag,
                remote_uri = To
            };
        Class=:=uas ->
            Dialog#dialog{
                local_seq = 0,
                remote_seq = CSeq,
                local_uri = To,
                local_tag = ToTag,
                remote_uri = From
            }
    end.

status_update(Status, Dialog) ->
    #dialog{
        id = DialogId, 
        app_id = AppId, 
        call_id = CallId,
        status = OldStatus, 
        media_started = Media,
        retrans_timer = RetransTimer
    } = Dialog,
    case OldStatus of
        init -> cast(dialog_update, start, Dialog);
        _ -> ok
    end,
    case is_reference(RetransTimer) of
        true -> erlang:cancel_timer(RetransTimer);
        false -> ok
    end,
    Dialog1 = case Status of
        {stop, Reason} -> 
            cast(dialog_update, {stop, reason(Reason)}, Dialog),
            Dialog;
        _ ->
            case Status=:=OldStatus of
                true -> 
                    ok;
                false -> 
                    ?debug(AppId, CallId, "Dialog ~p switched to ~p", [DialogId, Status]),
                    cast(dialog_update, {status, Status}, Dialog)
            end,
            Time = case Status of
                confirmed -> nksip_config:get(dialog_timeout);
                _ -> round(64*nksip_config:get(timer_t1)/1000)
            end,
            Dialog#dialog{
                status = Status, 
                retrans_timer = undefined,
                timeout = nksip_lib:timestamp() + Time
            }
    end,
    Dialog2 = case Media andalso (Status=:=bye orelse element(1, Status)=:=stop) of
        true -> 
            cast(session_update, stop, Dialog),
            Dialog1#dialog{media_started=false};
        false -> 
            Dialog1
    end,
    case Status of
        proceeding_uac ->
            Dialog3 = target_update(Dialog2),
            session_update(Dialog3);
        accepted_uac ->
            Dialog3 = target_update(Dialog2),
            session_update(Dialog3);
        proceeding_uas ->
            Dialog3 = target_update(Dialog2),
            session_update(Dialog3);
        accepted_uas ->    
            Dialog3 = target_update(Dialog2),
            Dialog4 = session_update(Dialog3),
            T1 = nksip_config:get(timer_t1),
            Timer = erlang:start_timer(T1 , self(), {dialog, retrans, DialogId}),
            Dialog4#dialog{
                retrans_timer = Timer,
                next_retrans = 2*T1
            };
        confirmed ->
            Dialog3 = session_update(Dialog2),
            Dialog3#dialog{request=undefined, response=undefined};
        bye ->
            Dialog2;
        {stop, StopReason} -> 
            ?debug(AppId, CallId, "Dialog ~p stop: ~p", [DialogId, StopReason]),
            nksip_proc:del({nksip_dialog, DialogId}),
            nksip_counters:async([{nksip_dialogs, -1}, {{nksip_dialogs, AppId}, -1}]),
            removed
    end.


%% @private
-spec target_update(nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

target_update(#dialog{request=#sipmsg{}, response=#sipmsg{}}=Dialog) ->
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
        request = #sipmsg{contacts=ReqContacts} = Req,
        response = #sipmsg{response=Code, contacts=RespContacts} = Resp
    } = Dialog,
    Class = class(Dialog),
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
        RTOther -> 
            ?notice(AppId, CallId, "Invalid Contact in Remote Target: ~p (dialog ~s)", 
                    [RTOther, DialogId]),
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
            case lists:reverse(nksip_parse:header_uris(<<"Record-Route">>, Resp)) of
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
            case nksip_parse:header_uris(<<"Record-Route">>, Req) of
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

target_update(Dialog) ->
    Dialog.


%% @private
-spec session_update(nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

session_update(Dialog) ->
    #dialog{
        request = Req,
        response = Resp,
        local_sdp = DLocalSDP, 
        remote_sdp = DRemoteSDP, 
        media_started = Started
    } = Dialog, 
    case Req of
       #sipmsg{body=ReqBody} -> ok;
       _ -> ReqBody = undefined
    end,
    case Resp of
       #sipmsg{body=RespBody} -> ok;
       _ -> RespBody = undefined
    end,
    case class(Dialog) of
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
    end.


timer(retrans, Dialog, Dialogs) ->
    #dialog{
        id = DialogId, 
        app_id = AppId,
        call_id = CallId,
        response = #sipmsg{cseq_method=Method, response=Code} = Resp, 
        next_retrans = Next
    } = Dialog,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?info(AppId, CallId, "Dialog ~p resending ~p ~p response",
                  [DialogId, Method, Code]),
            Timer = erlang:start_timer(Next, self(), {dialog, retrans, DialogId}),
            Dialog1 = Dialog#dialog{
                retrans_timer = Timer,
                next_retrans = min(2*Next, nksip_config:get(timer_t2))
            },
            update(Dialog1, Dialogs);
        error ->
            ?notice(AppId, CallId, "Dialog ~p could not resend ~p ~p response",
                    [DialogId, Method, Code]),
            removed = status_update({stop, ack_timeout}, Dialog),
            lists:keydelete(DialogId, #dialog.id, Dialogs)
    end;

timer(timeout, Dialog, Dialogs) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, status=Status} = Dialog,
    ?notice(AppId, CallId, "Dialog ~p timeout in ~p", [DialogId, Status]),
    Reason = case Status of
        accepted_uac -> ack_timeout;
        accepted_uas -> ack_timeout;
        _ -> timeout
    end,
    removed = status_update({stop, Reason}, Dialog),
    lists:keydelete(DialogId, #dialog.id, Dialogs).



%% ===================================================================
%% Util
%% ===================================================================


find(Id, [#dialog{id=Id}=Dialog|_]) ->
    Dialog;

find(Id, [_|Rest]) ->
    find(Id, Rest);

find(_, []) ->
    not_found.


update(#dialog{id=Id}=Dialog, [#dialog{id=Id}|Rest]) ->
    [Dialog|Rest];

update(#dialog{id=Id}=Dialog, Dialogs) ->
    lists:keystore(Id, #dialog.id, Dialogs, Dialog).



remotes_update(SipMsg, #dialog{id=DialogId, remotes=Remotes}=Dialog) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, transport=Transport} = SipMsg,
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    case lists:member({Ip, Port}, Remotes) of
        true ->
            Dialog;
        false ->
            Remotes1 = [{Ip, Port}|Remotes],
            ?debug(AppId, CallId, "dialog ~p updated remotes: ~p", 
                   [DialogId, Remotes1]),
            nksip_proc:put({nksip_dialog, AppId, CallId, DialogId}, Remotes1),
            Dialog#dialog{remotes=Remotes1}
    end.

cast(Fun, Arg, #dialog{id=DialogId, app_id=AppId, call_id=CallId}) ->
    Id ={dlg, AppId, CallId, DialogId},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, [Id, Arg]).


%% @private
reason(486) -> busy;
reason(487) -> cancelled;
reason(503) -> service_unavailable;
reason(603) -> decline;
reason(Other) -> Other.



%% @private
-spec class(#dialog{}) -> uac | uas.
class(#dialog{request=#sipmsg{from_tag=Tag}, local_tag=Tag}) -> uac;
class(_) -> uas.


