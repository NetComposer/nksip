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
-module(nksip_dialog_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_internal.hrl").

-export([field/2, fields/2]).
-export([create/4, status_update/2, target_update/4, session_update/4, remotes_update/2]).
-export([reason/1, class/2]).


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec fields([nksip_dialog:field()], nksip_dialog:dialog()) -> [any()].

fields(Fields, Req) when is_list(Fields) ->
    [field(Field, Req) || Field <- Fields].


%% @private Extracts a specific field from the request
%% See {@link nksip_request:field/2}.
-spec field(nksip_dialog:field(), nksip_dialog:dialog()) -> any().

field(Type, Dialog) ->
    #dialog{
        id = DialogId,
        app_id = AppId, 
        call_id = CallId,
        created = Created,
        updated = Updated,
        answered = Answered, 
        state = State,
        % expires = Expires,
        local_seq = LocalSeq, 
        remote_seq  = RemoteSeq, 
        local_uri = LocalUri,
        remote_uri = RemoteUri,
        local_target = LocalTarget,
        remote_target = RemoteTarget,
        route_set = RouteSet,
        early = Early,
        secure = Secure,
        local_sdp = LocalSdp,
        remote_sdp = RemoteSdp,
        stop_reason = StopReason
    } = Dialog,
    case Type of
        id -> DialogId;
        sipapp_id -> AppId;
        call_id -> CallId;
        created -> Created;
        updated -> Updated;
        answered -> Answered;
        state -> State;
        % expires -> Expires;
        local_seq -> LocalSeq; 
        remote_seq  -> RemoteSeq; 
        local_uri -> nksip_unparse:uri(LocalUri);
        parsed_local_uri -> LocalUri;
        remote_uri -> nksip_unparse:uri(RemoteUri);
        parsed_remote_uri -> RemoteUri;
        local_target -> nksip_unparse:uri(LocalTarget);
        parsed_local_target -> LocalTarget;
        remote_target -> nksip_unparse:uri(RemoteTarget);
        parsed_remote_target -> RemoteTarget;
        route_set -> [nksip_lib:to_binary(Route) || Route <- RouteSet];
        parsed_route_set -> RouteSet;
        early -> Early;
        secure -> Secure;
        local_sdp -> LocalSdp;
        remote_sdp -> RemoteSdp;
        stop_reason -> StopReason;
        from_tag -> nksip_lib:get_binary(tag, LocalUri#uri.ext_opts);
        to_tag -> nksip_lib:get_binary(tag, RemoteUri#uri.ext_opts);
        _ -> <<>> 
    end.


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
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}
    } = Req,
    #sipmsg{to=To} = Resp,
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
        state = init,
        local_target = #uri{},
        remote_target = #uri{},
        route_set = [],
        secure = Proto=:=tls andalso Scheme=:=sips,
        early = true,
        local_sdp = undefined,
        remote_sdp = undefined,
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

status_update(State, #dialog{state=State}=Dialog) ->
    Dialog;
status_update(State, Dialog) ->
    #dialog{
        id = DialogId, 
        app_id = AppId, 
        state = OldState, 
        local_sdp = LocalSDP, 
        remote_sdp = RemoteSDP,
        inv_queue = Queue
    } = Dialog,
    case OldState of
        init -> cast(dialog_update, start, Dialog);
        _ -> ok
    end,
    case State of
        confirmed ->
            cast(dialog_update, {status, State}, Dialog),
            case queue:out(Queue) of
                {{value, Req}, Queue1} ->
                    spawn(fun() -> nksip_process:send(Req) end),
                    Dialog#dialog{state=State, inv_queue=Queue1};
                {empty, Queue1} ->
                    Dialog#dialog{state=State, inv_queue=Queue1}
            end;
        bye ->
            case {LocalSDP, RemoteSDP} of
                {#sdp{}, #sdp{}} -> cast(session_update, stop, Dialog);
                _ -> ok
            end,
            cast(dialog_update, {status, bye}, Dialog),
            Dialog#dialog{state=bye, local_sdp=undefined, remote_sdp=undefined};
        {stop, Reason} -> 
            case {LocalSDP, RemoteSDP} of
                {#sdp{}, #sdp{}} -> cast(session_update, stop, Dialog);
                _ -> ok
            end,
            cast(dialog_update, {stop, reason(Reason)}, Dialog),
            nksip_proc:del({nksip_dialog, DialogId}),
            nksip_counters:async([{nksip_dialogs, -1}, {{nksip_dialogs, AppId}, -1}]),
            Dialog;
        _ -> 
            cast(dialog_update, {status, State}, Dialog),
            Dialog#dialog{state=State}
    end.


%% @private
-spec target_update(uac|uas, nksip:request(), nksip:response(), nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

target_update(Class, Req, Resp, Dialog) ->
    #sipmsg{contacts=ReqContacts, body=ReqBody}=Req,
    #sipmsg{response=Code, contacts=RespContacts, body=RespBody}=Resp,
    #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        early = Early, 
        secure = Secure,
        answered = Answered,
        remote_target = RemoteTarget,
        local_target = LocalTarget,
        route_set = RouteSet                        
    } = Dialog,
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
    Dialog1 = Dialog#dialog{
        updated = Now,
        answered = Answered1,
        local_target = LocalTarget1,
        remote_target = RemoteTarget1,
        early = Early1,
        route_set = RouteSet1
    },
    case RemoteTarget of
        #uri{} -> ok;
        RemoteTarget1 -> ok;
        _ ->cast(dialog_update, target_update, Dialog)
    end,
    if 
        Code >= 100, Code < 300 -> session_update(Class, ReqBody, RespBody, Dialog1);
        true -> Dialog1
    end.


%% @private
-spec session_update(uac|uas, nksip:request(), nksip:response(), nksip_dialog:dialog()) ->
    nksip_dialog:dialog().

session_update(Class, ReqBody, RespBody, Dialog) ->
    #dialog{local_sdp=DLocalSDP, remote_sdp=DRemoteSDP} = Dialog, 
    Started = case {DLocalSDP, DRemoteSDP} of
        {#sdp{}, #sdp{}} -> true;
        _ -> false
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
            Dialog#dialog{local_sdp=LocalSDP, remote_sdp=RemoteSDP};
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



cast(Fun, Arg, #dialog{id=DialogId, app_id=AppId}) ->
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, [DialogId, Arg]).



%% @private
reason(486) -> busy;
reason(487) -> cancelled;
reason(503) -> service_unavailable;
reason(603) -> decline;
reason(Other) -> Other.



%% @private
-spec class(nksip:request(), #dlg_state{}) -> uac | uas.
class(#sipmsg{from_tag=FromTag}, #dlg_state{from_tag=FromTag}) -> uac;
class(_, _) -> uas.



