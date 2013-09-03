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
-module(nksip_call_dialog_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([request/2, ack/2, response/2, make/4, new_local_seq/2]).
-import(nksip_call_dialog_lib, [create/3, status_update/2, remotes_update/2, 
                                find/2, update/2]).



-type call() :: nksip_call:call().

-type trans() :: nksip_call:trans().



%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec request(nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, Error} 
    when Error :: finished | request_pending.

request(#trans{method='ACK'}, Call) ->
    {ok, Call};

request(#trans{fork_id=undefined}=UAC, Call) ->
    #trans{method=Method, request=Req} = UAC,
    case nksip_dialog:id(Req) of
        undefined ->
            {ok, Call};
        {dlg, _AppId, _CallId, DialogId} ->
            case find(DialogId, Call) of
                #dialog{status=Status, local_seq=LocalSeq}=Dialog ->
                    ?call_debug("Dialog ~p UAC request ~p in ~p", 
                                [DialogId, Method, Status], Call),
                    #sipmsg{cseq=CSeq} = Req,
                    Dialog1 = case CSeq > LocalSeq of
                        true -> Dialog#dialog{local_seq=CSeq};
                        false -> Dialog
                    end,
                    case do_request(Method, Status, Req, Dialog1) of
                        {ok, Dialog2} -> {ok, update(Dialog2, Call)};
                        {error, Error} -> {error, Error}
                    end;
                not_found when Method=:='INVITE' ->
                    {ok, Call};
                not_found ->
                    {error, finished}
            end
    end;

request(_, Call) ->
    {ok, Call}.


        

%% @private
-spec do_request(nksip:method(), nksip_dialog:status(), nksip:request(), 
                 nksip:dialog()) ->
    {ok, nksip:dialog()} | {error, Error} 
    when Error :: finished | request_pending.

do_request(_, bye, _Req, _Dialog) ->
    {error, finished};

do_request('INVITE', confirmed, Req, Dialog) ->
    Dialog1 = Dialog#dialog{request=Req},
    {ok, status_update(proceeding_uac, Dialog1)};

do_request('INVITE', _Status, _Req, _Dialog) ->
    {error, request_pending};

do_request('BYE', _Status, _Req, Dialog) ->
    {ok, status_update(bye, Dialog)};

do_request(_Method, _Status, _Req, Dialog) ->
    {ok, Dialog}.


%% @private
-spec ack(trans(), call()) ->
    call().

ack(#trans{method='ACK', request=Req}, Call) ->
    #sipmsg{cseq=CSeq} = Req,
    case nksip_dialog:id(Req) of
        undefined ->
            ?call_notice("Dialog UAC invalid ACK", [], Call),
            Call;
        {dlg, _AppId, _CallId, DialogId} ->
            case find(DialogId, Call) of
                #dialog{status=Status, request=InvReq}=Dialog ->
                    #sipmsg{cseq=InvCSeq} = InvReq,
                    case Status of
                        accepted_uac when CSeq=:=InvCSeq ->
                            ?call_debug("Dialog ~p (~p) UAC request 'ACK'", 
                                        [DialogId, Status], Call),
                            Dialog1 = status_update(confirmed, Dialog#dialog{ack=Req}),
                            update(Dialog1, Call);
                        _ ->
                            ?call_notice("Dialog ~p (~p) ignoring ACK", 
                                         [DialogId, Status], Call),
                            Call
                    end;
                not_found ->
                    ?call_notice("Dialog ~p not found for UAC ACK", [DialogId], Call),
                    Call
            end
    end.
    

%% @private
-spec response(trans(), call()) ->
    call().

response(#trans{fork_id=undefined}=UAC, #call{dialogs=Dialogs}=Call) ->
    #trans{method=Method, request=Req, response=Resp} = UAC,
    case nksip_dialog:id(Resp) of
        undefined ->
            Call;
        {dlg, _AppId, _CallId, DialogId} ->
            #sipmsg{response=Code} = Resp,
            case find(DialogId, Call) of
                #dialog{status=Status} = Dialog ->
                    ?call_debug("Dialog ~p (~p) UAC response ~p ~p", 
                                [DialogId, Status, Method, Code], Call),
                    Dialog1 = do_response(Method, Code, Req, Resp, Dialog),
                    Dialog2 = remotes_update(Resp, Dialog1),
                    update(Dialog2, Call);
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = create(uac, Req, Resp),
                    response(UAC, Call#call{dialogs=[Dialog|Dialogs]});
                not_found ->
                    Call
            end
    end;

response(_, Call) ->
    Call.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog()) ->
    nksip:dialog().

do_response(_Method, Code, _Req, _Resp, Dialog) when Code=:=408; Code=:=481 ->
    status_update({stop, Code}, Dialog);

do_response(_Method, Code, _Req, _Resp, Dialog) when Code < 101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<200 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    status_update(proceeding_uac, Dialog1);

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog) 
            when Code<300 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    status_update(accepted_uac, Dialog1);
    
do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog) 
            when Code<300 andalso (Status=:=accepted_uac orelse Status=:=confirmed) ->
    #dialog{app_id=AppId, call_id=CallId, id=DialogId, ack=ACK} = Dialog,
    case ACK of
        #sipmsg{} ->
            case nksip_transport_uac:resend_request(ACK) of
                {ok, _} ->
                    ?info(AppId, CallId, 
                          "Dialog ~p (~p) retransmitting 'ACK'", [DialogId, Status]),
                    Dialog;
                error ->
                    ?notice(AppId, CallId,
                            "Dialog ~p (~p) could not retransmit 'ACK'", 
                            [DialogId, Status]),
                    status_update({stop, 503}, Dialog)
            end;
        _ ->
            ?info(AppId, CallId, 
                    "Dialog ~p (~p) received 'INVITE' ~p but no ACK yet", 
                    [DialogId, Status, Code]),
            Dialog
    end;

do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog) 
            when Code>=300 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
    case Dialog#dialog.answered of
        undefined -> status_update({stop, Code}, Dialog);
        _ -> status_update(confirmed, Dialog)
    end;

do_response('INVITE', Code, _Req, Resp, #dialog{id=DialogId, status=Status}=Dialog) ->
    #sipmsg{response=Code} = Resp,
    #dialog{app_id=AppId, call_id=CallId} = Dialog,
    ?notice(AppId, CallId, "Dialog ~p (~p) ignoring 'INVITE' ~p response",
           [DialogId, Status, Code]),
    Dialog;

do_response('BYE', _Code, Req, _Resp, #dialog{local_tag=LocalTag}=Dialog) ->
    Reason = case Req#sipmsg.from_tag of
        LocalTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog);

do_response(_, _Code, _Req, _Resp, Dialog) ->
    Dialog.


 %% @private
-spec make(integer(), nksip:method(), nksip_lib:proplist(), call()) ->
    {ok, {AppId, RUri, Opts}, call()} | {error, Error}
    when Error :: invalid_dialog | unknown_dialog,
         AppId::nksip:app_id(), RUri::nksip:uri(), Opts::nksip_lib:proplist().

make(DialogId, Method, Opts, #call{dialogs=Dialogs}=Call) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        #dialog{app_id=AppId, call_id=CallId, status=Status}=Dialog ->
            ?debug(AppId, CallId, "Dialog ~p make ~p request in ~p", 
                   [DialogId, Method, Status]),
            case Method=:='ACK' andalso Status=/=accepted_uac of
                true ->
                    {error, invalid_dialog};
                false ->
                    {Result, Dialog1} = generate(Method, Opts, Dialog),
                    {ok, Result, update(Dialog1, Call)}
            end;
        _ ->
            {error, unknown_dialog}
    end.


%% @private
-spec new_local_seq(nksip:request(), call()) ->
    {nksip:cseq(), call()}.

new_local_seq(Req, Call) ->
    case nksip_dialog:id(Req) of
        undefined ->
            {nksip_config:cseq(), Call};
        {dlg, _, _, DialogId} ->
            case find(DialogId, Call) of
                #dialog{local_seq=LocalSeq}=Dialog ->
                    Dialog1 = Dialog#dialog{local_seq=LocalSeq+1},
                    {LocalSeq+1, update(Dialog1, Call)};
                not_found ->
                    {nksip_config:cseq(), Call}
            end
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec generate(nksip:method(), nksip_lib:proplist(), nksip:dialog()) ->
    {{AppId, RUri, Opts}, nksip:dialog()} 
    when AppId::nksip:app_id(), RUri::nksip:uri(), Opts::nksip_lib:proplist().

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
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method =:= 'ACK' -> 
            RCSeq = Req#sipmsg.cseq, 
            LCSeq = CurrentCSeq;
        0 when CurrentCSeq > 0 -> 
            RCSeq = LCSeq = CurrentCSeq+1;
        0 -> 
            RCSeq = LCSeq = nksip_config:cseq()+100;
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
                [] -> 
                    ?notice(AppId, CallId, "Dialog UAC ~p request has invalid "
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
        case Method of
            'ACK' ->
                case 
                    nksip_lib:extract(Req#sipmsg.headers,
                                      [<<"Authorization">>, <<"Proxy-Authorization">>])
                of
                    [] -> [];
                    AuthHds -> {pre_headers, AuthHds}
                end;
            _ ->
                []
        end
        | Opts
    ],
    {{AppId, RUri, Opts1}, Dialog#dialog{local_seq=LCSeq}}.




