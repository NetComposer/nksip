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

-export([request/2, timer/2]).
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




%% ===================================================================
%% Internal
%% ===================================================================

process_trans_ack(TransId, #call{app_id=AppId, call_id=CallId, uass=Trans}=SD) ->
    {value, UAS, Rest} = lists:keytake(TransId, #uas.id, Trans),
    #uas{
        status = Status, 
        request = #sipmsg{transport=#transport{proto=Proto}}, 
        retrans_timer = TimerG, 
        timeout_timer = TimerH
    } = UAS,
    case Status of
        invite_completed ->
            nksip_lib:cancel_timer(TimerG),
            nksip_lib:cancel_timer(TimerH),
            UAS1 = UAS#uas{retrans_timer=undefined, timeout_timer=undefined},
            case Proto of 
                udp -> 
                    T4 = nksip_config:get(timer_t4), 
                    UAS2 = UAS1#uas{
                        status = invite_confirmed,
                        timeout_timer = start_timer(T4, timer_i, TransId)
                    },
                    next(SD#call{uass=[UAS2|Rest]});
                _ ->
                    next(remove(SD#call{uass=[UAS1|Rest]}))
            end;
        _ ->
            ?notice(AppId, CallId, "UAS received ACK in ~p", [Status]),
            {noreply, SD}
    end.


process_retrans(UAS, #call{app_id=AppId, call_id=CallId}=SD) ->
    #uas{status=Status, request=#sipmsg{method=Method}, response=Resp} = UAS,
    case 
        Status=:=invite_proceeding orelse Status=:=invite_completed
        orelse Status=:=proceeding orelse Status=:=completed
    of
        true ->
            case Resp of
                #sipmsg{response=Code} ->
                    case nksip_transport_uas:resend_response(Resp) of
                        {ok, _} -> 
                            ?info(AppId, CallId, 
                                  "UAS retransmitting ~p ~p response in ~p", 
                                  [Method, Code, Status]);
                        error ->
                            ?notice(AppId, CallId, 
                                    "UAS could not retransmit ~p ~p response in ~p", 
                                    [Method, Code, Status])
                    end;
                _ ->
                    ?info(AppId, CallId, "UAS received ~p retransmission in ~p", 
                          [Method, Status]),
                    ok
            end;
        _ ->
            false
    end,
    {noreply, SD}.


start(Id, Req, #call{app_opts=Opts, uass=Trans}=SD) ->
    case nksip_uas_lib:preprocess(Req) of
        {ok, #sipmsg{start=Start, method=Method}=Req1} -> 
            Timeout = case Method of
               'INVITE' -> ?INVITE_TIMEOUT;
                _ -> ?NOINVITE_TIMEOUT
            end,
            TimeoutTimer = start_timer(Timeout, timeout, Id),
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
    UAS1 = UAS#uas{status=authorize},
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
    UAS1 = UAS#uas{status=route},
    SD1 = SD#call{uass=[UAS1|Rest]},
    app_call(route, [Scheme, User, Domain], SD1),
    {noreply, SD1};

route({reply, Reply}, #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]}=SD) ->
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
    Status = case Method of
        'INVITE' -> invite_proceeding;
        _ -> trying
    end,
    SD1 = SD#call{uass=[UAS#uas{status=Status}|Rest]},
    ?debug(AppId, CallId, "UAS ~p route: ~p", [Method, Route]),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_parse:header_tokens(<<"Require">>, Req) of
                [] -> 
                    route(Route, SD1);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, SD1)
            end;
        _ ->
            route(Route, SD1)
    end;

route({response, Reply, Opts}, #call{uass=[UAS|Rest]}=SD) ->
    #uas{request=#sipmsg{method=Method, opts=ReqOpts}=Req} = UAS,
    Status = case Method of
        'INVIE' -> invite_proceeding;
        _ -> trying
    end,
    UAS1 = UAS#uas{status=Status, request=Req#sipmsg{opts=Opts++ReqOpts}},
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
route({proxy, UriList, Opts}, SD) ->
    nksip_call_proxy:start(UriList, Opts, SD);

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

process(launch, #call{app_id=AppId, call_id=CallId, uass=[UAS|_]}=SD) ->
    #uas{request=#sipmsg{method=Method}} = UAS,
    case nksip_call_dialog_uas:request(SD) of
        {ok, DialogId, SD1} -> 
            trace({launch_dialog, Method}, SD1),
            process_dialog(Method, DialogId, SD1);
        nodialog -> 
            trace(launch_no_dialog, SD),
            process_nodialog(Method, SD);
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
            reply(Reply, SD)
    end;

process({reply, Reply}, SD) ->
    reply(Reply, SD).


process_dialog('INVITE', DialogId, #call{uass=[UAS|Rest]}=SD) ->
    #uas{id=Id, request=Req, cancelled=Cancelled} = UAS,
    app_call(invite, [DialogId], SD),
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            start_timer(1000*Expires+100, expire, Id);
        _ ->
            undefined
    end,
    UAS1 = UAS#uas{expire_timer=ExpireTimer},
    SD1 = SD#call{blocked=true, uass=[UAS1|Rest]},
    case Cancelled of
        true -> cancel(launch, SD1);
        false -> next(SD1)
    end;

process_dialog('ACK', DialogId, SD) ->
    app_cast(ack, [DialogId], SD),
    next(SD#call{blocked=false});

process_dialog('BYE', DialogId, SD) ->
    app_call(bye, [DialogId], SD),
    next(SD);

process_dialog('OPTIONS', _DialogId, SD) ->
    app_call(options, [], SD),
    next(SD);

process_dialog('REGISTER', _DialogId, SD) ->
    app_call(register, [], SD),
    next(SD);

process_dialog(_, _DialogId, #call{app_id=AppId}=SD) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD).


process_nodialog('CANCEL', #call{uass=[UAS|_]}=SD) ->
    #uas{request=Req} = UAS,
    case is_cancel(Req, SD) of
        {true, InvId} ->
            {noreply, #call{uass=UASs2}=SD1} = reply(ok, SD),
            {value, InvUAS, InvRest} = 
                lists:keytake(InvId, #uas.id, UASs2),
            case InvUAS of
                #uas{status=process} ->
                    SD2 = SD1#call{uass=[InvUAS|InvRest]},
                    cancel(launch, SD2);
                _ ->
                    InvUAS1 = InvUAS#uas{cancelled=true},
                    SD2 = SD1#call{uass=[InvUAS1|InvRest]},
                    next(SD2)
            end;
        false ->
            reply(no_transaction, SD)
    end;

process_nodialog('ACK', #call{app_id=AppId, call_id=CallId}=SD) ->
    ?notice(AppId, CallId, "received out-of-dialog ACK", []),
    next(SD);

process_nodialog('BYE', SD) ->
    reply(no_transaction, SD);

process_nodialog('OPTIONS', SD) ->
    app_call(options, [], SD),
    next(SD);

process_nodialog('REGISTER', SD) ->
    app_call(register, [], SD),
    next(SD);

process_nodialog(_, #call{app_id=AppId}=SD) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD).
        

cancel(launch, #call{uass=[UAS|Rest]}=SD) ->
    UAS1 = UAS#uas{status=cancel},
    SD1 = SD#call{uass=[UAS1|Rest]},
    app_call(cancel, [], SD1),
    {noreply, SD1};

cancel({reply, Reply}, #call{uass=[UAS|Rest]}=SD) ->
    case Reply of
        true -> 
            reply(request_terminated, SD);
        false -> 
            UAS1 = UAS#uas{status=process},
            SD1 = SD#call{uass=[UAS1|Rest]},
            {noreply, SD1}
    end.


%% @private
timer(send_100, #call{uass=[UAS|Rest]}=SD) ->
    UAS1 = UAS#uas{s100_timer=undefined},
    case UAS of
        #uas{request=Req, response=undefined}=UAS ->
            case nksip_transport_uas:send_response(Req, 100) of
                {ok, Resp} -> 
                    UAS2 = UAS1#uas{response=Resp},
                    next(SD#call{uass=[UAS2|Rest]});
                error ->
                    ?notice(Req, "UAS could not send 100 response", []),
                    next(SD#call{uass=[UAS1|Rest]})
            end;
        _ ->
            next(SD#call{uass=[UAS1|Rest]})
    end;

timer(timeout, #call{app_id=AppId, call_id=CallId, uass=[UAS|_]}=SD) ->
    #uas{status=Status, request=#sipmsg{method=Method}} = UAS,
    case 
        lists:member(Status, [authorize, route, process, invite_proceeding, 
                              trying, proceeding])
    of
        true ->
            ?warning(AppId, CallId, "UAS ~p didn't receive any answer in ~p", 
                     [Method, Status]),
            reply(timeout, SD);
        false ->
            next(SD)
    end;

timer(timer_g, #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]}=SD) ->
    #uas{
        id = Id, 
        response = #sipmsg{response=Code, cseq_method=Method}=Resp,
        next_retrans = Next
    } = UAS,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?info(AppId, CallId, "UAS retransmitting ~p ~p response in completed",
                  [Method, Code]),
            T2 = nksip_config:get(timer_t2),
            UAS1 = UAS#uas{
                retrans_timer = start_timer(Next, timer_g, Id),
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
    ?notice(AppId, CallId, "UAS timer_l timeout", []),
    next(SD#call{blocked=false, uass=Rest});

timer(expire, #call{uass=[UAS|Rest]}=SD) ->
    case UAS of
        #uas{status=invite_proceeding} ->
            nksip_call_uas:process(cancel, SD#call{uass=[UAS|Rest]});
        _ ->
            {noreply, SD}
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


is_cancel(#sipmsg{method='CANCEL'}=CancelReq, SD) -> 
    #call{app_id=AppId, call_id=CallId, uass=UASs} = SD,
    TransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #uas.id, UASs) of
        #uas{request=InvReq} ->
            #sipmsg{transport=CancelTransp} = CancelReq,
            #sipmsg{transport=InvTransp} = InvReq, 
            #transport{remote_ip=CancelIp, remote_port=CancelPort} = CancelTransp,
            #transport{remote_ip=InvIp, remote_port=InvPort} = InvTransp,
            if
                CancelIp=:=InvIp, CancelPort=:=InvPort ->
                    {true, TransId};
                true ->
                    ?notice(AppId, CallId, 
                           "UAS Trans rejecting CANCEL because came from ~p:~p, "
                           "request came from ~p:~p", 
                           [CancelIp, CancelPort, InvIp, InvPort]),
                    false
            end;
        false ->
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
    #uas{id=Id} = UAS,
    ReqId = {req, CallId, Id},
    From = {'fun', nksip_call_srv, app_reply, [self(), Fun, Id]},
    nksip_sipapp_srv:sipapp_call_async(CorePid, Module, Fun, Args++[ReqId], From).


%% @private
-spec app_cast(atom(), list(), #call{}) ->
    ok.

app_cast(_Fun, _Args, #call{app_pid=undefined}) ->
    ok;

app_cast(Fun, Args, 
         #call{call_id=CallId, module=Module, app_pid=CorePid, uass=[UAS|_]}) ->
    #uas{id=Id} = UAS,
    ReqId = {req, CallId, Id},
    nksip_sipapp_srv:sipapp_cast(CorePid, Module, Fun, Args++[ReqId]).



reply(#sipmsg{response=Code}=Resp, SD) ->
    #call{app_id=AppId, call_id=CallId, uass=[UAS|Rest]} = SD,
    #uas{
        status = Status, 
        request = #sipmsg{method=Method} = Req,
        response = Resp, 
        s100_timer = S100Timer
    } = UAS,
    case 
        Status=:=invite_proceeding orelse Status=:=trying 
        orelse Status=:=proceeding
    of
        true ->
            nksip_lib:cancel_timer(S100Timer),
            case nksip_transport_uas:send_response(Resp) of
                {ok, #sipmsg{response=Code1}=Resp1} -> ok;
                error -> #sipmsg{response=Code1}=Resp1=nksip_reply:reply(Req, 503)
            end,
            UAS1 = UAS#uas{response=Resp1, s100_timer=undefined},
            SD1 = nksip_call_dialog_uas:response(SD#call{uass=[UAS1|Rest]}),
            SD2 = reply(Method, Code1, SD1),
            next(SD2);
        false ->
            ?warning(AppId, CallId, "UAS cannot send ~p response in ~p", 
                     [Code, Status]),
            next(SD)
    end;

reply(UserReply,  #call{uass=[#uas{request=Req}|_]}=SD) ->
    reply(nksip_reply:reply(Req, UserReply), SD).



reply('INVITE', Code, SD) when Code < 200 ->
    SD;

reply('INVITE', Code, #call{uass=[UAS|Rest]}=SD) when Code < 300 ->
    #uas{id=Id, request=Req, timeout_timer=TimeoutTimer} = UAS,
    nksip_lib:cancel_timer(TimeoutTimer),
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
    T1 = nksip_config:get(timer_t1),
    UAS1 = UAS#uas{
        status = invite_accepted,
        timeout_timer = start_timer(64*T1, timer_l, Id)
    },
    SD#call{blocked=true, uass=[UAS1|Rest]};

reply('INVITE', Code, #call{uass=[UAS|Rest]}=SD) when Code >= 300 ->
    #uas{id=Id, request=Req, timeout_timer=TimeoutTimer} = UAS,
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    nksip_lib:cancel_timer(TimeoutTimer),
    T1 = nksip_config:get(timer_t1),
    case Proto of 
        udp ->
            UAS1 = UAS#uas{
                status = invite_completed,
                retrans_timer = start_timer(T1, timer_g, Id), 
                next_retrans = 2*T1,
                timeout_timer = start_timer(64*T1, timer_h, Id)
            },
            SD#call{uass=[UAS1|Rest]};
        _ ->
            UAS1 = UAS#uas{
                status = invite_completed,
                timeout_timer = start_timer(64*T1, timer_h, Id)
            },
            SD#call{uass=[UAS1|Rest]}
    end;

reply(_, Code, #call{uass=[UAS|Rest]}=SD) when Code < 200 ->
    UAS1 = UAS#uas{status=proceeding},
    SD#call{uass=[UAS1|Rest]};

reply(_, Code, #call{uass=[UAS|Rest]}=SD) when Code >= 200 ->
    #uas{id=Id, request=Req, timeout_timer=TimeoutTimer} = UAS,
    #sipmsg{transport=#transport{proto=Proto}, opts=Opts} = Req,
    nksip_lib:cancel_timer(TimeoutTimer),
    case lists:member(stateless, Opts) of
        true ->
            remove(SD);
        false ->
            case Proto of
                udp ->
                    T1 = nksip_config:get(timer_t1),
                    UAS1 = UAS#uas{
                        status = completed, 
                        timeout_timer = start_timer(64*T1, timer_j, Id)
                    },
                    SD#call{uass=[UAS1|Rest]};
                _ ->
                    remove(SD)
            end
    end.

trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).

start_timer(Time, Tag, Pos) ->
    {Tag, erlang:start_timer(Time, self(), {uas, Tag, Pos})}.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.

next(SD) ->
    nksip_call_srv:next(SD).


remove(#call{uass=[UAS|Rest]}=SD) ->
    #uas{
        id = Id, 
        s100_timer = S100,
        timeout_timer = Timeout, 
        retrans_timer = Retrans, 
        expire_timer = Expire
    } = UAS,
    case 
        S100=/=undefined orelse Timeout=/=undefined orelse 
        Retrans=/=undefined orelse Expire=/=undefined 
    of
        true -> ?P("REMOVED WITH TIMERS: ~p", [UAS]);
        false -> ok
    end,
    cancel_timer(S100),
    cancel_timer(Timeout),
    cancel_timer(Retrans),
    cancel_timer(Expire),
    UAS1 = UAS#uac{
        status = removed,
        timeout_timer = start_timer(?CALL_FINISH_TIMEOUT, remove, Id),
        retrans_timer = undefined,
        expire_timer = undefined
    },
    SD#call{uacs=[UAS1|Rest]}.












