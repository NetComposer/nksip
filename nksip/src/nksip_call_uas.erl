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
-import(nksip_call_lib, [update/2, start_timer/2, cancel_timers/2, trace/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(INVITE_TIMEOUT, (1000*nksip_config:get(ringing_timeout))).
-define(NOINVITE_TIMEOUT, 60000).
-define(CANCEL_TIMEOUT, 60000).


-type status() ::  authorize | route | 
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed |
                   finished.


%% ===================================================================
%% Private
%% ===================================================================


request(Req, #call{blocked=_Blocked, msg_queue=_MsgQueue}=SD) -> 
    case is_trans_ack(Req, SD) of
        {true, UAS} -> 
            process_trans_ack(UAS, SD);
        false ->
            case is_retrans(Req, SD) of
                {true, UAS} ->
                    process_retrans(UAS, SD);
                % {false, TransId} 
                %     when Blocked 
                %     andalso (Method=:='INVITE' orelse Method=:='BYE') ->
                %     MsgQueue1 = queue:in({TransId, Req}, MsgQueue),
                %     next(SD#call{msg_queue=MsgQueue1});
                {false, TransId} ->
                    do_request(TransId, Req, SD)
            end
    end.

%% @doc Checks if `Request' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(Request::nksip:request(), #call{}) ->
    boolean().

is_trans_ack(#sipmsg{method='ACK'}=Request, #call{trans=Trans}) ->
    TransId = transaction_id(Request#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uas} = UAS ->
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


process_trans_ack(#trans{status=Status, request=Req}=UAS, SD) ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    case Status of
        invite_completed ->
            UAS1 = cancel_timers([retrans, timeout], UAS),
            UAS2 = case Proto of 
                udp -> start_timer(timer_i, UAS1#trans{status=invite_confirmed});
                _ -> UAS1#trans{status=finished}
            end,
            next(update(UAS2, SD));
        _ ->
            ?call_notice("UAS received non 2xx ACK in ~p", [Status], SD),
            next(SD)
    end.

is_retrans(Req, #call{trans=Trans}) ->
    TransId = transaction_id(Req),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> {true, UAS};
        _ -> {false, TransId}
    end.


process_retrans(#trans{status=Status, request=Req, responses=Resps}, SD) ->
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
                [] ->
                    ?call_info("UAS received ~p retransmission in ~p", 
                               [Method, Status], SD)
            end;
        false ->
            ?call_info("UAS received ~p retransmission in ~p", 
                       [Method, Status], SD)
    end,
    next(SD).


sipapp_reply(Fun, TransId, Reply, #call{trans=Trans}=SD) ->
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uas, status=Status}=UAS ->
            case Fun of
                _ when Status=:=finished ->
                    ?call_info("UAS received reply for removed transaction", [], SD),
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
                    ?call_warning("UAS (~p) received unexpected SipApp reply ~p, ~p, ~p",
                                  [Status, Fun, TransId, Reply], SD),
                    next(SD)

            end;
        _ ->
            ?call_warning("UAS received unexpected SipApp reply ~p, ~p, ~p",
                          [Fun, TransId, Reply], SD),
            next(SD)
    end.



%% ===================================================================
%% Request cycle
%% ===================================================================


do_request(TransId, Req, SD) ->
    #call{trans=Trans, next=ReqId, msgs=Msgs, msg_keep_time=Keep} = SD,
    Now = nksip_lib:timestamp(),
    Expire = Now + Keep,
    case nksip_uas_lib:preprocess(Req#sipmsg{id=ReqId, expire=Expire}) of
        {ok, #sipmsg{method=Method}=Req1} -> 
            LoopId = loop_id(Req1),
            Timeout = case Method of
               'INVITE' -> ?INVITE_TIMEOUT;
                _ -> ?NOINVITE_TIMEOUT
            end,
            UAS = #trans{
                class = uas,
                trans_id = TransId, 
                request = Req1, 
                responses = [],
                loop_id = LoopId,
                cancel = false,
                timeout = Now + Timeout
            },
            nksip_counters:async([nksip_msgs]),
            Msg = #msg{
                msg_id = ReqId, 
                msg_class = req, 
                expire = Expire,
                trans_class = uas, 
                trans_id = TransId
            },
            SD1 = SD#call{trans=[UAS|Trans], msgs=[Msg|Msgs], next=ReqId+1},
            case lists:keyfind(LoopId, #trans.loop_id, Trans) of
                true -> reply(loop_detected, UAS, SD1);
                false -> send100(UAS, SD1)
            end;
        ignore -> 
            % It is an own-generated ACK without transaction
            next(SD)
    end.


send100(#trans{request=Req}=UAS, #call{app_opts=Opts}=SD) ->
    #sipmsg{method=Method} = Req,
    case lists:member(no_100, Opts) of 
        false when Method=/='ACK' -> 
            case nksip_transport_uas:send_response(Req, 100) of
                {ok, _} -> 
                    authorize(launch, UAS, SD);
                error -> 
                    ?call_notice("UAS couldn't send ~p 100 response", 
                                 [Method], SD),
                    reply(service_unavailable, UAS, SD)
            end;
        _ ->
            authorize(launch, UAS, SD)
    end.
        

authorize(launch, #trans{request=Req}=UAS, SD) ->
    Auth = nksip_auth:get_authentication(Req),
    app_call(authorize, [Auth], UAS, SD),
    next(update(UAS#trans{status=authorize}, SD));

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
            {strict_proxy, nksip_lib:proplist()}, #trans{}, #call{}) -> term().

route(launch, #trans{request=Req}=UAS, SD) ->
    trace(route, SD),
    #sipmsg{ruri=#uri{scheme=Scheme, user=User, domain=Domain}} = Req,
    app_call(route, [Scheme, User, Domain], UAS, SD),
    next(update(UAS#trans{status=route}, SD));

route({reply, Reply}, #trans{request=Req}=UAS, SD) ->
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
    SD1 = update(UAS#trans{status=Status}, SD),
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

do_route({response, Reply, Opts}, #trans{request=Req}=UAS, SD) ->
    #sipmsg{opts=ReqOpts} = Req,
    UAS1 = UAS#trans{request=Req#sipmsg{opts=Opts++ReqOpts}},
    reply(Reply, UAS1, update(UAS1, SD));

do_route({process, Opts}, #trans{request=Req}=UAS, SD) ->
    #sipmsg{headers=Headers, opts=ReqOpts} = Req,
    Req1 = case nksip_lib:get_value(headers, Opts, []) of
        [] ->  Req#sipmsg{opts=Opts++ReqOpts};
        Headers1 -> Req#sipmsg{headers=Headers1++Headers, opts=Opts++ReqOpts}
    end,
    UAS1 = UAS#trans{request=Req1},
    process(launch, UAS1, update(UAS1, SD));

% We want to proxy the request
do_route({proxy, UriList, Opts}, UAS, SD) ->
    nksip_call_proxy:start(UriList, Opts, UAS, SD);

% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
do_route({strict_proxy, Opts}, #trans{request=Req}=UAS, SD) ->
    case Req#sipmsg.routes of
        [Next|_] ->
            ?call_info("strict routing to ~p", [Next], SD),
            do_route({proxy, Next, [stateless|Opts]}, UAS, SD);
        _ ->
            reply({internal_error, <<"Invalid Srict Routing">>}, UAS, SD)
    end.

process(launch,  #trans{request=Req}=UAS, #call{dialogs=Dialogs}=SD) ->
    #sipmsg{method=Method} = Req,
    case nksip_call_dialog_uas:request(Req, Dialogs) of
        nodialog -> 
            trace(launch_no_dialog, SD),
            do_process_nodialog(Method, UAS, SD);
        {ok, DialogId, Dialogs1} -> 
            trace({launch_dialog, Method}, SD),
            do_process_dialog(Method, DialogId, UAS, SD#call{dialogs=Dialogs1});
        {error, Error} when Method=/='ACK' ->
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
            reply(Reply, UAS, SD);
        {error, Error} when Method=:='ACK' ->
            ?call_notice("UAS 'ACK' dialog request error ~p", [Method, Error], SD),
            next(SD)
    end;

process({reply, Reply}, UAS, SD) ->
    reply(Reply, UAS, SD).


do_process_dialog('INVITE', DialogId, UAS, SD) ->
    #trans{cancel=Cancelled} = UAS,
    app_call(invite, [DialogId], UAS, SD),
    UAS1 = start_timer(expire, UAS),
    SD1 = update(UAS1, SD),
    case Cancelled of
        true -> cancel(launch, UAS1, SD1);
        false -> next(SD1)
    end;

do_process_dialog('ACK', DialogId, UAS, SD) ->
    app_cast(ack, [DialogId], UAS, SD),
    next(SD);

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


do_process_nodialog('CANCEL',  #trans{request=Req}=UAS, SD) ->
    case is_cancel(Req, SD) of
        {true, InvUAS} ->
            case InvUAS of
                #trans{status=Status}=InvUAS ->
                    if
                        Status=:=authorize; Status=:=route ->
                            SD1 = send_reply(ok, UAS, SD),
                            InvUAS1 = InvUAS#trans{cancel=true},
                            next(update(InvUAS1, SD1));
                        Status=:=invite_proceeding ->
                            SD1 = send_reply(ok, UAS, SD),
                            cancel(launch, InvUAS, SD1);
                        true ->
                            reply(no_transaction, UAS, SD)
                    end
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
    next(SD);

cancel({reply, Reply}, #trans{status=Status}=UAS, SD) ->
    case Reply of
        true when Status=:=invite_proeeding ->
            reply(request_terminated, UAS, SD);
        _ -> 
            next(SD)
    end.


is_cancel(#sipmsg{method='CANCEL'}=CancelReq, #call{trans=Trans}=SD) -> 
    TransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uas, request=InvReq} = InvUAS ->
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

send_reply(#sipmsg{response=Code}=Resp, UAS, SD) ->
    #trans{
        trans_id = TransId, 
        status = Status, 
        request = #sipmsg{method=Method} = Req,
        responses = Resps
    } = UAS,
    #call{msgs=Msgs, next=RespId, dialogs=Dialogs, msg_keep_time=Keep} = SD,
    case 
        Status=:=invite_proceeding orelse Status=:=trying 
        orelse Status=:=proceeding
    of
        true ->
            case nksip_transport_uas:send_response(Resp) of
                {ok, Resp1} -> ok;
                error -> Resp1 = nksip_reply:reply(Req, 503)
            end,    
            Dialogs1 = nksip_call_dialog_uas:response(Req, Resp1, Dialogs),
            Expire = nksip_lib:timestamp() + Keep,
            #sipmsg{response=Code2} = Resp2 = Resp1#sipmsg{id=RespId, expire=Expire},
            UAS1= UAS#trans{responses=[Resp2|Resps]},
            Msg = #msg{
                msg_id = RespId,
                msg_class = resp,
                expire = Expire,
                trans_class = uas, 
                trans_id=TransId
            },
            nksip_counters:async([nksip_msgs]),
            SD1 = SD#call{msgs=[Msg|Msgs], next=RespId+1, dialogs=Dialogs1},
            UAS2 = do_reply(Method, Code2, UAS1),
            update(UAS2, SD1);
        false ->
            ?call_warning("UAS cannot send ~p ~p response in ~p", 
                          [Method, Code, Status], SD),
            SD
    end;

send_reply(UserReply, #trans{request=Req}=UAS, SD) ->
    send_reply(nksip_reply:reply(Req, UserReply), UAS, SD).



do_reply('INVITE', Code, UAS) when Code < 200 ->
    UAS;

do_reply('INVITE', Code, #trans{trans_id=Id, request=Req}=UAS) when Code < 300 ->
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
    % RFC6026 accepted state, to wait for INVITE retransmissions
    % Dialog will send 2xx retransmissions
    start_timer(timer_l, UAS1#trans{status=invite_accepted});

do_reply('INVITE', Code, #trans{request=Req}=UAS) when Code >= 300 ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAS1 = cancel_timers([timeout], UAS),
    UAS2 = start_timer(timer_h, UAS1#trans{status=invite_completed}),
    case Proto of 
        udp -> start_timer(timer_g, UAS2);
        _ -> UAS2
    end;

do_reply(_, Code, UAS) when Code < 200 ->
    UAS#trans{status=proceeding};

do_reply(_, Code, #trans{request=Req}=UAS) when Code >= 200 ->
    #sipmsg{transport=#transport{proto=Proto}} = Req,
    UAS1 = cancel_timers([timeout], UAS),
    case Proto of
        udp -> start_timer(timer_j, UAS1#trans{status=completed});
        _ -> UAS1#trans{status=finished}
    end.


%% ===================================================================
%% Timers
%% ===================================================================


% INVITE 3456xx retrans
timer(timer_g, UAS, SD) ->
    #trans{request=#sipmsg{method=Method}, responses=[Resp|_]} = UAS,
    #sipmsg{response=Code} = Resp,
    UAS1 = start_timer(timer_g, UAS),
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?call_info("UAS retransmitting 'INVITE' ~p response", [Code], SD);
        error ->
            ?call_notice("UAS could not retransmit 'INVITE' ~p response",
                         [Method, Code], SD)
    end,
    next(update(UAS1, SD));

% INVITE accepted finished
timer(timer_l, UAS, SD) ->
    ?call_notice("UAS 'INVITE' Timer L fired", [], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    next(update(UAS1, SD));

% INVITE confirmed finished
timer(timer_i, UAS, SD) ->
    ?call_debug("UAC 'INVITE' Timer I fired", [], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    next(update(UAS1, SD));

% NoINVITE completed finished
timer(timer_j, #trans{request=#sipmsg{method=Method}}=UAS, SD) ->
    ?call_notice("UAS ~p Timer J fired", [Method], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    next(update(UAS1, SD));

% INVITE completed timeout
timer(timer_h, UAS, SD) ->
    ?call_notice("UAS 'INVITE' timeout (Timer H) fired, no ACK received", [], SD),
    UAS1 = cancel_timers([timeout, retrans], UAS#trans{status=finished}),
    next(update(UAS1, SD));

timer(expire, UAS, SD) ->
    case UAS of
        #trans{status=invite_proceeding} -> process(cancel, UAS, SD);
        _ -> next(SD)
    end.




%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), #trans{}, #call{}) ->
    ok.

app_call(Fun, Args, UAS, #call{app_id=AppId, call_id=CallId}) ->
    #trans{request=#sipmsg{id=Id}} = UAS,
    ReqId = {req, AppId, CallId, Id},
    From = {'fun', nksip_call, sipapp_reply, [AppId, CallId, Fun, Id]},
    nksip_sipapp_srv:sipapp_call_async(AppId, Fun, Args++[ReqId], From).


%% @private
-spec app_cast(atom(), list(), #trans{}, #call{}) ->
    ok.

app_cast(Fun, Args, UAS, #call{app_id=AppId, call_id=CallId}) ->
    #trans{request=#sipmsg{id=Id}} = UAS,
    ReqId = {req, AppId, CallId, Id},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, Args++[ReqId]).


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

