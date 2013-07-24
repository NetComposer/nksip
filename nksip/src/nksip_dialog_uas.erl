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

%% @doc Dialog UAS processing module

-module(nksip_dialog_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_internal.hrl").

-export([request/1, response/2]).
-export([proc_request/4, proc_response/3]).


%% ===================================================================
%% Private
%% ===================================================================

%% @private Called when a SipApp UAS receives a new request.
-spec request(nksip:request()) -> 
        ok | {error, Error}
        when Error :: unknown_dialog | timeout_dialog | terminated_dialog | 
                      old_cseq | proceeding_uac | proceeding_uas | invalid_dialog.

request(#sipmsg{method=Method, to=To, to_tag=ToTag, opts=Opts}=Req) ->
    case nksip_dialog_fsm:call(Req, {request, uas, Req}) of
        ok ->
            ok;
        {error, unknown_dialog} when Method =:= 'INVITE' ->
            Req1 = case ToTag of
                <<>> -> 
                    ToTag1 = nksip_lib:get_binary(to_tag, Opts),
                    To1 = To#uri{ext_opts=[{tag, ToTag1}|To#uri.ext_opts]},
                    Req#sipmsg{to=To1, to_tag=ToTag1};
                _ ->
                    Req
            end,
            Pid = nksip_dialog_fsm:start(uas, Req1),
            nksip_dialog_fsm:call(Pid, {request, uas, Req1});
        {error, Error} -> 
            {error, Error}
    end.


%% @private Called to send an in-dialog response
-spec response(nksip:request(), nksip:response()) -> 
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog.

response(#sipmsg{method=Method, to_tag=ToTag}, Resp) 
         when Method=:='INVITE'; ToTag=/=(<<>>) ->
   case nksip_dialog_fsm:call(Resp, {response, uas, Resp}) of
        ok -> ok;
        {error, _} when Method=:='BYE' -> ok;
        {error, Error} -> {error, Error}
    end;

response(_Req, _Resp) ->
    ok.


%% @private
-spec proc_request(nksip:request(), term(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_request(#sipmsg{method='ACK'}=Req, From, StateName, SD) ->
    proc_request2(Req, From, StateName, SD);

proc_request(#sipmsg{cseq=CSeq}=Req, From, StateName, SD) ->
    #dlg_state{dialog=#dialog{remote_seq=RemoteSeq}=Dialog} = SD,
    case RemoteSeq=/=undefined andalso CSeq<RemoteSeq of
        true ->
            gen_fsm:reply(From, {error, old_cseq}),
            {StateName, SD};
        false ->
            SD1 = SD#dlg_state{dialog=Dialog#dialog{remote_seq=CSeq}},
            proc_request2(Req, From, StateName, SD1)
    end.


%% @private
-spec proc_request2(nksip:request(), term(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_request2(Req, From, StateName, SD) ->
    #dlg_state{dialog=Dialog, invite_request=InvReq} = SD,
    #sipmsg{method=Method, cseq=CSeq, call_id=CallId, body=Body} = Req,
    #dialog{id=DialogId, app_id=AppId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s UAS request ~p (~p)", 
           [DialogId, Method, StateName]),
    case Method of
        'INVITE' when StateName=:=init; StateName=:=confirmed ->
            gen_fsm:reply(From, ok),
            SD1 = SD#dlg_state{invite_request=Req},
            {proceeding_uas, SD1};
        'INVITE' when StateName=:=proceeding_uac; StateName=:=accepted_uac ->
            gen_fsm:reply(From, {error, proceeding_uac}),
            {StateName, SD};
        'INVITE' when StateName=:=proceeding_uas; StateName=:=accepted_uas ->
            gen_fsm:reply(From, {error, proceeding_uas}),
            {StateName, SD};
        'ACK' when StateName=:=accepted_uas, CSeq=:=InvReq#sipmsg.cseq ->
            gen_fsm:reply(From, ok),
            SD1 = case InvReq#sipmsg.body of
                #sdp{} -> SD;
                _ -> SD#dlg_state{invite_request=InvReq#sipmsg{body=Body}}
            end,
            SD2 = nksip_call_dialog:session_update(uas, SD1),
            SD3 = SD2#dlg_state{is_first=false, invite_request=undefined, 
                                    invite_response=undefined},
            {confirmed, SD3};
        'ACK' when StateName=:=proceeding_uas, CSeq=:=InvReq#sipmsg.cseq ->
            % Probably the ACK has arrived before our own 2xx response has come 
            % to the dialog. Try again later.
            Msg = {request, uas, Req},
            gen_fsm:send_all_state_event(self(), {retry, Msg, From}),
            {StateName, SD};
        'ACK' ->
            % It should be a retransmission 
            gen_fsm:reply(From, {error, invalid_dialog}),
            ?info(AppId, CallId, "Dialog ~s (~p) ignored received ACK", 
                   [DialogId, StateName]),
            {StateName, SD};
        'BYE' ->
            gen_fsm:reply(From, ok),
            Reason = case nksip_call_dialog:class(Req, SD) of
                uac -> caller_bye;
                uas -> callee_bye
            end,
            Dialog1 = Dialog#dialog{stop_reason=Reason},
            case StateName of
                confirmed -> 
                    ok;
                _ ->
                    ?debug(AppId, CallId, "Dialog ~s received BYE in ~p", 
                           [DialogId, StateName])
            end,
            {bye, SD#dlg_state{dialog=Dialog1}};
        _ ->
            gen_fsm:reply(From, ok),
            {StateName, SD}
    end.



%% @private
-spec proc_response(nksip:response(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}. 

proc_response(Resp, StateName, #dlg_state{invite_request=InvReq, dialog=Dialog}=SD) ->
    #dialog{id=DialogId, app_id=AppId, call_id=CallId, answered=Answered} = Dialog,
    #sipmsg{cseq_method=Method, cseq=CSeq, response=Code} = Resp,
    ?debug(AppId, CallId, "Dialog ~s UAS response ~p (~p)", [DialogId, Code, StateName]),
    if
        Method=:='INVITE', StateName=:=proceeding_uas, CSeq=:=InvReq#sipmsg.cseq ->
            if
                Code < 101 -> 
                    SD1 = SD#dlg_state{invite_response=Resp},
                    {proceeding_uas, SD1};
                Code < 200 -> 
                    SD1 = SD#dlg_state{invite_response=Resp},
                    nksip_call_dialog:target_update(uas, proceeding_uas, SD1);
                Code < 300 -> 
                    SD1 = SD#dlg_state{invite_response=Resp},
                    nksip_call_dialog:target_update(uas, accepted_uas, SD1);
                Code >= 300, Answered =:= undefined -> 
                    Dialog1 = Dialog#dialog{stop_reason=nksip_call_dialog:reason(Code)},
                    {stop, SD#dlg_state{dialog=Dialog1}};
                Code >= 300 -> 
                    SD1 = SD#dlg_state{invite_request = undefined, 
                                            invite_response = undefined},   % Free memory
                    {confirmed, SD1}
            end;
        Method=:='INVITE' ->
            ?notice(AppId, CallId, "Dialog ~s UAS (~p) invalid INVITE response",
                    [DialogId, StateName]),
            {StateName, SD};
        Method=:='BYE', StateName=:=bye, Code >= 200, Code < 300 ->
            {stop, SD};
        true ->
            {StateName, SD}
    end.


