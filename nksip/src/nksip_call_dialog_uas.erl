% -------------------------------------------------------------------
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

%% @private Call dialog UAS processing module
-module(nksip_call_dialog_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/2, response/3]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec request(nksip:request(), call()) ->
    {ok, nksip_dialog:id(), call()} | {error, Error}
    when Error :: old_cseq | unknown_dialog | bye | 
                  proceeding_uac | proceeding_uas | invalid.

request(Req, Call) ->
    case nksip_dialog:id(Req) of
        <<>> ->
            {ok, undefined, Call};
        DialogId ->
            #sipmsg{method=Method, cseq=CSeq} = Req,
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{status=Status, remote_seq=RemoteSeq}=Dialog ->
                    ?call_debug("Dialog ~s (~p) UAS request ~p", 
                                [DialogId, Status, Method], Call),
                    if
                        Method=/='ACK', RemoteSeq>0, CSeq<RemoteSeq  ->
                            {error, old_cseq};
                        true -> 
                            Dialog1 = Dialog#dialog{remote_seq=CSeq},
                            % Dialog2 = nksip_call_dialog:remotes_update(Req, Dialog1),
                            case do_request(Method, Status, Req, Dialog1, Call) of
                                {ok, Dialog2} -> 
                                    {ok, DialogId, 
                                         nksip_call_dialog:update(Dialog2, Call)};
                                {error, Error} ->
                                    {error, Error}
                            end
                    end;
                not_found when Method=:='INVITE' -> 
                    {ok, DialogId, Call};
                not_found -> 
                    {error, unknown_dialog}
            end
    end.



%% @private
-spec do_request(nksip:method(), nksip_dialog:status(), 
                 nksip:request(), nksip:dialog(), call()) ->
    {ok, nksip:dialog()} | {error, Error}
    when Error :: bye | proceeding_uac | proceeding_uas | invalid.

do_request('ACK', bye, _Req, Dialog, _Call) ->
    {ok, Dialog};

do_request(_, bye, _Req, _Dialog, _Call) ->
    {error, bye};

do_request('INVITE', confirmed, Req, Dialog, Call) ->
    {ok, status_update(proceeding_uas, Dialog#dialog{request=Req}, Call)};

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uac; Status=:=accepted_uac ->
    {error, proceeding_uac};

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uas; Status=:=accepted_uas ->
    {error, proceeding_uas};

do_request('ACK', Status, ACKReq, #dialog{request=InvReq}=Dialog, Call) ->
    #sipmsg{cseq=ACKSeq} = ACKReq,
    case InvReq of
        #sipmsg{cseq=ACKSeq} when Status=:=accepted_uas -> 
            {ok, status_update(confirmed, Dialog#dialog{ack=ACKReq}, Call)};
        #sipmsg{cseq=ACKSeq} when Status=:=confirmed -> 
            {ok, Dialog};   % It is an ACK retransmission
        #sipmsg{cseq=InvCSeq} ->
            ?P("INVALID ACK (seq ~p) INV (~p), ~p", [ACKSeq, InvCSeq, Status]),
            {error, invalid};
        _ -> 
            ?P("INVALID ACK (seq ~p), NO INV, ~p", [ACKSeq, Status]),
            {error, invalid}
    end;

do_request('ACK', _Status, _Req, _Dialog, _Call) ->
    {error, invalid};

do_request('BYE', Status, _Req, Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    case Status of
        confirmed -> ok;
        _ -> ?call_debug("Dialog ~s (~p) received BYE", [DialogId, Status], Call)
    end,
    {ok, status_update(bye, Dialog, Call)};

do_request(_, _, _, Dialog, _Call) ->
    {ok, Dialog}.



%% @private
-spec response(nksip:request(), nksip:response(), call()) ->
    call().

response(#sipmsg{method=Method}=Req, Resp, Call) ->
    #sipmsg{response=Code} = Resp,
    #call{dialogs=Dialogs} = Call,
    case nksip_dialog:id(Resp) of
        <<>> ->
            Call;
        DialogId ->
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{status=Status}=Dialog ->
                    #sipmsg{response=Code} = Resp,
                    ?call_debug("Dialog ~s (~p) UAS ~p response ~p", 
                                [DialogId, Status, Method, Code], Call),
                    Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
                    nksip_call_dialog:update(Dialog1, Call);
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = nksip_call_dialog:create(uas, Req, Resp),
                    response(Req, Resp, Call#call{dialogs=[Dialog|Dialogs]});
                not_found ->
                    Call
            end
    end.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), call()) ->
    nksip:dialog().

do_response(_, Code, _Req, _Resp, Dialog, Call) when Code=:=408; Code=:=481 ->
    status_update({stop, Code}, Dialog, Call);

do_response(_, Code, _Req, _Resp, Dialog, _Call) when Code<101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<200 andalso (Status=:=init orelse Status=:=proceeding_uas) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp},
    status_update(proceeding_uas, Dialog1, Call);

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<300 andalso (Status=:=init orelse Status=:=proceeding_uas) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp}, 
    status_update(accepted_uas, Dialog1, Call);

do_response('INVITE', Code, _Req, _Resp, #dialog{answered=Answered}=Dialog, Call)
            when Code>=300 ->
    case Answered of
        undefined -> status_update({stop, Code}, Dialog, Call);
        _ -> status_update(confirmed, Dialog, Call)
    end;

do_response('INVITE', Code, _Req, Resp, Dialog, Call) ->
    #sipmsg{response=Code} = Resp,
    #dialog{status=Status} = Dialog,
    ?call_notice("Dialog unexpected INVITE response ~p in ~p", [Code, Status], Call),
    Dialog;
    
do_response('BYE', _Code, Req, _Resp, #dialog{caller_tag=CallerTag}=Dialog, Call) ->
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog, Call);

do_response(_, _, _, _, Dialog, _Call) ->
    Dialog.


%% @private
-spec status_update(nksip_dialog:status(), nksip:dialog(), call()) ->
    nksip:dialog().

status_update(Status, Dialog, Call) ->
    nksip_call_dialog:status_update(uas, Status, Dialog, Call).




