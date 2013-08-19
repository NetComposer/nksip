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

%% @doc UAS Transaction FSM.
-module(nksip_call_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/2, timer/3, sipapp_reply/4]).
-export_type([status/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(INVITE_TIMEOUT, (1000*nksip_config:get(ringing_timeout))).
-define(NOINVITE_TIMEOUT, 60000).
-define(CANCEL_TIMEOUT, 60000).


-type status() ::  authorize | route | cancel |
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed.


%% ===================================================================
%% Private
%% ===================================================================


request(#sipmsg{method=Method}=Req, #call{blocked=Blocked, msg_queue=MsgQueue}=SD) -> 
    case is_trans_ack(Req, SD) of
        {true, UAS} -> 
            process_trans_ack(UAS, SD);
        false ->
            case is_retrans(Req, SD) of
                {true, UAS} ->
                    process_retrans(UAS, SD);
                {false, TransId} 
                    when Blocked 
                    andalso (Method=:='INVITE' orelse Method=:='BYE') ->
                    MsgQueue1 = queue:in({TransId, Req}, MsgQueue),
                    next(SD#call{msg_queue=MsgQueue1});
                {false, TransId} ->
                    do_request(TransId, Req, SD)
            end
    end.

%% @doc Checks if `Request' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(Request::nksip:request(), #call{}) ->
    boolean().

is_trans_ack(#sipmsg{method='ACK'}=Request, #call{uass=UASs}) ->
    TransId = transaction_id(Request#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #uas.trans_id, UASs) of
        #uas{} = UAS ->
            {true, UAS};
        false ->
            case TransId of
                <<"old_", _/binary>> ->
                    % CHECK OLD STYLE
                    false;
                _ ->
                    false
            end
    end;
is_trans_ack(_, _) ->
    false.


process_trans_ack(#uas{status=Status, request=Req}=UAS, SD) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    case Status of
        invite_completed ->
            UAS1 = cancel_timers([retrans, timeout], UAS),
            case Proto of 
                udp -> 
                    T4 = nksip_config:get(timer_t4), 
                    UAS2 = UAS1#uas{
                        status = invite_confirmed,
                        timeout_timer = start_timer(T4, timer_i, UAS1)
                    };
                _ ->
                    UAS2 = remove(UAS1)
            end,
            next(update(UAS2, SD));
        _ ->
            ?call_notice("UAS received ACK in ~p", [Status], SD),
            next(SD)
    end.

is_retrans(Req, #call{uass=Trans}) ->
    TransId = transaction_id(Req),
    case lists:keyfind(TransId, #uas.trans_id, Trans) of
        false -> {false, TransId};
        UAS -> {true, UAS}    
    end.


process_retrans(#uas{status=Status, request=Req, responses=Resps}, SD) ->
    #sipmsg{method=Method} = Req,
    case 
        Status=:=invite_proceeding orelse Status=:=invite_completed
        orelse Status=:=proceeding orelse Status=:=completed
    of
        true ->
            case Resps of
                [#sipmsg{response=Code}=Resp|_] ->
                    case nksip_transport_uas:resend_response(Resp) of
                        {ok, _} -> 
                            ?call_info("UAS retransmitting ~p ~p response in ~p", 
                                       [Method, Code, Status], SD);
                        error ->
                            ?call_notice("UAS could not retransmit ~p ~p response in ~p", 
                                         [Method, Code, Status], SD)
                    end;
                _ ->
                    ?call_info("UAS received ~p retransmission in ~p", 
                               [Method, Status], SD)
            end;
        false ->
            ?call_info("UAS received ~p retransmission in ~p", 
                       [Method, Status], SD)
    end,
    next(SD).


sipapp_reply(Fun, Id, Reply, #call{uass=UASs}=SD) ->
    case lists:keyfind(Id, #uas.trans_id, UASs) of
        #uas{status=Status}=UAS ->
            case Fun of
                _ when Status=:=removed ->
                    ?call_info("CALL received reply for removed request", [], SD),
                    next(SD);
                authorize when Status=:=authorize -> 
                    authorize({reply, Reply}, UAS, SD);
                route when Status=:=route -> 
                    route({reply, Reply}, UAS, SD);
                cancel when Status=:=cancel ->
                    cancel({reply, Reply}, UAS, SD);
                process ->
                    process({reply, Reply}, UAS, SD);
                _ ->
                    ?call_warning("CALL (~p) received unexpected app reply ~p, ~p, ~p",
                                  [Status, Fun, Id, Reply], SD),
                    next(SD)

            end;
        false ->
            ?call_warning("CALL received unexpected app reply ~p, ~p, ~p",
                          [Fun, Id, Reply], SD),
            next(SD)
    end.



%% ===================================================================
%% Request cycle
%% ===================================================================


do_request(TransId, Req, SD) ->
    #call{app_opts=Opts, uass=UASs, next=Next, sipmsgs=SipMsgs} = SD,
    case nksip_uas_lib:preprocess(Req#sipmsg{id=Next}) of
        {ok, #sipmsg{start=Start, method=Method}=Req1} -> 
            LoopId = loop_id(Req1),
            UAS1 = #uas{
                trans_id = TransId, 
                request = Req1, 
                loop_id = LoopId,
                cancelled = false
            },
            Timeout = case Method of
               'INVITE' -> ?INVITE_TIMEOUT;
                _ -> ?NOINVITE_TIMEOUT
            end,
            S100Timer = case lists:member(no_100, Opts) of 
                false when Method=/='ACK' ->
                    Elapsed = round((nksip_lib:l_timestamp()-Start)/1000),
                    S100 = max(0, 100 - Elapsed),
                    start_timer(S100, send_100, UAS1);
                _ ->
                    undefined
            end,
            UAS2 = #uas{
                s100_timer = S100Timer,
                timeout_timer = start_timer(Timeout, timeout, UAS1)
            },
            SipMsgs1 = [{Next, uas, TransId}|SipMsgs],
            SD1 = SD#call{uass=[UAS2|UASs], sipmsgs=SipMsgs1, next=Next+1},
            case lists:keyfind(LoopId, #uas.loop_id, UASs) of
                true -> reply(loop_detected, UAS2, SD1);
                false -> authorize(launch, UAS2, SD1)
            end;
        ignore -> 
            % It is an own-generated ACK without transaction
            next(SD)
    end.


authorize(launch, #uas{request=Req}=UAS, SD) ->
    Auth = nksip_auth:get_authentication(Req),
    app_call(authorize, [Auth], UAS, SD),
    next(update(UAS#uas{status=authorize}, SD));

authorize({reply, Reply}, UAS, SD) ->
    trace(authorize_reply, SD),
    case Reply of
        ok -> route(launch, UAS, SD);
        true -> route(launch, UAS, SD);
        false -> reply(forbidden, UAS, SD);
        authenticate -> reply(authenticate, UAS, SD);
        {authenticate, Realm} -> reply({authenticate, Realm}, UAS, SD);
        proxy_authenticate -> reply(proxy_authenticate, UAS, SD);
        {proxy_authenticate, Realm} -> reply({proxy_authenticate, Realm}, UAS, SD);
        Other -> reply(Other, UAS, SD)
    end.


%% @private
-spec route(launch | timeout | {reply, term()} | 
            {response, nksip:sipreply(), nksip_lib:proplist()} |
            {process, nksip_lib:proplist()} |
            {proxy, nksip:uri_set(), nksip_lib:proplist()} |
            {strict_proxy, nksip_lib:proplist()}, #uas{}, #call{}) -> term().

route(launch, #uas{request=Req}=UAS, SD) ->
    trace(route, SD),
    #sipmsg{ruri=#uri{scheme=Scheme, user=User, domain=Domain}} = Req,
    app_call(route, [Scheme, User, Domain], UAS, SD),
    next(update(UAS#uas{status=route}, SD));

route({reply, Reply}, #uas{request=Req}=UAS, SD) ->
    trace(route_reply, SD),
    #sipmsg{method=Method, ruri=RUri} = Req,
    Route = case Reply of
        {response, Resp} -> {response, Resp, []};
        {response, Resp, Opts} -> {response, Resp, Opts};
        process -> {process, []};
        {process, Opts} -> {process, Opts};
        proxy -> {proxy, RUri, []};
        {proxy, Uris} -> {proxy, Uris, []}; 
        {proxy, ruri, Opts} -> {proxy, RUri, Opts};
        {proxy, Uris, Opts} -> {proxy, Uris, Opts};
        strict_proxy -> {strict_proxy, []};
        {strict_proxy, Opts} -> {strict_proxy, Opts};
        Resp -> {response, Resp, [stateless]}
    end,
    Status = case Method of
        'INVITE' -> invite_proceeding;
        _ -> trying
    end,
    SD1 = update(UAS#uas{status=Status}, SD),
    ?call_debug("UAS ~p route: ~p", [Method, Route], SD1),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_parse:header_tokens(<<"Require">>, Req) of
                [] -> 
                    do_route(Route, UAS, SD1);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, UAS, SD1)
            end;
        _ ->
            do_route(Route, UAS, SD1)
    end.

do_route({response, Reply, Opts}, #uas{request=Req}=UAS, SD) ->
    #sipmsg{method=Method, opts=ReqOpts} = Req,
    Status = case Method of
        'INVIE' -> invite_proceeding;
        _ -> trying
    end,
    UAS1 = UAS#uas{status=Status, request=Req#sipmsg{opts=Opts++ReqOpts}},
    reply(Reply, UAS1, update(UAS1, SD));

do_route({process, Opts}, #uas{request=Req}=UAS, SD) ->
    #sipmsg{headers=Headers, opts=ReqOpts} = Req,
    Req1 = case nksip_lib:get_value(headers, Opts, []) of
        [] ->  Req#sipmsg{opts=Opts++ReqOpts};
        Headers1 -> Req#sipmsg{headers=Headers1++Headers, opts=Opts++ReqOpts}
    end,
    UAS1 = UAS#uas{request=Req1},
    process(launch, UAS1, update(UAS1, SD));

% We want to proxy the request
do_route({proxy, UriList, Opts}, UAS, SD) ->
    nksip_call_proxy:start(UriList, Opts, UAS, SD);

% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
do_route({strict_proxy, Opts}, #uas{request=Req}=UAS, SD) ->
    case Req#sipmsg.routes of
        [Next|_] ->
            ?call_info("strict routing to ~p", [Next], SD),
            do_route({proxy, Next, [stateless|Opts]}, UAS, SD);
        _ ->
            reply({internal_error, <<"Invalid Srict Routing">>}, UAS, SD)
    end.

process(launch,  #uas{request=Req}=UAS, SD) ->
    #sipmsg{method=Method} = Req,
    case nksip_call_dialog_uas:request(Req, SD) of
        {ok, DialogId, SD1} -> 
            trace({launch_dialog, Method}, SD1),
            do_process_dialog(Method, DialogId, UAS, SD1);
        nodialog -> 
            trace(launch_no_dialog, SD),
            do_process_nodialog(Method, UAS, SD);
        {error, Error} ->
            ?call_notice("UAS ~p dialog request error ~p", [Method, Error], SD),
            Reply = case Error of
                proceeding_uac ->
                    request_pending;
                proceeding_uas -> 
                    {500, [{<<"Retry-After">>, crypto:rand_uniform(0, 11)}], 
                                <<>>, [{reason, <<"Processing Previous INVITE">>}]};
                old_cseq ->
                    {internal_error, <<"Old CSeq in Dialog">>};
                _ ->
                    no_transaction
            end,
            reply(Reply, UAS, SD)
    end;

process({reply, Reply}, UAS, SD) ->
    reply(Reply, UAS, SD).


do_process_dialog('INVITE', DialogId, UAS, SD) ->
    #uas{request=Req, cancelled=Cancelled} = UAS,
    app_call(invite, [DialogId], UAS, SD),
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            start_timer(1000*Expires+100, expire, UAS);
        _ ->
            undefined
    end,
    UAS1 = UAS#uas{expire_timer=ExpireTimer},
    SD1 = update(UAS1, SD#call{blocked=true}),
    case Cancelled of
        true -> cancel(launch, UAS1, SD1);
        false -> next(SD1)
    end;

do_process_dialog('ACK', DialogId, UAS, SD) ->
    app_cast(ack, [DialogId], UAS, SD),
    next(SD#call{blocked=false});

do_process_dialog('BYE', DialogId, UAS, SD) ->
    app_call(bye, [DialogId], UAS, SD),
    next(SD);

do_process_dialog('OPTIONS', _DialogId, UAS, SD) ->
    app_call(options, [], UAS, SD),
    next(SD);

do_process_dialog('REGISTER', _DialogId, UAS, SD) ->
    app_call(register, [], UAS, SD),
    next(SD);

do_process_dialog(_, _DialogId, UAS, #call{app_id=AppId}=SD) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, UAS, SD).


do_process_nodialog('CANCEL',  #uas{request=Req}=UAS, SD) ->
    case is_cancel(Req, SD) of
        {true, InvUAS} ->
            SD1 = send_reply(ok, UAS, SD),
            case InvUAS of
                #uas{status=process} ->
                    cancel(launch, InvUAS, update(InvUAS, SD1));
                _ ->
                    InvUAS1 = InvUAS#uas{cancelled=true},
                    next(update(InvUAS1, SD))
            end;
        false ->
            reply(no_transaction, UAS, SD)
    end;

do_process_nodialog('ACK', _UAS, SD) ->
    ?notice("received out-of-dialog ACK", [], SD),
    next(SD);

do_process_nodialog('BYE', UAS, SD) ->
    reply(no_transaction, UAS, SD);

do_process_nodialog('OPTIONS', UAS, SD) ->
    app_call(options, [], UAS, SD),
    next(SD);

do_process_nodialog('REGISTER', UAS, SD) ->
    app_call(register, [], UAS, SD),
    next(SD);

do_process_nodialog(_, UAS, #call{app_id=AppId}=SD) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, UAS, SD).
        

cancel(launch, UAS, SD) ->
    app_call(cancel, [], UAS, SD),
    next(update(UAS#uas{status=cancel}, SD));

cancel({reply, Reply}, UAS, SD) ->
    case Reply of
        true -> 
            reply(request_terminated, UAS, SD);
        false -> 
            next(update(UAS#uas{status=process}, SD))
    end.


is_cancel(#sipmsg{method='CANCEL'}=CancelReq, #call{uass=UASs}=SD) -> 
    TransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #uas.trans_id, UASs) of
        #uas{request=InvReq} = InvUAS ->
            #sipmsg{transport=CancelTransp} = CancelReq,
            #sipmsg{transport=InvTransp} = InvReq, 
            #transport{remote_ip=CancelIp, remote_port=CancelPort} = CancelTransp,
            #transport{remote_ip=InvIp, remote_port=InvPort} = InvTransp,
            if
                CancelIp=:=InvIp, CancelPort=:=InvPort ->
                    {true, InvUAS};
                true ->
                    ?call_notice("UAS Trans rejecting CANCEL because came from ~p:~p, "
                                 "request came from ~p:~p", 
                                 [CancelIp, CancelPort, InvIp, InvPort], SD),
                    false
            end;
        false ->
            ?call_debug("received unknown CANCEL", [], SD),
            false
    end;
is_cancel(_, _) ->
    false.



%% ===================================================================
%% Reply
%% ===================================================================


reply(Reply, UAS, SD) ->
    next(send_reply(Reply, UAS, SD)).

send_reply(#sipmsg{response=Code}=Resp, UAS, #call{sipmsgs=SipMsgs, next=Next}=SD) ->
    #uas{
        trans_id = TransId, 
        status = Status, 
        request = #sipmsg{method=Method} = Req,
        responses = Resps
    } = UAS,
    case 
        Status=:=invite_proceeding orelse Status=:=trying 
        orelse Status=:=proceeding
    of
        true ->
            UAS1 = cancel_timers([s100], UAS),
            case nksip_transport_uas:send_response(Resp) of
                {ok, Resp1} -> ok;
                error -> Resp1 = nksip_reply:reply(Req, 503)
            end,
            #sipmsg{response=Code1} = Resp2 = Resp1#sipmsg{id=Next},
            UAS2 = UAS1#uas{responses=[Resp2|Resps]},
            SD1 = nksip_call_dialog_uas:response(Req, Resp1, SD),
            SipMsgs1 = [{Next, uas, TransId}|SipMsgs],
            SD2 = SD1#call{sipmsgs=SipMsgs1, next=Next+1},
            SD3 = case do_reply(Method, Code1, UAS2) of
                {blocked, UAS3} -> update(UAS3, SD2#call{blocked=true});
                UAS3 -> update(UAS3, SD2#call{blocked=false})
            end,
            next(SD3);
        false ->
            ?call_warning("UAS cannot send ~p response in ~p", 
                          [Code, Status], SD),
            next(SD)
    end;

send_reply(UserReply, #uas{request=Req}=UAS, SD) ->
    send_reply(nksip_reply:reply(Req, UserReply), UAS, SD).



do_reply('INVITE', Code, UAS) when Code < 200 ->
    UAS;

do_reply('INVITE', Code, #uas{trans_id=Id, request=Req}=UAS) when Code < 300 ->
    case Id of
        <<"old_", _/binary>> ->
            % In old-style transactions, save TransId to be used in
            % detecting ACKs
            ToTag = nksip_lib:get_binary(to_tag, Req#sipmsg.opts),
            TransId1 = transaction_id(Req#sipmsg{to_tag=ToTag}),
            nksip_proc:put({nksip_call_uas_ack, TransId1});
        _ ->
            ok
    end,
    UAS1 = cancel_timers([timeout], UAS),
    T1 = nksip_config:get(timer_t1),
    UAS2 = UAS1#uas{
        status = invite_accepted,
        timeout_timer = start_timer(64*T1, timer_l, UAS)
    },
    {blocked, UAS2};

do_reply('INVITE', Code, #uas{request=Req}=UAS) when Code >= 300 ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAS1 = cancel_timers([timeout], UAS),
    T1 = nksip_config:get(timer_t1),
    case Proto of 
        udp ->
            UAS1#uas{
                status = invite_completed,
                retrans_timer = start_timer(T1, timer_g, UAS), 
                next_retrans = 2*T1,
                timeout_timer = start_timer(64*T1, timer_h, UAS)
            };
        _ ->
            UAS1#uas{
                status = invite_completed,
                timeout_timer = start_timer(64*T1, timer_h, UAS)
            }
    end;

do_reply(_, Code, UAS) when Code < 200 ->
    UAS#uas{status=proceeding};

do_reply(_, Code, #uas{request=Req}=UAS) when Code >= 200 ->
    #sipmsg{transport=#transport{proto=Proto}, opts=Opts} = Req,
    UAS1 = cancel_timers([timeout], UAS),
    case lists:member(stateless, Opts) of
        true ->
            remove(UAS1);
        false ->
            case Proto of
                udp ->
                    T1 = nksip_config:get(timer_t1),
                    UAS1#uas{
                        status = completed, 
                        timeout_timer = start_timer(64*T1, timer_j, UAS)
                    };
                _ ->
                    remove(UAS1)
            end
    end.


%% ===================================================================
%% Timers
%% ===================================================================

%% @private
timer(remove, #uas{trans_id=TransId}, #call{uacs=UASs}=SD) ->
    UASs1 = lists:keydelete(TransId, #uas.trans_id, UASs),
    next(SD#call{uacs=UASs1});
    
timer(send_100, UAS, SD) ->
    case UAS of
        #uas{responses=[]} -> reply(100, UAS, update(UAS, SD));
        _ -> next(SD)
    end;

timer(timeout, #uas{status=Status, request=Req}=UAS, SD) ->
    case 
        lists:member(Status, [authorize, route, process, invite_proceeding, 
                              trying, proceeding])
    of
        true ->
            #sipmsg{method=Method} = Req,
            ?call_warning("UAS ~p timeout in ~p", [Method, Status], SD),
            reply(timeout, UAS, update(UAS, SD));
        false ->
            next(SD)
    end;

% INVITE completed retrans
timer(timer_g, UAS, SD) ->
    #uas{responses=[Resp|_], next_retrans=Next} = UAS,
    #sipmsg{response=Code, cseq_method=Method} = Resp,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?call_info("UAS retransmitting 'INVITE' ~p response in completed",
                  [Code], SD),
            T2 = nksip_config:get(timer_t2),
            UAS1 = UAS#uas{
                retrans_timer = start_timer(Next, timer_g, UAS),
                next_retrans = min(2*Next, T2)
            },
            next(update(UAS1, SD));
        error ->
            ?call_notice("UAS could not retransmit 'INVITE' ~p response in completed",
                         [Method, Code], SD),
            next(update(remove(UAS), SD))
    end;

% INVITE completed timeout
timer(timer_h, UAS, SD) ->
    ?call_notice("UAS Trans did not receive 'ACK' in completed", [], SD),
    next(update(remove(UAS), SD));

% ACK normal timeout
timer(timer_i, UAS, SD) ->
    timer(remove, UAS, SD);

% NoINVITE completed normal timeout
timer(timer_j, UAS, SD) ->
    timer(remove, UAS, SD);

% INVITE accepted timeout
timer(timer_l, UAS, SD) ->
    ?call_notice("UAS 'INVITE' accepted timer_l timeout", [], SD),
    next(update(remove(UAS), SD));

timer(expire, UAS, SD) ->
    case UAS of
        #uas{status=invite_proceeding} ->
            nksip_call_uas:process(cancel, update(UAS, SD));
        _ ->
            next(SD)
    end.




%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), #uas{}, #call{}) ->
    ok.

app_call(Fun, Args, UAS, #call{app_id=AppId, call_id=CallId}) ->
    #uas{request=#sipmsg{id=Id}} = UAS,
    ReqId = {req, AppId, CallId, Id},
    From = {'fun', nksip_call, sipapp_reply, [AppId, CallId, Fun, Id]},
    nksip_sipapp_srv:sipapp_call_async(AppId, Fun, Args++[ReqId], From).


%% @private
-spec app_cast(atom(), list(), #uas{}, #call{}) ->
    ok.

app_cast(Fun, Args, UAS, #call{app_id=AppId, call_id=CallId}) ->
    #uas{request=#sipmsg{id=Id}} = UAS,
    ReqId = {req, AppId, CallId, Id},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, Args++[ReqId]).


remove(UAS) ->
    UAS1 = cancel_timers([s100, timeout, retrans, expire], UAS),
    UAS1#uac{
        status = removed,
        timeout_timer = start_timer(?CALL_FINISH_TIMEOUT, remove, UAS)
    }.

update(#uas{trans_id=TransId}=UAS, #call{uass=[#uas{trans_id=TransId}|Rest]}=SD) ->
    SD#call{uass=[UAS|Rest]};

update(#uas{trans_id=TransId}=UAS, #call{uass=UASs}=SD) ->
    Rest = lists:keydelete(TransId, #uas.trans_id, UASs),
    SD#call{uass=[UAS|Rest]}.



-spec transaction_id(nksip:request()) ->
    binary().
    
transaction_id(Req) ->
        #sipmsg{
            sipapp_id = AppId, 
            ruri = RUri, 
            method = Method,
            from_tag = FromTag, 
            to_tag = ToTag, 
            vias = [Via|_], 
            call_id = CallId, 
            cseq = CSeq
        } = Req,
    {_Transp, ViaIp, ViaPort} = nksip_parse:transport(Via),
    case nksip_lib:get_value(branch, Via#via.opts) of
        <<"z9hG4bK", Branch/binary>> ->
            nksip_lib:lhash({AppId, Method, ViaIp, ViaPort, Branch});
        _ ->
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            Hash = nksip_lib:lhash({AppId, UriIp, UriPort, FromTag, ToTag, CallId, CSeq, 
                                    Method, ViaIp, ViaPort}),
            <<"old_", Hash/binary>>
    end.

-spec loop_id(nksip:request()) ->
    binary().
    
loop_id(Req) ->
    #sipmsg{
        sipapp_id = AppId, 
        from_tag = FromTag, 
        call_id = CallId, 
        cseq = CSeq, 
        cseq_method = CSeqMethod
    } = Req,
    nksip_lib:lhash({AppId, FromTag, CallId, CSeq, CSeqMethod}).


next(SD) ->
    nksip_call_srv:next(SD).



start_timer(Time, Tag, #uas{trans_id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {uas, Tag, Id})}.

cancel_timers([s100|Rest], #uas{s100_timer=OldTimer}=UAS) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAS#uas{s100_timer=undefined});

cancel_timers([timeout|Rest], #uas{timeout_timer=OldTimer}=UAS) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAS#uas{timeout_timer=undefined});

cancel_timers([retrans|Rest], #uas{retrans_timer=OldTimer}=UAS) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAS#uas{retrans_timer=undefined});

cancel_timers([expire|Rest], #uas{expire_timer=OldTimer}=UAS) ->
    cancel_timer(OldTimer),
    cancel_timers(Rest, UAS#uas{expire_timer=undefined});

cancel_timers([], UAS) ->
    UAS.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.

trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).










