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

-export([request/2, response/3, make/3]).
-import(nksip_call_dialog, [status_update/3, target_update/5, session_update/2, store/2]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec request(nksip:request(), call()) ->
    {ok, nksip_dialog:id(), call()} | {error, Error}
    when Error :: old_cseq | unknown_dialog | bye | 
                  request_pending | retry | invalid.

request(#sipmsg{dialog_id = <<>>}, Call) ->
    {ok, undefined, Call};

request(#sipmsg{class={req, 'ACK'}}=Req, Call) ->
    ack(Req, Call);

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
                                 store(Dialog2, Call)};
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
    when Error :: bye | request_pending | retry | invalid.

do_request(_, bye, _Req, _Dialog, _Call) ->
    {error, bye};

do_request('INVITE', confirmed, Req, Dialog, Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Dialog),
    case HasSDP of
        true when Offer/=undefined ->
            {error, request_pending};
        _ ->
            Offer1 = case HasSDP of 
                true -> {remote, invite, SDP};
                false -> undefined
            end,
            Dialog1 = Dialog#dialog{
                invite_req = Req, 
                invite_resp = undefined, 
                invite_class = uas,
                ack_req = undefined,
                sdp_offer = Offer1,
                sdp_answer = undefined
            },
            {ok, status_update(proceeding_uas, Dialog1, Call)}
    end;

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uac; Status=:=accepted_uac ->
    {error, request_pending};

do_request('INVITE', Status, _Req, _Dialog, _Call) 
           when Status=:=proceeding_uas; Status=:=accepted_uas ->
    {error, retry};

do_request('BYE', Status, _Req, Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    case Status of
        confirmed -> ok;
        _ -> ?call_debug("Dialog ~s (~p) received BYE", [DialogId, Status], Call)
    end,
    {ok, status_update(bye, Dialog, Call)};

do_request('PRACK', proceeding_uas, Req, Dialog, Call) ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Req, Dialog),
    {Offer1, Answer1} = case Offer of
        undefined when HasSDP -> {{remote, prack, SDP}, undefined};
        {local, invite, _} when HasSDP -> {Offer, {remote, prack, SDP}};
        % If {local, invite, _} and no SDP, ACK must answer or delete
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    {ok, session_update(Dialog1, Call)};

do_request('PRACK', Status, _Req, Dialog, Call) ->
    ?call_notice("ignoring PRACK in ~p", [Status], Call),
    {ok, Dialog};

do_request('UPDATE', _Status, Req, Dialog, _Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Dialog),
    case Offer of
        undefined when HasSDP -> {ok, Dialog#dialog{sdp_offer={remote, update, SDP}}};
        undefined -> {ok, Dialog};
        {local, _, _} -> {error, request_pending};
        {remote, _, _} -> {error, retry}
    end;

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
            store(Dialog1, Call);
        not_found when Method=:='INVITE', Code>100, Code<300 ->
            Dialog = nksip_call_dialog:create(uas, Req, Resp),
            {ok, Dialog1} = do_request('INVITE', confirmed, Req, Dialog, Call),
            response(Req, Resp, Call#call{dialogs=[Dialog1|Dialogs]});
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
            when Code>100 andalso Code<300 andalso
            (Status=:=init orelse Status=:=proceeding_uas) ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {remote, invite, _} when HasSDP ->
            {Offer, {local, invite, SDP}};
        {remote, invite, _} when Code>=200 ->
            {undefined, undefined};
        % New answer to previous INVITE offer, it is not a new offer
        undefined when element(1, Req#sipmsg.body)==sdp, HasSDP ->
           {{remote, invite, Req#sipmsg.body}, {local, invite, SDP}};
        undefined when HasSDP ->
            {{local, invite, SDP}, undefined};
        % We are repeating a remote request
        {local, invite, _} when HasSDP ->
            {{local, invite, SDP}, undefined};
        _ ->
            {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{
        invite_resp = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    case Code >= 200 of
        true -> status_update(accepted_uas, Dialog1, Call);
        false -> status_update(proceeding_uas, Dialog1, Call)
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog, Call)
            when Code>=300 andalso 
            (Status=:=init orelse Status=:=proceeding_uas) ->
    #dialog{answered=Answered, sdp_offer=Offer} = Dialog,
    case Answered of
        undefined -> 
            status_update({stop, Code}, Dialog, Call);
        _ -> 
            Offer1 = case Offer of
                {_, invite, _} -> undefined;
                {_, prack, _} -> undefined;
                _ -> Offer
            end,
            Dialog1 = Dialog#dialog{sdp_offer=Offer1},
            status_update(confirmed, Dialog1, Call)
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

do_response('PRACK', Code, _Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {remote, prack, _} when HasSDP -> {Offer, {local, prack, SDP}};
        {remote, prack, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    session_update(Dialog1, Call);

do_response('PRACK', Code, _Req, Resp, Dialog, _Call) when Code>300 ->
    {_, _, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {remote, prack, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1};
    
do_response('UPDATE', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {remote, update, _} when HasSDP -> {Offer, {local, update, SDP}};
        {remote, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    Dialog2 = target_update(uas, Req, Resp, Dialog1, Call),
    session_update(Dialog2, Call);

 do_response('UPDATE', Code, _Req, Resp, Dialog, _Call) when Code>300 ->
    {_, _, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {remote, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1};
    
do_response(_, _, _, _, Dialog, _Call) ->
    Dialog.

%% @private
-spec ack(nksip:request(), call()) ->
    call().

ack(#sipmsg{class={req, 'ACK'}}=AckReq, Call) ->
    #sipmsg{cseq=AckSeq, dialog_id=DialogId} = AckReq,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status, invite_req=#sipmsg{cseq=InvSeq}}=Dialog ->
            ?call_debug("Dialog ~s (~p) UAS request 'ACK'", 
                        [DialogId, Status], Call),
            case Status of
                accepted_uas when InvSeq==AckSeq->
                    {HasSDP, SDP, Offer, Answer} = get_sdp(AckReq, Dialog), 
                    {Offer1, Answer1} = case Offer of
                        {local, invite, _} when HasSDP -> {Offer, {remote, ack, SDP}};
                        {local, invite, _} -> {undefined, undefined};
                        _ -> {Offer, Answer}
                    end,
                    Dialog1 = Dialog#dialog{
                        ack_req = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = status_update(confirmed, Dialog1, Call),
                    {ok, DialogId, store(Dialog2, Call)};
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
    end.


%% private
-spec make(nksip:response(), nksip_lib:proplist(), call()) ->
    {nksip:response(), nksip_lib:proplist()}.

make(#sipmsg{cseq_method=Method, contacts=Contacts}=Resp, Opts, Call)
        when Method=='INVITE'; Method=='UPDATE' ->
    #sipmsg{contacts=Contacts} = Resp,
    DialogId = nksip_dialog:class_id(uas, Resp),
    case lists:member(make_contact, Opts) of
        false when Contacts==[] ->
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{local_target=LTarget} ->
                    {
                        Resp#sipmsg{contacts=[LTarget], dialog_id=DialogId},
                        Opts
                    };
                not_found ->
                    {Resp#sipmsg{dialog_id=DialogId}, [make_contact|Opts]}
            end; 
        _ ->
            {Resp#sipmsg{dialog_id=DialogId}, Opts}
    end;

make(Resp, Opts, _Call) ->
    DialogId = nksip_dialog:class_id(uas, Resp),
    {Resp#sipmsg{dialog_id=DialogId}, Opts}.


%% @private
-spec get_sdp(nksip:request()|nksip:respomse(), nksip_dialog:dialog()) ->
    {boolean(), #sdp{}|undefined, sdp_offer()}.

get_sdp(#sipmsg{body=Body}, #dialog{sdp_offer=Offer, sdp_answer=Answer}) ->
    case Body of
        #sdp{} = SDP -> {true, SDP, Offer, Answer};
        _ -> {false, undefined, Offer, Answer}
    end.

