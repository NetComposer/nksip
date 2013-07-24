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

%% @private Dialog proxy processing module
-module(nksip_dialog_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_internal.hrl").

-export([request/1, response/2, proc_request/3, proc_response/3]).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Called when a SipApp acting as a proxy sends a request
-spec request(nksip:request()) ->
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog.

request(#sipmsg{to_tag=ToTag}=Req) when ToTag=/=(<<>>) ->
    nksip_dialog_fsm:call(Req, {request, proxy, Req});
request(_) ->
    ok.


% @private Called when a SipApp acting as a proxy receives a response
-spec response(nksip:request(), nksip:response()) ->
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog.

response(#sipmsg{ruri=RUri}=Req, 
         #sipmsg{cseq_method=Method, response=Code, to=To, to_tag=ToTag}=Resp) ->
    case nksip_dialog_fsm:call(Resp, {response, proxy, Resp}) of
        ok ->
            ok;
        {error, unknown_dialog} when Method =:= 'INVITE', Code > 100, Code < 300 ->
            Pid = nksip_dialog_fsm:start(proxy, Resp#sipmsg{ruri=RUri}),
            case request(Req#sipmsg{to=To, to_tag=ToTag}) of
                ok -> nksip_dialog_fsm:call(Pid, {response, proxy, Resp});
                {error, Error} -> {error, Error}
            end;
        {error, unknown_dialog} ->
            ok;
        {error, Error} ->
            {error, Error}
    end.



%% ===================================================================
%% Private
%% ===================================================================



%% @private
-spec proc_request(nksip:request(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}. 

proc_request(Req, StateName, #dlg_state{invite_request=InvReq, dialog=Dialog}=SD) ->
    #dialog{
        id=DialogId, 
        call_id=CallId,
        local_seq=LocalSeq,
        remote_seq=RemoteSeq
    } = Dialog,
    #sipmsg{sipapp_id=AppId, method=Method, cseq=CSeq, body=Body} = Req,
    ?debug(AppId, CallId, "Dialog ~s proxy request ~p (~p)", 
           [DialogId, Method, StateName]),
    Class = nksip_call_dialog:class(Req, SD),
    SD1 = case Class of
        uac when CSeq =< LocalSeq -> SD;
        uac -> SD#dlg_state{dialog=Dialog#dialog{local_seq=CSeq}};
        uas when CSeq =< RemoteSeq -> SD;
        uas ->SD#dlg_state{dialog=Dialog#dialog{remote_seq=CSeq}}
    end,
    case Method of
        'INVITE' when StateName=:=init; StateName=:=confirmed ->
            {proceeding_uac, SD1#dlg_state{invite_request=Req}};
        'INVITE' ->
            ?notice(AppId, CallId, "Dialog ~s proxy sending INVITE in ~p", 
                    [DialogId, StateName]),
            {proceeding_uac, SD1#dlg_state{invite_request=Req}};
        'ACK' when StateName=:=accepted_uac; CSeq=:=InvReq#sipmsg.cseq ->
            SD2 = case InvReq#sipmsg.body of
                #sdp{} -> SD1;
                _ -> SD1#dlg_state{invite_request=InvReq#sipmsg{body=Body}}
            end,
            SD3 = nksip_call_dialog:session_update(Class, SD2),
            SD4 = SD3#dlg_state{is_first=false, invite_request=undefined, 
                                invite_response=undefined},
            {confirmed, SD4};
        'ACK' ->
            ?notice(AppId, CallId, "Dialog ~s proxy (~p) ignoring ACK", 
                            [DialogId, StateName]),
            {StateName, SD1};
        'BYE' ->
            Reason = case Class of uac -> caller_bye; uas -> callee_bye end,
            Dialog1 = Dialog#dialog{stop_reason=Reason},
            {bye, SD1#dlg_state{dialog=Dialog1}};
        _ ->
            {StateName, SD1}
    end.


%% @private
-spec proc_response(nksip:response(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_response(Resp, StateName, #dlg_state{invite_request=InvReq, dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, answered=Answered} = Dialog,
    #sipmsg{cseq_method=Method, response=Code, cseq=CSeq} = Resp, 
    ?debug(AppId, CallId, "Dialog ~s proxy response ~p (~p)", 
          [DialogId, Code, StateName]), 

    Class = nksip_call_dialog:class(Resp, SD),
    if 
        Method=:='INVITE' andalso CSeq=:=InvReq#sipmsg.cseq andalso
        (StateName=:=init orelse StateName=:=proceeding_uac) ->
            if 
                Code < 101 ->
                   {proceeding_uac, SD};
                Code < 200 ->
                    SD1 = SD#dlg_state{invite_response=Resp},
                    nksip_call_dialog:target_update(Class, proceeding_uac, SD1);
                Code < 300 ->
                    SD1 = SD#dlg_state{invite_response=Resp},
                    nksip_call_dialog:target_update(Class, accepted_uac, SD1);
                Code >= 300, Answered =:= undefined ->
                    Dialog1 = Dialog#dialog{stop_reason=nksip_call_dialog:reason(Code)},
                    {stop, SD#dlg_state{dialog=Dialog1}};
                Code >= 300 ->
                    SD1 = SD#dlg_state{invite_request=undefined, 
                                       invite_response=undefined},
                    {confirmed, SD1}
            end;
        Method=:='INVITE' andalso Code >= 200 andalso Code < 300 ->
            % It should be a retransmission
            {StateName, SD};
        Method=:='INVITE' ->
            ?notice(AppId, CallId, "Dialog ~s proxy (~p) received invalid "
                    "INVITE response", [DialogId, StateName]),
            {StateName, SD};
        Method=:='BYE', StateName=:=bye, Code >= 200, Code < 300 ->
            {stop, SD};
        true ->
            {StateName, SD}
    end.




