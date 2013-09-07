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

%% @doc UAC transaction process
-module(nksip_call_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/3, response/2, cancel/2, fork_cancel/2, timer/3]).
-export_type([status/0, id/0]).
-import(nksip_call_lib, [update/2, new_sipmsg/3, update_sipmsg/2, 
                         timeout_timer/2, retrans_timer/2, expire_timer/2, cancel_timers/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(MAX_AUTH_TRIES, 5).


%% ===================================================================
%% Types
%% ===================================================================

-type status() :: invite_calling | invite_proceeding | invite_accepted |
                  invite_completed |
                  trying | proceeding | completed |
                  finished | ack.

-type id() :: integer().

-type trans() :: nksip_call:trans().

-type call() :: nksip_call:call().

-type uac_from() :: {srv, from()} | {fork, nksip_call_fork:id()} | none.



%% ===================================================================
%% Send Request
%% ===================================================================


%% @doc Starts a new UAC transaction
-spec request(nksip:request(), uac_from(), call()) ->
    call().

request(#sipmsg{method=Method, opts=Opts}=Req, From, #call{trans=Trans}=Call) ->
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req)
    end,
    {IsFork, Forked} = case From of 
        {fork, _} -> {true, "(forked) "};
        _ -> {false, ""}
    end,
    {Req2, Call1} = new_sipmsg(Req1, IsFork, Call),
    UAC = make_uac(Req2, From),
    case lists:member(async, Opts) andalso From of
        {srv, SrvFrom} -> 
            FullReqId = nksip_request:id(Req2),
            gen_server:reply(SrvFrom, {async, FullReqId});
        _ ->
            ok
    end,
    #trans{id=TransId, request=#sipmsg{id=ReqId}} = UAC,
    ?call_debug("UAC ~p sending ~srequest ~p (~p)", 
                [TransId, Forked, Method, ReqId], Call1),
    do_send(Method, UAC, Call1#call{trans=[UAC|Trans]}).


%% @private
-spec make_uac(nksip:request(), uac_from()) ->
    {trans(), call()}.

make_uac(Req, From) ->
    #sipmsg{method=Method, ruri=RUri, opts=Opts} = Req, 
    Status = case Method of
        'ACK' -> ack;
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    #trans{
        class = uac,
        id = transaction_id(Req),
        status = Status,
        start = nksip_lib:timestamp(),
        from = From,
        request = Req,
        method = Method,
        ruri = RUri,
        opts = Opts,
        response = undefined,
        code = 0,
        to_tags = [],
        cancel = undefined,
        iter = 1
    }.



% @private
-spec do_send(nksip:method(), trans(), call()) ->
    call().

do_send('ACK', #trans{id=Id, request=Req}=UAC, Call) ->
    case nksip_transport_uac:send_request(Req) of
       {ok, SentReq} ->
            ?call_debug("UAC ~p sent 'ACK' request", [Id], Call),
            Call1 = send_user_reply({req, SentReq}, UAC, Call),
            UAC1 = UAC#trans{status=finished, request=SentReq},
            Call2 = update_sipmsg(SentReq, Call1),
            Call3 = nksip_call_dialog_uac:ack(UAC1, Call2),
            update(UAC1, Call3);
        error ->
            ?call_debug("UAC ~p error sending 'ACK' request", [Id], Call),
            Call1 = send_user_reply({error, network_error}, UAC, Call),
            UAC1 = UAC#trans{status=finished},
            update(UAC1, Call1)
    end;

do_send(_, #trans{method=Method, id=Id, request=Req, from=From, opts=Opts}=UAC, Call) ->
    DialogResult = case From of
        {fork, _} -> 
            {ok, Call};
        _ -> 
            case lists:member(no_dialog, Opts) of
                true -> {ok, Call};
                false -> nksip_call_dialog_uac:request(UAC, Call)
            end
    end,
    case DialogResult of
        {ok, Call1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    ?call_debug("UAC ~p sent ~p request", [Id, Method], Call),
                    Call2 = send_user_reply({req, SentReq}, UAC, Call1),
                    #sipmsg{transport=#transport{proto=Proto}} = SentReq,
                    Call3 = update_sipmsg(SentReq, Call2),
                    UAC1 = UAC#trans{request=SentReq, proto=Proto},
                    UAC2 = sent_method(Method, UAC1),
                    update(UAC2, Call3);
                error ->
                    ?call_debug("UAC ~p error sending ~p request", 
                                [Id, Method], Call),
                    Call2 = send_user_reply({req, Req}, UAC, Call1),
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    response(Reply, Call2)
            end;
        {error, finished} ->
            Call1 = send_user_reply({error, unknown_dialog}, UAC, Call),
            update(UAC#trans{status=finished}, Call1);
        {error, request_pending} ->
            Call1 = send_user_reply({error, request_pending}, UAC, Call),
            update(UAC#trans{status=finished}, Call1)
    end.


%% @private 
-spec sent_method(nksip:method(), trans()) ->
    trans().

sent_method('INVITE', #trans{proto=Proto}=UAC) ->
    UAC1 = expire_timer(expire, UAC#trans{status=invite_calling}),
    UAC2 = timeout_timer(timer_b, UAC1),
    case Proto of 
        udp -> retrans_timer(timer_a, UAC2);
        _ -> UAC2
    end;

sent_method(_Other, #trans{proto=Proto}=UAC) ->
    UAC1 = timeout_timer(timer_f, UAC#trans{status=trying}),
    case Proto of 
        udp -> retrans_timer(timer_e, UAC1);
        _ -> UAC1
    end.
    


%% ===================================================================
%% Receive response
%% ===================================================================


%% @doc Called when a new response is received
-spec response(nksip:response(), call()) ->
    call().

response(Resp, #call{trans=Trans}=Call) ->
    #sipmsg{cseq_method=Method, response=Code} = Resp,
    TransId = transaction_id(Resp),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uac}=UAC -> 
            do_response(Resp, UAC, Call);
        _ -> 
            case nksip_uac_lib:is_stateless(Resp) of
                true ->
                    nksip_call_proxy:response_stateless(Resp, Call);
                false ->
                    ?call_notice("UAC ~p received ~p ~p response for "
                                 "unknown request", [TransId, Method, Code], Call),
                    Call
            end
    end.


%% @private
-spec do_response(nksip:response(), trans(), call()) ->
    call().

do_response(Resp, UAC, Call) ->
    #sipmsg{transport=Transport, response=Code} = Resp,
    #trans{
        id = Id, 
        start = Start, 
        status = Status,
        method = Method,
        request = Req, 
        from = From, 
        ruri = RUri,
        opts = Opts
    } = UAC,
    #call{max_trans_time=MaxTime} = Call,
    Now = nksip_lib:timestamp(),
    Resp1 = case Now-Start < MaxTime of
        true -> Resp#sipmsg{ruri=RUri};
        false -> nksip_reply:reply(Req, timeout)
    end,
    NotStore = case From of {fork, _} -> true; _ -> false end,
    {Resp2, Call1} = new_sipmsg(Resp1, NotStore, Call),
    UAC1 = UAC#trans{response=Resp2, code=Code},
    case Transport of
        undefined -> 
            ok;    % It is own-generated
        _ -> 
            ?call_debug("UAC ~p ~p (~p) received ~p", 
                        [Id, Method, Status, Code], Call)
    end,
    Call2 = case lists:member(no_dialog, Opts) of
        true -> update(UAC1, Call1);
        false -> nksip_call_dialog_uac:response(UAC1, update(UAC1, Call1))
    end,
    do_response_status(Status, Resp2, UAC1, Call2).


%% @private
-spec do_response_status(status(), nksip:response(), trans(), call()) ->
    call().

do_response_status(invite_calling, Resp, UAC, Call) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=invite_proceeding}),
    do_response_status(invite_proceeding, Resp, UAC1, Call);

do_response_status(invite_proceeding, Resp, #trans{code=Code}=UAC, Call) 
                   when Code < 200 ->
    #trans{cancel=Cancel} = UAC,
    % Add another 3 minutes
    UAC1 = timeout_timer(timeout, cancel_timers([timeout], UAC)),
    Call1 = send_user_reply({resp, Resp}, UAC1, Call),
    case Cancel of
        to_cancel -> do_cancel(UAC1, update(UAC1, Call1));
        _ -> update(UAC1, Call1)
    end;

% Final 2xx response received
% Enters new RFC6026 'invite_accepted' state, to absorb 2xx retransmissions
% and forked responses
do_response_status(invite_proceeding, Resp, #trans{code=Code}=UAC, Call) 
                   when Code < 300 ->
    #sipmsg{to_tag=ToTag} = Resp,
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
    UAC2 = timeout_timer(timer_m, UAC1#trans{status=invite_accepted, to_tags=[ToTag]}),
    update(UAC2, Call1);


% Final [3456]xx response received, own error response
do_response_status(invite_proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
    update(UAC1#trans{status=finished}, Call1);


% Final [3456]xx response received, real response
do_response_status(invite_proceeding, Resp, UAC, Call) ->
    #sipmsg{to=To, to_tag=ToTag} = Resp,
    #trans{request=#sipmsg{vias=[Via|_]}=Req, proto=Proto} = UAC,
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
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
    UAC2 = UAC1#trans{request=Ack, response=undefined, to_tags=[ToTag]},
    send_ack(UAC2),
    UAC3 = case Proto of
        udp -> timeout_timer(timer_d, UAC2#trans{status=invite_completed});
        _ -> UAC2#trans{status=finished}
    end,
    % do_received_auth() send the reply if it is not resent
    do_received_auth(Req, Resp, UAC3, update(UAC3, Call));


do_response_status(invite_accepted, _Resp, #trans{code=Code}, Call) 
                   when Code < 200 ->
    Call;

do_response_status(invite_accepted, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, to_tags=ToTags} = UAC,
    case lists:member(ToTag, ToTags) of
        true ->
            ?call_debug("UAC ~p (invite_accepted) received ~p retransmission",
                        [Id, Code], Call),
            Call;
        false when Code < 300 ->    
            % 2xx response
            ?call_info("UAC ~p (invite_accepted) sending ACK and BYE to "
                               "secondary response", 
                               [Id], Call),
            spawn(
                fun() ->
                    case nksip_uac:ack(Resp, []) of
                        ok -> nksip_uac:bye(Resp, [async]);
                        _ -> error
                    end
                end),
            UAC1 = UAC#trans{to_tags=ToTags++[ToTag]},
            update(UAC1, Call);
        false ->                    
            % [3456]xx response
            ?call_info("UAC ~p (invite_accepted) received new ~p response",
                        [Id, Code], Call),
            UAC1 = UAC#trans{to_tags=ToTags++[ToTag]},
            update(UAC1, Call)
    end;

do_response_status(invite_completed, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, to_tags=ToTags} = UAC,
    case ToTags of
        [ToTag|_] when Code >= 300 ->
            send_ack(UAC);
        _ ->  
            ?call_notice("UAC ~p 'INVITE' (invite_completed) received ~p", 
                        [Id, Code], Call)
    end,
    Call;

do_response_status(trying, Resp, UAC, Call) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=proceeding}),
    do_response_status(proceeding, Resp, UAC1, Call);

do_response_status(proceeding, #sipmsg{response=Code}=Resp, UAC, Call) 
                   when Code < 200 ->
    send_user_reply({resp, Resp}, UAC, Call);

% Final response received, own error response
do_response_status(proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout], UAC#trans{status=finished}),
    update(UAC1, Call1);

% Final response received, real response
do_response_status(proceeding, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{proto=Proto, request=Req} = UAC,
    UAC1 = cancel_timers([timeout], UAC),
    UAC3 = case Proto of
        udp -> 
            UAC2 = UAC1#trans{
                status = completed, 
                request = undefined, 
                response = undefined,
                to_tags = [ToTag]
            },
            timeout_timer(timer_k, UAC2);
        _ -> 
            UAC1#trans{status=finished}
    end,
    % do_received_auth() send the reply if it is not resent
    do_received_auth(Req, Resp, UAC3, update(UAC3, Call));

do_response_status(completed, Resp, UAC, Call) ->
    #sipmsg{cseq_method=Method, response=Code, to_tag=ToTag} = Resp,
    #trans{id=Id, to_tags=ToTags} = UAC,
    case lists:member(ToTag, ToTags) of
        true ->
            ?call_info("UAC ~p ~p (completed) received ~p retransmission", 
                       [Id, Method, Code], Call),
            Call;
        false ->
            ?call_info("UAC ~p ~p (completed) received new ~p response", 
                       [Id, Method, Code], Call),
            UAC1 = UAC#trans{to_tags=ToTags++[ToTag]},
            update(UAC1, Call)
    end.


%% @private 
-spec do_received_auth(nksip:request(), nksip:response(), trans(), call()) ->
    call().

do_received_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = Id,
        status = Status,
        method = Method, 
        code = Code, 
        iter = Iter,
        from = From
    } = UAC,
    IsFork = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
        andalso Method=/='CANCEL' andalso (not IsFork) andalso
        nksip_auth:make_request(Req, Resp) 
    of
        false ->
            send_user_reply({resp, Resp}, UAC, Call);
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            ?call_debug("UAC ~p ~p (~p) resending authorized request", 
                        [Id, Method, Status], Call),
            {CSeq, Call1} = nksip_call_dialog_uac:new_local_seq(Req, Call),
            Req2 = Req1#sipmsg{
                vias = Vias, 
                cseq = CSeq,
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            {Req4, Call2} = new_sipmsg(Req3, false, Call1),
            NewUAC = make_uac(Req4, From),
            NewUAC1 = NewUAC#trans{iter=Iter+1},
            do_send(Method, NewUAC1, update(NewUAC1, Call2));
        error ->
            ?call_debug("UAC ~p could not generate new auth request", [Id], Call),    
            send_user_reply({resp, Resp}, UAC, Call)
    end.








%% ===================================================================
%% Cancel
%% ===================================================================


%% @doc Used to cancel an ongoing invite request.
%% It will be blocked until a provisional or final response is received
-spec cancel(trans(), call()) ->
    call().

cancel(UAC, Call) ->
    case UAC of
        #trans{
            id = Id,
            class = uac, 
            status = invite_calling, 
            cancel = undefined
        }=UAC ->
            ?call_debug("UAC ~p (invite_calling) delaying CANCEL", [Id], Call),
            UAC1 = UAC#trans{cancel=to_cancel},
            update(UAC1, Call);
        #trans{
            class = uac, 
            status = invite_proceeding, 
            cancel = undefined
        }=UAC ->
            do_cancel(UAC, Call);
        _ ->
            Call
    end.

do_cancel(#trans{id=Id, status=Status, request=Req}=UAC, Call) ->
    ?call_debug("UAC ~p (~p) generating CANCEL", [Id, Status], Call),
    CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
    UAC1 = UAC#trans{cancel=cancelled},
    request(CancelReq, none, update(UAC1, Call)).




%% @odc Used to cancel a forked request
-spec fork_cancel(nksip_call_fork:id(), call()) ->
    call().

fork_cancel(ForkId, #call{trans=Trans}=Call) ->
    fork_cancel(ForkId, Trans, Call).

fork_cancel(_ForkId, [], Call) ->
    Call;

fork_cancel(ForkId, [
            #trans{
                class = uac, 
                from = {fork, ForkId}, 
                status = invite_calling,
                cancel = undefined
            }=UAC | Rest], Call) ->
    UAC1 = UAC#trans{cancel={to_cancel, none, []}},
    fork_cancel(ForkId, Rest, update(UAC1, Call));

fork_cancel(ForkId, [
            #trans{
                class = uac, 
                from = {fork, ForkId}, 
                status = invite_proceeding,
                cancel = undefined,
                request = Req
            }=UAC | Rest], Call) ->
    CancelReq = nksip_uac_lib:make_cancel(Req),
    Call1 = update(UAC#trans{cancel=cancelled}, Call),
    fork_cancel(ForkId, Rest, request(CancelReq, none, Call1));

fork_cancel(ForkId, [_|Rest], Call) ->
    fork_cancel(ForkId, Rest, Call).



%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), trans(), call()) ->
    call().

timer(timeout, #trans{id=Id, method=Method, request=Req}, Call) ->
    ?call_notice("UAC ~p ~p timeout: no final response", [Id, Method], Call),
    Resp = nksip_reply:reply(Req, timeout),
    response(Resp, Call);

% INVITE retrans
timer(timer_a, #trans{id=Id, request=Req, status=Status}=UAC, Call) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting 'INVITE'", [Id, Status], Call),
            UAC1 = retrans_timer(timer_a, UAC),
            update(UAC1, Call);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit 'INVITE'", [Id, Status], Call),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            response(Resp, Call)
    end;

% INVITE timeout
timer(timer_b, #trans{id=Id, request=Req, status=Status}, Call) ->
    ?call_notice("UAC ~p 'INVITE' (~p) timeout (Timer B) fired", [Id, Status], Call),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer B Timeout">>}),
    response(Resp, Call);

% Finished in INVITE completed
timer(timer_d, #trans{id=Id, status=Status}=UAC, Call) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer D fired", [Id, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% INVITE accepted finished
timer(timer_m,  #trans{id=Id, status=Status}=UAC, Call) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer M fired", [Id, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% No INVITE retrans
timer(timer_e, #trans{id=Id, status=Status, method=Method, request=Req}=UAC, Call) ->
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting ~p", [Id, Status, Method], Call),
            UAC1 = retrans_timer(timer_e, UAC),
            update(UAC1, Call);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit ~p", 
                         [Id, Status, Method], Call),
            Resp = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            response(Resp, Call)
    end;

% No INVITE timeout
timer(timer_f, #trans{id=Id, status=Status, method=Method, request=Req}, Call) ->
    ?call_notice("UAC ~p ~p (~p) timeout (Timer F) fired", [Id, Method, Status], Call),
    Resp = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    response(Resp, Call);

% No INVITE completed finished
timer(timer_k,  #trans{id=Id, status=Status, method=Method}=UAC, Call) ->
    ?call_debug("UAC ~p ~p (~p) Timer K fired", [Id, Method, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

timer(expire, #trans{id=Id, status=Status, request=Req}=UAC, Call) ->
    UAC1 = UAC#trans{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer EXPIRE fired, sending CANCEL", 
                        [Id, Status], Call),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=[]}),
            request(CancelReq, none, Call);
        true ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer EXPIRE fired", [Id, Status], Call),
            update(UAC1, Call)
    end.




%% ===================================================================
%% Util
%% ===================================================================

send_user_reply({req, Req}, #trans{from={srv, From}, method='ACK', opts=Opts}, Call) ->
    Fun = nksip_lib:get_value(callback, Opts, fun(_) -> ok end),
    ReqId = nksip_request:id(Req),
    Full = lists:member(full_request, Opts),
    Async = lists:member(async, Opts),
    if
        Async, Full -> catch Fun({req, Req});
        Async -> catch Fun({async, ReqId});
        Full -> gen_server:reply(From, {req, Req});
        true -> gen_server:reply(From, ok)
    end,
    Call;

send_user_reply({req, Req}, #trans{from={srv, _From}, opts=Opts}, Call) ->
    Fun = nksip_lib:get_value(callback, Opts, fun(_) -> ok end),
    ReqId = nksip_request:id(Req),
    case lists:member(full_request, Opts) of
        true -> catch Fun({req, Req});
        false -> catch Fun({req_id, ReqId})
    end,
    Call;


send_user_reply({resp, Resp}, #trans{from={srv, From}, opts=Opts}, Call) ->
    Fun = nksip_lib:get_value(callback, Opts, fun(_) -> ok end),
    #sipmsg{response=Code} = Resp,
    RespId = nksip_response:id(Resp),
    DlgId = nksip_dialog:id(Resp),
    Full = lists:member(full_response, Opts),
    Async = lists:member(async, Opts),
    if
        Code < 101 -> ok;
        Async, Full -> catch Fun({resp, Resp});
        Async -> catch Fun({ok, Code, RespId, DlgId});
        Code < 200, Full -> catch Fun({resp, Resp});
        Code < 200 -> catch Fun({ok, Code, RespId, DlgId});
        Full -> gen_server:reply(From, {resp, Resp});
        true -> gen_server:reply(From, {ok, Code, RespId, DlgId})
    end,
    Call;

send_user_reply({error, Error}, #trans{from={srv, From}, opts=Opts}, Call) ->
    Fun = nksip_lib:get_value(callback, Opts, fun(_) -> ok end),
    case lists:member(async, Opts) of
        true -> catch Fun({error, Error});
        false -> gen_server:reply(From, {error, Error})
    end,
    Call;

send_user_reply({resp, Resp}, #trans{from={fork, ForkId}}, Call) ->
    nksip_call_fork:response(ForkId, Resp, Call);

send_user_reply(_Resp, _UAC, Call) ->
    Call.





%% @private
-spec send_ack(trans()) ->
    ok.

send_ack(#trans{request=Ack, id=Id}) ->
    case nksip_transport_uac:resend_request(Ack) of
        {ok, _} -> 
            ok;
        error -> 
            #sipmsg{app_id=AppId, call_id=CallId} = Ack,
            ?notice(AppId, CallId, "UAC ~p could not send non-2xx ACK", [Id])
    end.


%% @private
-spec transaction_id(nksip:request()) -> 
    integer().

transaction_id(#sipmsg{app_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    erlang:phash2({AppId, CallId, Method, Branch}).


% %% @private
% -spec send_from_reply(uac_from(), {async, nksip:request()}|{error, term()}) ->
%     ok.

% send_from_reply({Pid, Ref}, {async, #sipmsg{id=ReqId, app_id=AppId, call_id=CallId}})
%           when is_pid(Pid), is_reference(Ref) -> 
%     gen_server:reply({Pid, Ref}, {async, {req, AppId, CallId, ReqId}});

% send_from_reply({Pid, Ref}, {error, Error}) when is_pid(Pid), is_reference(Ref) -> 
%     gen_server:reply({Pid, Ref}, {error, Error});

% send_from_reply(_, _) ->
%     ok.




