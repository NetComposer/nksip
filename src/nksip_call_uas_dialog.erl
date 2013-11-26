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
-module(nksip_call_uas_dialog).
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

request(#sipmsg{dialog_id = <<>>}, Call) ->
    {ok, undefined, Call};

request(#sipmsg{class={req, 'ACK'}}=AckReq, Call) ->
    #sipmsg{cseq=AckSeq, dialog_id=DialogId} = AckReq,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status, invite_req=#sipmsg{cseq=InvSeq}}=Dialog ->
            ?call_debug("Dialog ~s (~p) UAS request 'ACK'", 
                        [DialogId, Status], Call),
            case Status of
                accepted_uas when InvSeq==AckSeq->
                    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
                    {Offer1, Answer1} = case AckReq#sipmsg.body of
                        #sdp{}=SDP ->
                            case {Offer, Answer} of
                                {{local, _},  undefined} -> {Offer, {remote, SDP}};
                                _ -> {Offer, Answer}
                            end;
                        _ ->
                            {Offer, Answer}
                    end,
                    Dialog1 = Dialog#dialog{
                        ack_req = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = status_update(confirmed, Dialog1, Call),
                    {ok, DialogId, nksip_call_dialog:update(Dialog2, Call)};
                confirmed ->
                    % It should be a retransmission
                    {ok, Dialog};
                bye ->
                    {ok, Dialog};
                _ ->
                    {error, invalid}
            end;
        not_found -> 
            {error, unknown_dialog}
    end;

request(Req, Call) ->
    #sipmsg{class={req, Method}, cseq=CSeq, dialog_id=DialogId} = Req,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status, remote_seq=RemoteSeq}=Dialog ->
            ?call_debug("Dialog ~s (~p) UAS request ~p", 
                        [DialogId, Status, Method], Call),
            case RemoteSeq>0 andalso CSeq<RemoteSeq of
                true ->
                    {error, old_cseq};
                false -> 
                    Dialog1 = Dialog#dialog{remote_seq=CSeq},
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
    end.



%% @private
-spec do_request(nksip:method(), nksip_dialog:status(), 
                 nksip:request(), nksip:dialog(), call()) ->
    {ok, nksip:dialog()} | {error, Error}
    when Error :: bye | proceeding_uac | proceeding_uas | invalid.

do_request(_, bye, _Req, _Dialog, _Call) ->
    {error, bye};

do_request('INVITE', confirmed, Req, Dialog, Call) ->
    Dialog1 = Dialog#dialog{
        invite_req = Req, 
        invite_resp = undefined, 
        ack_req = undefined,
        sdp_offer = undefined,
        sdp_answer = undefined
    },
    {ok, status_update(proceeding_uas, Dialog1, Call)};

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uac; Status=:=accepted_uac ->
    {error, proceeding_uac};

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uas; Status=:=accepted_uas ->
    {error, proceeding_uas};

do_request('BYE', Status, _Req, Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    case Status of
        confirmed -> ok;
        _ -> ?call_debug("Dialog ~s (~p) received BYE", [DialogId, Status], Call)
    end,
    {ok, status_update(bye, Dialog, Call)};

do_request('PRACK', proceeding_uas, Req, Dialog, Call) ->
    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
    {Offer1, Answer1} = case Req#sipmsg.body of
        #sdp{}=SDP ->
            case {Offer, Answer} of
                {undefined, undefined} -> {{remote, SDP}, undefined};
                {{local, _}, undefined} -> {Offer, {remote, SDP}};
                _ -> {Offer, Answer}
            end;
        _ ->
            {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    {ok, status_update(proceeding_uas, Dialog1, Call)};

do_request('PRACK', Status, _Req, Dialog, Call) ->
    ?call_notice("ignoring PRACK in ~p", [Status], Call),
    {ok, Dialog};

do_request(_, _, _, Dialog, _Call) ->
    {ok, Dialog}.



%% @private
-spec response(nksip:request(), nksip:response(), call()) ->
    call().

response(_, #sipmsg{dialog_id = <<>>}, Call) ->
    Call;

response(Req, Resp, Call) ->
    #sipmsg{class={req, Method}} = Req,
    #sipmsg{class={resp, Code, _Reason}, dialog_id=DialogId} = Resp,
    #call{dialogs=Dialogs} = Call,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status}=Dialog ->
            ?call_debug("Dialog ~s (~p) UAS ~p response ~p", 
                        [DialogId, Status, Method, Code], Call),
            Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
            nksip_call_dialog:update(Dialog1, Call);
        not_found when Method=:='INVITE', Code>100, Code<300 ->
            Dialog = nksip_call_dialog:create(uas, Req, Resp),
            response(Req, Resp, Call#call{dialogs=[Dialog|Dialogs]});
        not_found ->
            Call
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
            when Code<200 andalso 
            (Status=:=init orelse Status=:=proceeding_uas) ->
    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
    {Offer1, Answer1} = case {Req#sipmsg.body, Resp#sipmsg.body} of
        {#sdp{}=SDP1, #sdp{}=SDP2} -> {{remote, SDP1}, {local, SDP2}};
        {_, #sdp{}=SDP2} -> {{local, SDP2}, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{
        invite_req = Req, 
        invite_resp = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    status_update(proceeding_uas, Dialog1, Call);

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<300 andalso 
            (Status=:=init orelse Status=:=proceeding_uas) ->
    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
    {Offer1, Answer1} = case {Req#sipmsg.body, Resp#sipmsg.body} of
        {#sdp{}=SDP1, #sdp{}=SDP2} -> {{remote, SDP1}, {local, SDP2}};
        {_, #sdp{}=SDP2} -> {{local, SDP2}, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{
        invite_req = Req, 
        invite_resp = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    status_update(accepted_uas, Dialog1, Call);

do_response('INVITE', Code, _Req, _Resp, #dialog{answered=Answered}=Dialog, Call)
            when Code>=300 ->
    case Answered of
        undefined -> status_update({stop, Code}, Dialog, Call);
        _ -> status_update(confirmed, Dialog, Call)
    end;

do_response('INVITE', Code, _Req, _Resp, Dialog, Call) ->
    #dialog{status=Status} = Dialog,
    ?call_notice("Dialog unexpected INVITE response ~p in ~p", [Code, Status], Call),
    Dialog;
    
do_response('BYE', _Code, Req, _Resp, #dialog{caller_tag=CallerTag}=Dialog, Call) ->
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog, Call);

do_response('PRACK', Code, _Req, Resp, #dialog{status=proceeding_uas}=Dialog, Call)
            when Code>=200, Code<300 ->
    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
    {Offer1, Answer1} = case Resp#sipmsg.body of
        #sdp{}=SDP ->
            case {Offer, Answer} of
                {{remote, _}, undefined} -> {Offer, {local, SDP}};
                _ -> {Offer, Answer}
            end;
        _ ->
            {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    status_update(proceeding_uas, Dialog1, Call);

do_response('PRACK', Code, _Req, _Resp, #dialog{status=Status}=Dialog, Call) ->
    ?call_notice("ignoring PRACK ~p response in ~p", [Code, Status], Call),
    Dialog;

do_response(_, _, _, _, Dialog, _Call) ->
    Dialog.


%% @private
-spec status_update(nksip_dialog:status(), nksip:dialog(), call()) ->
    nksip:dialog().

status_update(Status, Dialog, Call) ->
    nksip_call_dialog:status_update(uas, Status, Dialog, Call).




