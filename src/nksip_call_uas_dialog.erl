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

%% @private Call dialog UAS processing module
-module(nksip_call_uas_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/2, response/3, make/3]).
-import(nksip_call_dialog, [find/2, invite_update/3, store/2,
                            find_event/2, event_update/4]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec request(nksip:request(), call()) ->
    {ok, nksip_dialog:id(), call()} | {error, Error}
    when Error :: old_cseq | unknown_dialog | bye | 
                  request_pending | retry | invalid.

request(#sipmsg{to_tag = <<>>}, Call) ->
    {ok, Call};

request(#sipmsg{class={req, 'ACK'}}=Req, Call) ->
    ack(Req, Call);

request(Req, Call) ->
    #sipmsg{class={req, Method}, cseq=CSeq, dialog_id=DialogId} = Req,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{remote_seq=RemoteSeq}=Dialog ->
            ?call_debug("Dialog ~s UAS request ~p", [DialogId, Method], Call),
            case RemoteSeq>0 andalso CSeq<RemoteSeq of
                true ->
                    {error, old_cseq};
                false -> 
                    Dialog1 = Dialog#dialog{remote_seq=CSeq},
                    case do_request(Method, Req, Dialog1, Call) of
                        {ok, Dialog2} -> {ok, store(Dialog2, Call)};
                        {error, Error} -> {error, Error}
                    end
            end;
        not_found -> 
            {error, unknown_dialog}
    end.


%% @private
-spec do_request(nksip:method(), nksip:request(), nksip:dialog(), call()) ->
    {ok, nksip:dialog()} | {error, Error}
    when Error :: bye | request_pending | retry | invalid.


do_request('INVITE', Req, #dialog{invite=undefined}=Dialog, Call) ->
    Invite = #dialog_invite{status=confirmed},
    do_request('INVITE', Req, Dialog#dialog{invite=Invite}, Call);

do_request('INVITE', Req, 
           #dialog{invite=#dialog_invite{status=confirmed}=Invite}=Dialog, _Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Invite),
    case HasSDP of
        true when Offer/=undefined ->
            {error, request_pending};
        _ ->
            Offer1 = case HasSDP of 
                true -> {remote, invite, SDP};
                false -> undefined
            end,
            Invite1 = Invite#dialog_invite{
                status = proceeding_uas,
                class = uas,
                request = Req, 
                response = undefined, 
                ack = undefined,
                sdp_offer = Offer1,
                sdp_answer = undefined
            },
            {ok, Dialog#dialog{invite=Invite1}}
    end;

do_request('INVITE', _Req, #dialog{invite=#dialog_invite{status=Status}}, _Call) ->
    case Status of
        proceeding_uac -> {error, request_pending};
        accepted_uac -> {error, request_pending};
        proceeding_uas -> {error, retry};
        accepted_uas -> {error, retry}
    end;

do_request('BYE', _Req, #dialog{invite=#dialog_invite{}=Invite}=Dialog, Call) ->
    #dialog{id=DialogId} = Dialog,
    #dialog_invite{status=Status} = Invite,
    case Status of
        confirmed -> ok;
        _ -> ?call_debug("Dialog ~s (~p) received BYE", [DialogId, Status], Call)
    end,
    {ok, invite_update(bye, Dialog, Call)};

do_request('PRACK', Req, 
           #dialog{invite=#dialog_invite{status=proceeding_uas}=Invite}=Dialog, Call) ->
    {HasSDP, SDP, Offer, _Answer} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP ->
            Invite1 = Invite#dialog_invite{sdp_offer={remote, prack, SDP}},
            {ok, Dialog#dialog{invite=Invite1}};
        {local, invite, _} when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_answer={remote, prack, SDP}},
            {ok, invite_update(prack, Dialog#dialog{invite=Invite1}, Call)};
        _ -> 
            % If {local, invite, _} and no SDP, ACK must answer or delete
            {ok, Dialog}
    end;

do_request('PRACK', _Req, _Dialog, _Call) ->
    {error, request_pending};

do_request('UPDATE', Req, #dialog{invite=#dialog_invite{}=Invite}=Dialog, _Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_offer={remote, update, SDP}},
            {ok, Dialog#dialog{invite=Invite1}};
        undefined ->
            {ok, Dialog};
        {local, _, _} -> 
            {error, request_pending};
        {remote, _, _} -> 
            {error, retry}
    end;

do_request(_, _, Dialog, _Call) ->
    {ok, Dialog}.


%% @private
-spec response(nksip:request(), nksip:response(), call()) ->
    call().

response(Req, Resp, Call) ->
    #sipmsg{class={req, Method}} = Req,
    #sipmsg{class={resp, Code, _Reason}, dialog_id=DialogId} = Resp,
    #call{dialogs=Dialogs} = Call,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{}=Dialog ->
            ?call_debug("Dialog ~s UAS ~p response ~p", [DialogId, Method, Code], Call),
            Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
            store(Dialog1, Call);
        not_found
            when Code>100 andalso Code<300 andalso
               (Method=='INVITE' orelse Method=='SUBSCRIBE' orelse
                Method=='NOTIFY') ->
            Dialog1 = nksip_call_dialog:create(uas, Req, Resp, Call),
            {ok, Dialog2} = do_request(Method, Req, Dialog1, Call),
            response(Req, Resp, Call#call{dialogs=[Dialog2|Dialogs]});
        not_found ->
            Call
    end.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), call()) ->
    nksip:dialog().

do_response(_, Code, _Req, _Resp, Dialog, Call) when Code==408; Code==481 ->
    nksip_call_dialog:stop(Code, Dialog, Call);

do_response(_, Code, _Req, _Resp, Dialog, _Call) when Code<101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, 
            #dialog{invite=#dialog_invite{status=proceeding_uas}=Invite}=Dialog, Call) 
            when Code>100 andalso Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {remote, invite, _} when HasSDP ->
            {Offer, {local, invite, SDP}};
        {remote, invite, _} when Code>=200 ->
            {undefined, undefined};
        undefined when HasSDP, element(1, Req#sipmsg.body)==sdp ->
            % New answer to previous INVITE offer, it is not a new offer
           {{remote, invite, Req#sipmsg.body}, {local, invite, SDP}};
        undefined when HasSDP ->
            {{local, invite, SDP}, undefined};
        {local, invite, _} when HasSDP ->
            % We are repeating a remote request
            {{local, invite, SDP}, undefined};
        _ ->
            {Offer, Answer}
    end,
    Invite1 = Invite#dialog_invite{
        response = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    Dialog1 = Dialog#dialog{invite=Invite1},
    case Code < 200 of
        true -> invite_update(proceeding_uas, Dialog1, Call);
        false -> invite_update(accepted_uas, Dialog1, Call)
    end;

do_response('INVITE', Code, _Req, Resp, 
            #dialog{invite=#dialog_invite{status=proceeding_uas}=Invite}=Dialog, Call) 
            when Code>=300 ->
    case Invite#dialog_invite.answered of
        undefined -> 
            invite_update({stop, Code}, Dialog, Call);
        _ -> 
            Offer1 = case Invite#dialog_invite.sdp_offer of
                {_, invite, _} -> undefined;
                {_, prack, _} -> undefined;
                Offer -> Offer
            end,
            Invite1 = Invite#dialog_invite{response=Resp, sdp_offer=Offer1},
            invite_update(confirmed, Dialog#dialog{invite=Invite1}, Call)
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{id=DialogId}=Dialog, Call) ->
    case Dialog#dialog.invite of
        #dialog_invite{status=Status} -> ok;
        _ -> Status = undefined
    end,
    ?call_notice("Dialog UAS ~s ignoring unexpected INVITE response ~p in ~p", 
                 [DialogId, Code, Status], Call),
    Dialog;

do_response('BYE', _Code, Req, _Resp, Dialog, Call) ->
    #dialog{caller_tag=CallerTag} = Dialog,
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    invite_update({stop, Reason}, Dialog, Call);

do_response('PRACK', Code, _Req, Resp, 
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, Call) 
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, _Answer} = get_sdp(Resp, Invite),
    case Offer of
        {remote, prack, _} when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_answer={local, prack, SDP}},
            invite_update(prack, Dialog#dialog{invite=Invite1}, Call);
        {remote, prack, _} -> 
            Invite1 = Invite#dialog_invite{sdp_offer=undefined, sdp_answer=undefined},
            Dialog#dialog{invite=Invite1};
        _ ->
            Dialog
    end;

do_response('PRACK', Code, _Req, _Resp, 
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, _Call) 
            when Code>300 ->
    case Invite#dialog_invite.sdp_offer of
        {remote, prack, _} -> 
            Invite1 = Invite#dialog_invite{sdp_offer=undefined, sdp_answer=undefined},
            Dialog#dialog{invite=Invite1};
        _ -> 
            Dialog
    end;
    
do_response('UPDATE', Code, Req, Resp,
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, Call)
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {remote, update, _} when HasSDP -> {Offer, {local, update, SDP}};
        {remote, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Invite1 = Invite#dialog_invite{sdp_offer=Offer1, sdp_answer=Answer1},
    invite_update({update, uas, Req, Resp}, Dialog#dialog{invite=Invite1}, Call);

do_response('UPDATE', Code, _Req, _Resp,
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, _Call)
            when Code>300 ->
    case Invite#dialog_invite.sdp_offer of
        {remote, update, _} ->
            Invite1 = Invite#dialog_invite{sdp_offer=undefined, sdp_answer=undefined},
            Dialog#dialog{invite=Invite1};
        _ -> 
            Dialog
    end;
    
do_response('UPDATE', Code, Req, Resp,
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, Call)
            when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {local, update, _} when HasSDP -> {Offer, {remote, update, SDP}};
        {local, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Invite1 = Invite#dialog_invite{sdp_offer=Offer1, sdp_answer=Answer1},
    invite_update({update, uac, Req, Resp}, Dialog#dialog{invite=Invite1}, Call);

do_response('UPDATE', Code, _Req, _Resp, 
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, _Call)
            when Code>300 ->
    case Invite#dialog_invite.sdp_offer of
        {local, update, _} -> 
            Invite1 = Invite#dialog_invite{sdp_offer=undefined, sdp_answer=undefined},
            Dialog#dialog{invite=Invite1};
        _ ->
            Dialog
    end;
    
do_response('SUBSCRIBE', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    #sipmsg{event=EventId, expires=Expires} = Resp,
    case find_event(EventId, Dialog) of
        not_found ->
            #dialog{events=Events} = Dialog,
            Dialog1 = Dialog#dialog{events=[#dialog_event{id=EventId}|Events]},
            do_response('SUBSCRIBE', Code, Req, Resp, Dialog1, Call);
        #dialog_event{} = Event ->
            Expires1 = case is_integer(Expires) andalso Expires>=0 of
                true -> Expires; 
                false -> ?DEFAULT_EVENT_EXPIRES
            end,
            Event1 = Event#dialog_event{
                class = uas,
                request = Req,
                response = Resp,
                expires = Expires1
            },
            case Expires1 of
                0 -> event_update({terminated, timeout}, Event1, Dialog, Call);
                _ -> event_update(neutral, Event1, Dialog, Call)
            end
    end;


do_response('SUBSCRIBE', Code, _Req, Resp, Dialog, Call) 
            when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                 Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                 Code==604 ->
    #sipmsg{event=EventId} = Resp,
    case find_event(EventId, Dialog) of
        not_found ->
            Dialog;
        #dialog_event{} = Event ->
            event_update({terminated, Code}, Event, Dialog, Call)
    end;

do_response('NOTIFY', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    #sipmsg{event=EventId} = Resp,
    {Status1, Expires} = nksip_parse:notify_status(Resp),
     case find_event(EventId, Dialog) of
        not_found ->
            #dialog{events=Events} = Dialog,
            Dialog1 = Dialog#dialog{events=[#dialog_event{id=EventId}|Events]},
            do_response('NOTIFY', Code, Req, Resp, Dialog1, Call);
        #dialog_event{}=Event ->
            Expires1 = case is_integer(Expires) andalso Expires>=0 of
                true -> Expires; 
                false -> ?DEFAULT_EVENT_EXPIRES
            end,
            Event1 = Event#dialog_event{
                class = uas,
                request = Req, 
                response = Resp, 
                expires = Expires1
            },
            event_update(Status1, Event1, Dialog, Call)
    end;

do_response('NOTIFY', Code, _Req, Resp, Dialog, Call) 
            when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                 Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                 Code==604 ->
    #sipmsg{event=EventId} = Resp,
    case find_event(EventId, Dialog) of
        not_found ->
            Dialog;
        #dialog_event{} = Event ->
            event_update({terminated, Code}, Event, Dialog, Call)
    end;

do_response(_, _, _, _, Dialog, _Call) ->
    Dialog.

%% @private
-spec ack(nksip:request(), call()) ->
    call().

ack(#sipmsg{class={req, 'ACK'}}=AckReq, Call) ->
    #sipmsg{cseq=CSeq, dialog_id=DialogId} = AckReq,
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{invite=#dialog_invite{}=Invite}=Dialog ->
            #dialog_invite{status=Status, request=InvReq} = Invite,
            #sipmsg{cseq=InvSeq} = InvReq,
            ?call_debug("Dialog ~s (~p) UAS request 'ACK'", [DialogId, Status], Call),
            case Status of
                accepted_uas when CSeq==InvSeq->
                    {HasSDP, SDP, Offer, Answer} = get_sdp(AckReq, Invite), 
                    {Offer1, Answer1} = case Offer of
                        {local, invite, _} when HasSDP -> {Offer, {remote, ack, SDP}};
                        {local, invite, _} -> {undefined, undefined};
                        _ -> {Offer, Answer}
                    end,
                    Invite1 = Invite#dialog_invite{
                        ack = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = Dialog#dialog{invite=Invite1},
                    Dialog3 = invite_update(confirmed, Dialog2, Call),
                    {ok, store(Dialog3, Call)};
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

make(#sipmsg{cseq_method=Method, contacts=Contacts}=Resp, Opts, Call) ->
    #sipmsg{contacts=Contacts} = Resp,
    DialogId = nksip_dialog:class_id(uas, Resp),
    case lists:member(make_contact, Opts) of
        false when Contacts==[] ->
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{local_target=LTarget} ->
                    {
                        Resp#sipmsg{dialog_id=DialogId, contacts=[LTarget]},
                        Opts
                    };
                not_found when Method=='INVITE' orelse Method=='UPDATE' ->
                    {Resp#sipmsg{dialog_id=DialogId}, [make_contact|Opts]};
                not_found ->
                    {Resp#sipmsg{dialog_id=DialogId}, Opts}
            end; 
        _ ->
            {Resp#sipmsg{dialog_id=DialogId}, Opts}
    end.

%% @private
-spec get_sdp(nksip:request()|nksip:respomse(), #dialog_invite{}) ->
    {boolean(), #sdp{}|undefined, nksip_call_dialog:sdp_offer()}.

get_sdp(#sipmsg{body=Body}, #dialog_invite{sdp_offer=Offer, sdp_answer=Answer}) ->
    case Body of
        #sdp{} = SDP -> {true, SDP, Offer, Answer};
        _ -> {false, undefined, Offer, Answer}
    end.

