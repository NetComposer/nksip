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

-export([send/2, received/2, get_cancel/4, timer/3]).
-export_type([status/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(MAX_AUTH_TRIES, 5).


%% ===================================================================
%% Types
%% ===================================================================

% -type call_status() :: check | accept.

-type status() :: wait_invite |
                  invite_calling | invite_proceeding | invite_accepted |
                  invite_completed |
                  trying | proceeding | completed |
                  removed.


send(#sipmsg{method=Method, opts=Opts}=Req, SD) ->
    #call{next=Next, uacs=UACs, sipmsgs=SipMsgs} = SD,
    Req1 = case Method of 
        'CANCEL' -> Req#sipmsg{id=Next};
        _ -> nksip_transport_uac:add_via(Req#sipmsg{id=Next})
    end,
    case nksip_lib:get_value(respfun, Opts) of
        Fun when is_function(Fun, 1) -> ok;
        _ -> Fun = fun(_) -> ok end
    end,
    TransId = transaction_id(Req1),
    Status = case Method of
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    UAC = #uac{
        trans_id = TransId,
        status = Status,
        request = Req1,
        responses = [],
        respfun = Fun,
        iter = 1
    },
    SipMsgs1 = [{Next, uac, TransId}|SipMsgs],
    SD1 = SD#call{next=Next+1, sipmsgs=SipMsgs1, uacs=[UAC|UACs]},
    do_send(SD1).


do_send(#call{uacs=[#uac{request=Req}=UAC|Rest]}=SD) ->
    #sipmsg{id=ReqId, method=Method} = Req,
    case nksip_call_dialog_uac:request(Req, SD) of
        {bye, SD1} ->
            Reply = nksip_reply:reply(Req, no_transaction),
            received(Reply, SD1);
        {wait, SD1} ->
            UAC1 = UAC#uac{status=wait_invite},
            next(SD1#call{uacs=[UAC1|Rest]});
        {ok, SD1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    ?call_debug("UAC sent ~p (~p) request", [Method, ReqId], SD),
                    UAC1 = sent_method(Method, UAC#uac{request=SentReq}),
                    SD2 = SD1#call{uacs=[UAC1|Rest]},
                    SD3 = case Method of 
                        'ACK' -> nksip_call_dialog_uac:ack(SentReq, SD2);
                        _ -> SD2
                    end,
                    reply_request(UAC1),
                    next(SD3);
                error ->
                    ?call_debug("UAC error sending ~p (~p) request", 
                                [Method, ReqId], SD),
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    received(Reply, SD1)
            end
    end.


sent_method('INVITE', #uac{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}, opts=Opts} = Req,
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            case lists:member(no_uac_expire, Opts) of
                true -> undefined;
                _ -> start_timer(1000*Expires, expire, UAC)
            end;
        _ ->
            undefined
    end,
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = invite_calling,
        timeout_timer = start_timer(64*T1, timer_b, UAC),
        expire_timer = ExpireTimer
    },
    case Proto of 
        udp ->
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_a, UAC),
                next_retrans = 2*T1
            };
        _ ->
            UAC1
    end;

% Maintain ACK to resend if neccesary
sent_method('ACK', UAC) ->
    T1 = nksip_config:get(timer_t1),
    UAC#uac{
        status = completed,
        timeout_timer = start_timer(64*T1, remove, UAC)
    };
    
sent_method(_Other, #uac{request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = trying,
        timeout_timer = start_timer(64*T1, timer_f, UAC)
    },
    case Proto of
        udp ->
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_e, UAC),
                next_retrans = 2*T1
            };
        _ ->
            UAC1
    end.
    

received(Resp, SD) ->
    #sipmsg{response=Code, cseq_method=Method} = Resp,
    #call{uacs=UACs, sipmsgs=SipMsgs, next=Next} = SD,
    TransId = transaction_id(Resp),
    case lists:keytake(TransId, #uac.trans_id, UACs) of
        {value, UAC, Rest} ->
            #uac{
                status = Status, 
                request = #sipmsg{ruri=RUri} = Req, 
                responses = Resps
            } = UAC,
            Resp1 = Resp#sipmsg{id=Next, ruri=RUri},
            UAC1 = UAC#uac{responses=[Resp1|Resps]},
            SipMsgs1 = [{Next, uac, TransId}|SipMsgs],
            SD1 = SD#call{uacs=[UAC1|Rest], sipmsgs=SipMsgs1, next=Next+1},
            do_received(Req, Resp1, Status, SD1);
        false ->
            ?call_notice("received ~p ~p unknown response (~s)", 
                         [Method, Code, TransId], SD),
            next(SD)
    end.


do_received(#sipmsg{method=Method}, _Resp, removed, SD) ->
    ?call_notice("UAC received ~p response for removed request", [Method], SD),
    next(SD);

do_received(Req, Resp, Status, #call{uacs=[UAC|Rest]}=SD) ->
    #sipmsg{method=Method} = Req,
    #sipmsg{response=Code, transport=RespTransp} = Resp,
    #uac{iter=Iter} = UAC,
    case RespTransp of
        undefined -> 
            ok;    % It is own-generated
        _ -> 
            ?call_debug("UAC ~p received ~p in ~p", [Method, Code, Status], SD)
    end,
    SD1 = nksip_call_dialog_uac:response(Req, Resp, SD),
    UAC1 = do_received_status(Status, Req, Resp, UAC),
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
         andalso Method=/='CANCEL'
    of
        true -> 
            case do_received_auth(Req, Resp, UAC) of
                {ok, NewUAC} ->
                    do_send(SD1#call{uacs=[NewUAC, UAC1|Rest]});
                error ->    
                    reply_response(UAC1),
                    next(SD1#call{uacs=[UAC1|Rest]})
            end;
        false ->
            reply_response(UAC1),
            next(SD1#call{uacs=[UAC1|Rest]})
    end.


do_received_auth(Req, Resp, #uac{iter=Iter}=UAC) ->
    case nksip_auth:make_request(Req, Resp) of
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            Req2 = Req1#sipmsg{
                vias = Vias, 
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            NewUAC = UAC#uac{
                trans_id = transaction_id(Req3),
                request = Req3,
                responses = [],
                first_to_tag = <<>>,
                cancel = undefined,
                iter = Iter+1
            },
            {ok, NewUAC};
        error ->    
            error
    end.


do_received_status(Status, Req, Resp, UAC)
              when Status=:=invite_calling; Status=:=invite_proceeding ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    #sipmsg{response=Code, to_tag=ToTag, transport=RespTransp} = Resp,
    if
        Code < 200 ->
            UAC1 = cancel_timers([retrans], UAC),
            proc_cancel(ok, UAC1#uac{status=invite_proceeding});
        Code < 300 ->
            UAC1 = cancel_timers([retrans, timeout, expire], UAC),
            UAC2 = proc_cancel(final_response, UAC1),
            T1 = nksip_config:get(timer_t1), 
            UAC2#uac{
                status = invite_accepted,
                timeout_timer = start_timer(64*T1, timer_m, UAC),
                first_to_tag = ToTag
            };
        Code >= 300 ->
            UAC1 = cancel_timers([retrans, timeout, expire], UAC),
            UAC2 = proc_cancel(final_response, UAC1#uac{status=invite_completed}),
            case RespTransp of
                undefined -> ok;
                _ -> send_ack(Req, Resp)
            end,
            case Proto of
                udp -> UAC2#uac{timeout_timer=start_timer(32000, timer_d, UAC)};
                _ -> remove(UAC2)
            end
    end;

do_received_status(invite_accepted, _Req, Resp, UAC) -> 
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code, to_tag=ToTag} = Resp,
    #uac{first_to_tag=FirstToTag} = UAC,
    if
        Code>=200, Code<300, ToTag=/=(<<>>), ToTag=/=FirstToTag ->
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
            ?info(AppId, CallId, 
                  "UAC Trans received 'INVITE' ~p in invite_accepted", [Code])
    end,
    UAC;

do_received_status(invite_completed, Req, Resp, UAC) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, response=Code} = Resp,
    if
        Code >= 300 -> 
            send_ack(Req, Resp);
        true ->  
            ?info(AppId, CallId, 
                  "UAC Trans received 'INVITE' ~p in invite_completed", [Code])
    end,
    UAC;

do_received_status(Status, Req, Resp, UAC) 
              when Status=:=trying; Status=:=proceeding ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    #sipmsg{response=Code} = Resp,
    if
        Code < 200 ->
            cancel_timers([retrans], UAC#uac{status=proceeding});
        Code >= 200 ->
            UAC1 = cancel_timers([retrans, timeout], UAC#uac{status=completed}),
            case Proto of
                udp ->
                    T4 = nksip_config:get(timer_t4), 
                    UAC1#uac{
                        status = completed, 
                        timeout_timer=start_timer(T4, timer_k, UAC)
                    };
                _ ->
                    remove(UAC1)
            end
    end;

do_received_status(completed, Req, Resp, UAC) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, method=Method} = Req,
    #sipmsg{response=Code} = Resp,
    ?info(AppId, CallId, "UAC Trans received ~p ~p retransmission in completed", 
          [Method, Code]),
    UAC.

get_cancel(TransId, Opts, From, #call{uacs=UACs}=SD) ->
    case lists:keytake(TransId, #uac.trans_id, UACs) of
        {value, UAC, Rest} ->
            #uac{status=Status, request=Req} = UAC,
            case Status of
                invite_calling ->
                    CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
                    UAC1 = UAC#uac{cancel={From, CancelReq}},
                    next(SD#call{uacs=[UAC1|Rest]});
                invite_proceeding ->
                    CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
                    gen_server:reply(From, {ok, CancelReq}),
                    next(SD);
                _ ->
                    gen_server:reply(From, {error, no_transaction}),
                    next(SD)
            end;
        false ->
            gen_server:reply(From, {error, no_transaction}),
            next(SD)
    end.



%% ===================================================================
%% Timers
%% ===================================================================

timer(remove, #uac{trans_id=TransId}, #call{uacs=UACs}=SD) ->
    UACs1 = lists:keydelete(TransId, #uac.trans_id, UACs),
    next(SD#call{uacs=UACs1});
    
% INVITE retrans
timer(timer_a, UAC, SD) ->
    #uac{status=Status, request=Req, next_retrans=Next} = UAC,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC retransmitting 'INVITE' in ~p", [Status], SD),
            UAC1 = UAC#uac{
                retrans_timer = start_timer(Next, timer_e, UAC),
                next_retrans = 2*Next
            },
            next(store(UAC1, SD));
        error ->
            ?call_notice("UAC could not retransmit 'INVITE' in ~p", [Status], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            received(Resp, SD)
    end;

% INVITE timeout
timer(timer_b, UAC, SD) ->
    #uac{status=Status, request=Req} = UAC,
    ?call_notice("UAC 'INVITE' Timer F timeout in ~p", [Status], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    received(Resp, SD);

% Timeout in invite_completed
timer(timer_d, UAC, SD) ->
    UAC1 = remove(UAC#uac{timeout_timer=undefined}),
    next(store(UAC1, SD));

% No INVITE retrans
timer(timer_e, UAC, SD) ->
    #uac{
        status = Status,
        request = #sipmsg{method=Method} = Req,
        next_retrans = Next
    } = UAC,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC retransmitting ~p in ~p", [Method, Status], SD),
            T2 = nksip_config:get(timer_t2),
            UAC1 = UAC#uac{
                retrans_timer = start_timer(Next, timer_e, UAC),
                next_retrans = min(2*Next, T2)
            },
            next(store(UAC1, SD));
        error ->
            ?call_notice("UAC could not retransmit ~p in ~p", [Method, Status], SD),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            received(Resp, SD)
    end;

% No INVITE timeout
timer(timer_f, UAC, SD) ->
    #uac{status=Status, request=#sipmsg{method=Method}=Req} = UAC,
    ?call_notice("UAC ~p Timer F timeout in ~p", [Method, Status], SD),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    received(Resp, SD);

% No INVITE completed timeout
timer(timer_k,  UAC, SD) ->
    UAC1 = remove(UAC#uac{timeout_timer=undefined}),
    next(store(UAC1, SD));

% INVITE accepted timeout
timer(timer_m,  UAC, SD) ->
    UAC1 = remove(UAC#uac{timeout_timer=undefined}),
    next(store(UAC1, SD));

timer(expire, #uac{status=Status, request=Req}=UAC, SD) ->
    UAC1 = UAC#uac{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            send(CancelReq, SD);
        true ->
            next(store(UAC1, SD))
    end.



%% ===================================================================
%% Util
%% ===================================================================




%% @private
reply_request(#uac{respfun=Fun, request=Req}) ->
    #sipmsg{method=Method, opts=Opts} = Req,
    case lists:member(full_request, Opts) of
        true when Method=:='ACK' -> catch Fun({ok, Req});
        false when Method=:='ACK' -> catch Fun(ok);
        true -> catch Fun({request, Req});
        false -> ok
    end.

reply_response(#uac{respfun=Fun, request=Req, responses=[Resp|_]}) ->
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


send_ack(Req, Resp) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, vias=[Via|_]} = Req,
    #sipmsg{to=To} = Resp,
    AckReq = Req#sipmsg{
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
    case nksip_transport_uac:resend_request(AckReq) of
        {ok, _} -> ok;
        error -> ?notice(AppId, CallId, "UAC Trans could not send non-2xx ACK", [])
    end.



store(#uac{trans_id=TransId}=UAC, #call{uacs=UACs}=SD) ->
    UACs1 = lists:keystore(TransId, #uac.trans_id, UACs, UAC),
    SD#call{uacs=UACs1}.

remove(UAC) ->
    #uac{
        timeout_timer = Timeout, 
        retrans_timer = Retrans, 
        expire_timer = Expire
    } = UAC,
    case Timeout=/=undefined orelse Retrans=/=undefined orelse Expire=/=undefined of
        true -> ?P("REMOVED WITH TIMERS: ~p", [UAC]);
        false -> ok
    end,
    UAC1 = cancel_timers([timeout, retrans, expire], UAC),
    UAC1#uac{
        status = removed,
        timeout_timer = start_timer(?CALL_FINISH_TIMEOUT, remove, UAC)
    }.



%% @private
-spec transaction_id(nksip:request()) -> binary().

transaction_id(#sipmsg{sipapp_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    % nksip_lib:lhash({AppId, CallId, Method, Branch}).
    erlang:phash2({AppId, CallId, Method, Branch}).

next(SD) ->
    nksip_call_srv:next(SD).


proc_cancel(Reply, #uac{cancel=Cancel}=UAC) ->
    case Cancel of
        {From, CancelReq} when Reply=:=ok -> whgen_server:reply(From, {ok, CancelReq});
        {From, _} -> gen_server:reply(From, {error, Reply});
        _ -> ok
    end,
    UAC#uac{cancel=undefined}.

start_timer(Time, Tag, #uac{trans_id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {uac, Tag, Id})}.

cancel_timers([timeout|Rest], #uac{timeout_timer=OldTimer}=UAC) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAC#uac{timeout_timer=undefined});

cancel_timers([retrans|Rest], #uac{retrans_timer=OldTimer}=UAC) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAC#uac{retrans_timer=undefined});

cancel_timers([expire|Rest], #uac{expire_timer=OldTimer}=UAC) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAC#uac{expire_timer=undefined});

cancel_timers([], UAC) ->
    UAC.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.


