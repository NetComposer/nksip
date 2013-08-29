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

%% @doc UAC Process FSM

-module(nksip_call_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/3, response/2, get_cancel/4, make_dialog/5, timer/3]).
-export_type([status/0]).
-import(nksip_call_lib, [update/2, start_timer/2, cancel_timers/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(MAX_AUTH_TRIES, 5).
-define(MAX_UAC_TRANS, 900).


%% ===================================================================
%% Types
%% ===================================================================

-type status() :: invite_calling | invite_proceeding | invite_accepted |
                  invite_completed |
                  trying | proceeding | completed |
                  finished | ack.


request(#sipmsg{method=Method}=Req, From, SD) ->
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req)
    end,
    case From of 
        {fork, ForkId} -> 
            Forked = "";
        _ -> 
            ForkId = 0,
            Forked = " (forked) "
    end,
    {UAC, SD1} = add_request(Req1, ForkId, SD),
    #trans{id=TransId, request=#sipmsg{id=ReqId}} = UAC,
    case From of
        none -> 
            ok;
        _ -> 
            #call{app_id=AppId, call_id=CallId} = SD,
            gen_server:reply(From, {ok, {req, AppId, CallId, ReqId}})
    end,
    ?call_debug("UAC ~p sending ~s request ~p (~p)", 
                [TransId, Forked, Method, ReqId], SD1),
    do_send(Method, UAC, SD1).



add_request(Req, ForkId, SD) ->
    #sipmsg{method=Method, ruri=RUri, opts=Opts} = Req, 
    #call{trans=Trans} = SD,
    {Req1, SD1} = nksip_call_lib:add_msg(Req, ForkId>0, SD),
    Status = case Method of
        'ACK' -> ack;
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    TransId = transaction_id(Req),
    UAC = #trans{
        class = uac,
        id = TransId,
        status = Status,
        fork_id = ForkId,
        request = Req1,
        method = Method,
        ruri = RUri,
        opts = Opts,
        response = undefined,
        code = 0,
        iter = 1
    },
    {UAC, SD1#call{trans=[UAC|Trans]}}.


do_send('ACK', #trans{id=Id, request=Req}=UAC, SD) ->
    case nksip_transport_uac:send_request(Req) of
       {ok, SentReq} ->
            ?call_debug("UAC ~p sent 'ACK' request", [Id], SD),
            UAC1 = UAC#trans{status=finished, request=SentReq},
            reply_request(UAC1),
            SD1 = nksip_call_lib:update_msg(SentReq, SD),
            SD2 = nksip_call_dialog_uac:ack(UAC1, SD1),
            update(UAC1, SD2);
        error ->
            ?call_debug("UAC ~p error sending 'ACK' request", [Id], SD),
            UAC1 = UAC#trans{status=finished},
            update(UAC1, SD)
    end;

do_send(_, #trans{method=Method, id=Id, request=Req}=UAC, SD) ->
    case nksip_call_dialog_uac:request(UAC, SD) of
        {ok, SD1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    #sipmsg{transport=#transport{proto=Proto}} = SentReq,
                    SD2 = nksip_call_lib:update_msg(SentReq, SD1),
                    ?call_debug("UAC ~p sent ~p request", [Id, Method], SD),
                    UAC1 = UAC#trans{request=SentReq, proto=Proto},
                    reply_request(UAC1),
                    UAC2 = start_timer(timeout, UAC1),
                    UAC3 = sent_method(Method, UAC2),
                    update(UAC3, SD2);
                error ->
                    ?call_debug("UAC ~p error sending ~p request", 
                                [Id, Method], SD),
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    response(Reply, SD1)
            end;
        {error, finished} ->
            Reply = nksip_reply:reply(Req, no_transaction),
            response(Reply, SD);
        {error, request_pending} ->
            Reply = nksip_reply:reply(Req, request_pending),
            response(Reply, SD)
    end.


sent_method('INVITE', #trans{proto=Proto}=UAC) ->
    UAC1 = start_timer(expire, UAC#trans{status=invite_calling}),
    UAC2 = start_timer(timer_b, UAC1),
    case Proto of 
        udp -> start_timer(timer_a, UAC2);
        _ -> UAC2
    end;

sent_method(_Other, #trans{proto=Proto}=UAC) ->
    UAC1 = start_timer(timer_f, UAC#trans{status=trying}),
    case Proto of 
        udp -> start_timer(timer_e, UAC1);
        _ -> UAC1
    end.
    

response(Resp, #call{trans=Trans}=SD) ->
    #sipmsg{response=Code, cseq_method=Method} = Resp,
    TransId = transaction_id(Resp),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uac, ruri=RUri}=UAC ->
            {Resp1, SD1} = nksip_call_lib:add_msg(Resp#sipmsg{ruri=RUri}, false, SD),
            UAC1 = UAC#trans{response=Resp1, code=Code},
            do_response(UAC1, update(UAC1, SD1));
        _ ->
            #sipmsg{vias=[#via{opts=Opts}|ViaR]} = Resp,
            case nksip_lib:get_binary(branch, Opts) of
                <<"z9hG4bK", Branch/binary>> when ViaR =/= [] ->
                    GlobalId = nksip_config:get(global_id),
                    StatelessId = nksip_lib:hash({Branch, GlobalId, stateless}),
                    case nksip_lib:get_binary(nksip, Opts) of
                        StatelessId -> 
                            nksip_call_uas_proxy:response_stateless(Resp, SD);
                        _ ->
                            ?call_notice("UAC ~p received ~p ~p response for "
                                         "unknown request", [TransId, Method, Code], SD)
                    end;
                _ ->
                    ?call_notice("UAC ~p received ~p ~p response for "
                                 "unknown request", [TransId, Method, Code], SD)
            end,
            SD
    end.


do_response(UAC, SD) ->
    #trans{
        id = Id, 
        fork_id = ForkId,
        method = Method, 
        status = Status, 
        response = #sipmsg{response=Code, transport=RespTransp} = Resp, 
        iter = Iter
    } = UAC,
    case RespTransp of
        undefined -> ok;    % It is own-generated
        _ -> ?call_debug("UAC ~p ~p (~p) received ~p", [Id, Method, Status, Code], SD)
    end,
    SD1 = nksip_call_dialog_uac:response(UAC, SD),
    UAC1 = do_received_status(Status, Resp, UAC),
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
         andalso Method=/='CANCEL' andalso ForkId>0 andalso
         do_received_auth(UAC1, SD1)
    of
        {ok, NewUAC, SD2} ->
            do_send(Method, NewUAC, update(UAC1, SD2));
        _ ->
            reply_response(Resp, UAC1),
            update(UAC1, SD1)
    end.

do_received_auth(#trans{request=Req, response=Resp, status=Status, iter=Iter}, SD) ->
    case nksip_auth:make_request(Req, Resp) of
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            Req2 = Req1#sipmsg{
                vias = Vias, 
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            {NewUAC, SD1} = add_request(Req3, 0, SD),
            #trans{id=Id, request=#sipmsg{method=Method}} = NewUAC,
            ?call_debug("UAC ~p ~p (~p) resending authorized request", 
                        [Id, Method, Status], SD),
            {ok, NewUAC#trans{iter=Iter+1}, SD1};
        error ->    
            error
    end.


do_received_status(invite_calling, Resp, UAC) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=invite_proceeding}),
    do_received_status(invite_proceeding, Resp, UAC1);

do_received_status(invite_proceeding, #sipmsg{response=Code}, UAC) when Code < 200 ->
    UAC1 = cancel_timers([timeout], UAC),
    UAC2 = start_timer(timeout, UAC1),       % Another 3 minutes
    proc_cancel(ok, UAC2);

% Final 2xx response received
do_received_status(invite_proceeding, #sipmsg{response=Code, to_tag=ToTag}, UAC) 
                   when Code < 300 ->
    UAC1 = cancel_timers([timeout, expire], UAC),
    UAC2 = proc_cancel(final_response, UAC1),
    % New RFC6026 state, to absorb 2xx retransmissions and forked responses
    start_timer(timer_m, UAC2#trans{status=invite_accepted, first_to_tag=ToTag});

% Final [3456]xx response received, own error response
do_received_status(invite_proceeding, #sipmsg{transport=undefined}, UAC) ->
    UAC1 = cancel_timers([timeout, expire], UAC),
    proc_cancel(final_response, UAC1#trans{status=finished});

% Final [3456]xx response received, real response
do_received_status(invite_proceeding, Resp, UAC) ->
    #sipmsg{to=To} = Resp,
    #trans{request=#sipmsg{vias=[Via|_]}=Req, proto=Proto} = UAC,
    UAC1 = cancel_timers([timeout, expire], UAC),
    UAC2 = proc_cancel(final_response, UAC1),
    Ack = Req#sipmsg{
        method = 'ACK',
        to = To,
        vias = [Via],
        cseq_method = 'ACK',
        forwards = 70,
        routes = [],
        contacts = [],
        headers = [],
        content_type = [],
        body = <<>>
    },
    UAC3 = UAC2#trans{request=Ack, response=undefined},
    send_ack(UAC3),
    case Proto of
        udp -> start_timer(timer_d, UAC2#trans{status=invite_completed});
        _ -> UAC2#trans{status=finished}
    end;


do_received_status(invite_accepted, Resp, UAC) -> 
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code, to_tag=ToTag} = Resp,
    #trans{id=Id, first_to_tag=FirstToTag} = UAC,
    if
        ToTag=/=(<<>>), ToTag=/=FirstToTag, Code>=200, Code<300 ->
            % BYE any secondary response
            spawn(
                fun() ->
                    case nksip_dialog:id(Resp) of
                        {dlg, _, _, DialogId} = Dialog ->
                            ?info(AppId, CallId,
                                  "UAC ~p (invite_accepted) sending ACK and BYE to "
                                  "secondary response (Dialog ~p)", [Id, DialogId]),
                            case nksip_uac:ack(Dialog, []) of
                                ok -> nksip_uac:bye(Dialog, [async]);
                                _ -> error
                            end;
                        undefined ->
                            ok
                    end
                end);
        true ->
            ok
    end,
    UAC;

do_received_status(invite_completed, Resp, UAC) ->
    #trans{id=Id} = UAC,
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code} = Resp,
    if
        Code >= 300 -> 
            send_ack(UAC);
        true ->  
            ?info(AppId, CallId, 
                  "UAC ~p 'INVITE' (invite_completed) received ~p", [Id, Code])
    end,
    UAC;

do_received_status(trying, Resp, UAC) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=proceeding}),
    do_received_status(proceeding, Resp, UAC1);

do_received_status(proceeding, #sipmsg{response=Code}, UAC) when Code < 200 ->
    UAC;

% Final response received, own error response
do_received_status(proceeding, #sipmsg{transport=undefined}, UAC) ->
    cancel_timers([timeout], UAC#trans{status=finished});

% Final response received, real response
do_received_status(proceeding, _Resp, #trans{proto=Proto}=UAC) ->
    UAC1 = cancel_timers([timeout], UAC),
    case Proto of
        udp -> 
            UAC2 = UAC#trans{status=completed, request=undefined, response=undefined},
            start_timer(timer_k, UAC2);
        _ -> 
            UAC1#trans{status=finished}
    end;

do_received_status(completed, Resp, UAC) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, cseq_method=Method, response=Code} = Resp,
    #trans{id=Id} = UAC,
    ?info(AppId, CallId, "UAC ~p ~p (completed) received ~p retransmission", 
          [Id, Method, Code]),
    UAC.

get_cancel(UAC, Opts, From, SD) ->
    case UAC of
        #trans{class=uac, status=invite_calling, request=Req}=UAC ->
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            UAC1 = UAC#trans{cancel={From, CancelReq}},
            update(UAC1, SD);
        #trans{class=uac, status=invite_proceeding, request=Req} ->
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            gen_server:reply(From, {ok, CancelReq}),
            SD;
        _ ->
            gen_server:reply(From, {error, unknown_request}),
            SD
    end.


make_dialog(DialogId, Method, Opts, From, SD) ->
    case nksip_call_dialog_uac:make(DialogId, Method, Opts, SD) of
        {ok, Result, SD1} ->
            gen_server:reply(From, {ok, Result}),
            SD1;
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            SD
    end.







%% ===================================================================
%% Timers
%% ===================================================================

timer(timeout, #trans{id=Id, method=Method, request=Req}, SD) ->
    ?call_notice("UAC ~p ~p timeout: no final response", [Id, Method], SD),
    Resp = nksip_reply:reply(Req, timeout),
    response(Resp, SD);

% INVITE retrans
timer(timer_a, #trans{id=Id, request=Req, status=Status}=UAC, SD) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting 'INVITE'", [Id, Status], SD),
            UAC1 = start_timer(timer_a, UAC),
            update(UAC1, SD);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit 'INVITE'", [Id, Status], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            response(Resp, SD)
    end;

% INVITE timeout
timer(timer_b, #trans{id=Id, request=Req, status=Status}, SD) ->
    ?call_notice("UAC ~p 'INVITE' (~p) timeout (Timer B) fired", [Id, Status], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer B Timeout">>}),
    response(Resp, SD);

% Finished in INVITE completed
timer(timer_d, #trans{id=Id, status=Status}=UAC, SD) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer D fired", [Id, Status], SD),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, SD);

% INVITE accepted finished
timer(timer_m,  #trans{id=Id, status=Status}=UAC, SD) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer M fired", [Id, Status], SD),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, SD);

% No INVITE retrans
timer(timer_e, #trans{id=Id, status=Status, method=Method, request=Req}=UAC, SD) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting ~p", [Id, Status, Method], SD),
            UAC1 = start_timer(timer_e, UAC),
            update(UAC1, SD);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit ~p", [Id, Status, Method], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            response(Resp, SD)
    end;

% No INVITE timeout
timer(timer_f, #trans{id=Id, status=Status, method=Method, request=Req}, SD) ->
    ?call_notice("UAC ~p ~p (~p) timeout (Timer F) fired", [Id, Method, Status], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    response(Resp, SD);

% No INVITE completed finished
timer(timer_k,  #trans{id=Id, status=Status, method=Method}=UAC, SD) ->
    ?call_debug("UAC ~p ~p (~p) Timer K fired", [Id, Method, Status], SD),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, SD);

timer(expire, #trans{id=Id, status=Status, request=Req}=UAC, SD) ->
    UAC1 = UAC#trans{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer EXPIRE fired, sending CANCEL", 
                        [Id, Status], SD),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            request(CancelReq, none, SD);
        true ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer EXPIRE fired", [Id, Status], SD),
            update(UAC1, SD)
    end.




%% ===================================================================
%% Util
%% ===================================================================

%% @private
reply_request(#trans{request=Req, method=Method, opts=Opts}) ->
    Fun = nksip_lib:get_value(respfun, Opts),
    case lists:member(full_request, Opts) of
        true when Method=:='ACK', is_function(Fun, 1) -> catch Fun({ok, Req});
        false when Method=:='ACK', is_function(Fun, 1) -> catch Fun(ok);
        true when is_function(Fun, 1) -> catch Fun({request, Req});
        false -> ok
    end.

reply_response(Resp, #trans{method=Method, opts=Opts}) ->
    case Resp of
        #sipmsg{response=Code} when Code < 101 ->
            ok;
        #sipmsg{response=Code}=Resp ->
            Fun = nksip_lib:get_value(respfun, Opts),
            case lists:member(full_response, Opts) of
                true when is_function(Fun, 1) ->
                    catch Fun({reply, Resp#sipmsg{ruri=Resp#sipmsg.ruri}});
                false when Method=:='INVITE', is_function(Fun, 1) ->
                    catch Fun({ok, Code, nksip_dialog:id(Resp)});
                false when is_function(Fun, 1) -> 
                    catch Fun({ok, Code});
                _ ->
                    ok
            end
    end.

proc_cancel(Reply, #trans{cancel=Cancel}=UAC) ->
    case Cancel of
        {From, CancelReq} when Reply=:=ok -> gen_server:reply(From, {ok, CancelReq});
        {From, _} -> gen_server:reply(From, {error, Reply});
        _ -> ok
    end,
    UAC#trans{cancel=undefined}.


send_ack(#trans{request=Ack, id=Id}) ->
    case nksip_transport_uac:resend_request(Ack) of
        {ok, _} -> 
            ok;
        error -> 
            #sipmsg{sipapp_id=AppId, call_id=CallId} = Ack,
            ?notice(AppId, CallId, "UAC ~p could not send non-2xx ACK", [Id])
    end.


%% @private
-spec transaction_id(nksip:request()) -> binary().

transaction_id(#sipmsg{sipapp_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    erlang:phash2({AppId, CallId, Method, Branch}).



