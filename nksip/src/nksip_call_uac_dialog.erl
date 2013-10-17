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

-export([request/2, ack/2, response/3, make/4, new_local_seq/2]).

-type call() :: nksip_call:call().



%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec request(nksip:request(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, Error} 
    when Error :: finished | request_pending.

request(#sipmsg{method='ACK'}, _) ->
    error(ack_in_dialog_request);

request(#sipmsg{method=Method}=Req, Call) ->
    case nksip_dialog:id(Req) of
        <<>> ->
            {ok, Call};
        DialogId ->
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
                        {ok, Dialog2} -> 
                            {ok, nksip_call_dialog:update(Dialog2, Call)};
                        {error, Error} -> 
                            {error, Error}
                    end;
                not_found when Method=:='INVITE' ->
                    {ok, Call};
                not_found ->
                    {error, finished}
            end
    end.
        

%% @private
-spec do_request(nksip:method(), nksip_dialog:status(), nksip:request(), 
                 nksip:dialog(), call()) ->
    {ok, nksip:dialog()} | {error, Error} 
    when Error :: finished | request_pending.

do_request(_, bye, _Req, _Dialog, _Call) ->
    {error, finished};

do_request('INVITE', confirmed, Req, Dialog, Call) ->
    Dialog1 = Dialog#dialog{request=Req},
    {ok, status_update(proceeding_uac, Dialog1, Call)};

do_request('INVITE', _Status, _Req, _Dialog, _Call) ->
    {error, request_pending};

do_request('BYE', _Status, _Req, Dialog, Call) ->
    {ok, status_update(bye, Dialog, Call)};

do_request(_Method, _Status, _Req, Dialog, _Call) ->
    {ok, Dialog}.


%% @private
-spec ack(nksip:request(), call()) ->
    call().

ack(#sipmsg{method='ACK'}=Req, Call) ->
    #sipmsg{cseq=CSeq} = Req,
    case nksip_dialog:id(Req) of
        <<>> ->
            ?call_notice("Dialog UAC invalid ACK", [], Call),
            Call;
        DialogId ->
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{status=Status, request=InvReq}=Dialog ->
                    #sipmsg{cseq=InvCSeq} = InvReq,
                    case Status of
                        accepted_uac when CSeq=:=InvCSeq ->
                            ?call_debug("Dialog ~s (~p) UAC request 'ACK'", 
                                        [DialogId, Status], Call),
                            Dialog1 = Dialog#dialog{ack=Req},
                            Dialog2 = status_update(confirmed, Dialog1, Call),
                            nksip_call_dialog:update(Dialog2, Call);
                        _ ->
                            ?call_notice("Dialog ~s (~p) ignoring ACK", 
                                         [DialogId, Status], Call),
                            Call
                    end;
                not_found ->
                    ?call_notice("Dialog ~s not found for UAC ACK", [DialogId], Call),
                    Call
            end
    end.
    

%% @private
-spec response(nksip:request(), nksip:response(), call()) ->
    call().

response(#sipmsg{method=Method}=Req, Resp, #call{dialogs=Dialogs}=Call) ->
    case nksip_dialog:id(Resp) of
        <<>> ->
            Call;
        DialogId ->
            #sipmsg{response=Code} = Resp,
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{status=Status} = Dialog ->
                    ?call_debug("Dialog ~s (~p) UAC response ~p ~p", 
                                [DialogId, Status, Method, Code], Call),
                    Dialog1 = do_response(Method, Code, Req, Resp, Dialog, Call),
                    % Dialog2 = nksip_call_dialog:remotes_update(Resp, Dialog1),
                    nksip_call_dialog:update(Dialog1, Call);
                not_found when Method=:='INVITE', Code>100, Code<300 ->
                    Dialog = nksip_call_dialog:create(uac, Req, Resp),
                    response(Req, Resp, Call#call{dialogs=[Dialog|Dialogs]});
                not_found ->
                    Call
            end
    end;

response(_, _, Call) ->
    Call.


%% @private
-spec do_response(nksip:method(), nksip:response_code(), nksip:request(),
                  nksip:response(), nksip:dialog(), call()) ->
    nksip:dialog().

do_response(_Method, Code, _Req, _Resp, Dialog, Call) when Code=:=408; Code=:=481 ->
    status_update({stop, Code}, Dialog, Call);

do_response(_Method, Code, _Req, _Resp, Dialog, _Call) when Code < 101 ->
    Dialog;

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<200 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    status_update(proceeding_uac, Dialog1, Call);

do_response('INVITE', Code, Req, Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<300 andalso (Status=:=init orelse Status=:=proceeding_uac) ->
    Dialog1 = Dialog#dialog{request=Req, response=Resp, ack=undefined},
    status_update(accepted_uac, Dialog1, Call);
    
do_response('INVITE', Code, _Req, _Resp, #dialog{status=Status}=Dialog, Call) 
            when Code<300 andalso (Status=:=accepted_uac orelse Status=:=confirmed) ->
    #dialog{app_id=AppId, call_id=CallId, id=DialogId, ack=ACK} = Dialog,
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
            when is_integer(Code) andalso Code>=300 andalso 
            (Status=:=init orelse Status=:=proceeding_uac) ->
    case Dialog#dialog.answered of
        undefined -> status_update({stop, Code}, Dialog, Call);
        _ -> status_update(confirmed, Dialog, Call)
    end;

do_response('INVITE', Code, _Req, Resp, Dialog, Call) ->
    #sipmsg{response=Code} = Resp,
    #dialog{id=DialogId, status=Status} = Dialog,
    ?call_notice("Dialog ~s (~p) ignoring 'INVITE' ~p response",
                 [DialogId, Status, Code], Call),
    Dialog;

do_response('BYE', _Code, Req, _Resp, #dialog{caller_tag=CallerTag}=Dialog, Call) ->
    Reason = case Req#sipmsg.from_tag of
        CallerTag -> caller_bye;
        _ -> callee_bye
    end,
    status_update({stop, Reason}, Dialog, Call);

do_response(_, _Code, _Req, _Resp, Dialog, _Call) ->
    Dialog.


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
            case Method=:='ACK' andalso Status=/=accepted_uac of
                true ->
                    {error, invalid_dialog};
                false ->
                    {Result, Dialog1} = generate(Method, Opts, Dialog),
                    {ok, Result, nksip_call_dialog:update(Dialog1, Call)}
            end;
        _ ->
            {error, unknown_dialog}
    end.


%% @private
-spec new_local_seq(nksip:request(), call()) ->
    {nksip:cseq(), call()}.

new_local_seq(Req, Call) ->
    case nksip_dialog:id(Req) of
        <<>> ->
            {nksip_config:cseq(), Call};
        DialogId ->
            case nksip_call_dialog:find(DialogId, Call) of
                #dialog{local_seq=LocalSeq}=Dialog ->
                    Dialog1 = Dialog#dialog{local_seq=LocalSeq+1},
                    {LocalSeq+1, nksip_call_dialog:update(Dialog1, Call)};
                not_found ->
                    {nksip_config:cseq(), Call}
            end
    end.



%% ===================================================================
%% Internal
%% ===================================================================

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
        request = Req
    } = Dialog,
    case nksip_lib:get_integer(cseq, Opts) of
        0 when Method =:= 'ACK' -> 
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
                [] -> 
                    ?notice(AppId, CallId, "Dialog ~s UAC request has invalid "
                                            "contact: ~p", [DialogId, ContactSpec]),
                    [];
                Contacts0 -> 
                    Contacts0
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


%% @private
-spec status_update(nksip_dialog:status(), nksip:dialog(), call()) ->
    nksip:dialog().

status_update(Status, Dialog, Call) ->
    nksip_call_dialog:status_update(uac, Status, Dialog, Call).




