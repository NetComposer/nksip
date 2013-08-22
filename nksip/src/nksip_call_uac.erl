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

-export([send/2, received/2, get_cancel/4, make_dialog/5, timer/3]).
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


send(#sipmsg{method=Method}=Req, SD) ->
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req)
    end,
    {UAC, SD1} = add_request(Req1, SD),
    #trans{trans_id=TransId, request=#sipmsg{id=ReqId}} = UAC,
    ?call_debug("UAC sending request ~p (ReqId:~p, TransId:~p)",
                [Method, ReqId, TransId], SD1),
    do_send(UAC, SD1).


add_request(Req, SD) ->
    #sipmsg{method=Method, opts=Opts} = Req, 
    #call{next=ReqId, msgs=Msgs, trans=Trans, msg_keep_time=Keep} = SD,
    case nksip_lib:get_value(respfun, Opts) of
        Fun when is_function(Fun, 1) -> ok;
        _ -> Fun = fun(_) -> ok end
    end,
    Status = case Method of
        'ACK' -> ack;
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    TransId = transaction_id(Req),
    Expire = nksip_lib:timestamp() + Keep,
    UAC = #trans{
        class = uac,
        trans_id = TransId,
        status = Status,
        start = nksip_lib:timestamp(),
        request = Req#sipmsg{id=ReqId, expire=Expire},
        responses = [],
        respfun = Fun,
        iter = 1
    },
    Msg = #msg{
        msg_id = ReqId, 
        msg_class = req, 
        expire = Expire,
        trans_class = uac, 
        trans_id = TransId
    },
    nksip_counters:async([nksip_msgs]),
    {UAC, SD#call{next=ReqId+1, msgs=[Msg|Msgs], trans=[UAC|Trans]}}.


do_send(UAC, SD) ->
    #trans{request=#sipmsg{id=ReqId, method=Method}=Req} = UAC,
    #call{dialogs=Dialogs} = SD,
    case nksip_call_dialog_uac:request(Req, Dialogs) of
        finished ->
            Reply = nksip_reply:reply(Req, no_transaction),
            received(Reply, SD);
        request_pending ->
            Reply = nksip_reply:reply(Req, request_pending),
            received(Reply, SD);
        {ok, Dialogs1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    ?call_debug("UAC sent ~p (~p) request", [Method, ReqId], SD),
                    Dialogs2 = case Method of 
                        'ACK' -> nksip_call_dialog_uac:ack(SentReq, Dialogs1);
                        _ -> Dialogs1
                    end,
                    UAC1 = sent_method(Method, UAC#trans{request=SentReq}),
                    reply_request(UAC1),
                    next(update(UAC1, SD#call{dialogs=Dialogs2}));
                error when Method=:='ACK' ->
                    ?call_debug("UAC error sending 'ACK' (~p) request", [ReqId], SD),
                    UAC1 = UAC#trans{status=finished},
                    next(update(UAC1, SD#call{dialogs=Dialogs1}));
                error ->
                    ?call_debug("UAC error sending ~p (~p) request", 
                                [Method, ReqId], SD),
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    received(Reply, SD#call{dialogs=Dialogs1})
            end
    end.


sent_method('INVITE', #trans{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAC1 = start_timer(expire, UAC#trans{status=invite_calling}),
    UAC2 = start_timer(timer_b, UAC1),
    case Proto of 
        udp -> start_timer(timer_a, UAC2);
        _ -> UAC2
    end;

sent_method('ACK', UAC) ->
    UAC#trans{status=finished};
    
sent_method(_Other, #trans{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAC1 = start_timer(timer_f, UAC#trans{status=trying}),
    case Proto of 
        udp -> start_timer(timer_e, UAC1);
        _ -> UAC1
    end.
    

received(Resp, #call{trans=Trans}=SD) ->
    #sipmsg{response=Code, cseq_method=Method} = Resp,
    TransId = transaction_id(Resp),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uac, status=finished} ->
            ?call_notice("received ~p ~p response for finished request (~p)", 
                         [Method, Code, TransId], SD),
            next(SD);
        #trans{class=uac}=UAC ->
            {Resp1, UAC1, SD1} = add_response(Resp, UAC, SD),
            do_received(Resp1, UAC1, SD1);
        _ ->
            ?call_notice("received ~p ~p response for unknown request (~p)", 
                         [Method, Code, TransId], SD),
            next(SD)
    end.


add_response(Resp, UAC, SD) ->
    #trans{trans_id=TransId, request=Req, responses=Resps} = UAC,
    #sipmsg{ruri=RUri} = Req,
    #call{next=RespId, msgs=Msgs, msg_keep_time=Keep} = SD,
    Expire = nksip_lib:timestamp() + Keep,
    Resp1 = Resp#sipmsg{id=RespId, ruri=RUri, expire=Expire},
    UAC1 = UAC#trans{responses=[Resp1|Resps]},
    Msg = #msg{
        msg_id = RespId, 
        msg_class = resp, 
        expire = Expire,
        trans_class = uac, 
        trans_id = TransId
    },
    nksip_counters:async([nksip_msgs]),
    {Resp1, UAC1, update(UAC1, SD#call{msgs=[Msg|Msgs], next=RespId+1})}.


do_received(Resp, UAC, SD) ->
    #sipmsg{response=Code, transport=RespTransp} = Resp,
    #trans{status=Status, request=Req, iter=Iter} = UAC,
    #sipmsg{method=Method} = Req,
    #call{dialogs=Dialogs} = SD,
    case RespTransp of
        undefined -> ok;    % It is own-generated
        _ -> ?call_debug("UAC ~p received ~p in ~p", [Method, Code, Status], SD)
    end,
    Dialogs1 = nksip_call_dialog_uac:response(Req, Resp, Dialogs),
    SD1 = SD#call{dialogs=Dialogs1},
    UAC1 = do_received_status(Status, Resp, UAC),
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
         andalso Method=/='CANCEL' andalso do_received_auth(Resp, UAC, SD1)
    of
        {ok, NewUAC, SD2} ->
            do_send(NewUAC, update(UAC1, SD2));
        _ ->
            reply_response(Resp, UAC1),
            next(update(UAC1, SD1))
    end.

do_received_auth(Resp, #trans{request=Req, iter=Iter}, SD) ->
    case nksip_auth:make_request(Req, Resp) of
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            Req2 = Req1#sipmsg{
                vias = Vias, 
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            {NewUAC, SD1} = add_request(Req3, SD),
            #trans{trans_id=TransId, request=#sipmsg{id=ReqId, method=Method}} = NewUAC,
            ?call_debug("UAC resending authorized request ~p (~p, ~p)", 
                        [Method, ReqId, TransId], SD),
            {ok, NewUAC#trans{iter=Iter+1}, SD1};
        error ->    
            error
    end.



do_received_status(invite_calling, Resp, UAC) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=invite_proceeding}),
    do_received_status(invite_proceeding, Resp, UAC1);

do_received_status(invite_proceeding, #sipmsg{response=Code}, UAC) when Code < 200 ->
    proc_cancel(ok, UAC);

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
do_received_status(invite_proceeding, Resp, #trans{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAC1 = cancel_timers([timeout, expire], UAC),
    UAC2 = proc_cancel(final_response, UAC1),
    send_ack(Req, Resp),
    case Proto of
        udp -> start_timer(timer_d, UAC2#trans{status=invite_completed});
        _ -> UAC2#trans{status=finished}
    end;


do_received_status(invite_accepted, Resp, UAC) -> 
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code, to_tag=ToTag} = Resp,
    #trans{first_to_tag=FirstToTag} = UAC,
    if
        ToTag=/=(<<>>), ToTag=/=FirstToTag, Code>=200, Code<300 ->
            % BYE any secondary response
            spawn(
                fun() ->
                    case nksip_dialog:id(Resp) of
                        {dlg, _, _, Id} = DialogId ->
                            ?info(AppId, CallId, "UAC sending ACK and BYE to secondary "
                                  "response (Dialog ~p)", [Id]),
                            case nksip_uac:ack(DialogId, []) of
                                ok -> nksip_uac:bye(DialogId, [async]);
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

do_received_status(invite_completed, Resp, #trans{request=Req}=UAC) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code} = Resp,
    if
        Code >= 300 -> 
            send_ack(Req, Resp);
        true ->  
            ?info(AppId, CallId, 
                  "UAC Trans received 'INVITE' ~p in invite_completed", [Code])
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
do_received_status(proceeding, _Resp, #trans{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAC1 = cancel_timers([timeout], UAC),
    case Proto of
        udp -> start_timer(timer_k, UAC1#trans{status=completed});
        _ -> UAC1#trans{status=finished}
    end;

do_received_status(completed, Resp, UAC) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, cseq_method=Method, response=Code} = Resp,
    ?info(AppId, CallId, "UAC Trans received ~p ~p retransmission in completed", 
          [Method, Code]),
    UAC.

get_cancel(TransId, Opts, From, #call{trans=Trans}=SD) ->
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uac, status=invite_calling, request=Req}=UAC ->
            ?P("CANCEL IN CALLING"),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            UAC1 = UAC#trans{cancel={From, CancelReq}},
            next(update(UAC1, SD));
        #trans{class=uac, status=invite_proceeding, request=Req} ->
            ?P("CANCEL IN PROCEEDING"),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            gen_server:reply(From, {ok, CancelReq}),
            next(SD);
        _ ->
            gen_server:reply(From, {error, no_transaction}),
            next(SD)
    end.


make_dialog(DialogId, Method, Opts, From, #call{dialogs=Dialogs}=SD) ->
    case nksip_call_dialog_uac:make(DialogId, Method, Opts, Dialogs) of
        {ok, Result, Dialogs1} ->
            gen_server:reply(From, {ok, Result}),
            next(SD#call{dialogs=Dialogs1});
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            next(SD)
    end.







%% ===================================================================
%% Timers
%% ===================================================================


% INVITE retrans
timer(timer_a, #trans{request=Req}=UAC, SD) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC retransmitting 'INVITE'", [], SD),
            UAC1 = start_timer(timer_a, UAC),
            next(update(UAC1, SD));
        error ->
            ?call_notice("UAC could not retransmit 'INVITE'", [], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            received(Resp, SD)
    end;

% INVITE timeout
timer(timer_b, #trans{request=Req}, SD) ->
    ?call_notice("UAC 'INVITE' timeout (Timer B) fired", [], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer B Timeout">>}),
    received(Resp, SD);

% Finished in INVITE completed
timer(timer_d, UAC, SD) ->
    ?call_debug("UAC 'INVITE' Timer D fired", [], SD),
    UAC1 = UAC#trans{status=finished, timeout=undefined},
    next(update(UAC1, SD));

% INVITE accepted finished
timer(timer_m,  UAC, SD) ->
    ?call_debug("UAC 'INVITE' Timer M fired", [], SD),
    UAC1 = UAC#trans{status=finished, timeout=undefined},
    next(update(UAC1, SD));

% No INVITE retrans
timer(timer_e, #trans{request=#sipmsg{method=Method}=Req}=UAC, SD) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC retransmitting ~p", [Method], SD),
            UAC1 = start_timer(timer_e, UAC),
            next(update(UAC1, SD));
        error ->
            ?call_notice("UAC could not retransmit ~p", [Method], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            received(Resp, SD)
    end;

% No INVITE timeout
timer(timer_f, #trans{request=#sipmsg{method=Method}=Req}, SD) ->
    ?call_notice("UAC ~p timeout (Timer F) fired", [Method], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    received(Resp, SD);

% No INVITE completed finished
timer(timer_k,  #trans{request=#sipmsg{method=Method}}=UAC, SD) ->
    ?call_debug("UAC ~p Timer K fired", [Method], SD),
    UAC1 = UAC#trans{status=finished, timeout=undefined},
    next(update(UAC1, SD));

timer(expire, #trans{status=Status, request=Req}=UAC, SD) ->
    UAC1 = UAC#trans{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            ?call_debug("Timer EXPIRE fired, sending CANCEL", [], SD),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            send(CancelReq, SD);
        true ->
            ?call_debug("Timer EXPIRE fired", [], SD),
            next(update(UAC1, SD))
    end.




%% ===================================================================
%% Util
%% ===================================================================

%% @private
reply_request(#trans{respfun=Fun, request=Req}) ->
    #sipmsg{method=Method, opts=Opts} = Req,
    case lists:member(full_request, Opts) of
        true when Method=:='ACK' -> catch Fun({ok, Req});
        false when Method=:='ACK' -> catch Fun(ok);
        true -> catch Fun({request, Req});
        false -> ok
    end.

reply_response(Resp, #trans{respfun=Fun, request=Req}) ->
    #sipmsg{method=Method, opts=Opts} = Req,
    case Resp of
        #sipmsg{response=Code} when Code < 101 ->
            ok;
        #sipmsg{response=Code}=Resp ->
            case lists:member(full_response, Opts) of
                true ->
                    catch Fun({reply, Resp#sipmsg{ruri=Resp#sipmsg.ruri}});
                false when Method=:='INVITE' ->
                    catch Fun({ok, Code, nksip_dialog:id(Resp)});
                false -> 
                    catch Fun({ok, Code})
            end
    end.

proc_cancel(Reply, #trans{cancel=Cancel}=UAC) ->
    case Cancel of
        {From, CancelReq} when Reply=:=ok -> gen_server:reply(From, {ok, CancelReq});
        {From, _} -> gen_server:reply(From, {error, Reply});
        _ -> ok
    end,
    UAC#trans{cancel=undefined}.


send_ack(#sipmsg{vias=[Via|_]}=Req, #sipmsg{to=To}) ->
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
    case nksip_transport_uac:resend_request(Ack) of
        {ok, _} -> 
            ok;
        error -> 
            #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
            ?notice(AppId, CallId, "UAC Trans could not send non-2xx ACK", [])
    end.


%% @private
-spec transaction_id(nksip:request()) -> binary().

transaction_id(#sipmsg{sipapp_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    % nksip_lib:lhash({AppId, CallId, Method, Branch}).
    erlang:phash2({AppId, CallId, Method, Branch}).

next(SD) ->
    nksip_call_srv:next(SD).



