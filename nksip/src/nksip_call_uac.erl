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

-export([request/3, response/2, cancel/4, fork_cancel/2, make_dialog/5, timer/3]).
-export_type([status/0, id/0]).
-import(nksip_call_lib, [update/2, timeout_timer/2, retrans_timer/2, expire_timer/2,
                         cancel_timers/2]).

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



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new UAC transaction
-spec request(nksip:request(), from()|{fork, nksip_call_fork:id()}|none, call()) ->
    call().

request(#sipmsg{method=Method}=Req, From, Call) ->
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req)
    end,
    case From of 
        {fork, ForkId} -> 
            Forked = "(forked) ";
        _ -> 
            ForkId = undefined,
            Forked = ""
    end,
    {UAC, Call1} = add_request(Req1, ForkId, Call),
    #trans{id=TransId, request=#sipmsg{id=ReqId}} = UAC,
    case From of
        {Pid, Ref} when is_pid(Pid), is_reference(Ref) ->
            #call{app_id=AppId, call_id=CallId} = Call,
            gen_server:reply(From, {ok, {req, AppId, CallId, ReqId}});
        _ ->
            ok
    end,
    ?call_debug("UAC ~p sending ~srequest ~p (~p)", 
                [TransId, Forked, Method, ReqId], Call1),
    do_send(Method, UAC, Call1).


%% @private
-spec add_request(nksip:request(), nksip_call_fork:id()|undefined, call()) ->
    {trans(), call()}.

add_request(Req, ForkId, Call) ->
    #sipmsg{method=Method, ruri=RUri, opts=Opts} = Req, 
    #call{trans=Trans} = Call,
    {Req1, Call1} = nksip_call_lib:add_msg(Req, ForkId=/=undefined, Call),
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
        start = nksip_lib:timestamp(),
        fork_id = ForkId,
        request = Req1,
        method = Method,
        ruri = RUri,
        opts = Opts,
        response = undefined,
        code = 0,
        cancel = undefined,
        iter = 1
    },
    {UAC, Call1#call{trans=[UAC|Trans]}}.


% @private
-spec do_send(nksip:method(), trans(), call()) ->
    call().

do_send('ACK', #trans{id=Id, request=Req}=UAC, Call) ->
    case nksip_transport_uac:send_request(Req) of
       {ok, SentReq} ->
            ?call_debug("UAC ~p sent 'ACK' request", [Id], Call),
            UAC1 = UAC#trans{status=finished, request=SentReq},
            reply_request(UAC1),
            Call1 = nksip_call_lib:update_msg(SentReq, Call),
            Call2 = nksip_call_dialog_uac:ack(UAC1, Call1),
            update(UAC1, Call2);
        error ->
            ?call_debug("UAC ~p error sending 'ACK' request", [Id], Call),
            UAC1 = UAC#trans{status=finished},
            update(UAC1, Call)
    end;

do_send(_, #trans{method=Method, id=Id, request=Req}=UAC, Call) ->
    case nksip_call_dialog_uac:request(UAC, Call) of
        {ok, Call1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req);
                _ -> nksip_transport_uac:send_request(Req)
            end,
            case Send of
                {ok, SentReq} ->
                    #sipmsg{transport=#transport{proto=Proto}} = SentReq,
                    Call2 = nksip_call_lib:update_msg(SentReq, Call1),
                    ?call_debug("UAC ~p sent ~p request", [Id, Method], Call),
                    UAC1 = UAC#trans{request=SentReq, proto=Proto},
                    reply_request(UAC1),
                    UAC2 = timeout_timer(timeout, UAC1),
                    UAC3 = sent_method(Method, UAC2),
                    update(UAC3, Call2);
                error ->
                    ?call_debug("UAC ~p error sending ~p request", 
                                [Id, Method], Call),
                    Reply = nksip_reply:reply(Req, service_unavailable),
                    response(Reply, Call1)
            end;
        {error, finished} ->
            Reply = nksip_reply:reply(Req, no_transaction),
            response(Reply, Call);
        {error, request_pending} ->
            Reply = nksip_reply:reply(Req, request_pending),
            response(Reply, Call)
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
    

%% @doc Called when a new response is received
-spec response(nksip:response(), call()) ->
    call().

response(Resp, #call{trans=Trans, max_trans_time=MaxTime}=Call) ->
    #sipmsg{cseq_method=Method, response=Code} = Resp,
    TransId = transaction_id(Resp),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uac, start=Start, ruri=RUri, fork_id=ForkId}=UAC ->
            Now = nksip_lib:timestamp(),
            Resp1 = case Now-Start < MaxTime of
                true -> Resp;
                false -> nksip_reply:reply(UAC#trans.request, timeout)
            end,
            Resp2 = Resp1#sipmsg{ruri=RUri},
            {Resp3, Call1} = nksip_call_lib:add_msg(Resp2, ForkId=/=undefined, Call),
            UAC1 = UAC#trans{response=Resp3, code=Resp3#sipmsg.response},
            do_response(UAC1, update(UAC1, Call1));
        _ ->
            #sipmsg{vias=[#via{opts=Opts}|ViaR]} = Resp,
            case nksip_lib:get_binary(branch, Opts) of
                <<"z9hG4bK", Branch/binary>> when ViaR =/= [] ->
                    GlobalId = nksip_config:get(global_id),
                    StatelessId = nksip_lib:hash({Branch, GlobalId, stateless}),
                    case nksip_lib:get_binary(nksip, Opts) of
                        StatelessId -> 
                            nksip_call_proxy:response_stateless(Resp, Call);
                        _ ->
                            ?call_notice("UAC ~p received ~p ~p response for "
                                         "unknown request", 
                                         [TransId, Method, Code], Call)
                    end;
                _ ->
                    ?call_notice("UAC ~p received ~p ~p response for "
                                 "unknown request", [TransId, Method, Code], Call)
            end,
            Call
    end.


%% @private
-spec do_response(trans(), call()) ->
    call().

do_response(UAC, Call) ->
    #trans{
        id = Id, 
        fork_id = ForkId,
        method = Method, 
        status = Status, 
        request = Req,
        response = #sipmsg{response=Code, transport=RespTransp} = Resp, 
        iter = Iter,
        cancel = Cancel
    } = UAC,
    case RespTransp of
        undefined -> ok;    % It is own-generated
        _ -> ?call_debug("UAC ~p ~p (~p) received ~p", [Id, Method, Status, Code], Call)
    end,
    Call1 = nksip_call_dialog_uac:response(UAC, Call),
    case do_received_status(Status, Resp, UAC) of
        {UAC1, ToCancel} -> ok;
        UAC1 -> ToCancel = none
    end,
    case Cancel of
        {to_cancel, From, Opts} when ToCancel=:=cancel_ok ->
            UAC2 = UAC1#trans{cancel=cancelled},
            Call2 = reply_response(Resp, UAC2, update(UAC2, Call1)),
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            request(CancelReq, From, Call2);
        {to_cancel, From, _} when ToCancel=:=cancel_final_response ->
            gen_server:reply(From, {error, final_response}),
            reply_response(Resp, UAC1, update(UAC1, Call1));
        _ ->
            Call2 = update(UAC1, Call1),
            case 
                (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
                andalso Method=/='CANCEL' andalso ForkId=:=undefined andalso
                do_received_auth(UAC1, Call2)
            of
                {ok, NewUAC, Call3} -> do_send(Method, NewUAC, Call3);
                _ -> reply_response(Resp, UAC1, Call2)
            end
            
    end.


%% @private 
-spec do_received_auth(trans(), call()) ->
    {ok, trans(), call()} | error.

do_received_auth(#trans{request=Req, response=Resp, status=Status, iter=Iter}, Call) ->
    case nksip_auth:make_request(Req, Resp) of
        {ok, #sipmsg{vias=[_|Vias], opts=Opts}=Req1} ->
            Req2 = Req1#sipmsg{
                vias = Vias, 
                opts = nksip_lib:delete(Opts, make_contact)
            },
            Req3 = nksip_transport_uac:add_via(Req2),
            {NewUAC, Call1} = add_request(Req3, undefined, Call),
            #trans{id=Id, request=#sipmsg{method=Method}} = NewUAC,
            ?call_debug("UAC ~p ~p (~p) resending authorized request", 
                        [Id, Method, Status], Call),
            {ok, NewUAC#trans{iter=Iter+1}, Call1};
        error ->    
            error
    end.


%% @private
-spec do_received_status(status(), nksip:response(), trans()) ->
    trans() | {trans(), cancel_ok} | {trans(), cancel_final_response}.

do_received_status(invite_calling, Resp, UAC) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=invite_proceeding}),
    do_received_status(invite_proceeding, Resp, UAC1);

do_received_status(invite_proceeding, #sipmsg{response=Code}, UAC) when Code < 200 ->
    UAC1 = cancel_timers([timeout], UAC),
    UAC2 = timeout_timer(timeout, UAC1),       % Another 3 minutes
    {UAC2, cancel_ok};

% Final 2xx response received
do_received_status(invite_proceeding, #sipmsg{response=Code, to_tag=ToTag}, UAC) 
                   when Code < 300 ->
    UAC1 = cancel_timers([timeout, expire], UAC),
    % New RFC6026 state, to absorb 2xx retransmissions and forked responses
    UAC2 = UAC1#trans{status=invite_accepted, first_to_tag=ToTag},
    {timeout_timer(timer_m, UAC2), cancel_final_response};

% Final [3456]xx response received, own error response
do_received_status(invite_proceeding, #sipmsg{transport=undefined}, UAC) ->
    UAC1 = cancel_timers([timeout, expire], UAC),
    {UAC1#trans{status=finished}, cancel_final_response};

% Final [3456]xx response received, real response
do_received_status(invite_proceeding, Resp, UAC) ->
    #sipmsg{to=To} = Resp,
    #trans{request=#sipmsg{vias=[Via|_]}=Req, proto=Proto} = UAC,
    UAC1 = cancel_timers([timeout, expire], UAC),
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
    UAC2 = UAC1#trans{request=Ack, response=undefined},
    send_ack(UAC2),
    UAC3 = case Proto of
        udp -> timeout_timer(timer_d, UAC2#trans{status=invite_completed});
        _ -> UAC2#trans{status=finished}
    end,
    {UAC3, cancel_final_response};


do_received_status(invite_accepted, Resp, UAC) -> 
    #sipmsg{app_id=AppId, call_id=CallId, response=Code, to_tag=ToTag} = Resp,
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
    #sipmsg{app_id=AppId, call_id=CallId, response=Code} = Resp,
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
            timeout_timer(timer_k, UAC2);
        _ -> 
            UAC1#trans{status=finished}
    end;

do_received_status(completed, Resp, UAC) ->
    #sipmsg{app_id=AppId, call_id=CallId, cseq_method=Method, response=Code} = Resp,
    #trans{id=Id} = UAC,
    ?info(AppId, CallId, "UAC ~p ~p (completed) received ~p retransmission", 
          [Id, Method, Code]),
    UAC.


%% @doc Used to cancel an ongoing invite request.
%% It will be blocked until a provisional or final response is received
-spec cancel(trans(), nksip_lib:proplist(), from(), call()) ->
    call().

cancel(UAC, Opts, From, Call) ->
    case UAC of
        #trans{class=uac, status=invite_calling, cancel=undefined}=UAC ->
            UAC1 = UAC#trans{cancel={to_cancel, From, Opts}},
            update(UAC1, Call);
        #trans{class=uac, status=invite_proceeding, cancel=undefined, request=Req}=UAC ->
            CancelReq = nksip_uac_lib:make_cancel(Req#sipmsg{opts=Opts}),
            UAC1 = UAC#trans{cancel=cancelled},
            request(CancelReq, From, update(UAC1, Call));
        _ ->
            gen_server:reply(From, {error, invalid_request}),
            Call
    end.


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
                fork_id = ForkId, 
                status = invite_calling,
                cancel = undefined
            }=UAC | Rest], Call) ->
    UAC1 = UAC#trans{cancel={to_cancel, none, []}},
    fork_cancel(ForkId, Rest, update(UAC1, Call));

fork_cancel(ForkId, [
            #trans{
                class = uac, 
                fork_id = ForkId, 
                status = invite_proceeding,
                cancel = undefined,
                request = Req
            }=UAC | Rest], Call) ->
    CancelReq = nksip_uac_lib:make_cancel(Req),
    Call1 = update(UAC#trans{cancel=cancelled}, Call),
    fork_cancel(ForkId, Rest, request(CancelReq, none, Call1));

fork_cancel(ForkId, [_|Rest], Call) ->
    fork_cancel(ForkId, Rest, Call).


%% @doc Generates a new in-dialog request
-spec make_dialog(nksip_dialog:id(), nksip:method(), nksip_lib:proplist(), 
                  from(), call()) ->
    call().

make_dialog(DialogId, Method, Opts, From, Call) ->
    case nksip_call_dialog_uac:make(DialogId, Method, Opts, Call) of
        {ok, Result, Call1} ->
            gen_server:reply(From, {ok, Result}),
            Call1;
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            Call
    end.







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

%% @private
-spec reply_request(trans()) ->
    ok.

reply_request(#trans{request=Req, method=Method, opts=Opts}) ->
    Fun = nksip_lib:get_value(respfun, Opts),
    case lists:member(full_request, Opts) of
        true when Method=:='ACK', is_function(Fun, 1) -> catch Fun({ok, Req});
        false when Method=:='ACK', is_function(Fun, 1) -> catch Fun(ok);
        true when is_function(Fun, 1) -> catch Fun({request, Req});
        false -> ok
    end,
    ok.


%% @private
-spec reply_response(nksip:response(), trans(), call()) ->
    call().

reply_response(Resp, #trans{fork_id=undefined, method=Method, opts=Opts}, Call) ->
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
    end,
    Call;

reply_response(Resp, #trans{fork_id=ForkId}, Call) ->
    nksip_call_fork:response(ForkId, Resp, Call).


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



