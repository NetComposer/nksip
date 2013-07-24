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

-export([create/4, status_update/2, target_update/1, session_update/1, timer/2]).
-export([remotes_update/2, class/1]).


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
    ?debug(AppId, CallId, "Dialog ~s (~s) created", [DialogId, Class]),
    Remotes = [{Ip, Port}],
    nksip_proc:put({nksip_dialog, DialogId}, Remotes),
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
        remotes = [{Ip, Port}],
        inv_queue = queue:new()
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
        inv_queue = Queue,
        retrans_timer = RetransTimer,
        timeout_timer = TimeoutTimer
    } = Dialog,
    case OldStatus of
        init -> cast(dialog_update, start, Dialog);
        _ -> ok
    end,
    cancel_timer(TimeoutTimer),
    cancel_timer(RetransTimer),
    Dialog1 = case Status of
        {stop, Reason} -> 
            cast(dialog_update, {stop, reason(Reason)}, Dialog),
            Dialog;
        _ ->
            case Status=:=OldStatus of
                true -> 
                    ok;
                false -> 
                    ?debug(AppId, CallId, "Dialog ~s swched to ~p", [DialogId, Status]),
                    cast(dialog_update, {status, Status}, Dialog)
            end,
            TimeOut = case Status of
                confirmed -> 1000*nksip_config:get(dialog_timeout);
                _ -> 64*nksip_config:get(timer_t1)
            end,
            Dialog#dialog{
                status = Status, 
                retrans_timer = undefined,
                timeout_timer = start_timer(TimeOut, timeout, DialogId)
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
            Dialog4#dialog{
                retrans_timer = start_timer(T1, dialog_retrans, DialogId),
                next_retrans = 2*T1
            };
        confirmed ->
            Dialog3 = session_update(Dialog2),
            case queue:out(Queue) of
                {{value, Id}, Queue1} -> gen_server:cast(self(), {send_id, Id});
                {empty, Queue1} -> ok
            end,
            Dialog3#dialog{request=undefined, response=undefined, inv_queue=Queue1};
        bye ->
            remove_pending(Dialog2),
            Dialog2;
        {stop, StopReason} -> 
            ?debug(AppId, CallId, "Dialog ~s stop: ~p", [DialogId, StopReason]),
            remove_pending(Dialog2),
            nksip_proc:del({nksip_dialog, DialogId}),
            nksip_counters:async([{nksip_dialogs, -1}, {{nksip_dialogs, AppId}, -1}]),
            removed
    end.


%% @private
-spec target_update(nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

target_update(Dialog) ->
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
    }.


%% @private
-spec session_update(nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

session_update(Dialog) ->
    #dialog{
        request = #sipmsg{body=ReqBody},
        response = #sipmsg{body=RespBody},
        local_sdp = DLocalSDP, 
        remote_sdp = DRemoteSDP, 
        media_started = Started
    } = Dialog, 
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


timer(retrans, #call{app_id=AppId, call_id=CallId, dialogs=[Dialog|Rest]}=SD) ->
    #dialog{
        id = DialogId, 
        response = #sipmsg{cseq_method=Method, response=Code} = Resp, 
        next_retrans = Next
    } = Dialog,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?info(AppId, CallId, "Dialog ~s resending ~p ~p response",
                  [DialogId, Method, Code]),
            Dialog1 = Dialog#dialog{
                retrans_timer = start_timer(Next, retrans, DialogId),
                next_retrans = min(2*Next, nksip_config:get(timer_t2))
            },
            nksip_call_srv:next(SD#call{dialogs=[Dialog1|Rest]});
        error ->
            ?notice(AppId, CallId, "Dialog ~s could not resend ~p ~p response",
                    [DialogId, Method, Code]),
            status_update({stop, ack_timeout}, Dialog),
            nksip_call_srv:next(SD#call{dialogs=Rest})
    end;

timer(timeout, #call{dialogs=[Dialog|Rest]}=SD) ->
    #dialog{id=Id, app_id=AppId, call_id=CallId, status=Status} = Dialog,
    ?notice(AppId, CallId, "Dialog ~s timeout in ~p", [Id, Status]),
    status_update({stop, timeout}, Dialog),
    nksip_call_srv:next(SD#call{dialogs=Rest}).



%% ===================================================================
%% Util
%% ===================================================================


remotes_update(SipMsg, #dialog{id=DialogId, remotes=Remotes}=Dialog) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, transport=Transport} = SipMsg,
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    case lists:member({Ip, Port}, Remotes) of
        true ->
            Dialog;
        false ->
            Remotes1 = [{Ip, Port}|Remotes],
            ?debug(AppId, CallId, "dialog ~s updated remotes: ~p", 
                   [DialogId, Remotes1]),
            nksip_proc:put({nksip_dialog, DialogId}, Remotes1),
            Dialog#dialog{remotes=Remotes1}
    end.


remove_pending(#dialog{inv_queue=Queue}=Dialog) ->
    case queue:out(Queue) of
        {{value, Id}, Queue1} ->
            gen_server:cast(self(), {send_no_trans_id, Id}),
            remove_pending(Dialog#dialog{inv_queue=Queue1});
        {empty, Queue1} ->
            Dialog#dialog{inv_queue=Queue1}
    end.



cast(Fun, Arg, #dialog{id=DialogId, app_id=AppId}) ->
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, [DialogId, Arg]).


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


start_timer(Time, Tag, Pos) ->
    {Tag, erlang:start_timer(Time, self(), {dialog, Tag, Pos})}.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.


