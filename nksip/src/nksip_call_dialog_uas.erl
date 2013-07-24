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

-module(nksip_call_dialog_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/1, response/1]).
-import(nksip_call_dialog, [create/4, status_update/2, remotes_update/2]).


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
                    do_request(SD#call{dialogs=[Dialog|Rest]});
                {value, #dialog{remote_seq=RemoteSeq}=Dialog, Rest} ->
                    case RemoteSeq=/=undefined andalso CSeq<RemoteSeq of
                        true -> 
                            {error, old_cseq};
                        false -> 
                            Dialog1 = Dialog#dialog{remote_seq=CSeq},
                            do_request(SD#call{dialogs=[Dialog1|Rest]})
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
            Dialog = create(uas, DialogId, Req, Resp),
            do_response(SD#call{dialogs=[Dialog|Dialogs]});
        false ->
            SD;
        {value, Dialog, Rest} ->
            do_response(SD#call{dialogs=[Dialog|Rest]})
    end.



%% @private
do_request(#call{uass=[UAS|_], dialogs=[Dialog|Rest]}=SD) ->
    #uas{request=#sipmsg{method=Method, cseq=CSeq, body=Body}} = UAS,
    #dialog{
        id = DialogId, 
        status = Status, 
        request = #sipmsg{cseq=InvCSeq, body=InvBody} = InvReq
    } = Dialog,
    #call{app_id=AppId, call_id=CallId} = SD,
    ?debug(AppId, CallId, "Dialog ~s UAS request ~p (~p)", [DialogId, Method, Status]),
    Result = case Method of
        _ when Status=:=bye ->
            {error, bye};
        'INVITE' when Status=:=confirmed ->
            {ok, status_update(proceeding_uas, Dialog)};
        'INVITE' when Status=:=proceeding_uac; Status=:=accepted_uac ->
            {error, proceeding_uac};
        'INVITE' when Status=:=proceeding_uas; Status=:=accepted_uas ->
            {error, proceeding_uas};
        'ACK' when Status=:=accepted_uas, CSeq=:=InvCSeq ->
            D1 = case InvBody of
                #sdp{} -> Dialog;
                _ -> Dialog#dialog{request=InvReq#sipmsg{body=Body}} 
            end,
            {ok, status_update(confirmed, D1)};
        'ACK' ->
            {error, invalid};
        'BYE' ->
            case Status of
                confirmed -> 
                    ok;
                _ ->
                    ?debug(AppId, CallId, "Dialog ~s received BYE in ~p", 
                           [DialogId, Status])
            end,
            {ok, status_update(bye, Dialog)};
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, Dialog1} -> {ok, DialogId, SD#call{dialogs=[Dialog1|Rest]}};
        {error, Error} -> {error, Error}
    end.



%% @private
do_response(#call{uass=[UAS|_], dialogs=[Dialog|Rest]}=SD) ->
    #uas{request=#sipmsg{method=Method, from_tag=FromTag}=Req} = UAS,
    #uas{response=#sipmsg{response=Code}=Resp} = UAS,
    #dialog{id=DialogId, status=Status, local_tag=LocalTag} = Dialog,
    #call{app_id=AppId, call_id=CallId} = SD,
    ?debug(AppId, CallId, "Dialog ~s UAS response ~p (~p)", [DialogId, Code, Status]),
    Result = case Method of
        _ when Code=:=408; Code=:=481 ->
            {remove, Code};
        'INVITE' ->
            if
                Code < 101 -> 
                    {ok, Dialog};
                Code < 200 andalso (Status=:=init orelse Status=:=proceeding_uas) -> 
                    D1 = Dialog#dialog{request=Req, response=Resp},
                    {ok, status_update(proceeding_uas, D1)};
                Code < 300 andalso (Status=:=init orelse Status=:=proceeding_uas) -> 
                    D1 = Dialog#dialog{request=Req, response=Resp},
                    {ok, status_update(accepted_uas, D1)};
                Code >= 300 -> 
                    {ok, status_update(confirmed, Dialog)}
            end;
        'BYE' ->
            Reason = case FromTag of
                LocalTag -> caller_bye;
                _ -> callee_bye
            end,
            {remove, Reason};
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, Dialog1} ->
            Dialog2 = remotes_update(Req, Dialog1), 
            SD#call{dialogs=[Dialog2|Rest]};
        {remove, StopReason} ->
            status_update({stop, StopReason}, Dialog),
            SD#call{dialogs=Rest}
    end.






