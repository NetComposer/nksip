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

-export([test_request/2, request/2, ack/2, response/3]).
-export([make/4, new_local_seq/2, uac_id/3]).
-import(nksip_call_dialog, [status_update/3, target_update/5, session_update/2, store/2]).

-type call() :: nksip_call:call().



%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec test_request(nksip:request(), nksip_call:call()) ->
    ok | {error, Error} 
    when Error :: unknown_dialog | request_pending.

test_request(#sipmsg{class={req, 'ACK'}}, _) ->
    error(ack_in_dialog_test_request);

test_request(#sipmsg{to_tag = <<>>}, _Call) ->
    ok;

test_request(#sipmsg{class={req, Method}, dialog_id=DialogId}=Req, Call) ->
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status}=Dialog ->
            {HasSDP, _SDP, Offer, _} = get_sdp(Req, Dialog),
            if 
                Method=='INVITE', Status==confirmed, HasSDP, Offer/=undefined -> 
                    {error, request_pending};
                Method=='INVITE', Status/=confirmed -> 
                    {error, request_pending};
                Method=='UPDATE', HasSDP, Offer/=undefined ->
                    {error, request_pending};
                true ->
                    ok
            end;
        not_found ->
            {error, unknown_dialog}
    end.


%% @private
-spec request(nksip:request(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, Error} 
    when Error :: unknown_dialog | request_pending.

request(#sipmsg{class={req, 'ACK'}}, _) ->
    error(ack_in_dialog_request);

request(#sipmsg{dialog_id = <<>>}, Call) ->
    {ok, Call};

request(#sipmsg{class={req, Method}, dialog_id=DialogId}=Req, Call) ->
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{status=Status, local_seq=LocalSeq}=Dialog ->
            ?call_debug("Dialog ~s UAC request ~p in ~p", 
                        [DialogId, Method, Status], Call),
            #sipmsg{cseq=CSeq} = Req,
            Dialog1 = case CSeq > LocalSeq of
                true -> Dialog#dialog{local_seq=CSeq};
                false -> Dialog
            end,
            case do_request(Method, Status, Req, Dialog1, Call) of
                {ok, Dialog2} -> {ok, store(Dialog2, Call)};
                {error, Error} -> {error, Error}
            end;
        not_found when Method=='INVITE' ->
            {ok, Call};
        not_found ->
            {error, unknown_dialog}
    end.
      

%% @private
-spec do_request(nksip:method(), nksip_dialog:status(), nksip:request(), 
                 nksip:dialog(), call()) ->
    {ok, nksip:dialog()} | {error, Error} 
    when Error :: unknown_dialog | request_pending.

do_request(_, bye, _Req, _Dialog, _Call) ->
    {error, unknown_dialog};

do_request('INVITE', confirmed, Req, Dialog, Call) ->
    {HasSDP, SDP, Offer, _} = get_sdp(Req, Dialog),
    case HasSDP of
        true when Offer/=undefined ->
            {error, request_pending};
        _ ->
            Offer1 = case HasSDP of 
                true -> {local, invite, SDP};
                false -> undefined
            end,
            Dialog1 = Dialog#dialog{
                invite_req = Req, 
                invite_resp = undefined, 
                invite_class = uac,
                ack_req = undefined,
                sdp_offer = Offer1,
                sdp_answer = undefined
            },
            {ok, status_update(proceeding_uac, Dialog1, Call)}
    end;

do_request('INVITE', _Status, _Req, _Dialog, _Call) ->
    {error, request_pending};

do_request('BYE', _Status, _Req, Dialog, Call) ->
    {ok, status_update(bye, Dialog, Call)};

do_request('PRACK', proceeding_uac, Req, Dialog, Call) ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Req, Dialog),
    {Offer1, Answer1} = case Offer of
        undefined when HasSDP -> {{local, prack, SDP}, undefined};
        {remote, invite, _} when HasSDP -> {Offer, {local, prack, SDP}};
        % If {remote, invite, _} and no SDP, ACK must answer or delete
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
        undefined when HasSDP -> {ok, Dialog#dialog{sdp_offer={local, update, SDP}}};
        undefined -> {ok, Dialog};
        _ -> {error, request_pending}
    end;

do_request(_Method, _Status, _Req, Dialog, _Call) ->
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
        #dialog{status=Status} = Dialog ->
            ?call_debug("Dialog ~s (~p) UAC response ~p ~p", 
                        [DialogId, Status, Method, Code], Call),
            Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
            store(Dialog1, Call);
        not_found when Method=='INVITE', Code>100, Code<300 ->
            Dialog = nksip_call_dialog:create(uac, Req, Resp),
            {ok, Dialog1} = do_request('INVITE', confirmed, Req, Dialog, Call),
            response(Req, Resp, Call#call{dialogs=[Dialog1|Dialogs]});
        not_found ->
            Call
    end.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), call()) ->
    nksip:dialog().

do_response(_Method, Code, _Req, _Resp, Dialog, Call) 
            when Code==408; Code==481 ->
    status_update({stop, Code}, Dialog, Call);

do_response(_Method, Code, _Req, _Resp, Dialog, _Call) when Code < 101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code>100 andalso Code<300 andalso
            (Status==init orelse Status==proceeding_uac) ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {local, invite, _} when HasSDP ->
            {Offer, {remote, invite, SDP}};
        {local, invite, _} when Code>=200 ->
            {undefined, undefined};
        % New answer to previous INVITE offer, it is not a new offer
        undefined when element(1, Req#sipmsg.body)==sdp, HasSDP ->
           {{local, invite, Req#sipmsg.body}, {remote, invite, SDP}};
        undefined when HasSDP ->
            {{remote, invite, SDP}, undefined};
        % We are repeating a remote request
        {remote, invite, _} when HasSDP ->
            {{remote, invite, SDP}, undefined};
        _ ->
            {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{
        invite_resp = Resp,
        sdp_offer = Offer1,
        sdp_answer = Answer1
    },
    case Code >= 200 of
        true -> status_update(accepted_uac, Dialog1, Call);
        false -> status_update(proceeding_uac, Dialog1, Call)
    end;
   
    
do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<300 andalso 
            (Status==accepted_uac orelse Status==confirmed) ->
    #dialog{app_id=AppId, call_id=CallId, id=DialogId, ack_req=ACK} = Dialog,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case ACK of
        #sipmsg{} ->
            case nksip_transport_uac:resend_request(ACK, Opts) of
                {ok, _} ->
                    ?info(AppId, CallId, 
                          "Dialog ~s (~p) retransmitting 'ACK'", [DialogId, Status]),
                    Dialog;
                error ->
                    ?notice(AppId, CallId,
                            "Dialog ~s (~p) could not retransmit 'ACK'", 
                            [DialogId, Status]),
                    status_update({stop, 503}, Dialog, Call)
            end;
        _ ->
            ?call_info("Dialog ~s (~p) received 'INVITE' ~p but no ACK yet", 
                       [DialogId, Status, Code], Call),
            Dialog
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog, Call) 
            when Code>=300 andalso 
            (Status==init orelse Status==proceeding_uac) ->
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

do_response('INVITE', Code, _Req, Resp, Dialog, Call) ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    #dialog{id=DialogId, status=Status} = Dialog,
    case Status of
        bye ->
            ok;
        _ ->
            ?call_notice("Dialog ~s (~p) ignoring 'INVITE' ~p response",
                         [DialogId, Status, Code], Call)
    end,
    Dialog;

do_response('BYE', _Code, Req, _Resp, Dialog, Call) ->
    #dialog{caller_tag=CallerTag} = Dialog,
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog, Call);

do_response('PRACK', Code, _Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {local, prack, _} when HasSDP -> {Offer, {remote, prack, SDP}};
        {local, prack, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    session_update(Dialog1, Call);

do_response('PRACK', Code, _Req, _Resp, Dialog, _Call) when Code>300 ->
    #dialog{sdp_offer=Offer, sdp_answer=Answer} = Dialog,
    {Offer1, Answer1} = case Offer of
        {local, prack, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1};
    
do_response('UPDATE', Code, Req, Resp, Dialog, Call) when Code>=200, Code<300 ->
    {HasSDP, SDP, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {local, update, _} when HasSDP -> {Offer, {remote, update, SDP}};
        {local, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog1 = Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1},
    Dialog2 = target_update(uac, Req, Resp, Dialog1, Call),
    session_update(Dialog2, Call);

do_response('UPDATE', Code, _Req, Resp, Dialog, _Call) when Code>300 ->
    {_, _, Offer, Answer} = get_sdp(Resp, Dialog),
    {Offer1, Answer1} = case Offer of
        {local, update, _} -> {undefined, undefined};
        _ -> {Offer, Answer}
    end,
    Dialog#dialog{sdp_offer=Offer1, sdp_answer=Answer1};
    
do_response(_, _Code, _Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec ack(nksip:request(), call()) ->
    call().

ack(#sipmsg{class={req, 'ACK'}, dialog_id = <<>>}, Call) ->
    ?call_notice("Dialog UAC invalid ACK", [], Call),
    Call;

ack(#sipmsg{class={req, 'ACK'}, cseq=CSeq, dialog_id=DialogId}=AckReq, Call) ->
    case nksip_call_dialog:find(DialogId, Call) of
        #dialog{id=DialogId, status=Status, invite_req=InvReq}=Dialog ->
            #sipmsg{cseq=InvCSeq} = InvReq,
            case Status of
                accepted_uac when CSeq==InvCSeq ->
                    ?call_debug("Dialog ~s (~p) UAC request 'ACK'", 
                                [DialogId, Status], Call),
                    {HasSDP, SDP, Offer, Answer} = get_sdp(AckReq, Dialog), 
                    {Offer1, Answer1} = case Offer of
                        {remote, invite, _} when HasSDP -> {Offer, {local, ack, SDP}};
                        {remote, invite, _} -> {undefined, undefined};
                        _ -> {Offer, Answer}
                    end,
                    Dialog1 = Dialog#dialog{
                        ack_req = AckReq, 
                        sdp_offer = Offer1, 
                        sdp_answer = Answer1
                    },
                    Dialog2 = status_update(confirmed, Dialog1, Call),
                    store(Dialog2, Call);
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
        #dialog{status=Status}=Dialog ->
            ?call_debug("Dialog ~s make ~p request in ~p", 
                        [DialogId, Method, Status], Call),
            case Method=='ACK' andalso Status/=accepted_uac of
                true ->
                    {error, invalid_dialog};
                false ->
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
    case nksip_call_dialog:find(DialogId, Call) of
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
-spec get_sdp(nksip:request()|nksip:respomse(), nksip_dialog:dialog()) ->
    {boolean(), #sdp{}|undefined, sdp_offer()}.

get_sdp(#sipmsg{body=Body}, #dialog{sdp_offer=Offer, sdp_answer=Answer}) ->
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
        invite_req = Req
    } = Dialog,
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method == 'ACK' -> 
            RCSeq = Req#sipmsg.cseq, 
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





