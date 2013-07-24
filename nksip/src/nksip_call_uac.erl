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

-export([get_uac/1, send/1, received/2, get_cancel/4, make_dialog/4, timer/2]).
-export([send_no_trans_id/2]).
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


%% ===================================================================
%% Public
%% ===================================================================



get_uac(#sipmsg{method=Method, call_id=CallId, opts=Opts}=Req) ->
    case nksip_lib:get_value(respfun, Opts) of
        Fun when is_function(Fun, 1) -> ok;
        _ -> Fun = fun(_) -> ok end
    end,
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req)
    end,
    Id = transaction_id(Req1),
    nksip_proc:put({nksip_trans_id, Id}, CallId),
    #uac{
        id = Id,
        request = Req1,
        responses = [],
        respfun = Fun,
        iter = 1
    }.


get_cancel(Id, Opts, From, #call{uacs=UACs}=SD) ->
    case lists:keytake(Id, #uac.id, UACs) of
        {value, #uac{status=Status, request=Req}=UAC, Rest} ->
            Cancel = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            case Status of
                invite_calling ->
                    UAC1 = UAC#uac{cancel={reply, From, Cancel}},
                    {noreply, SD#call{uacs=[UAC1|Rest]}};
                invite_proceeding ->
                    {reply, {ok, Cancel}, SD};
                _ ->
                    {reply, no_transaction, SD}
            end;
        false ->
            {reply, no_transaction, SD}
    end.

make_dialog(Id, Method, Opts, SD) ->
    case nksip_call_dialog_uac:make(Id, Method, Opts, SD) of
        {ok, Reply, SD1} -> {reply, {ok, Reply}, SD1};
        {error, Error} -> {reply, {error, Error}, SD}
    end.


send_no_trans_id(Id, #call{uacs=UACs}=SD) ->
    case lists:keytake(Id, #uac.id, UACs) of
        {value, #uac{request=#sipmsg{method=Method}=Req}=UAC, Rest} -> 
            Status = case Method of
                'INVITE'-> invite_calling;
                _ -> trying
            end,
            UAC1 = UAC#uac{status=Status},
            Reply = nksip_reply:reply(Req, no_transaction),
            received(Reply, SD#call{uacs=[UAC1|Rest]});
        false -> 
            next(SD)
    end.


received(Resp, #call{app_id=AppId, call_id=CallId, uacs=UACs}=SD) ->
    #sipmsg{response=Code, cseq_method=Method} = Resp,
    Id = transaction_id(Resp),
    case lists:keytake(Id, #uac.id, UACs) of
        {value, UAC, Rest} ->
            #uac{request=#sipmsg{ruri=RUri}, responses=Resps} = UAC,
            UAC1 = UAC#uac{responses=[Resp#sipmsg{ruri=RUri}|Resps]},
            accept(SD#call{uacs=[UAC1|Rest]});
        false ->
            ?notice(AppId, CallId, "received ~p ~p unknown response (~s)", 
                    [Method, Code, Id]),
            next(SD)
    end.


send(#call{app_id=AppId, call_id=CallId, uacs=[#uac{id=Id, request=Req}=UAC|Rest]}=SD) ->
    case nksip_call_dialog_uac:request(SD) of
        {wait, SD1} ->
            UAC1 = UAC#uac{status=wait_invite},
            next(SD1#call{uacs=[UAC1|Rest]});
        {ok, SD1} ->
            #sipmsg{method=Method} = Req,
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    ?debug(AppId, CallId, "UAC sent ~p (~s) request", [Method, Id]),
                    UAC1 = UAC#uac{request=SentReq},
                    SD2 = sent_method(Method, SD1#call{uacs=[UAC1|Rest]}),
                    reply_request(SD2),
                    next(SD2);
                error ->
                    ?debug(AppId, CallId, "UAC error sending ~p (~s) request", 
                           [Method, Id]),
                    Status = case Method of
                        'INVITE'-> invite_calling;
                        _ -> trying
                    end,
                    UAC1 = UAC#uac{status=Status},
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    received(Reply, SD1#call{uacs=[UAC1|Rest]})
            end
    end.


sent_method('INVITE', #call{uacs=[#uac{id=Id, request=Req}=UAC|Rest]}=SD) ->
    #sipmsg{transport=#transport{proto=Proto}, opts=Opts} = Req,
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            case lists:member(no_uac_expire, Opts) of
                true -> undefined;
                _ -> start_timer(1000*Expires, expire, Id)
            end;
        _ ->
            undefined
    end,
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = invite_calling,
        timeout_timer = start_timer(64*T1, timer_b, Id),
        expire_timer = ExpireTimer
    },
    UAC2 = case Proto of 
        udp ->
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_a, Id),
                next_retrans = 2*T1
            };
        _ ->
            UAC1
    end,
    SD#call{uacs=[UAC2|Rest]};

% Maintain ACK to resend if neccesary
sent_method('ACK', #call{uacs=[#uac{id=Id}=UAC|Rest]}=SD) ->
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = completed,
        timeout_timer = start_timer(64*T1, remove, Id)
    },
    nksip_call_dialog_uac:ack(SD#call{uacs=[UAC1|Rest]});

sent_method(_, #call{uacs=[#uac{id=Id, request=Req}=UAC|Rest]}=SD) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = trying,
        timeout_timer = start_timer(64*T1, timer_f, Id)
    },
    UAC2 = case Proto of
        udp ->
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_e, Id),
                next_retrans = 2*T1
            };
        _ ->
            UAC1
    end,
    SD#call{uacs=[UAC2|Rest]}.


accept(#call{app_id=AppId, call_id=CallId, uacs=[#uac{status=removed}=UAC|_]}=SD) ->
    #uac{request=#sipmsg{method=Method}} = UAC,
    ?notice(AppId, CallId, "UAC received ~p response for removed request", [Method]),
    next(SD);

accept(#call{app_id=AppId, call_id=CallId, uacs=[UAC|Rest]}=SD) ->
    #uac{
        status = Status,
        request = #sipmsg{method=Method} = Req,
        responses = [#sipmsg{response=Code, transport=RespTransp}=Resp|_],
        iter = Iter
    } = UAC,
    case RespTransp of
        undefined -> ok;
        _ -> ?debug(AppId, CallId, "UAC ~p received ~p in ~p", [Method, Code, Status])
    end,
    SD1 = nksip_call_dialog_uac:response(SD),
    SD2 = accept_status(Status, Code, SD1),
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
         andalso Method=/='CANCEL'
    of
        true -> 
            case nksip_auth:make_request(Req, Resp) of
                {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
                    Req2 = Req1#sipmsg{
                        vias = Vias, 
                        opts = nksip_lib:delete(Opts, make_contact)
                    },
                    Req3 = nksip_transport_uac:add_via(Req2),
                    NewUAC = UAC#uac{
                        id = transaction_id(Req3),
                        request = Req3,
                        responses = [],
                        first_to_tag = <<>>,
                        cancel = undefined,
                        iter = Iter+1
                    },
                    send(SD2#call{uacs=[NewUAC, UAC|Rest]});
                error ->    
                    % stop_secondary_dialogs(Resp),
                    reply_response(SD2),
                    next(SD2)
            end;
        false ->
            reply_response(SD2),
            next(SD2)
    end.


accept_status(Status, Code, #call{uacs=[UAC|Rest]}=SD) 
    when Status=:=invite_calling; Status=:=invite_proceeding ->
    #uac{
        id = Id, 
        request = #sipmsg{transport=#transport{proto=Proto}},
        responses = [#sipmsg{to_tag=ToTag, transport=RespTransp}|_],
        retrans_timer = RetransTimer, 
        timeout_timer = TimeoutTimer,
        expire_timer = ExpireTimer,
        cancel = Cancel
    } = UAC,
    if
        Code < 200 ->
            cancel_timer(RetransTimer),
            case Cancel of
                {reply, From, Cancel} -> gen_server:reply(From, Cancel);
                _ -> ok
            end,
            UAC1 = UAC#uac{status=invite_proceeding, retrans_timer=undefined, 
                           cancel=undefined},
            SD#call{uacs=[UAC1|Rest]};
        Code < 300 ->
            cancel_timer(RetransTimer),
            cancel_timer(TimeoutTimer), 
            cancel_timer(ExpireTimer), 
            T1 = nksip_config:get(timer_t1), 
            UAC1 = UAC#uac{
                status = invite_accepted,
                retrans_timer = undefined,
                timeout_timer = start_timer(64*T1, timer_m, Id),
                expire_timer = undefined,
                first_to_tag = ToTag
            },
            SD#call{uacs=[UAC1|Rest]};
        Code >= 300 ->
            cancel_timer(RetransTimer),
            cancel_timer(TimeoutTimer), 
            cancel_timer(ExpireTimer), 
            case RespTransp of
                undefined -> ok;
                _ -> send_ack(UAC, SD)
            end,
            case Proto of
                udp ->
                    UAC1 = UAC#uac{
                        status = invite_completed,
                        retrans_timer = undefined,
                        timeout_timer = start_timer(32000, timer_d, Id),
                        expire_timer = undefined
                    },
                    SD#call{uacs=[UAC1|Rest]};
                _ ->
                    remove(SD)
            end
    end;

accept_status(invite_accepted, Code, SD) -> 
    #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]} = SD,
    #uac{
        status = Status,
        request = #sipmsg{method=Method},
        responses = [#sipmsg{response=Code, to_tag=ToTag}=Resp|_],
        first_to_tag = FirstToTag
    } = UAC,
    case Code>=200 andalso Code<300 andalso ToTag=/=FirstToTag of
        true ->
            % BYE any secondary response
            spawn(
                fun() ->
                    DialogId = nksip_dialog:id(Resp),
                    ?info(AppId, CallId, "UAC sending ACK and BYE to secondary "
                          "Response (Dialog ~s)", [DialogId]),
                    case nksip_uac:ack(DialogId, []) of
                        ok -> nksip_uac:bye(DialogId, [async]);
                        _ -> error
                    end
                end);
        _ ->
            ?info(AppId, CallId, 
                  "UAC Trans received ~p ~p retransmission in ~p", [Method, Code, Status])
    end,
    SD;

accept_status(invite_completed, Code, SD) ->
    #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]} = SD,
    if
        Code >= 300 -> 
            send_ack(UAC, SD);
        true ->  
            ?info(AppId, CallId, 
                  "UAC Trans received 'INVITE' ~p response in invite_completed", 
                  [Code])
    end,
    SD;

accept_status(Status, Code, #call{uacs=[UAC|Rest]} = SD) 
              when Status=:=trying; Status=:=proceeding ->
    #uac{
        id = Id, 
        request = #sipmsg{transport=#transport{proto=Proto}},
        retrans_timer = RetransTimer, 
        timeout_timer = TimeoutTimer
    } = UAC,
    if
        Code < 200 ->
            cancel_timer(RetransTimer),
            UAC1 = UAC#uac{status=proceeding, retrans_timer=undefined},
            SD#call{uacs=[UAC1|Rest]};
        Code >= 200 ->
            cancel_timer(RetransTimer),
            cancel_timer(TimeoutTimer),
            case Proto of
                udp ->
                    T4 = nksip_config:get(timer_t4), 
                    UAC1 = UAC#uac{
                        status = completed,
                        retrans_timer = undefined,
                        timeout_timer = start_timer(T4, timer_k, Id)
                    },
                    SD#call{uacs=[UAC1|Rest]};
                _ ->
                    remove(SD)
            end
    end;

accept_status(completed, Code, SD) ->
    #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]} = SD,
    #uac{responses = [#sipmsg{cseq_method=Method}|_]} = UAC,
    ?info(AppId, CallId, 
         "UAC Trans received ~p ~p retransmission in completed", [Method, Code]),
    SD.



%% ===================================================================
%% Timers
%% ===================================================================

timer(remove, #call{uacs=[_|Rest]}=SD) ->
    next(SD#call{uacs=Rest});
    
% INVITE retrans
timer(timer_a, #call{app_id=AppId, call_id=CallId, uacs=[UAC|Rest]}=SD) ->
    #uac{id=Id, status=Status, request=Req, next_retrans=Next} = UAC,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?info(AppId, CallId, "UAC retransmitting 'INVITE' in ~p", [Status]),
            UAC1 = UAC#uac{
                retrans_timer = start_timer(Next, timer_e, Id),
                next_retrans = 2*Next
            },
            next(SD#call{uacs=[UAC1|Rest]});
        error ->
            ?notice(AppId, CallId, "UAC could not retransmit 'INVITE' in ~p", [Status]),
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            received(Resp, SD)
    end;

% INVITE timeout
timer(timer_b, #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]}=SD) ->
    #uac{status=Status, request=Req} = UAC,
    ?notice(AppId, CallId, "UAC 'INVITE' Timer F timeout in ~p", [Status]),
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout">>),
    received(Resp, SD);

% Timeout in invite_completed
timer(timer_d, #call{uacs=[UAC|Rest]}=SD) ->
    UAC1 = UAC#uac{timeout_timer=undefined},
    next(remove(SD#call{uacs=[UAC1|Rest]}));

% No INVITE retrans
timer(timer_e, #call{app_id=AppId, call_id=CallId, uacs=[UAC|Rest]}=SD) ->
    #uac{
        id = Id,
        status = Status,
        request = #sipmsg{method=Method} = Req,
        next_retrans = Next
    } = UAC,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?info(AppId, CallId, "UAC retransmitting ~p in ~p", [Method, Status]),
            T2 = nksip_config:get(timer_t2),
            UAC1 = UAC#uac{
                retrans_timer = start_timer(Next, timer_e, Id),
                next_retrans = min(2*Next, T2)
            },
            next(SD#call{uacs=[UAC1|Rest]});
        error ->
            ?notice(AppId, CallId, "UAC could not retransmit ~p in ~p",
                    [Method, Status]),
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            received(Resp, SD)
    end;

% No INVITE timeout
timer(timer_f, #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]}=SD) ->
    #uac{status=Status, request=#sipmsg{method=Method}=Req} = UAC,
    ?notice(AppId, CallId, "UAC ~p Timer F timeout in ~p", [Method, Status]),
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout">>),
    received(Resp, SD);

% No INVITE completed timeout
timer(timer_k,  #call{uacs=[UAC|Rest]}=SD) ->
    UAC1 = UAC#uac{timeout_timer=undefined},
    next(remove(SD#call{uacs=[UAC1|Rest]}));

% INVITE accepted timeout
timer(timer_m,  #call{uacs=[UAC|Rest]}=SD) ->
    UAC1 = UAC#uac{timeout_timer=undefined},
    next(remove(SD#call{uacs=[UAC1|Rest]}));

timer(expire, #call{uacs=[#uac{status=Status, request=Req}=UAC|Rest]}=SD) ->
    UAC1 = UAC#uac{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            Cancel = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            CancelUAC = get_uac(Cancel),
            send(SD#call{uacs=[CancelUAC, UAC1|Rest]});
        true ->
            next(SD#call{uacs=[UAC1|Rest]})
    end.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
reply_request(#call{uacs=[UAC|_]}) ->
    #uac{respfun=Fun, request=Req} = UAC,
    #sipmsg{method=Method, opts=Opts} = Req,
    case lists:member(full_request, Opts) of
        true when Method=:='ACK' -> Fun({ok, Req});
        false when Method=:='ACK' -> Fun(ok);
        true -> Fun({request, Req});
        false -> ok
    end.

reply_response(#call{uacs=[UAC|_]}) ->
    #uac{respfun=Fun, request=Req, responses=[Resp|_]} = UAC,
    #sipmsg{method=Method, opts=Opts} = Req,
    case Resp of
        #sipmsg{response=Code} when Code < 101 ->
            ok;
        #sipmsg{response=Code}=Resp ->
            case lists:member(full_response, Opts) of
                true ->
                    Fun({reply, Resp#sipmsg{ruri=Resp#sipmsg.ruri}});
                false when Method=:='INVITE' ->
                    Fun({ok, Code, nksip_dialog:id(Resp)});
                false -> 
                    Fun({ok, Code})
            end
    end.


send_ack(#uac{request=Req, responses=[Resp|_]}, SD) ->
    #sipmsg{vias=[Via|_]} = Req,
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
        {ok, _} -> 
            ok;
        error -> 
            #call{app_id=AppId, call_id=CallId} = SD,
            ?notice(AppId, CallId, "UAC Trans could not send non-2xx ACK", [])
    end.



remove(#call{uacs=[UAC|Rest]}=SD) ->
    #uac{
        id = Id, 
        timeout_timer = Timeout, 
        retrans_timer = Retrans, 
        expire_timer = Expire
    } = UAC,
    case Timeout=/=undefined orelse Retrans=/=undefined orelse Expire=/=undefined of
        true -> ?P("REMOVED WITH TIMERS: ~p", [UAC]);
        false -> ok
    end,
    cancel_timer(Timeout),
    cancel_timer(Retrans),
    cancel_timer(Expire),
    UAC1 = UAC#uac{
        status = removed,
        timeout_timer = start_timer(?CALL_FINISH_TIMEOUT, remove, Id),
        retrans_timer = undefined,
        expire_timer = undefined
    },
    SD#call{uacs=[UAC1|Rest]}.



%% @private
-spec transaction_id(nksip:request()) -> binary().

transaction_id(#sipmsg{sipapp_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    nksip_lib:lhash({AppId, CallId, Method, Branch}).

next(SD) ->
    nksip_call_srv:next(SD).


start_timer(Time, Tag, Pos) ->
    {Tag, erlang:start_timer(Time, self(), {uac, Tag, Pos})}.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.


