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
-export([target_update/3, session_update/2]).
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
        sipapp_id = AppId, 
        call_id = CallId,
        created = Created,
        updated = Updated,
        answered = Answered, 
        state = State,
        expires = Expires,
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
        expires -> Expires;
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
reason(486) -> busy;
reason(487) -> cancelled;
reason(503) -> service_unavailable;
reason(603) -> decline;
reason(Code) -> {code, Code}.


%% @private
-spec target_update(uac|uas, nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

target_update(Class, StateName, SD) ->
    #dlg_state{invite_request=Req, invite_response=Resp, dialog=Dialog} = SD,
    #dialog{
        id = DialogId,
        sipapp_id = AppId,
        call_id = CallId,
        early = Early, 
        secure = Secure,
        answered = Answered,
        remote_target = RemoteTarget,
        local_target = LocalTarget,
        route_set = RouteSet                        
    } = Dialog,
    #sipmsg{contacts=ReqContacts}=Req,
    #sipmsg{response=Code, contacts=RespContacts}=Resp,
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
    case RemoteTarget1 of
        RemoteTarget -> ok;
        _ -> nksip_sipapp_srv:sipapp_cast(AppId, dialog_update, [DialogId, target_update])
    end,
    SD1 = SD#dlg_state{dialog=Dialog1},
    SD2 = if 
        Code >= 100, Code < 300 -> session_update(Class, SD1);
        true -> SD1
    end,
    {StateName, SD2}.


%% @private
-spec session_update(uac|uas, #dlg_state{}) ->
    #dlg_state{}.

session_update(Class, 
                #dlg_state{
                    invite_request=#sipmsg{body=ReqBody},
                    invite_response=#sipmsg{body=RespBody},
                    dialog=Dialog, 
                    started_media=StartedMedia
                }=SD) ->
     #dialog{
        id = DialogId,
        sipapp_id = AppId,
        local_sdp = DLocalSDP, 
        remote_sdp = DRemoteSDP
    } = Dialog, 
    case Class of
        uac ->
            LocalSDP = case ReqBody of #sdp{} -> ReqBody; _ -> undefined end,
            RemoteSDP = case RespBody of #sdp{} -> RespBody; _ -> undefined end;
        uas ->
            LocalSDP = case RespBody of #sdp{} -> RespBody; _ -> undefined end,
            RemoteSDP = case ReqBody of #sdp{} -> ReqBody; _ -> undefined end
    end,
    case {StartedMedia, LocalSDP, RemoteSDP} of
        {false, #sdp{}, #sdp{}} ->
            Dialog1 = Dialog#dialog{
                        local_sdp = LocalSDP, 
                        remote_sdp = RemoteSDP},
            nksip_sipapp_srv:sipapp_cast(AppId, session_update, 
                        [DialogId, {start, LocalSDP, RemoteSDP}]),
            SD#dlg_state{started_media=true, dialog=Dialog1};
        {false, _, _} ->
            SD;
        {true, #sdp{}, #sdp{}} ->
            case 
                nksip_sdp:is_new(RemoteSDP, DRemoteSDP) orelse
                nksip_sdp:is_new(LocalSDP, DLocalSDP)
            of
                true -> 
                    Dialog1 = Dialog#dialog{
                        local_sdp = LocalSDP, 
                        remote_sdp=RemoteSDP
                    },
                    nksip_sipapp_srv:sipapp_cast(AppId, session_update, 
                            [DialogId, {update, LocalSDP, RemoteSDP}]),
                    SD#dlg_state{dialog=Dialog1};
                false ->
                    SD
            end;
        {true, _, _} ->
            SD
    end;
session_update(_Class, SD) ->
    SD.


%% @private
-spec class(nksip:request(), #dlg_state{}) -> uac | uas.
class(#sipmsg{from_tag=FromTag}, #dlg_state{from_tag=FromTag}) -> uac;
class(_, _) -> uas.



