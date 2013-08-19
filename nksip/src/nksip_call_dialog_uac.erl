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

-export([request/2, ack/2, response/3, make/4]).
-import(nksip_call_dialog, [create/4, status_update/2, remotes_update/2, 
                            find/2, store/2]).


%% ===================================================================
%% Public
%% ===================================================================

request(#sipmsg{method='ACK'}, SD) ->
    {ok, SD};

request(#sipmsg{id=ReqId, method=Method, cseq=CSeq}=Req, #call{dialogs=Dialogs}=SD) ->
    case nksip_dialog:id(Req) of
        undefined ->
            {ok, SD};
        {dlg, AppId, CallId, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{
                    status = Status, 
                    local_seq = LocalSeq,
                    inv_queue = Queue
                } = Dialog ->
                    ?debug(AppId, CallId, 
                           "Dialog ~p UAC request ~p (~p)", [DialogId, Method, Status]),
                    D1 = case CSeq > LocalSeq of
                        true -> Dialog#dialog{local_seq=CSeq};
                        false -> Dialog
                    end,
                    case Method of
                        _ when Status=:=bye ->
                            {bye, SD};
                        'INVITE' when Status=:=confirmed ->
                            D2 = D1#dialog{request=Req, response=undefined},
                            D3 = status_update(proceeding_uac, D2),
                            {ok, SD#call{dialogs=store(D3, Dialogs)}};
                        'INVITE' ->
                            ?debug(AppId, CallId, 
                                  "Dialog ~p UAC stored INVITE lock", [DialogId]),
                            D2 = D1#dialog{inv_queue=Queue++[ReqId]},
                            {wait, SD#call{dialogs=store(D2, Dialogs)}};
                        'BYE' ->
                            D2 = status_update(bye, D1),
                            {ok, SD#call{dialogs=store(D2, Dialogs)}};
                        _ ->
                            {ok, SD#call{dialogs=store(D1, Dialogs)}}
                    end;
                not_found ->
                    {bye, SD}
            end
    end.
                            

ack(Req, #call{app_id=AppId, call_id=CallId, dialogs=Dialogs}=SD) ->
    #sipmsg{method='ACK', cseq=CSeq, body=Body} = Req,
    case nksip_dialog:id(Req) of
        undefined ->
            ?notice(AppId, CallId, "Dialog UAC invalid ACK", []),
            SD;
        {dlg, AppId, CallId, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{
                    status = Status, 
                    request = #sipmsg{cseq=LastCSeq, body=ReqBody} = InvReq
                } = Dialog ->
                    case Status of
                        accepted_uac when CSeq=:=LastCSeq ->
                            ?debug(AppId, CallId, "Dialog ~p UAC request 'ACK' (~p)", 
                                   [DialogId, Status]),
                            D1 = case ReqBody of
                                #sdp{} -> 
                                    Dialog#dialog{ack=Req};
                                _ -> 
                                    InvReq1 = InvReq#sipmsg{body=Body},
                                    Dialog#dialog{request=InvReq1, ack=Req}
                            end,
                            D2 = status_update(confirmed, D1),
                            SD#call{dialogs=store(D2, Dialogs)};
                        _ ->
                            ?notice(AppId, CallId, "Dialog ~p UAC in ~p ignoring ACK", 
                                    [DialogId, Status]),
                            SD
                    end;
                not_found ->
                    ?notice(AppId, CallId, "Dialog ~p UAC invalid ACK", [DialogId]),
                    SD
            end
    end.
    
response(Req, Resp, #call{dialogs=Dialogs}=SD) ->
    #sipmsg{method=Method} = Req, 
    #sipmsg{response=Code} = Resp,
    case nksip_dialog:id(Resp) of
        undefined ->
            SD;
        {dlg, _, _, DialogId} ->
            case find(DialogId, Dialogs) of
                #dialog{status=Status} = Dialog ->
                    ?call_debug("Dialog ~p UAC response ~p (~p)", 
                                [DialogId, Code, Status], SD),
                    Dialogs1 = case do_response(Method,Code, Req, Resp, Dialog) of
                        {ok, Dialog1} -> 
                            Dialog2 = remotes_update(Resp, Dialog1),
                            store(Dialog2, Dialogs);
                        {stop, Reason} -> 
                            removed = status_update({stop, Reason}, Dialog),
                            lists:keydelete(DialogId, #dialog.id, Dialogs)
                    end,
                    SD#call{dialogs=Dialogs1};
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = create(uac, DialogId, Req, Resp),
                    response(Req, Resp, [Dialog|Dialogs]);
                not_found ->
                    SD
            end
    end.


%% @private
do_response(_Method, Code, _Req, _Resp, _Dialog) when Code=:=408; Code=:=481 ->
    {stop, Code};

do_response(_, Code, _Req, _Resp, Dialog) when Code < 101 ->
    {ok, Dialog};

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<200, Status=:=init; Status=:=proceeding_uac ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    {ok, status_update(proceeding_uac, Dialog1)};

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<300, Status=:=init; Status=:=proceeding_uac ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    {ok, status_update(accepted_uac, Dialog1)};
    
do_response('INVITE', Code, Req, _Resp, #dialog{id=Id, status=Status, ack=ACK}=Dialog) 
            when Code<300, Status=:=accepted_uac; Status=:=confirmed ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
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
                    {stop, 503}
            end;
        _ ->
            ?notice(AppId, CallId, 
                  "Dialog ~p received 'INVITE' ~p retransmission "
                  "in ~p but no ACK yet", [Id, Code, Status]),
            {ok, Dialog}
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status, answered=Answered}=Dialog) 
            when Code>=300, Status=:=init; Status=:=proceeding_uac ->
    Dialog1 = Dialog#dialog{request=undefined, response=undefined, ack=undefined},
    case Answered of
        undefined -> {stop, Code};
        _ -> {ok, status_update(confirmed, Dialog1)}
    end;

do_response('INVITE', Code, Req, Resp, #dialog{id=Id, status=Status}=Dialog) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
    #sipmsg{response=Code} = Resp,
    ?notice(AppId, CallId, "Dialog ~p ignoring 'INVITE' ~p response in ~p",
           [Id, Code, Status]),
    {ok, Dialog};

do_response('BYE', _Code, Req, _Resp, #dialog{local_tag=LocalTag}) ->
    Reason = case Req#sipmsg.from_tag of
        LocalTag -> caller_bye;
        _ -> callee_bye
    end,
    {stop, Reason};

do_response(_, _Code, _Req, _Resp, Dialog) ->
    {ok, Dialog}.


 %% @private
make(DialogId, Method, Opts, SD) ->
    #call{app_id=AppId, call_id=CallId, dialogs=Dialogs} = SD,
    case lists:keytake(DialogId, #dialog.id, Dialogs) of
        {value, #dialog{status=Status}=Dialog, Rest} ->
            ?debug(AppId, CallId, "Dialog ~p UAC make ~p (~p)", 
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




