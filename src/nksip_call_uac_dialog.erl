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

%% @private Call dialog UAC processing module
-module(nksip_call_uac_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([pre_request/2, request/2, ack/2, response/3]).
-export([make/4, new_local_seq/2, uac_id/3]).
-import(nksip_call_dialog, [find/2, invite_update/3, store/2,
                            find_event/2, event_update/4]).

-type call() :: nksip_call:call().


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec pre_request(nksip:request(), nksip_call:call()) ->
    ok | {error, Error} 
    when Error :: unknown_dialog | unknown_event | request_pending.

pre_request(#sipmsg{class={req, 'ACK'}}, _) ->
    error(ack_in_dialog_pre_request);

pre_request(#sipmsg{to_tag = <<>>}, _Call) ->
    ok;

pre_request(Req, Call) ->
    #sipmsg{class={req, Method}, dialog_id=DialogId, event=EventId} = Req,
    case find(DialogId, Call) of
        #dialog{invite=Invite} = Dialog ->
            if
                Method=='INVITE'; Method=='UPDATE';  
                Method=='BYE'; Method=='PRACK'  ->
                    case Invite of
                        #dialog_invite{status=Status} = Invite ->
                            {HasSDP, _SDP, Offer, _} = get_sdp(Req, Invite),
                            if 
                                Method=='INVITE', Status/=confirmed -> 
                                    {error, request_pending};
                                Method=='INVITE', HasSDP, Offer/=undefined -> 
                                    {error, request_pending};
                                Method=='PRACK', Status/=proceeding_uac ->
                                    {error, request_pending};
                                Method=='UPDATE', HasSDP, Offer/=undefined ->
                                    {error, request_pending};
                                true ->
                                    ok 
                            end;
                        undefined when Method=='INVITE' ->
                            % Sending a INVITE over a event-created dialog
                            ok;
                        undefined ->
                            {error, unknown_dialog}
                    end;
                Method=='NOTIFY' ->
                    case find_event(EventId, Dialog) of
                        #dialog_event{} -> ok;
                        _ -> {error, unknown_event}
                    end;
                true ->
                    ok
            end;
        _ ->
            {error, unknown_dialog}
    end.


%% @private
-spec request(nksip:request(), nksip_call:call()) ->
    nksip_call:call().

request(#sipmsg{to_tag = <<>>}, Call) ->
    Call;

request(#sipmsg{class={req, Method}, dialog_id=DialogId}=Req, Call) ->
    ?call_debug("Dialog ~s UAC request ~p", [DialogId, Method], Call), 
    #dialog{local_seq=LocalSeq} = Dialog = find(DialogId, Call),
    #sipmsg{cseq=CSeq} = Req,
    Dialog1 = case CSeq > LocalSeq of
        true -> Dialog#dialog{local_seq=CSeq};
        false -> Dialog
    end,
    Dialog2 = do_request(Method, Req, Dialog1, Call),
    store(Dialog2, Call).
        
      
%% @private
-spec do_request(nksip:method(), nksip:request(), nksip:dialog(), call()) ->
    nksip:dialog().

do_request('INVITE', Req, #dialog{invite=undefined}=Dialog, Call) ->
    Invite = #dialog_invite{status=confirmed},
    do_request('INVITE', Req, Dialog#dialog{invite=Invite}, Call);

do_request('INVITE', Req, #dialog{invite=Invite}=Dialog, _Call) ->
    confirmed = Invite#dialog_invite.status,
    {HasSDP, SDP, _Offer, _} = get_sdp(Req, Invite),
    Offer1 = case HasSDP of 
        true -> {local, invite, SDP};
        false -> undefined
    end,
    Invite1 = Invite#dialog_invite{
        status = proceeding_uac,
        class = uac,
        request = Req, 
        response = undefined, 
        ack = undefined,
        sdp_offer = Offer1,
        sdp_answer = undefined
    },
    Dialog#dialog{invite=Invite1};

do_request('BYE', _Req, Dialog, Call) ->
    invite_update(bye, Dialog, Call);

do_request('PRACK', Req, #dialog{invite=Invite}=Dialog, Call) ->
    proceeding_uac = Invite#dialog_invite.status,
    {HasSDP, SDP, Offer, _Answer} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_offer={local, prack, SDP}},
            Dialog#dialog{invite=Invite1};
        {remote, invite, _} when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_answer={local, prack, SDP}},
            invite_update(prack, Dialog#dialog{invite=Invite1}, Call);
        _ -> 
            % If {remote, invite, _} and no SDP, ACK must answer or delete
            Dialog
    end;

do_request('UPDATE', Req, #dialog{invite=Invite}=Dialog, _Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Invite),
    case Offer of
        undefined when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_offer={local, update, SDP}},
            Dialog#dialog{invite=Invite1};
        _ -> 
            Dialog
    end;

do_request(_Method, _Req, Dialog, _Call) ->
    Dialog.


%% @private
-spec response(nksip:request(), nksip:response(), call()) ->
    call().

response(_, #sipmsg{to_tag = <<>>}, Call) ->
    Call;

response(Req, Resp, Call) ->
    #sipmsg{class={req, Method}} = Req,
    #sipmsg{class={resp, Code, _Reason}, dialog_id=DialogId} = Resp,
    #call{dialogs=Dialogs} = Call,
    case find(DialogId, Call) of
        #dialog{} = Dialog ->
            ?call_debug("Dialog ~s UAC response ~p ~p", [DialogId, Method, Code], Call),
            Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
            store(Dialog1, Call);
        not_found 
            when Code>100 andalso Code<300 andalso
               (Method=='INVITE' orelse Method=='SUBSCRIBE' orelse
                Method=='NOTIFY') ->
            Dialog1 = nksip_call_dialog:create(uac, Req, Resp, Call),
            Dialog2 = case Method of
                'INVITE' ->
                    Invite = #dialog_invite{status=confirmed},
                    Dialog1#dialog{invite=Invite};
                _ ->
                    Dialog1
            end,
            Dialog3 = do_request(Method, Req, Dialog2, Call),
            response(Req, Resp, Call#call{dialogs=[Dialog3|Dialogs]});
        not_found ->
            Call
    end.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), call()) ->
    nksip:dialog().

do_response(_Method, Code, _Req, _Resp, Dialog, Call) when Code==408; Code==481 ->
    nksip_call_dialog:stop(Code, Dialog, Call);

do_response(_Method, Code, _Req, _Resp, Dialog, _Call) when Code < 101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, 
            #dialog{invite=#dialog_invite{status=proceeding_uac}=Invite}=Dialog, Call) 
            when Code>100 andalso Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Invite),
    {Offer1, Answer1} = case Offer of
        {local, invite, _} when HasSDP ->
            {Offer, {remote, invite, SDP}};
        {local, invite, _} when Code>=200 ->
            {undefined, undefined};
        undefined when HasSDP, element(1, Req#sipmsg.body)==sdp ->
            % New answer to previous INVITE offer, it is not a new offer
           {{local, invite, Req#sipmsg.body}, {remote, invite, SDP}};
        undefined when HasSDP ->
            {{remote, invite, SDP}, undefined};
        {remote, invite, _} when HasSDP ->
            % We are repeating a remote request
            {{remote, invite, SDP}, undefined};
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
        true -> invite_update(proceeding_uac, Dialog1, Call);
        false -> invite_update(accepted_uac, Dialog1, Call)
    end;
   
do_response('INVITE', Code, _Req, Resp, 
            #dialog{invite=#dialog_invite{status=proceeding_uac}=Invite}=Dialog, Call) 
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

    do_response('INVITE', Code, _Req, _Resp, 
            #dialog{invite=#dialog_invite{status=accepted_uac}=Invite}=Dialog, Call) 
            when Code<300 ->
    #dialog{app_id=AppId, call_id=CallId, id=DialogId, invite=Invite} = Dialog,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case Invite#dialog_invite.ack of
        #sipmsg{}=ACK ->
            case nksip_transport_uac:resend_request(ACK, Opts) of
                {ok, _} ->
                    ?info(AppId, CallId, 
                          "Dialog ~s (accepted_uac) retransmitting 'ACK'", [DialogId]),
                    Dialog;
                error ->
                    ?notice(AppId, CallId,
                            "Dialog ~s (accepted_uac) could not retransmit 'ACK'", 
                            [DialogId]),
                    invite_update({stop, 503}, Dialog, Call)
            end;
        _ ->
            ?call_info("Dialog ~s (accepted_uac) received 'INVITE' ~p but no ACK yet", 
                       [DialogId, Code], Call),
            Dialog
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{id=DialogId}=Dialog, Call) ->
    case Dialog#dialog.invite of
        #dialog_invite{status=Status} -> ok;
        _ -> Status = undefined
    end,
    ?call_notice("Dialog UAC ~s ignoring unexpected INVITE response ~p in ~p", 
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
        {local, prack, _} when HasSDP -> 
            Invite1 = Invite#dialog_invite{sdp_answer={remote, prack, SDP}},
            invite_update(prack, Dialog#dialog{invite=Invite1}, Call);
        {local, prack, _} -> 
            Invite1 = Invite#dialog_invite{sdp_offer=undefined, sdp_answer=undefined},
            Dialog#dialog{invite=Invite1};
        _ -> 
            Dialog
    end;

do_response('PRACK', Code, _Req, _Resp, 
            #dialog{invite=#dialog_invite{}=Invite}=Dialog, _Call) 
            when Code>300 ->
    case Invite#dialog_invite.sdp_offer  of
        {local, prack, _} -> 
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
                class = uac,
                request = Req,
                response = Resp,
                expires = Expires1
            },
            case Expires1 of
                0 -> event_update({terminated, timeout}, Event1, Dialog, Call);
                _ -> event_update(neutral, Event1, Dialog, Call)
            end
    end;

do_response('SUBSCRIBE', Code, _Req, Resp, Dialog, Call) when Code>=300 ->
    #sipmsg{event=EventId} = Resp,
    case find_event(EventId, Dialog) of
        not_found ->
            Dialog;
        #dialog_event{answered=undefined} = Event ->
            event_update({terminated, Code}, Event, Dialog, Call);
        #dialog_event{} ->
            if
                Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                Code==604 ->
                    event_update({terminated, Code}, Event, Dialog, Call);
                true ->
                    Dialog
            end
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
                class = uac,
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

do_response(_, _Code, _Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec ack(nksip:request(), call()) ->
    call().

ack(#sipmsg{class={req, 'ACK'}, to_tag = <<>>}, Call) ->
    ?call_notice("Dialog UAC invalid ACK", [], Call),
    Call;

ack(#sipmsg{class={req, 'ACK'}, cseq=CSeq, dialog_id=DialogId}=AckReq, Call) ->
    case find(DialogId, Call) of
        #dialog{invite=#dialog_invite{}=Invite}=Dialog ->
            #dialog_invite{status=Status, request=InvReq} = Invite,
            #sipmsg{cseq=InvCSeq} = InvReq,
            case Status of
                accepted_uac when CSeq==InvCSeq ->
                    ?call_debug("Dialog ~s (~p) UAC request 'ACK'", 
                                [DialogId, Status], Call),
                    {HasSDP, SDP, Offer, Answer} = get_sdp(AckReq, Invite), 
                    {Offer1, Answer1} = case Offer of
                        {remote, invite, _} when HasSDP -> {Offer, {local, ack, SDP}};
                        {remote, invite, _} -> {undefined, undefined};
                        _ -> {Offer, Answer}
                    end,
                    Invite1 = Invite#dialog_invite{
                        ack = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = Dialog#dialog{invite=Invite1},
                    Dialog3 = invite_update(confirmed, Dialog2, Call),
                    store(Dialog3, Call);
                _ ->
                    ?call_notice("Dialog ~s (~p) ignoring ACK", 
                                 [DialogId, Status], Call),
                    Call
            end;
        not_found ->
            ?call_notice("Dialog ~s not found for UAC ACK", [DialogId], Call),
            Call
    end.
    

 %% @private
-spec make(integer(), nksip:method(), nksip_lib:proplist(), call()) ->
    {ok, {AppId, RUri, Opts}, call()} | {error, Error}
    when Error :: invalid_dialog | unknown_dialog,
         AppId::nksip:app_id(), RUri::nksip:uri(), Opts::nksip_lib:proplist().

make(DialogId, Method, Opts, #call{dialogs=Dialogs}=Call) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        #dialog{invite=Invite}=Dialog ->
            ?call_debug("Dialog ~s make ~p request", 
                        [DialogId, Method], Call),
            case Invite of
                #dialog_invite{status=Status} when
                    Method=='ACK' andalso Status/=accepted_uac ->
                    {error, invalid_dialog};
                _ ->
                    {Result, Dialog1} = generate(Method, Opts, Dialog),
                    {ok, Result, store(Dialog1, Call)}
            end;
        _ ->
            {error, unknown_dialog}
    end.


%% @private
-spec new_local_seq(nksip:request(), call()) ->
    {nksip:cseq(), call()}.

new_local_seq(#sipmsg{dialog_id = <<>>}, Call) ->
    {nksip_config:cseq(), Call};

new_local_seq(#sipmsg{dialog_id=DialogId}, Call) ->
    case find(DialogId, Call) of
        #dialog{local_seq=LocalSeq}=Dialog ->
            Dialog1 = Dialog#dialog{local_seq=LocalSeq+1},
            {LocalSeq+1, store(Dialog1, Call)};
        not_found ->
            {nksip_config:cseq(), Call}
    end.


%% @private
-spec uac_id(nksip:request()|nksip:response(), boolean(), call()) ->
    nksip_dialog:id().

uac_id(SipMsg, IsProxy, #call{dialogs=Dialogs}) ->
    case nksip_dialog:class_id(uac, SipMsg) of
        <<>> ->
            <<>>;
        DlgIdA when not IsProxy ->
            DlgIdA;
        DlgIdA ->
            % If it is a proxy, we can be proxying a request in the opposite
            % direction, DlgIdA is not goint to exist, but DlgIdB is the
            % original dialog, use it
            case lists:keymember(DlgIdA, #dialog.id, Dialogs) of
                true ->
                    DlgIdA;
                false ->
                    DlgIdB = nksip_dialog:class_id(uas, SipMsg),
                    case lists:keymember(DlgIdB, #dialog.id, Dialogs) of
                        true -> DlgIdB;
                        false -> DlgIdA
                    end
            end
    end.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec get_sdp(nksip:request()|nksip:respomse(), #dialog_invite{}) ->
    {boolean(), #sdp{}|undefined, nksip_call_dialog:sdp_offer()}.

get_sdp(#sipmsg{body=Body}, #dialog_invite{sdp_offer=Offer, sdp_answer=Answer}) ->
    case Body of
        #sdp{} = SDP -> {true, SDP, Offer, Answer};
        _ -> {false, undefined, Offer, Answer}
    end.


%% @private
-spec generate(nksip:method(), nksip_lib:proplist(), nksip:dialog()) ->
    {{RUri, Opts}, nksip:dialog()} 
    when RUri::nksip:uri(), Opts::nksip_lib:proplist().

generate(Method, Opts, Dialog) ->
    #dialog{
        id = DialogId,
        app_id = AppId,
        call_id = CallId,
        local_uri = From,
        remote_uri = To,
        local_seq = CurrentCSeq, 
        local_target = LocalTarget,
        remote_target = RUri, 
        route_set = RouteSet,
        invite = Invite
    } = Dialog,
    case Invite of
        #dialog_invite{request=#sipmsg{cseq=InvCSeq}=Req} -> ok;
        _ -> Req = undefined, InvCSeq = 0
    end,
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method == 'ACK' -> 
            RCSeq = InvCSeq, 
            LCSeq = CurrentCSeq;
        0 when CurrentCSeq > 0 -> 
            RCSeq = LCSeq = CurrentCSeq+1;
        0 -> 
            RCSeq = LCSeq = nksip_config:cseq()+1000;
        RCSeq when CurrentCSeq > 0 -> 
            LCSeq = CurrentCSeq;
        RCSeq -> 
            LCSeq = RCSeq
    end,
    Contacts = case nksip_lib:get_value(contact, Opts) of
        undefined ->
            [];
        ContactSpec ->
            case nksip_parse:uris(ContactSpec) of
                [Contact0] -> 
                    [Contact0];
                _ -> 
                    ?notice(AppId, CallId, "Dialog ~s UAC request has invalid "
                                            "contact: ~p", [DialogId, ContactSpec]),
                    []
            end
    end,
    Opts1 = 
        case Method of
            'ACK' ->
                case 
                    nksip_lib:extract(Req#sipmsg.headers,
                                      [<<"Authorization">>, <<"Proxy-Authorization">>])
                of
                    [] -> [];
                    AuthHds -> [{pre_headers, AuthHds}]
                end;
            _ ->
                []
        end
        ++
        [
            {from, From},
            {to, To},
            {call_id, CallId},
            {cseq, RCSeq},
            {route, RouteSet},
            case lists:member(make_contact, Opts) of
                true ->
                    make_contact;
                false ->
                    case Contacts of
                        [] -> {contact, [LocalTarget]};
                        _ -> {contact, Contacts}
                    end
            end
            | Opts
        ],
    {{RUri, Opts1}, Dialog#dialog{local_seq=LCSeq}}.





