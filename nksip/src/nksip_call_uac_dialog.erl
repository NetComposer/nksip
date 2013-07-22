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

-module(nksip_call_uac_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/1, ack/1, response/1, make/4]).


%% ===================================================================
%% Public
%% ===================================================================

request(#call{uacs=[#uac{request=#sipmsg{method='ACK'}}|_]}=SD) ->
    {ok, SD};

request(#call{uacs=[#uac{request=Req}|_], dialogs=Dialogs}=SD) ->
    #sipmsg{method=Method, cseq=CSeq, headers=Hds, body=Body} = Req,
    case nksip_dialog:id(Req) of
        <<>> ->
            {ok, SD};
        DialogId ->
            case lists:keytake(DialogId, #dialog.id, Dialogs) of
                {value, Dialog, Rest} ->
                    #dialog{
                        id = DialogId, 
                        state = State, 
                        local_seq = LocalSeq,
                        inv_queue = Queue
                    } = Dialog,
                    #call{app_id=AppId, call_id=CallId} = SD,
                    ?debug(AppId, CallId, 
                           "Dialog ~s UAC request ~p (~p)", [DialogId, Method, State]),
                    Dialog1 = case CSeq > LocalSeq of
                        true -> Dialog#dialog{local_seq=CSeq};
                        false -> Dialog
                    end,
                    case Method of
                        'INVITE' when State=:=init; State=:=confirmed ->
                            Dialog2 = Dialog1#dialog{
                                inv_cseq=CSeq, inv_req_body=Body, inv_headers=Hds},
                            Dialog3 = 
                                nksip_dialog_lib:status_update(proceeding_uac, Dialog2),
                            {ok, SD#call{dialogs=[Dialog3|Rest]}};
                        'INVITE' ->
                            ?debug(AppId, CallId, 
                                  "Dialog ~s UAC stored INVITE lock", [DialogId]),
                            Dialog2 = Dialog1#dialog{inv_queue=Queue++[Req]},
                            {wait, SD#call{dialogs=[Dialog2|Rest]}};
                        'BYE' ->
                            Dialog2 = nksip_dialog_lib:status_update(bye, Dialog1),
                            {ok, SD#call{dialogs=[Dialog2|Rest]}};
                        _ ->
                            {ok, SD#call{dialogs=[Dialog1|Rest]}}
                    end;
                _ ->
                    {ok, SD}
            end
    end.
                            

ack(#call{uacs=[#uac{request=Req}|_], dialogs=Dialogs}=SD) ->
    #sipmsg{method='ACK', cseq=CSeq, body=Body} = Req,
    #call{app_id=AppId, call_id=CallId} = SD,
    case nksip_dialog:id(Req) of
        <<>> ->
            ?notice(AppId, CallId, "Dialog UAC invalid ACK", []),
            SD;
        DialogId ->
            case lists:keytake(DialogId, #dialog.id, Dialogs) of
                {value, Dialog, Rest} ->
                    #dialog{
                        id = DialogId, 
                        state = State, 
                        inv_cseq = LastCSeq,
                        inv_req_body = ReqBody,
                        inv_resp_body = RespBody
                    } = Dialog,
                    case State of
                        accepted_uac when CSeq=:=LastCSeq ->
                            ?debug(AppId, CallId, "Dialog ~s UAC request 'ACK' (~p)", 
                                   [DialogId, State]),
                            ReqBody1 = case ReqBody of
                                #sdp{} -> ReqBody;
                                _ -> Body
                            end,
                            Dialog1 = Dialog#dialog{
                                inv_req_body=undefined, 
                                inv_resp_body=undefined
                            },
                            Dialog2 = nksip_dialog_lib:status_update(confirmed, Dialog1),
                            Dialog3 = nksip_dialog_lib:session_update(uac, ReqBody1, 
                                                                      RespBody, Dialog2),
                            SD#call{dialogs=[Dialog3|Rest]};
                        _ ->
                            ?notice(AppId, CallId, "Dialog ~s UAC (~p) ignoring ACK", 
                                    [DialogId, State]),
                            SD
                    end;
                _ ->
                    ?notice(AppId, CallId, "Dialog ~s UAC invalid ACK", [DialogId]),
                    SD
            end
    end.
    
response(#call{uacs=[UAC|_], dialogs=Dialogs}=SD) ->
    #uac{
        request = #sipmsg{method=Method} = Req, 
        responses = [#sipmsg{response=Code}=Resp|_]
    } = UAC,
    DialogId = nksip_dialog:id(Resp),
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        false when Method=:='INVITE', Code>100, Code<300 ->
            Dialog = nksip_dialog_lib:create(uac, DialogId, Req, Resp),
            proc_response(SD#call{dialogs=[Dialog|Dialogs]});
        false ->
            SD;
        {value, Dialog, Rest} ->
            proc_response(SD#call{dialogs=[Dialog|Rest]})
    end.


 %% @private
make(DialogId, Method, Opts, SD) ->
    #call{app_id=AppId, call_id=CallId, dialogs=Dialogs} = SD,
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        {value, Dialog, Rest} ->
            #dialog{state=State, inv_cseq=InvCSeq} = Dialog,
            ?debug(AppId, CallId, "Dialog ~s UAC make ~p (~p)", 
                   [DialogId, Method, State]),
            case Method of
                'ACK' when State=:=accepted_uac, is_integer(InvCSeq) ->
                    {Reply, Dialog1} = generate(Method, Opts, Dialog),
                    {ok, Reply, SD#call{dialogs=[Dialog1|Rest]}};
                'ACK' ->
                    {error, invalid};
                _ ->
                    {Reply, Dialog1} = generate(Method, Opts, Dialog),
                    {ok, Reply, SD#call{dialogs=[Dialog1|Rest]}}
            end;
        _ ->
            {error, not_found}
    end.


%% @private
proc_response(#call{uacs=[UAC|RestUACs], dialogs=[Dialog|RestDialogs]}=SD) ->
    #uac{request=#sipmsg{method=Method, cseq=CSeq, body=ReqBody}=Req} = UAC,
    #uac{responses=[#sipmsg{response=Code, body=RespBody}=Resp|_]} = UAC,
    #dialog{id=DialogId, state=State, timer=Timer} = Dialog,
    #call{app_id=AppId, call_id=CallId} = SD,
    ?debug(AppId, CallId, "Dialog ~s UAC response ~p (~p)", [DialogId, Code, State]),
    Result = case Method of
        _ when Code=:=408; Code=:=481 ->
            {remove, Code};
        'INVITE' ->
            if
                Code < 101 ->
                    {ok, Dialog};
                Code < 200, State=:=proceeding_uac ->
                    D1 = Dialog#dialog{inv_req_body=ReqBody, inv_resp_body=RespBody},
                    D2 = nksip_dialog_lib:status_update(proceeding_uac, D1),
                    D3 = nksip_dialog_lib:target_update(uac, Req, Resp, D2),
                    {ok, D3};
                Code < 300, State=:=proceeding_uac ->
                    D1 = Dialog#dialog{inv_req_body=ReqBody, inv_resp_body=RespBody,
                                       inv_cseq=CSeq},
                    D2 = nksip_dialog_lib:status_update(accepted_uac, D1),
                    D3 = nksip_dialog_lib:target_update(uas, Req, Resp, D2),
                    {ok, D3};
                Code < 300, State=:=accepted_uac ->
                    case 
                        [AckReq || 
                         #uac{request=#sipmsg{method='ACK', cseq=AckSeq}}=AckReq
                         <- RestUACs, AckSeq=:=CSeq]
                    of
                        [AckReq|_] ->
                            case nksip_transport_uac:resend_request(AckReq) of
                                {ok, _} -> 
                                    ?debug(AppId, CallId, 
                                           "Dialog ~s retransmitting ACK", [DialogId]),
                                    {ok, Dialog};
                                error -> 
                                    ?notice(AppId, CallId, 
                                            "Dialog ~s could not retransmit ACK", 
                                            [DialogId]),
                                    {remove, service_unavailable}
                            end;
                        _ ->
                            {ok, Dialog}
                    end;
                true ->
                    {ok, Dialog}
            end;
        'BYE' ->
            Reason = case nksip_dialog_lib:class(Req, Dialog) of
                uac -> caller_bye;
                uas -> callee_bye
            end,
            nksip_dialog_lib:status_update({stop, Reason}, Dialog),
            remove;
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, #dialog{state=State}=Dialog1} ->
            Dialog2 = nksip_dialog_lib:remotes_update(Resp, Dialog1), 
            nksip_lib:cancel_timer(Timer),
            {Msg, Time} = case State of
                accepted_uac -> {ack_timeout, 64*nksip_config:get(timer_t1)};
                _ -> {timeout, nksip_config:get(dialog_timeout)}
            end,
            Timer1 = erlang:start_timer(Time, self(), {dialog, Msg, DialogId}),
            SD#call{dialogs=[Dialog2#dialog{timer=Timer1}|RestDialogs]};
        remove ->
            nksip_lib:cancel_timer(Timer),
            nksip_dialog_lib:status_update({stop, Code}, Dialog),
            SD#call{dialogs=RestDialogs}
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
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
        inv_headers = InvHeaders,
        inv_cseq = InvCSeq
    } = Dialog,
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method =:= 'ACK' -> RCSeq = InvCSeq, LCSeq = CurrentCSeq;
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
            nksip_lib:extract(InvHeaders,
                              [<<"Authorization">>, <<"Proxy-Authorization">>])
        of
            false -> [];
            [] -> [];
            AuthHds -> {pre_headers, AuthHds}
        end
        | Opts
    ],
    {{AppId, RUri, Opts1}, Dialog#dialog{local_seq=LCSeq}}.


