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

-export([request/2, timer/2, timer_dialog/2]).
-export_type([call_status/0, trans_status/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(INVITE_TIMEOUT, (1000*nksip_config:get(ringing_timeout))).
-define(NOINVITE_TIMEOUT, 60000).
-define(CANCEL_TIMEOUT, 60000).


-type call_status() :: authorize | route | process | cancel.

-type trans_status() :: invite_proceeding | invite_accepted | invite_completed | 
                        invite_confirmed | 
                        trying | proceeding | completed.


%% ===================================================================
%% Private
%% ===================================================================


request(#sipmsg{method=Method}=Req, #call{blocked=Blocked, msg_queue=MsgQueue}=SD) -> 
    case is_trans_ack(Req, SD) of
        {true, AckTransId} -> 
            process_trans_ack(AckTransId, SD);
        false ->
            case is_retrans(Req, SD) of
                {true, UAS} ->
                    process_retrans(UAS, SD);
                {false, TransId} 
                    when Blocked 
                    andalso (Method=:='INVITE' orelse Method=:='BYE') ->
                    MsgQueue1 = queue:in({TransId, Req}, MsgQueue),
                    {noreply, SD#call{msg_queue=MsgQueue1}};
                {false, TransId} ->
                    start(TransId, Req, SD)
            end
    end.


%% @private
timer(send_100, #call{uass=[UAS|Rest]}=SD) ->
    case UAS of
        #uas{request=Req, response=undefined}=UAS ->
            case nksip_transport_uas:send_response(Req, 100) of
                {ok, Resp} -> 
                    UAS1 = UAS#uas{response=Resp},
                    {noreply, SD#call{uass=[UAS1|Rest]}};
                error ->
                    ?notice(Req, "UAS could not send 100 response", []),
                    {noreply, SD}
            end;
        _ ->
            {noreply, SD}
    end;

timer(uas_timeout, #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]}=SD) ->
    case UAS of
        #uas{trans_status=TransStatus, request=#sipmsg{method=Method}}
            when TransStatus=:=invite_proceeding; TransStatus=:=trying;
                 TransStatus=:=proceeding ->
            ?warning(AppId, CallId, "UAS ~p didn't receive any answer in ~p", 
                     [Method, TransStatus]),
            SD1 = SD#call{uass=[UAS|Rest]},
            nksip_call_uas:reply(timeout, SD1);
        _ ->
            {noreply, SD}
    end;

timer(timer_g, #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]}=SD) ->
    #uas{
        pos = Pos, 
        response = #sipmsg{response=Code, cseq_method=Method}=Resp,
        next_retrans = Next
    } = UAS,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?info(AppId, CallId, "UAS retransmitting ~p ~p response in completed",
                  [Method, Code]),
            T2 = nksip_config:get(timer_t2),
            UAS1 = UAS#uas{
                retrans_timer = start_timer(Next, timer_g, Pos),
                next_retrans = min(2*Next, T2)
            },
            next(SD#call{uass=[UAS1|Rest]});
        error ->
            ?notice(AppId, CallId, "UAS could not retransmit ~p ~p response in completed",
                    [Method, Code]),
            next(SD#call{uass=Rest})
    end;

timer(timer_h, #call{app_id=AppId, call_id=CallId, uass=[_|Rest]}=SD) ->
    ?notice(AppId, CallId, "UAS Trans did not receive ACK in completed", []),
    next(SD#call{uass=Rest});

timer(timer_i, #call{uass=[_|Rest]}=SD) ->
    next(SD#call{uass=Rest});

timer(timer_j, #call{uass=[_|Rest]}=SD) ->
    next(SD#call{uass=Rest});

timer(timer_l, #call{app_id=AppId, call_id=CallId, uass=[_|Rest]}=SD) ->
    ?notice(AppId, CallId, "UAS did not receive ACK in accepted", []),
    SD1 = nksip_call_uas_dialog:ack_timeout(SD),
    next(SD1#call{blocked=false, uass=Rest});

timer(expire, #call{uass=[UAS|Rest]}=SD) ->
    case UAS of
        #uas{trans_status=invite_proceeding} ->
            nksip_call_uas:process(cancel, SD#call{uass=[UAS|Rest]});
        _ ->
            {noreply, SD}
    end.

timer_dialog(ack_timeout, #call{dialogs=[Dialog|Rest]}=SD) ->
    nksip_dialog_lib:status_update({stop, ack_timeout}, Dialog),
    {noreply, SD#call{dialogs=Rest}};

timer_dialog(timeout, #call{dialogs=[Dialog|Rest]}=SD) ->
    nksip_dialog_lib:status_update({stop, timeout}, Dialog),
    {noreply, SD#call{dialogs=Rest}}.






%% ===================================================================
%% Internal
%% ===================================================================

process_trans_ack(TransId, #call{app_id=AppId, call_id=CallId, uass=Trans}=SD) ->
    {value, UAS, Rest} = lists:keytake(TransId, #uas.id, Trans),
    #uas{
        pos = Pos, 
        trans_status = TransStatus, 
        request = #sipmsg{transport=#transport{proto=Proto}}, 
        retrans_timer = TimerG, 
        timeout_timer = TimerH
    } = UAS,
    case TransStatus of
        invite_completed ->
            nksip_lib:cancel_timer(TimerG),
            nksip_lib:cancel_timer(TimerH),
            case Proto of 
                udp -> 
                    T4 = nksip_config:get(timer_t4), 
                    UAS1 = UAS#uas{
                        trans_status = invite_confirmed,
                        timeout_timer = start_timer(T4, timer_i, Pos)
                    },
                    next(SD#call{uass=[UAS1|Rest]});
                _ ->
                    next(SD#call{uass=Rest})
            end;
        _ ->
            ?notice(AppId, CallId, "UAS received ACK in ~p", [TransStatus]),
            {noreply, SD}
    end.


process_retrans(UAS, #call{app_id=AppId, call_id=CallId}=SD) ->
    #uas{trans_status=TransStatus, request=#sipmsg{method=Method}, 
               response=Resp} = UAS,
    case 
        TransStatus=:=invite_proceeding orelse TransStatus=:=invite_completed
        orelse TransStatus=:=proceeding orelse TransStatus=:=completed
    of
        true ->
            case Resp of
                #sipmsg{response=Code} ->
                    case nksip_transport_uas:resend_response(Resp) of
                        {ok, _} -> 
                            ?info(AppId, CallId, 
                                  "UAS retransmitting ~p ~p response in ~p", 
                                  [Method, Code, TransStatus]);
                        error ->
                            ?notice(AppId, CallId, 
                                    "UAS could not retransmit ~p ~p response in ~p", 
                                    [Method, Code, TransStatus])
                    end;
                _ ->
                    ?info(AppId, CallId, "UAS received ~p retransmission in ~p", 
                          [Method, TransStatus]),
                    ok
            end;
        _ ->
            false
    end,
    {noreply, SD}.


start(Id, Req, #call{app_opts=Opts, uass=Trans}=SD) ->
    case nksip_uas_lib:preprocess(Req) of
        {ok, #sipmsg{start=Start, method=Method}=Req1} -> 
            {TransStatus, Timeout} = case Method of
               'INVITE' -> {invite_proceeding, ?INVITE_TIMEOUT};
                _ -> {trying, ?NOINVITE_TIMEOUT}
            end,
            TimeoutTimer = start_timer(Timeout, uas_timeout, Id),
            S100Timer = case lists:member(no_100, Opts) of 
                false when Method=/='ACK' ->
                    Elapsed = round((nksip_lib:l_timestamp()-Start)/1000),
                    S100 = max(0, 100 - Elapsed),
                    start_timer(S100, send_100, Id);
                _ ->
                    undefined
            end,
            LoopId = loop_id(Req1),
            UAS = #uas{
                id = Id, 
                trans_status = TransStatus,
                request = Req1, 
                loop_id = LoopId,
                s100_timer = S100Timer,
                timeout_timer = TimeoutTimer,
                cancelled = false
            },
            SD1 = SD#call{uass=[UAS|Trans]},
            case lists:keyfind(LoopId, #uas.loop_id, Trans) of
                true -> reply(loop_detected, SD1);
                false -> authorize(launch, SD1)
            end;
        ignore -> 
            % It is an own-generated ACK without transaction
            next(SD)
    end.


authorize(launch, #call{uass=[UAS|Rest]}=SD) ->
    #uas{request=#sipmsg{auth=Auth}} = UAS, 
    UAS1 = UAS#uas{call_status=authorize},
    SD1 = SD#call{uass=[UAS1|Rest]},
    app_call(authorize, [Auth], SD1),
    {noreply, SD1};


authorize({reply, Reply}, SD) ->
    trace(authorize_reply, SD),
    case Reply of
        ok -> route(launch, SD);
        true -> route(launch, SD);
        false -> reply(forbidden, SD);
        authenticate -> reply(authenticate, SD);
        {authenticate, Realm} -> reply({authenticate, Realm}, SD);
        proxy_authenticate -> reply(proxy_authenticate, SD);
        {proxy_authenticate, Realm} -> reply({proxy_authenticate, Realm}, SD);
        Other -> reply(Other, SD)
    end.


%% @private
-spec route(launch | timeout | {reply, term()} | 
            {response, nksip:sipreply(), nksip_lib:proplist()} |
            {process, nksip_lib:proplist()} |
            {proxy, nksip:uri_set(), nksip_lib:proplist()} |
            {strict_proxy, nksip_lib:proplist()}, #call{}) -> term().

route(launch, #call{uass=[UAS|Rest]}=SD) ->
    trace(route, SD),
    #uas{request=#sipmsg{ruri=#uri{scheme=Scheme, user=User, domain=Domain}}}=UAS,
    UAS1 = UAS#uas{call_status=route},
    SD1 = SD#call{uass=[UAS1|Rest]},
    app_call(route, [Scheme, User, Domain], SD1),
    {noreply, SD1};

route({reply, Reply}, #call{app_id=AppId, call_id=CallId, uass=[UAS|_]}=SD) ->
    trace(route_reply, SD),
    #uas{request=#sipmsg{method=Method, ruri=RUri}=Req} = UAS,
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
    ?debug(AppId, CallId, "UAS ~p route: ~p", [Method, Route]),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_parse:header_tokens(<<"Require">>, Req) of
                [] -> 
                    route(Route, SD);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, SD)
            end;
        _ ->
            route(Route, SD)
    end;

route({response, Reply, Opts}, #call{uass=[UAS|Rest]}=SD) ->
    #uas{request=#sipmsg{opts=ReqOpts}=Req} = UAS,
    UAS1 = UAS#uas{request=Req#sipmsg{opts=Opts++ReqOpts}},
    reply(Reply, SD#call{uass=[UAS1|Rest]});

route({process, Opts}, #call{uass=[UAS|Rest]}=SD) ->
    #uas{request=#sipmsg{headers=Headers, opts=ReqOpts}=Req} = UAS,
    Req1 = case nksip_lib:get_value(headers, Opts, []) of
        [] ->  Req#sipmsg{opts=Opts++ReqOpts};
        Headers1 -> Req#sipmsg{headers=Headers1++Headers, opts=Opts++ReqOpts}
    end,
    UAS1 = UAS#uas{request=Req1},
    process(launch, SD#call{uass=[UAS1|Rest]});

% We want to proxy the request
route({proxy, _UriList, _Opts}, _SD) ->
    % Lanzar forking proxy
    error;

% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
route({strict_proxy, Opts}, 
       #call{app_id=AppId, call_id=CallId, uass=[UAS|_]}=SD) ->
    #uas{request=#sipmsg{routes=Routes}} = UAS,
    case Routes of
        [Next|_] ->
            ?info(AppId, CallId, "strict routing to ~p", [Next]),
            route({proxy, Next, [stateless|Opts]}, SD);
        _ ->
            reply({internal_error, <<"Invalid Srict Routing">>}, SD)
    end.

process(launch, #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]}=SD) ->
    #uas{pos=Pos, request=#sipmsg{method=Method}=Req, cancelled=Cancelled} = UAS,
    UAS1 = UAS#uas{call_status=process},
    SD1 = SD#call{uass=[UAS1|Rest]},
    case nksip_call_uas_dialog:request(SD) of
       {ok, DialogId, SD2} ->
            trace({launch_dialog, Method}, SD2),
            case Method of
                'INVITE' -> 
                    app_call(invite, [DialogId], SD2),
                    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
                        [Expires|_] when Expires > 0 -> 
                            start_timer(1000*Expires+100, uas_expire, Pos);
                        _ ->
                            undefined
                    end,
                    UAS2 = UAS1#uas{expire_timer=ExpireTimer},
                    SD3 = SD2#call{blocked=true, uass=[UAS2|Rest]},
                    case Cancelled of
                        true -> cancel(launch, SD3);
                        false -> next(SD3)
                    end;
                'ACK' ->
                    app_cast(ack, [DialogId], SD2),
                    next(SD2#call{blocked=false});
                'BYE' ->
                    app_call(bye, [DialogId], SD2),
                    next(SD2);
                'OPTIONS' ->
                    app_call(options, [], SD2),
                    next(SD2);
                'REGISTER' ->
                    app_call(register, [], SD2),
                    next(SD2);
                _ ->
                    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD2)
            end;
        no_dialog ->
            trace(launch_no_dialog, SD1),
            case Method of
                'CANCEL' ->
                    case is_cancel(Req, SD) of
                        {true, InvPos} ->
                            {noreply, #call{uass=Trans2}=SD2} = reply(ok, SD1),
                            {value, InvUAS, InvRest} = 
                                lists:keytake(InvPos, #uas.pos, Trans2),
                            case InvUAS of
                                #uas{call_status=process} ->
                                    SD3 = SD2#call{uass=[InvUAS|InvRest]},
                                    cancel(launch, SD3);
                                _ ->
                                    InvUAS1 = InvUAS#uas{cancelled=true},
                                    SD3 = SD2#call{uass=[InvUAS1|InvRest]},
                                    {noreply, SD3}
                            end;
                        false ->
                            reply(no_transaction, SD)
                    end;
                'ACK' ->
                    ?notice(AppId, CallId, "received out-of-dialog ACK", []),
                    next(SD1);
                'BYE' ->
                    reply(no_transaction, SD1);
                'OPTIONS' ->
                    app_call(options, [], SD1),
                    next(SD1);
                'REGISTER' ->
                    app_call(register, [], SD1),
                    next(SD1);
                _ ->
                    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD1)
            end;
        {error, Error} ->
            ?notice(AppId, CallId, "UAS ~p dialog request error ~p", [Method, Error]),
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
            reply(Reply, SD1)
    end;

process({reply, Reply}, SD) ->
    reply(Reply, SD).


cancel(launch, #call{uass=[UAS|Rest]}=SD) ->
    UAS1 = UAS#uas{call_status=cancel},
    SD1 = SD#call{uass=[UAS1|Rest]},
    app_call(cancel, [], SD1),
    {noreply, SD1};

cancel({reply, Reply}, #call{uass=[UAS|Rest]}=SD) ->
    case Reply of
        true -> 
            reply(request_terminated, SD);
        false -> 
            UAS1 = UAS#uas{call_status=process},
            SD1 = SD#call{uass=[UAS1|Rest]},
            {noreply, SD1}
    end.


%% ===================================================================
%% Utils
%% ===================================================================


%% @doc Checks if `Request' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(Request::nksip:request(), #call{}) ->
    boolean().

is_trans_ack(#sipmsg{method='ACK'}=Request, #call{uass=Trans}) ->
    TransId = transaction_id(Request#sipmsg{method='INVITE'}),
    case lists:keymember(TransId, #uas.id, Trans) of
        false ->
            case TransId of
                <<"old_", _/binary>> ->
                    % CHECK OLD STYLE
                    false;
                _ ->
                    false
            end;
        true ->
            {true, TransId}
    end;
is_trans_ack(_, _) ->
    false.


is_cancel(#sipmsg{method='CANCEL'}=CancelReq, 
          #call{app_id=AppId, call_id=CallId, uass=Trans}) ->
    TransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #uas.id, Trans) of
        #uas{pos=InvPos, request=InvReq} ->
            #sipmsg{transport=#transport{remote_ip=CancelIp, remote_port=CancelPort}} = 
                CancelReq,
            #sipmsg{transport=#transport{remote_ip=InvIp, remote_port=InvPort}} = 
                InvReq, 
            if
                CancelIp=:=InvIp, CancelPort=:=InvPort ->
                    {true, InvPos};
                true ->
                    ?notice(AppId, CallId, 
                           "UAS Trans rejecting CANCEL because came from ~p:~p, "
                           "request came from ~p:~p", 
                           [CancelIp, CancelPort, InvIp, InvPort]),
                    false
            end;
        _ ->
            ?debug(AppId, CallId, "received unknown CANCEL", []),
            false
    end;
is_cancel(_, _) ->
    false.


is_retrans(Req, #call{uass=Trans}) ->
    TransId = transaction_id(Req),
    case lists:keyfind(TransId, #uas.id, Trans) of
        false -> {false, TransId};
        UAS -> {true, UAS}    
    end.


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


%% @private
-spec app_call(atom(), list(), #call{}) ->
    ok.

app_call(_Fun, _Args, #call{app_pid=undefined}) ->
    ok;

app_call(Fun, Args, SD) ->
    #call{call_id=CallId, module=Module, app_pid=CorePid, uass=[UAS|_]} = SD,
    #uas{pos=Pos} = UAS,
    ReqId = {req, CallId, Pos},
    From = {'fun', nksip_call_srv, app_reply, [self(), Fun, Pos]},
    nksip_sipapp_srv:sipapp_call_async(CorePid, Module, Fun, Args++[ReqId], From).


%% @private
-spec app_cast(atom(), list(), #call{}) ->
    ok.

app_cast(_Fun, _Args, #call{app_pid=undefined}) ->
    ok;

app_cast(Fun, Args, 
         #call{call_id=CallId, module=Module, app_pid=CorePid, uass=[UAS|_]}) ->
    #uas{pos=Pos} = UAS,
    ReqId = {req, CallId, Pos},
    nksip_sipapp_srv:sipapp_cast(CorePid, Module, Fun, Args++[ReqId]).



reply(#sipmsg{response=Code, opts=Opts}=Resp, SD) ->
    #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]} = SD,
    #uas{
        pos = Pos, 
        id = TransId,
        trans_status = TransStatus, 
        request = #sipmsg{method=Method, transport=#transport{proto=Proto}} = Req,
        response = Resp, 
        s100_timer = S100Timer,
        timeout_timer = TimeoutTimer
    } = UAS,
    case 
        TransStatus=:=invite_proceeding orelse TransStatus=:=trying 
        orelse TransStatus=:=proceeding
    of
        true ->
            nksip_lib:cancel_timer(S100Timer),
            case nksip_transport_uas:send_response(Resp) of
                {ok, #sipmsg{response=Code1}=Resp1} -> ok;
                error -> #sipmsg{response=Code1}=Resp1=nksip_reply:reply(Req, 503)
            end,
            UAS1 = UAS#uas{response=Resp1, s100_timer=undefined},
            {ok, SD1} = nksip_call_uas_dialog:response(SD#call{uass=[UAS1|Rest]}),
            Stateless = lists:member(stateless, Opts),
            case Method of
                'INVITE' when Code1 < 200 ->
                    {noreply, SD1};
                'INVITE' when Code1 < 300 ->
                    nksip_lib:cancel_timer(TimeoutTimer),
                    case TransId of
                        <<"old_", _/binary>> ->
                            % In old-style transactions, save TransId to be used in
                            % detecting ACKs
                            ToTag = nksip_lib:get_binary(to_tag, Req#sipmsg.opts),
                            TransId = transaction_id(Req#sipmsg{to_tag=ToTag}),
                            nksip_proc:put({nksip_call_uas_ack, TransId});
                        _ ->
                            ok
                    end,
                    T1 = nksip_config:get(timer_t1),
                    UAS2 = UAS1#uas{
                        trans_status = invite_accepted,
                        timeout_timer = start_timer(64*T1, timer_l, Pos)
                    },
                    next(SD1#call{blocked=true, uass=[UAS2|Rest]});
                'INVITE' when Code1 >= 300 ->
                    nksip_lib:cancel_timer(TimeoutTimer),
                    T1 = nksip_config:get(timer_t1),
                    case Proto of 
                        udp ->
                            T2 = nksip_config:get(timer_t2),
                            UAS2 = UAS#uas{
                                trans_status = invite_completed,
                                retrans_timer = start_timer(T1, timer_g, Pos), 
                                next_retrans = min(2*T1, T2),
                                timeout_timer = start_timer(64*T1, timer_h, Pos)
                            },
                            next(SD1#call{uass=[UAS2|Rest]});
                        _ ->
                            UAS2 = UAS#uas{
                                trans_status = invite_completed,
                                timeout_timer = start_timer(64*T1, timer_h, Pos)
                            },
                            next(SD1#call{uass=[UAS2|Rest]})
                    end;
                _ when Code1 < 200 ->
                    UAS2 = UAS1#uas{trans_status=proceeding},
                    {noreply, SD#call{uass=[UAS2|Rest]}};
                _ when Code1 >= 200, Stateless ->
                    nksip_lib:cancel_timer(TimeoutTimer),
                    next(SD1#call{uass=Rest});
                _ when Code1 >= 200 ->
                    nksip_lib:cancel_timer(TimeoutTimer),
                    case Proto of
                        udp ->
                            T1 = nksip_config:get(timer_t1),
                            UAS2 = UAS1#uas{
                                trans_status = completed, 
                                timeout_timer = start_timer(64*T1, timer_j, Pos)
                            },
                            next(SD1#call{uass=[UAS2|Rest]});
                        _ ->
                            next(SD1#call{uass=Rest})
                    end
            end;
        false ->
            ?warning(AppId, CallId, "UAS cannot send ~p response in ~p", 
                     [Code, TransStatus]),
            next(SD)
    end;

reply(UserReply,  #call{uass=[#uas{request=Req}|_]}=SD) ->
    reply(nksip_reply:reply(Req, UserReply), SD).


trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).

start_timer(Time, Tag, Pos) ->
    erlang:start_timer(Time, self(), {Tag, Pos}).

next(SD) ->
    nksip_call_srv:next(SD).
















