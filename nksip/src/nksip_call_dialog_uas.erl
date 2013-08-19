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
                            find/2, store/2]).


%% ===================================================================
%% Private
%% ===================================================================

%% @private Called when a SipApp UAS receives a new request.
request(#sipmsg{cseq=CSeq, method=Method}=Req, #call{dialogs=Dialogs}=SD) ->
    case nksip_dialog:id(Req) of
        undefined ->
            no_dialog;
        {dlg, _, _, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status, remote_seq=RemoteSeq}=Dialog ->
                    ?call_debug("Dialog ~p UAS request ~p (~p)", 
                                [DialogId, Method, Status], SD),
                    case 
                        Method=/='ACK' andalso
                        RemoteSeq=/=undefined andalso CSeq<RemoteSeq 
                    of
                        true -> 
                            {error, old_cseq};
                        false -> 
                            case do_request(Method, Status, Req, Dialog) of
                                {ok, Dialog1} -> {ok, DialogId, store(Dialog1, Dialogs)};
                                {error, Error} -> {error, Error}
                            end
                    end;
                not_found ->
                    no_dialog
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

do_request('BYE', Status, Req, Dialog) ->
    case Status of
        confirmed -> 
            ok;
        _ ->
            #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
            #dialog{id=DialogId} = Dialog,
            ?debug(AppId, CallId, "Dialog ~s received BYE in ~p", 
                   [DialogId, Status])
    end,
    {ok, status_update(bye, Dialog)};

do_request(_, _, _, Dialog) ->
    {ok, Dialog}.



%% @private Called to send an in-dialog response
response(Req, Resp, #call{dialogs=Dialogs}=SD) ->
    #sipmsg{method=Method} = Req, 
    #sipmsg{response=Code} = Resp,
    case nksip_dialog:id(Resp) of
        undefined ->
            SD;
        {dlg, _, _, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status} = Dialog ->
                    ?call_debug("Dialog ~p UAS response ~p (~p)", 
                                [DialogId, Code, Status], SD),
                    Dialogs1 = case do_response(Method, Code, Req, Resp, Dialog) of
                        {ok, Dialog1} -> 
                            Dialog2 = remotes_update(Req, Dialog1),
                            store(Dialog2, Dialogs);
                        {stop, Reason} -> 
                            removed = status_update({stop, Reason}, Dialog),
                            lists:keydelete(DialogId, #dialog.id, Dialogs)
                    end,
                    SD#call{dialogs=Dialogs1};
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = create(uas, DialogId, Req, Resp),
                    response(Req, Resp, SD#call{dialogs=[Dialog|Dialogs]});
                not_found ->
                    SD
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

