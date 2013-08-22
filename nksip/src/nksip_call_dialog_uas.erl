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

-export([request/2, response/3]).
-import(nksip_call_dialog, [create/4, status_update/2, remotes_update/2, 
                            find/2, update/2]).


%% ===================================================================
%% Private
%% ===================================================================

request(#sipmsg{cseq=CSeq, method=Method}=Req, Dialogs) ->
    case nksip_dialog:id(Req) of
        undefined ->
            no_dialog;
        {dlg, AppId, CallId, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status, remote_seq=RemoteSeq}=Dialog ->
                    ?debug(AppId, CallId, "Dialog ~p UAS request ~p (~p)", 
                                [DialogId, Method, Status]),
                    case 
                        Method=/='ACK' andalso
                        RemoteSeq=/=undefined andalso CSeq<RemoteSeq 
                    of
                        true -> 
                            {error, old_cseq};
                        false -> 
                            case do_request(Method, Status, Req, Dialog) of
                                {ok, Dialog1} -> 
                                    {ok, DialogId, update(Dialog1, Dialogs)};
                                {error, Error} -> 
                                    {error, Error}
                            end
                    end;
                not_found ->
                    {error, finished}
            end
    end.
            

%% @private
do_request(_, bye, _Req, _Dialog) ->
    {error, bye};

do_request('INVITE', confirmed, _Req, Dialog) ->
    {ok, status_update(proceeding_uas, Dialog)};

do_request('INVITE', Status, _Req, _Dialog) 
           when Status=:=proceeding_uac; Status=:=accepted_uac ->
    {error, proceeding_uac};

do_request('INVITE', Status, _Req, _Dialog) 
           when Status=:=proceeding_uas; Status=:=accepted_uas ->
    {error, proceeding_uas};

do_request('ACK', accepted_uas, Req, Dialog) ->
    #sipmsg{cseq=CSeq, body=Body} = Req,
    #dialog{request=#sipmsg{cseq=InvCSeq, body=InvBody}=InvReq} = Dialog,
    case CSeq of
        InvCSeq ->
            Dialog1 = case InvBody of
                #sdp{} -> Dialog;
                _ -> Dialog#dialog{request=InvReq#sipmsg{body=Body}} 
            end,
            {ok, status_update(confirmed, Dialog1)};
        _ ->
            {error, invalid}
    end;

do_request('ACK', _Status, _Req, _Dialog) ->
    {error, invalid};

do_request('BYE', Status, Req, Dialog) ->
    case Status of
        confirmed -> 
            ok;
        _ ->
            #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
            ?debug(AppId, CallId, "Dialog ~s received BYE in ~p", 
                   [Dialog#dialog.id, Status])
    end,
    {ok, status_update(bye, Dialog)};

do_request(_, _, _, Dialog) ->
    {ok, Dialog}.



%% @private Called to send an in-dialog response
response(#sipmsg{method=Method}=Req,  #sipmsg{response=Code}=Resp, Dialogs) ->
    case nksip_dialog:id(Resp) of
        undefined ->
            Dialogs;
        {dlg, AppId, CallId, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status}=Dialog ->
                    ?debug(AppId, CallId, "Dialog ~p UAS response ~p (~p)", 
                                [DialogId, Code, Status]),
                    case do_response(Method, Code, Req, Resp, Dialog) of
                        {ok, Dialog1} -> 
                            Dialog2 = remotes_update(Req, Dialog1),
                            update(Dialog2, Dialogs);
                        {stop, Reason} -> 
                            removed = status_update({stop, Reason}, Dialog),
                            lists:keydelete(DialogId, #dialog.id, Dialogs)
                    end;
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = create(uas, DialogId, Req, Resp),
                    response(Req, Resp, [Dialog|Dialogs]);
                not_found ->
                    Dialogs
            end
    end.


%% @private
do_response(_, Code, _Req, _Resp, _Dialog) when Code=:=408; Code=:=481 ->
    {stop, Code};

do_response(_, Code, _Req, _Resp, Dialog) when Code<101 ->
    {ok, Dialog};

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<200, Status=:=init; Status=:=proceeding_uas ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp},
    {ok, status_update(proceeding_uas, Dialog1)};

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<300, Status=:=init; Status=:=proceeding_uas ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp},
    {ok, status_update(accepted_uas, Dialog1)};

do_response('INVITE', Code, _Req, _Resp, Dialog) when Code>=300 ->
    {ok, status_update(confirmed, Dialog)};

do_response('BYE', _Code, Req, _Resp, #dialog{local_tag=LocalTag}) ->
    Reason = case Req#sipmsg.from_tag of
        LocalTag -> caller_bye;
        _ -> callee_bye
    end,
    {stop, Reason};

do_response(_, _, _, _, Dialog) ->
    {ok, Dialog}.

