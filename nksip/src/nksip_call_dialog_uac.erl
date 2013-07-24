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

-module(nksip_call_dialog_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/1, ack/1, response/1, make/4]).
-import(nksip_call_dialog, [create/4, status_update/2, remotes_update/2]).


%% ===================================================================
%% Public
%% ===================================================================

request(#call{uacs=[#uac{request=#sipmsg{method='ACK'}}|_]}=SD) ->
    {ok, SD};

request(#call{uacs=[#uac{id=Id, request=Req}|_], dialogs=Dialogs}=SD) ->
    #sipmsg{method=Method, cseq=CSeq} = Req,
    case nksip_dialog:id(Req) of
        <<>> ->
            {ok, SD};
        DialogId ->
            case lists:keytake(DialogId, #dialog.id, Dialogs) of
                {value, Dialog, Rest} ->
                    #dialog{
                        id = DialogId, 
                        status = Status, 
                        local_seq = LocalSeq,
                        inv_queue = Queue
                    } = Dialog,
                    #call{app_id=AppId, call_id=CallId} = SD,
                    ?debug(AppId, CallId, 
                           "Dialog ~s UAC request ~p (~p)", [DialogId, Method, Status]),
                    Dialog1 = case CSeq > LocalSeq of
                        true -> Dialog#dialog{local_seq=CSeq};
                        false -> Dialog
                    end,
                    case Method of
                        'INVITE' when Status=:=confirmed ->
                            D2 = Dialog1#dialog{request=Req, response=undefined},
                            D3 = status_update(proceeding_uac, D2),
                            {ok, SD#call{dialogs=[D3|Rest]}};
                        'INVITE' ->
                            ?debug(AppId, CallId, 
                                  "Dialog ~s UAC stored INVITE lock", [DialogId]),
                            Dialog2 = Dialog1#dialog{inv_queue=Queue++[Id]},
                            {wait, SD#call{dialogs=[Dialog2|Rest]}};
                        'BYE' ->
                            Dialog2 = status_update(bye, Dialog1),
                            {ok, SD#call{dialogs=[Dialog2|Rest]}};
                        _ ->
                            {ok, SD#call{dialogs=[Dialog1|Rest]}}
                    end;
                false ->
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
                        status = Status, 
                        request = #sipmsg{cseq=LastCSeq, body=ReqBody} = InvReq
                    } = Dialog,
                    case Status of
                        accepted_uac when CSeq=:=LastCSeq ->
                            ?debug(AppId, CallId, "Dialog ~s UAC request 'ACK' (~p)", 
                                   [DialogId, Status]),
                            D1 = case ReqBody of
                                #sdp{} -> 
                                    Dialog#dialog{ack=Req};
                                _ -> 
                                    InvReq1 = InvReq#sipmsg{body=Body},
                                    Dialog#dialog{request=InvReq1, ack=Req}
                            end,
                            D2 = status_update(confirmed, D1),
                            SD#call{dialogs=[D2|Rest]};
                        _ ->
                            ?notice(AppId, CallId, "Dialog ~s UAC in ~p ignoring ACK", 
                                    [DialogId, Status]),
                            SD
                    end;
                false ->
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
            Dialog = create(uac, DialogId, Req, Resp),
            do_response(SD#call{dialogs=[Dialog|Dialogs]});
        false ->
            SD;
        {value, Dialog, Rest} ->
            do_response(SD#call{dialogs=[Dialog|Rest]})
    end.


 %% @private
make(DialogId, Method, Opts, SD) ->
    #call{app_id=AppId, call_id=CallId, dialogs=Dialogs} = SD,
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        {value, #dialog{status=Status}=Dialog, Rest} ->
            ?debug(AppId, CallId, "Dialog ~s UAC make ~p (~p)", 
                   [DialogId, Method, Status]),
            case Method of
                'ACK' when Status=:=accepted_uac ->
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
do_response(#call{uacs=[UAC|_], dialogs=[Dialog|Rest]}=SD) ->
    #uac{request=#sipmsg{method=Method, from_tag=FromTag}=Req} = UAC,
    #uac{responses=[#sipmsg{response=Code}=Resp|_]} = UAC,
    #dialog{id=DialogId, status=Status, ack=ACK, 
            local_tag=LocalTag, answered=Answered} = Dialog,
    #call{app_id=AppId, call_id=CallId} = SD,
    ?debug(AppId, CallId, "Dialog ~s UAC response ~p (~p)", [DialogId, Code, Status]),
    Result = case Method of
        _ when Code=:=408; Code=:=481 ->
            {remove, Code};
        'INVITE' ->
            if
                Code < 101 ->
                    {ok, Dialog};
                Code < 200 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
                    D1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
                    {ok, status_update(proceeding_uac, D1)};
                Code < 300 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
                    D1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
                    {ok, status_update(accepted_uac, D1)};
                Code < 300 andalso (Status=:=accepted_uac orelse Status=:=confirmed) ->
                    case ACK of
                        #sipmsg{} ->
                            case nksip_transport_uac:resend_request(ACK) of
                                {ok, _} ->
                                    ?info(AppId, CallId, 
                                          "UAC retransmitting 'ACK' in ~p", [Status]),
                                    {ok, Dialog};
                                error ->
                                    ?notice(AppId, CallId,
                                            "UAC could not retransmit 'ACK' in ~p", 
                                            [Status]),
                                    {remove, 503}
                            end;
                        _ ->
                            ?notice(AppId, CallId, 
                                  "Dialog ~s received 'INVITE' ~p retransmission "
                                  "in ~p but no ACK yet", [DialogId, Code, Status]),
                            {ok, Dialog}
                    end;
                Code >= 300 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
                    D1 = Dialog#dialog{ack=undefined},
                    case Answered of
                        undefined -> {remove, Code};
                        _ -> {ok, status_update(confirmed, D1)}
                    end;
                true ->
                    ?notice(AppId, CallId, "Dialog ~s ignorinig ~p ~p response in ",
                           [DialogId, Method, Code]),
                    {ok, Dialog}
            end;
        'BYE' ->
            Reason = case FromTag of
                LocalTag -> caller_bye;
                _ -> callee_bye
            end,
            {remove, Reason};
        _ ->
            {ok, Dialog}
    end,
    case Result of
        {ok, Dialog1} ->
            Dialog2 = remotes_update(Resp, Dialog1), 
            SD#call{dialogs=[Dialog2|Rest]};
        {remove, StopReason} ->
            status_update({stop, StopReason}, Dialog),
            SD#call{dialogs=Rest}
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
        request = Req
    } = Dialog,
    case Method of
        'ACK' -> #sipmsg{cseq=InvCSeq, headers=Headers} = Req;
        _ -> InvCSeq = 1, Headers = []
    end,
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
            nksip_lib:extract(Headers,
                              [<<"Authorization">>, <<"Proxy-Authorization">>])
        of
            false -> [];
            [] -> [];
            AuthHds -> {pre_headers, AuthHds}
        end
        | Opts
    ],
    {{AppId, RUri, Opts1}, Dialog#dialog{local_seq=LCSeq}}.




