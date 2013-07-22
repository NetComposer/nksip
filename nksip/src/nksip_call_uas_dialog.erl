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

-module(nksip_call_uas_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/1, response/1, ack_timeout/1]).


%% ===================================================================
%% Private
%% ===================================================================

%% @private Called when a SipApp UAS receives a new request.
-spec request(nksip:request()) -> 
        ok | {error, Error}
        when Error :: unknown_dialog | timeout_dialog | terminated_dialog | 
                      old_cseq | proceeding_uac | proceeding_uas | invalid_dialog.

request(#call{uass=[#uas{request=Req}|_], dialogs=Dialogs}=SD) ->
    #sipmsg{cseq=CSeq, method=Method} = Req, 
    case nksip_dialog:id(Req) of
        <<>> ->
            no_dialog;
        DialogId ->
            case lists:keytake(DialogId, #dialog.id, Dialogs) of
                false ->
                    no_dialog;
                {value, Dialog, Rest} when Method=:='ACK' ->
                    proc_request(SD#call{dialogs=[Dialog|Rest]});
                {value, #dialog{remote_seq=RemoteSeq}=Dialog, Rest} ->
                    case RemoteSeq=/=undefined andalso CSeq<RemoteSeq of
                        true -> 
                            {error, old_cseq};
                        false -> 
                            Dialog1 = Dialog#dialog{remote_seq=CSeq},
                            proc_request(SD#call{dialogs=[Dialog1|Rest]})
                    end
            end
    end.
            


%% @private Called to send an in-dialog response
response(#call{uass=[UAS|_], dialogs=Dialogs}=SD) ->
    #uas{
        request=#sipmsg{method=Method}=Req, 
        response=#sipmsg{response=Code}=Resp
    } = UAS,
    DialogId = nksip_dialog:id(Resp),
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        false when Method=:='INVITE', Code>100, Code<300 ->
            Dialog = nksip_dialog_lib:create(uas, DialogId, Req, Resp),
            proc_response(SD#call{dialogs=[Dialog|Dialogs]});
        false ->
            ok;
        {value, Dialog, Rest} ->
            proc_response(SD#call{dialogs=[Dialog|Rest]})
    end.


ack_timeout(#call{uass=[UAS|_], dialogs=Dialogs}=SD) ->
    #uas{response=Resp} = UAS,
    DialogId = nksip_dialog:id(Resp),
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        false ->
            SD;
        {value, #dialog{state=accepted_uas}=Dialog, Rest} ->
            nksip_dialog_lib:status_update({stop, no_ack}, Dialog),
            SD#call{dialogs=Rest};
        {value, #dialog{state=State}, _} ->
            #call{app_id=AppId, call_id=CallId} = SD,
            ?warning(AppId, CallId, "Dialog ~s missing ACK in ~p", [DialogId, State]),
            SD
    end.



%% @private
proc_request(#call{uass=[UAS|_], dialogs=[Dialog|Rest]}=SD) ->
    #call{app_id=AppId, call_id=CallId} = SD,
    #uas{request=#sipmsg{method=Method, cseq=CSeq, body=Body}} = UAS,
    #dialog{
        id = DialogId, 
        state = State, 
        inv_cseq = LastCSeq, 
        inv_req_body = ReqBody, 
        inv_resp_body = RespBody
    } = Dialog,
    ?debug(AppId, CallId, "Dialog ~s UAS request ~p (~p)", [DialogId, Method, State]),
    Result = case Method of
        _ when State=:=bye ->
            {error, bye};
        'INVITE' when State=:=confirmed ->
            D1 = nksip_dialog_lib:update(proceeding_uas, Dialog),
            {ok, D1};
        'INVITE' when State=:=proceeding_uac; State=:=accepted_uac ->
            {error, proceeding_uac};
        'INVITE' when State=:=proceeding_uas; State=:=accepted_uas ->
            {error, proceeding_uas};
        'ACK' when State=:=accepted_uas, CSeq=:=LastCSeq ->
            ReqBody1 = case ReqBody of
                #sdp{} -> ReqBody;
                _ -> Body
            end,
            D1 = Dialog#dialog{inv_req_body=undefined, inv_resp_body=undefined},
            D2 = nksip_dialog_lib:status_update(confirmed, D1),
            D3 = nksip_dialog_lib:session_update(uas, ReqBody1, RespBody, D2),
            {ok, D3};
        'ACK' ->
            {error, invalid};
        'BYE' ->
            case State of
                confirmed -> 
                    ok;
                _ ->
                    ?debug(AppId, CallId, "Dialog ~s received BYE in ~p", 
                           [DialogId, State])
            end,
            D1 = nksip_dialog_lib:status_update(bye, Dialog),
            {ok, D1};
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, Dialog1} -> {ok, DialogId, SD#call{dialogs=[Dialog1|Rest]}};
        {error, Error} -> {error, Error}
    end.



%% @private
proc_response(#call{uass=[UAS|_], dialogs=[Dialog|Rest]}=SD) ->
    #uas{request=#sipmsg{method=Method, cseq=CSeq, body=ReqBody}=Req} = UAS,
    #uas{response=#sipmsg{response=Code, body=RespBody}=Resp} = UAS,
    #dialog{id=DialogId, state=State, timer=Timer} = Dialog,
    #call{app_id=AppId, call_id=CallId} = SD,
    ?debug(AppId, CallId, "Dialog ~s UAS response ~p (~p)", [DialogId, Code, State]),
    Result = case Method of
        _ when Code=:=408; Code=:=481 ->
            {remove, Code};
        'INVITE' ->
            if
                Code < 101 -> 
                    {ok, Dialog};
                Code < 200 -> 
                    D1 = Dialog#dialog{inv_req_body=ReqBody, inv_resp_body=RespBody},
                    D2 = nksip_dialog_lib:status_update(proceeding_uas, D1),
                    D3 = nksip_dialog_lib:target_update(uas, Req, Resp, D2),
                    {ok, D3};
                Code < 300 -> 
                    D1 = Dialog#dialog{inv_req_body=ReqBody, inv_resp_body=RespBody,
                                       inv_cseq=CSeq},
                    D2 = nksip_dialog_lib:status_update(accepted_uas, D1),
                    D3 = nksip_dialog_lib:target_update(uas, Req, Resp, D2),
                    {ok, D3};
                Code >= 300 -> 
                    D1 = Dialog#dialog{inv_req_body=undefined, inv_resp_body=undefined},
                    D2 = nksip_dialog_lib:status_update(confirmed, D1),
                    {ok, D2}
            end;
        'BYE' ->
            Reason = case nksip_dialog_lib:class(Req, Dialog) of
                uac -> caller_bye;
                uas -> callee_bye
            end,
            {remove, Reason};
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, #dialog{state=State}=Dialog1} ->
            Dialog2 = nksip_dialog_lib:remotes_update(Req, Dialog1), 
            nksip_lib:cancel_timer(Timer),
            {Msg, Time} = case State of
                accepted_uas -> {ack_timeout, 64*nksip_config:get(timer_t1)};
                _ -> {timeout, nksip_config:get(dialog_timeout)}
            end,
            Timer1 = erlang:start_timer(Time, self(), {dialog, Msg, DialogId}),
            {ok, SD#call{dialogs=[Dialog2#dialog{timer=Timer1}|Rest]}};
        {remove, StopReason} ->
            nksip_lib:cancel_timer(Timer),
            nksip_dialog_lib:status_update({stop, StopReason}, Dialog),
            {ok, SD#call{dialogs=Rest}}
    end.






