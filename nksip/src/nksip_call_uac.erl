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

-export([get_uac/1, send/2, received/2, get_cancel/4, make_dialog/4, timer/2]).
-export_type([status/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(MAX_AUTH_TRIES, 5).
-define(FINISH_TIMEOUT, 5000).


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
        to_tags = [],
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
    case nksip_call_uac_dialog:make(Id, Method, Opts, SD) of
        {ok, Reply, SD1} -> {reply, Reply, SD1};
        {error, Error} -> {reply, {error, Error}, SD}
    end.


send(UAC, #call{uacs=UACs}=SD) ->
    send(SD#call{uacs=[UAC|UACs]}).


received(Resp, #call{app_id=AppId, call_id=CallId, uacs=UACs}=SD) ->
    #sipmsg{response=Code, cseq_method=Method, to_tag=ToTag, opts=Opts} = Resp,
    Id = transaction_id(Resp),
    case lists:keytake(Id, #uac.id, UACs) of
        {value, UAC, Rest} ->
            #uac{request=#sipmsg{ruri=RUri}, responses=Resps, to_tags=Tags} = UAC,
            UAC1 = case lists:member(ToTag, Tags) of
                false when Tags=:=[] ->
                    Resp1 = Resp#sipmsg{ruri=RUri},
                    UAC#uac{responses=[Resp1|Resps], to_tags=[ToTag|Tags]};
                false ->
                    Resp1 = Resp#sipmsg{ruri=RUri, opts=[secondary_response|Opts]},
                    UAC#uac{responses=[Resp1|Resps]};
                true ->
                    Resp1 = Resp#sipmsg{ruri=RUri},
                    UAC#uac{responses=[Resp1|Resps]};
            end,
            accept(SD#call{uacs=[UAC1|Rest]});
        false ->
            ?notice(AppId, CallId, "received ~p ~p unknown (~s) response", 
                    [Method, Code, Id]),
            next(SD)
    end.



timer(uac_remove, #call{uacs=[_|Rest]}=SD) ->
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
            UAC1 = UAC#uac{retrans_timer=undefined},
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            received(Resp, SD#call{uacs=[UAC1|Rest]})
    end;

% INVITE timeout
timer(timer_b, #call{app_id=AppId, call_id=CallId, uacs=[UAC|Rest]}=SD) ->
    #uac{status=Status, request=Req, retrans_timer=RetransTimer} = UAC,
    cancel_timer(RetransTimer),
    ?notice(AppId, CallId, "UAC 'INVITE' Timer F timeout in ~p", [Status]),
    UAC1 = UAC#uac{retrans_timer=undefined, timeout_timer=undefined},
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout">>),
    received(Resp, SD#call{uacs=[UAC1|Rest]});

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
            UAC1 = UAC#uac{retrans_timer=undefined},
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            received(Resp, SD#call{uacs=[UAC1|Rest]})
    end;

% No INVITE timeout
timer(timer_f, #call{app_id=AppId, call_id=CallId, uacs=[UAC|Rest]}=SD) ->
    #uac{
        status = Status,
        request = #sipmsg{method=Method} = Req,
        retrans_timer = RetransTimer
    } = UAC,
    cancel_timer(RetransTimer),
    ?notice(AppId, CallId, "UAC ~p Timer F timeout in ~p", [Method, Status]),
    UAC1 = UAC#uac{retrans_timer=undefined, timeout_timer=undefined},
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout">>),
    received(Resp, SD#call{uacs=[UAC1|Rest]});

% No INVITE completed timeout
timer(timer_k, SD) ->
    next(remove(SD));

% INVITE accepted timeout
timer(timer_m, SD) ->
    next(remove(SD));

timer(uac_expire, #call{uacs=[#uac{status=Status, request=Req}=UAC|Rest]}=SD) ->
    UAC1 = UAC#uac{expire_timer=undefined},
    SD1 = SD#call{uacs=[UAC1|Rest]},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            Cancel = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            UAC = get_uac(Cancel),
            send(UAC, SD1);
        true ->
            next(SD1)
    end.


send(#call{app_id=AppId, call_id=CallId, uacs=[#uac{id=Id, request=Req}=UAC|Rest]}=SD) ->
    case nksip_call_uac_dialog:request(SD) of
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
                {ok, SentReq} when Method=:='ACK' ->
                    ?debug(AppId, CallId, "UAC sent ~p (~s) request", [Method, Id]),
                    UAC1 = UAC#uac{request=SentReq},
                    SD2 = SD1#call{uacs=[UAC1|Rest]},
                    SD3 = nksip_call_uac_dialog:ack(SentReq, SD2),
                    next(remove(SD3));
                {ok, SentReq} ->
                    ?debug(AppId, CallId, "UAC sent ~p (~s) request", [Method, Id]),
                    UAC1 = UAC#uac{request=SentReq},
                    UAC2 = case Method of
                        'INVITE' -> send_invite(UAC1);
                        _ -> send_noinvite(UAC1)
                    end,
                    SD2 = SD1#call{uacs=[UAC2|Rest]},
                    reply(request, SD2),
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


send_invite(#uac{id=Id, request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}, opts=Opts} = Req,
    T1 = nksip_config:get(timer_t1),
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            case lists:member(no_uac_expire, Opts) of
                true -> undefined;
                _ -> start_timer(1000*Expires, uac_expire, Id)
            end;
        _ ->
            undefined
    end,
    UAC1 = UAC#uac{
        status = invite_calling,
        timeout_timer = start_timer(64*T1, timer_b, Id),
        expire_timer = ExpireTimer
    },
    case Proto of 
        udp ->
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_a, Id),
                next_retrans = 2*T1
            };
        _ ->
            UAC1
    end.

send_noinvite(#uac{id=Id, request=Req}=UAC) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    T1 = nksip_config:get(timer_t1),
    UAC1 = UAC#uac{
        status = trying,
        % timeout_timer = start_timer(64*T1, timer_f, Id)
        timeout_timer = start_timer(10000, timer_f, Id)
    },
    case Proto of
        udp ->
            T2 = nksip_config:get(timer_t2), 
            UAC1#uac{
                retrans_timer = start_timer(T1, timer_e, Id),
                next_retrans = min(2*T1, T2)
            };
        _ ->
            UAC1
    end.


accept(#call{app_id=AppId, call_id=CallId, uacs=[UAC|_]}=SD) ->
    #uac{
        status = Status,
        request = #sipmsg{method=Method},
        responses = [#sipmsg{response=Code}|_]
    } = UAC,
    case Status of
        removed ->
            ?notice(AppId, CallId, "UAC received ~p ~p for removed request", 
                    [Method, Code]),
            next(SD);
        _ ->
            ?debug(AppId, CallId, "UAC ~p received ~p in ~p", [Method, Code, Status]),
            SD1 = nksip_call_uac_dialog:response(SD),
            SD2 = accept_status(Status, Code, SD1),
            accept_code(Code, SD2)
    end.

accept_status(Status, Code, #call{uacs=[UAC|Rest]}=SD) 
    when Status=:=invite_calling; Status=:=invite_proceeding ->
    #uac{
        id = Id, 
        request = #sipmsg{transport=#transport{proto=Proto}},
        retrans_timer = RetransTimer, 
        timeout_timer = TimeoutTimer,
        expire_timer = ExpireTimer
    } = UAC,
    if
        Code < 200 ->
            cancel_timer(RetransTimer),
            UAC1 = UAC#uac{status=invite_proceeding, retrans_timer=undefined},
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
                expire_timer = undefined
            },
            SD#call{uacs=[UAC1|Rest]};
        Code >= 300 ->
            cancel_timer(RetransTimer),
            cancel_timer(TimeoutTimer), 
            cancel_timer(ExpireTimer), 
            send_ack(UAC, SD),
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
        responses = [#sipmsg{response=Code, opts=RespOpts}=Resp|_]
    } = UAC,
    case lists:member(secondary_response, RespOpts) of
        true when Code >= 200, Code < 300 ->
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
                  "UAC Trans received ~p retransmission in ~p", 
                  [Method, Status])

    end,
    SD;

accept_status(invite_completed, Code, SD) ->
    #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]} = SD,
    #uac{responses=[#sipmsg{cseq_method=Method, response=Code}|_]} = UAC,
    if
        Code >= 300 -> 
            send_ack(UAC, SD);
        true ->  
            ?info(AppId, CallId, 
                  "UAC Trans received 'INVITE' ~p response in invite_completed", 
                  [Method, Code])
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

accept_status(completed, _Code, SD) ->
    #call{app_id=AppId, call_id=CallId, uacs=[UAC|_]} = SD,
    #uac{status=Status, responses=[#sipmsg{cseq_method=Method, opts=Opts}|_]} = UAC,
    case lists:member(secondary_response, Opts) of
        true ->
            % Forked response
            ?debug(AppId, CallId, 
                  "UAC ignoring forked ~p response in ~p", [Method, Status]);
        false ->
            ?info(AppId, CallId, 
                  "UAC Trans received ~p retransmission in ~p", [Method, Status])
    end,
    SD.


accept_code(Code, 
            #call{uacs=[#uac{request=#sipmsg{method=Method}, iter=Iter}=UAC|Rest]}=SD)
            when (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
                 andalso Method=/='CANCEL' ->
    #uac{request=Req, responses=[Resp|_]} = UAC,
    case nksip_auth:make_request(Req, Resp) of
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            Req2 = Req1#sipmsg{
                vias = Vias, 
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            UAC1 = UAC#uac{
                id = transaction_id(Req3),
                request = Req3,
                responses = [],
                to_tags = [],
                cancel = undefined,
                iter = Iter+1
            },
            send(SD#call{uacs=[UAC1|Rest]});
        error ->    
            % stop_secondary_dialogs(Resp),
            reply(Resp, SD),
            next(SD)
    end;

accept_code(Code, #call{uacs=[UAC|Rest]}=SD) when Code < 200 ->
    #uac{responses=[Resp|_], cancel=Cancel} = UAC,
    reply(Resp, SD),
    case Cancel of
        {reply, From, Cancel} -> gen_server:reply(From, Cancel);
        _ -> ok
    end,
    UAC1 = UAC#uac{cancel=undefined},
    next(SD#call{uacs=[UAC1|Rest]});


accept_code(_Code, #call{uacs=[UAC|_]}=SD) ->
    #uac{responses=[Resp|_]} = UAC,
    reply(Resp, SD),
    next(SD).




%% ===================================================================
%% Private
%% ===================================================================


%% @private
reply(Reply, #call{uacs=[UAC|_]}) ->
    #uac{respfun=Fun, request=Req} = UAC,
    #sipmsg{method=Method, opts=Opts} = Req,
    case Reply of
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
            end;
        request ->
            case lists:member(full_request, Opts) of
                true when Method=:='ACK' -> Fun({ok, Req});
                false when Method=:='ACK' -> Fun(ok);
                true -> Fun({request, Req});
                false -> ok
            end;
        {error, Error} ->
            Fun({error, Error})
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
    cancel_timer(Timeout),
    cancel_timer(Retrans),
    cancel_timer(Expire),
    UAC1 = UAC#uac{
        status = removed,
        timeout_timer = start_timer(?FINISH_TIMEOUT, uac_remove, Id),
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


