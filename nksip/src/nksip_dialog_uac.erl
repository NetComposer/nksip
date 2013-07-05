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

%% @doc Dialog UAC processing module

-module(nksip_dialog_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_internal.hrl").

-export([make/3, new_cseq/1, pre_request/1, pre_request_error/1, request/1, response/2]).
-export([proc_make/5, proc_pre_request/4, proc_pre_request_error/4,
         proc_request/4, proc_response/3]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Generates a new in-dialog request.
-spec make(nksip_dialog:spec(), nksip:method(), nksip_lib:proplist()) ->
    {ok, {nksip:sipapp_id(), nksip:uri(), nksip_lib:proplist()}} | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog | invalid_dialog.

make(DialogSpec, Method, Opts) ->
    nksip_dialog_fsm:call(DialogSpec, {make, Method, Opts}).


%% @doc Gets the next local_seq from dialog.
-spec new_cseq(nksip_dialog:spec()) ->
    {ok, nksip:cseq()} | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog.

new_cseq(DialogSpec) ->
    nksip_dialog_fsm:call(DialogSpec, new_cseq).


%% ===================================================================
%% Private
%% ==================================================================

%% @private Called before a SipApp uac is about to send an INVITE request
-spec pre_request(nksip:request()) -> 
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog | invalid_dialog.

pre_request(#sipmsg{method='INVITE', to_tag=ToTag, cseq=CSeq}=Req) 
            when ToTag=/=(<<>>) ->
    nksip_dialog_fsm:call(Req, {pre_request, CSeq});
pre_request(_) ->
    ok.


%% @private Called when a SipApp uac has failed sending a pre-request
-spec pre_request_error(nksip:request()) -> 
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog | invalid_dialog.

pre_request_error(#sipmsg{method='INVITE', to_tag=ToTag, cseq=CSeq}=Req) 
            when ToTag=/=(<<>>) ->
    nksip_dialog_fsm:call(Req, {pre_request_error, CSeq});
pre_request_error(_) ->
    ok.


%% @private Called when a SipApp uac has successfully sent a request
-spec request(nksip:request()) -> 
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog | invalid_dialog.

request(#sipmsg{to_tag=ToTag}=Req) when ToTag=/=(<<>>) ->
    nksip_dialog_fsm:call(Req, {request, uac, Req});
request(_) ->
    ok.


%% @private Called when a UAC request could create a dialog
-spec response(nksip:request(), nksip:response()) ->
    ok | {error, Error}
    when Error :: unknown_dialog | timeout_dialog | terminated_dialog | invalid_dialog.

response(_Req, #sipmsg{cseq_method='CANCEL'}) ->
    ok;
response(#sipmsg{ruri=RUri}=Req, 
         #sipmsg{response=Code, cseq_method='INVITE', to=To, to_tag=ToTag}=Resp) ->
    case nksip_dialog_fsm:call(Resp, {response, uac, Resp}) of
        ok ->
            ok;
        {error, unknown_dialog} when Code > 100, Code < 300 ->
            Pid = nksip_dialog_fsm:start(uac, Resp#sipmsg{ruri=RUri}),
            case request(Req#sipmsg{to=To, to_tag=ToTag}) of
                ok -> nksip_dialog_fsm:call(Pid, {response, uac, Resp});
                {error, Error} -> {error, Error}
            end;
        {error, unknown_dialog} ->
            ok;
        {error, Error} ->
            {error, Error}
    end;
response(_Req, Resp) ->
    nksip_dialog_fsm:call(Resp, {response, uac, Resp}),
    ok.


 %% @private
-spec proc_make(nksip:method(), nksip_lib:proplist(), term(), 
                    nksip_dialog:state(), #dlg_state{}) ->
    #dlg_state{}.

proc_make(Method, Opts, From, StateName, SD) ->
    #dlg_state{dialog=Dialog, invite_request=InvReq} = SD,
    #dialog{id=DialogId, sipapp_id=AppId, call_id=CallId} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s UAC make ~p (~p)", [DialogId, Method, StateName]),
    case Method of
        'ACK' when StateName=:=accepted_uac, is_integer(InvReq#sipmsg.cseq) ->
            {Reply, SD1} = generate('ACK', Opts, SD),
            gen_fsm:reply(From, {ok, Reply}),
            SD1;
        'ACK' ->
            gen_fsm:reply(From, {error, invalid_dialog}),
            SD;
        _ ->
            {Reply, SD1} = generate(Method, Opts, SD),
            gen_fsm:reply(From, {ok, Reply}),
            SD1
    end.


%% @private
-spec proc_pre_request(nksip:cseq(), term(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_pre_request(CSeq, From, StateName, SD) ->
    #dlg_state{dialog=Dialog, invite_queue=Queue} = SD,
    #dialog{id=DialogId, sipapp_id=AppId, call_id=CallId} = Dialog,
    if
        StateName=:=init; StateName=:=confirmed ->
            gen_fsm:reply(From, ok),
            ?debug(AppId, CallId, "Dialog ~s UAC invite lock", [DialogId]),
            {proceeding_uac, SD#dlg_state{invite_request=#sipmsg{cseq=CSeq}}};
        true ->
            ?debug(AppId, CallId, "Dialog ~s UAC stored invite lock", [DialogId]),
            {StateName, SD#dlg_state{invite_queue=Queue++[{From, CSeq}]}}
    end.


%% @private
-spec proc_pre_request_error(nksip:cseq(), term(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_pre_request_error(CSeq, From, StateName, SD) ->
    #dlg_state{dialog=Dialog, invite_request=InvReq} = SD,
    #dialog{id=DialogId, sipapp_id=AppId, call_id=CallId} = Dialog, 
    if
        StateName=:=proceeding_uac; CSeq=:=InvReq#sipmsg.cseq ->
            ?debug(AppId, CallId, "Dialog ~s UAC invite lock released", [DialogId]),
            gen_fsm:reply(From, ok),
            {confirmed, SD#dlg_state{invite_request=undefined}};
        true ->
            gen_fsm:reply(From, {error, invalid_dialog}),
            {StateName, SD}
    end.


%% @private
-spec proc_request(nksip:request(), term(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_request(Req, From, StateName, SD) ->
    #dlg_state{invite_request=InvReq, dialog=Dialog} = SD,
    #dialog{id=DialogId, sipapp_id=AppId, call_id=CallId, local_seq=LocalSeq}=Dialog,
    #sipmsg{method=Method, body=Body, cseq=CSeq}=Req, 
    ?debug(AppId, CallId, "Dialog ~s UAC request ~p (~p)", 
           [DialogId, Method, StateName]),
    SD1 = case CSeq > LocalSeq of
        true -> SD#dlg_state{dialog=Dialog#dialog{local_seq=CSeq}};
        false -> SD
    end,
    case Method of
        'INVITE' when StateName=:=init; StateName=:=confirmed ->
            gen_fsm:reply(From, ok),
            {proceeding_uac, SD1#dlg_state{invite_request=Req}};
        'INVITE' when StateName=:=proceeding_uac, CSeq=:=InvReq#sipmsg.cseq ->
            gen_fsm:reply(From, ok),
            {proceeding_uac, SD1#dlg_state{invite_request=Req}};
        'INVITE' ->
            gen_fsm:reply(From, {error, invalid_dialog}),
            {StateName, SD1};
        'ACK' when StateName=:=accepted_uac, CSeq=:=InvReq#sipmsg.cseq ->
            gen_fsm:reply(From, ok),
            % Take the SDP from the ACK request if the INVITE didn't have it
            SD2 = case InvReq#sipmsg.body of
                #sdp{} -> SD1;
                _ -> SD1#dlg_state{invite_request=InvReq#sipmsg{body=Body}}
            end,
            SD3 = nksip_dialog_lib:session_update(uac, SD2),
            SD4 = SD3#dlg_state{is_first=false, invite_request=undefined, 
                                invite_response=undefined, ack_request=Req},
            {confirmed, SD4};
        'ACK' ->
            gen_fsm:reply(From, {error, invalid_dialog}),
            ?notice(AppId, CallId, "Dialog ~s UAC (~p) ignoring ACK", 
                    [DialogId, StateName]),
            {StateName, SD1};
        'BYE' ->
            gen_fsm:reply(From, ok),
            Reason = case nksip_dialog_lib:class(Req, SD) of
                uac -> caller_bye;
                uas -> callee_bye
            end,
            Dialog1 = Dialog#dialog{stop_reason=Reason},
            {bye, SD1#dlg_state{dialog=Dialog1}};
        _ ->
            gen_fsm:reply(From, ok),
            {StateName, SD1}    
    end.


%% @private
-spec proc_response(nksip:response(), nksip_dialog:state(), #dlg_state{}) ->
    {nksip_dialog:state(), #dlg_state{}}.

proc_response(Res, StateName, SD) ->
    #sipmsg{response=Code, cseq=CSeq, cseq_method=Method}= Res,  
    #dlg_state{invite_request=InvReq, ack_request=AckReq, dialog=Dialog} = SD,
    #dialog{id=DialogId, sipapp_id=AppId, call_id=CallId, answered=Answered} = Dialog,
    ?debug(AppId, CallId, "Dialog ~s UAC response ~p (~p)", 
           [DialogId, Code, StateName]),
    if 
        Method=:='INVITE' andalso InvReq#sipmsg.cseq=:=CSeq andalso
        (StateName=:=init orelse StateName=:=proceeding_uac) ->
            if
                Code < 101 ->
                    {proceeding_uac, SD};
                Code < 200 ->
                    SD1 = SD#dlg_state{invite_response=Res},
                    nksip_dialog_lib:target_update(uac, proceeding_uac, SD1);
                Code < 300 ->
                    SD1 = SD#dlg_state{invite_response=Res},
                    nksip_dialog_lib:target_update(uac, accepted_uac, SD1);
                Code >= 300, Answered =:= undefined ->
                    Dialog1 = Dialog#dialog{stop_reason=nksip_dialog_lib:reason(Code)},
                    {stop, SD#dlg_state{dialog=Dialog1}};
                Code >= 300 ->
                    SD1 = SD#dlg_state{invite_request=undefined, 
                                       invite_response=undefined},
                    {confirmed, SD1}
            end;
        Method=:='INVITE' andalso Code >= 200 andalso Code < 300 ->
            case AckReq of
                #sipmsg{cseq=CSeq} ->
                    case nksip_transport_uac:resend_request(AckReq) of
                        {ok, _} -> 
                            ?debug(AppId, CallId, 
                                   "Dialog ~s retransmitting ACK", [DialogId]),
                            {StateName, SD};
                        error -> 
                            ?notice(AppId, CallId, 
                                    "Dialog ~s could not retransmit ACK", [DialogId]),
                            Dialog1 = Dialog#dialog{stop_reason=service_unavailable},
                            {stop, SD#dlg_state{dialog=Dialog1}}
                    end;
                _ ->
                    {StateName, SD}      % No ACK yet, ignore
            end;
        Method=:='INVITE' ->
            ?debug(AppId, CallId, "Dialog ~s UAC (~p) ignoring INVITE response ~p",
                   [DialogId, StateName, Code]),
            {StateName, SD};
        Method=:='BYE', Code >= 200, Code < 300 ->
            {stop, SD};
        true ->
            {StateName, SD}
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec generate(nksip:method(), nksip_lib:proplist(), #dlg_state{}) ->
    {{nksip:sipapp_id(), nksip:uri(), nksip_lib:proplist()}, #dlg_state{}}.

generate(Method, Opts, SD) ->
    #dlg_state{invite_request=InvReq, dialog=Dialog} = SD,
    #dialog{
        id = DialogId,
        sipapp_id = AppId,
        call_id = CallId,
        local_uri = From,
        remote_uri = To,
        local_seq = CurrentCSeq, 
        local_target = LocalTarget,
        remote_target = RUri, 
        route_set = RouteSet
    } = Dialog,
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method =:= 'ACK' -> RCSeq = InvReq#sipmsg.cseq, LCSeq = CurrentCSeq;
        0 when CurrentCSeq > 0 -> RCSeq = LCSeq = CurrentCSeq+1;
        0 -> RCSeq = LCSeq = nksip_config:cseq()+100;
        RCSeq when CurrentCSeq > 0 -> LCSeq = CurrentCSeq;
        RCSeq -> LCSeq = RCSeq
    end,
    Contacts = case nksip_lib:get_value(contact, Opts) of
        undefined ->
            [];
        ContactSpec ->
            case nksip_parse:uris(ContactSpec) of
                [] -> 
                    ?notice(AppId, CallId, "Dialog UAC ~s request has invalid "
                                            "contact: ~p", [DialogId, ContactSpec]),
                    [];
                Contacts0 -> 
                    Contacts0
            end
    end,
    Opts1 = [
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
        end,
        case 
            Method=:='ACK' andalso 
            nksip_lib:extract(InvReq#sipmsg.headers, 
                              [<<"Authorization">>, <<"Proxy-Authorization">>])
        of
            false -> [];
            [] -> [];
            AuthHds -> {pre_headers, AuthHds}
        end
        | Opts
    ],
    Dialog1 = Dialog#dialog{local_seq=LCSeq},
    {{AppId, RUri, Opts1}, SD#dlg_state{dialog=Dialog1}}.


