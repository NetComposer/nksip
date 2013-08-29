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

-export([request/2, response/2]).
-import(nksip_call_dialog_lib, [create/3, status_update/2, remotes_update/2, 
                                find/2, update/2]).


%% ===================================================================
%% Private
%% ===================================================================


request(#trans{request=Req}, #call{dialogs=Dialogs}=SD) ->
    case nksip_dialog:id(Req) of
        undefined ->
            {ok, undefined, SD};
        {dlg, _AppId, _CallId, DialogId} ->
            #sipmsg{method=Method, cseq=CSeq} = Req,
            case find(DialogId, Dialogs) of
                #dialog{status=Status, remote_seq=RemoteSeq}=Dialog ->
                    ?call_debug("Dialog ~p (~p) UAS request ~p", 
                                [DialogId, Status, Method], SD),
                    case 
                        Method=/='ACK' andalso
                        RemoteSeq=/=undefined andalso CSeq<RemoteSeq 
                    of
                        true -> 
                            {error, old_cseq};
                        false -> 
                            case do_request(Method, Status, Req, Dialog) of
                                {ok, Dialog1} -> 
                                    {ok, DialogId, update(Dialog1, SD)};
                                {error, Error} ->
                                    {error, Error}
                            end
                    end;
                not_found when Method=:='INVITE' -> 
                    {ok, DialogId, SD};
                not_found -> 
                    {error, unknown_dialog}
            end
    end.



%% @private
% After an INVITE, BYE has come before the ACK
do_request('ACK', bye, _Req, Dialog) ->
    {ok, Dialog};

do_request(_, bye, _Req, _Dialog) ->
    {error, bye};

do_request('INVITE', confirmed, Req, Dialog) ->
    {ok, status_update(proceeding_uas, Dialog#dialog{request=Req})};

do_request('INVITE', Status, _Req, _Dialog) 
           when Status=:=proceeding_uac; Status=:=accepted_uac ->
    {error, proceeding_uac};

do_request('INVITE', Status, _Req, _Dialog) 
           when Status=:=proceeding_uas; Status=:=accepted_uas ->
    {error, proceeding_uas};

do_request('ACK', Status, AckReq, #dialog{request=#sipmsg{}=InvReq}=Dialog) ->
    case AckReq#sipmsg.cseq =:= InvReq#sipmsg.cseq of
        true when Status=:=accepted_uas -> 
            {ok, status_update(confirmed, Dialog#dialog{ack=AckReq})};
        true when Status=:=confirmed ->
            {ok, Dialog};   % It is an ACK retransmission
        _ -> 
            ?P("ACK INVALID: ~p, ~p, ~p", [Status, AckReq#sipmsg.cseq, InvReq#sipmsg.cseq]),
            {error, invalid}
    end;

do_request('ACK', _Status, _Req, #dialog{request=InvReq}=_Dialog) ->
    ?P("ACK INVALID2: ~p, ~p, ~p", [_Status, _Req#sipmsg.cseq, InvReq]),
    {error, invalid};

do_request('BYE', Status, _Req, Dialog) ->
    case Status of
        confirmed -> 
            ok;
        _ ->
            #dialog{id=DialogId, app_id=AppId, call_id=CallId} = Dialog,
            ?debug(AppId, CallId, "Dialog ~p (~p) received BYE", 
                   [DialogId, Status])
    end,
    {ok, status_update(bye, Dialog)};

do_request(_, _, _, Dialog) ->
    {ok, Dialog}.



%% @private Called to send an in-dialog response
response(UAS, SD) ->
    #trans{method=Method, request=Req, response=Resp} = UAS,
    #sipmsg{response=Code} = Resp,
    #call{dialogs=Dialogs} = SD,
    case nksip_dialog:id(Resp) of
        undefined ->
            ok;
        {dlg, _AppId, _CallId, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status}=Dialog ->
                    #sipmsg{response=Code} = Resp,
                    ?call_debug("Dialog ~p (~p) UAS ~p response ~p", 
                                [DialogId, Status, Method, Code], SD),
                    Dialog1 = do_response(Method, Code, Req, Resp, Dialog),
                    Dialog2 = remotes_update(Req, Dialog1),
                    update(Dialog2, SD);
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = create(uas, Req, Resp),
                    response(UAS, SD#call{dialogs=[Dialog|Dialogs]});
                not_found ->
                    SD
            end
    end.



%% @private
do_response(_, Code, _Req, _Resp, Dialog) when Code=:=408; Code=:=481 ->
    status_update({stop, Code}, Dialog);

do_response(_, Code, _Req, _Resp, Dialog) when Code<101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<200 andalso (Status=:=init orelse Status=:=proceeding_uas) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp},
    status_update(proceeding_uas, Dialog1);

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<300 andalso (Status=:=init orelse Status=:=proceeding_uas) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp}, 
    status_update(accepted_uas, Dialog1);

do_response('INVITE', Code, _Req, _Resp, #dialog{answered=Answered}=Dialog)
            when Code>=300 ->
    case Answered of
        undefined -> status_update({stop, Code}, Dialog);
        _ -> status_update(confirmed, Dialog)
    end;

do_response('INVITE', Code, _Req, Resp, Dialog) ->
    #sipmsg{response=Code} = Resp,
    #dialog{app_id=AppId, call_id=CallId, status=Status} = Dialog,
    ?notice(AppId, CallId, 
           "Dialog unexpected INVITE response ~p in ~p", [Code, Status]),
    Dialog;
    
do_response('BYE', _Code, Req, _Resp, #dialog{local_tag=LocalTag}=Dialog) ->
    Reason = case Req#sipmsg.from_tag of
        LocalTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog);

do_response(_, _, _, _, Dialog) ->
    Dialog.

