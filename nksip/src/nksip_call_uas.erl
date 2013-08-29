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

-export([request/2, timer/3, sipapp_reply/4, sync_reply/4]).
-export_type([status/0]).
-import(nksip_call_lib, [update/2, start_timer/2, cancel_timers/2, trace/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-type status() ::  authorize | send_100 | route | ack |
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed |
                   finished.


%% ===================================================================
%% Private
%% ===================================================================


request(Req, SD) -> 
    case is_trans_ack(Req, SD) of
        {true, UAS} -> 
            process_trans_ack(UAS, SD);
        false ->
            case is_retrans(Req, SD) of
                {true, UAS} ->
                    process_retrans(UAS, SD);
                {false, TransId} ->
                    case nksip_uas_lib:preprocess(Req) of
                        own_ack -> SD;
                        Req1 -> do_request(Req1, TransId, SD)
                    end;
                error ->
                    SD
            end;
        error ->
            SD
    end.


process_trans_ack(UAS, SD) ->
    #trans{id=Id, status=Status, proto=Proto} = UAS,
    case Status of
        invite_completed ->
            UAS1 = cancel_timers([retrans, timeout], UAS),
            UAS3 = case Proto of 
                udp -> 
                    UAS2 = UAS1#trans{response=undefined, status=invite_confirmed},
                    start_timer(timer_i, UAS2);
                _ -> 
                    UAS1#trans{status=finished}
            end,
            ?call_debug("UAS ~p received in-transaction ACK", [Id], SD),
            update(UAS3, SD);
        _ ->
            ?call_notice("UAS ~p received non 2xx ACK in ~p", [Id, Status], SD),
            SD
    end.


process_retrans(UAS, SD) ->
    #trans{id=Id, status=Status, method=Method, response=Resp} = UAS,
    case 
        Status=:=invite_proceeding orelse Status=:=invite_completed
        orelse Status=:=proceeding orelse Status=:=completed
    of
        true when is_record(Resp, sipmsg) ->
            #sipmsg{response=Code} = Resp,
            case nksip_transport_uas:resend_response(Resp) of
                {ok, _} ->
                    ?call_info("UAS ~p ~p (~p) sending ~p retransmission", 
                               [Id, Method, Status, Code], SD);
                error ->
                    ?call_info("UAS ~p ~p (~p) could not send ~p retransmission", 
                               [Id, Method, Status, Code], SD)
            end;
        _ ->
            ?call_info("UAS ~p ~p received retransmission in ~p", 
                       [Id, Method, Status], SD)
    end,
    SD.


sipapp_reply(Fun, TransId, Reply, #call{trans=Trans}=SD) ->
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas, method=Method, status=Status}=UAS ->
            case Fun of
                _ when Status=:=finished ->
                    ?call_info("UAS ~p ~p received reply ~p in finished", 
                              [TransId, Method, {Fun, Reply}], SD),
                    SD;
                authorize when Status=:=authorize -> 
                    authorize({reply, Reply}, UAS, SD);
                route when Status=:=route -> 
                    route({reply, Reply}, UAS, SD);
                cancel when Status=:=cancel ->
                    cancel({reply, Reply}, UAS, SD);
                _ when Fun=:=invite; Fun=:=bye; Fun=:=options; 
                       Fun=:=register; Fun=fork ->
                    reply(Reply, UAS, SD);
                _ ->
                    ?call_notice("UAS ~p ~p received unexpected reply ~p in ~p",
                                  [TransId, Method, {Fun, Reply}, Status], SD),
                    SD

            end;
        _ ->
            ?call_notice("Unknown UAS ~p received unexpected reply ~p",
                          [TransId, {Fun, Reply}], SD),
            SD
    end.

sync_reply(Reply, UAS, From, SD) ->
    {Result, SD1} = send_reply(Reply, UAS, SD),
    gen_server:reply(From, Result),
    SD1.




%% ===================================================================
%% Request cycle
%% ===================================================================


do_request(Req, TransId, #call{trans=Trans}=SD) ->
    {Req1, SD1} = nksip_call_lib:add_msg(Req, false, SD),
    #sipmsg{id=MsgId, method=Method, ruri=RUri, transport=Transp, opts=Opts} = Req1,
    LoopId = loop_id(Req1),
    Status = case Method of 'INVITE' -> send_100; _ -> authorize end,
    UAS = #trans{
        class = uas,
        id = TransId, 
        status = Status,
        request = Req1,
        method = Method,
        ruri = RUri,
        proto = Transp#transport.proto,
        opts = Opts,
        stateless = true,
        response = undefined,
        code = 0,
        loop_id = LoopId,
        cancel = false
    },
    UAS1 = start_timer(timeout, UAS),
    SD2 = SD1#call{trans=[UAS1|Trans]},
    ?call_debug("UAS ~p received SipMsg ~p (~p)", [TransId, MsgId, Method], SD2),
    case lists:keyfind(LoopId, #trans.loop_id, Trans) of
        true -> reply(loop_detected, UAS1, SD2);
        false when Method=:='INVITE' -> send100(UAS1, SD2);
        false -> authorize(launch, UAS1, SD2)
    end.


send100(UAS, SD) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    #call{send_100=Send100} = SD,
    case Method=:='INVITE' andalso Send100 of 
        true ->
            case nksip_transport_uas:send_response(Req, 100) of
                {ok, _} -> 
                    authorize(launch, UAS, SD);
                error ->
                    ?call_notice("UAS ~p ~p could not send '100' response", 
                                 [Id, Method], SD),
                    reply(service_unavailable, UAS, SD)
            end;
        false -> 
            authorize(launch, UAS, SD)
    end.
        

authorize(launch, #trans{request=Req, id=Id, method=Method}=UAS, SD) ->
    Auth = nksip_auth:get_authentication(Req),
    ?call_debug("UAS ~p ~p calling authorize", [Id, Method],SD),
    app_call(authorize, [Auth], UAS, SD),
    update(UAS#trans{status=authorize}, SD);

authorize({reply, Reply}, #trans{id=Id, method=Method}=UAS, SD) ->
    ?call_debug("UAS ~p ~p authorize reply: ~p", [Id, Method, Reply], SD),
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

route(launch, #trans{id=Id, method=Method, ruri=RUri}=UAS, SD) ->
    #uri{scheme=Scheme, user=User, domain=Domain} = RUri,
    ?call_debug("UAS ~p ~p calling route", [Id, Method], SD),
    app_call(route, [Scheme, User, Domain], UAS, SD),
    update(UAS#trans{status=route}, SD);

route({reply, Reply}, UAS, SD) ->
    #trans{id=Id, method=Method, ruri=RUri, request=Req} = UAS,
    ?call_debug("UAS ~p ~p route reply: ~p", [Id, Method, Reply], SD),
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
        'ACK' -> ack;
        _ -> trying
    end,
    UAS1 = UAS#trans{status=Status},
    SD1 = update(UAS1, SD),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_sipmsg:header(Req, <<"Require">>, tokens) of
                {ok, []} -> 
                    do_route(Route, UAS1, SD1);
                {ok, Requires} -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, UAS1, SD1)
            end;
        _ ->
            do_route(Route, UAS1, SD1)
    end.

do_route({response, Reply, Opts}, UAS, SD) ->
    UAS1 = UAS#trans{stateless=lists:member(stateless, Opts)},
    reply(Reply, UAS1, update(UAS1, SD));

do_route({process, Opts}, #trans{request=Req}=UAS, SD) ->
    UAS1 = UAS#trans{stateless=lists:member(stateless, Opts)},
    UAS2 = case nksip_lib:get_value(headers, Opts, []) of
        [] -> 
            UAS1;
        Headers1 -> 
            #sipmsg{headers=Headers} = Req,
            UAS1#trans{request=Req#sipmsg{headers=Headers1++Headers}}
    end,
    process(uas, UAS2, update(UAS2, SD));

% We want to proxy the request
do_route({proxy, UriList, Opts}, UAS, SD) ->
    case nksip_call_proxy:start(UAS, UriList, Opts, SD) of
        stateless ->
            UAS1 = UAS#trans{status=finished},
            update(UAS1, SD);
        stateful ->
            process(proxy, UAS#trans{stateless=false}, SD);
        SipReply ->
            reply(SipReply, UAS, SD)
    end;


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

process(Type, #trans{stateless=false}=UAS, SD) ->
    #trans{id=Id, method=Method} = UAS,
    case nksip_call_dialog_uas:request(UAS, SD) of
        {ok, DialogId, SD1} -> 
            % Caution: for first INVITEs, DialogId is not yet created!
            ?call_debug("UAS ~p ~p dialog id: ~p", [Id, Method, DialogId], SD),
            do_process(Method, DialogId, Type, UAS, SD1);
        {error, Error} when Method=/='ACK' ->
            ?call_notice("UAS ~p ~p dialog request error: ~p", 
                         [Id, Method, Error], SD),
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
            ?call_notice("UAS ~p 'ACK' dialog request error: ~p", [Id, Error], SD),
            UAS1 = UAS#trans{status=finished},
            update(UAS1, SD)
    end;

process(uas, #trans{method=Method}=UAS, SD) ->
    do_process(Method, undefined, uas, UAS, SD).

do_process('INVITE', undefined, _Type, UAS, SD) ->
    reply({internal_error, <<"INVITE without dialog">>}, UAS, SD);

do_process('INVITE', DialogId, Type, #trans{cancel=Cancelled}=UAS, SD) ->
    case Type of uas -> app_call(invite, [DialogId], UAS, SD); proxy -> ok end,
    UAS1 = start_timer(expire, UAS),
    SD1 = update(UAS1, SD),
    case Cancelled of
        true -> cancel(launch, UAS1, SD1);
        false -> SD1
    end;

do_process('ACK', DialogId, Type, UAS, SD) ->
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    case DialogId of
        undefined -> ?call_notice("received out-of-dialog ACK", [], SD);
        _ when Type=:=uas -> app_cast(ack, [DialogId], UAS, SD);
        _ -> ok
    end,
    update(UAS1, SD);

do_process('BYE', DialogId, Type, UAS, SD) ->
    case DialogId of
        undefined -> 
            reply(no_transaction, UAS, SD);
        _ when Type=:=uas ->
            app_call(bye, [DialogId], UAS, SD),
            SD;
        _ ->
            SD
    end;

do_process('OPTIONS', _DialogId, Type, UAS, SD) ->
    case Type of uas -> app_call(options, [], UAS, SD); _ -> ok end,
    SD;

do_process('REGISTER', _DialogId, Type, UAS, SD) ->
    case Type of uas -> app_call(register, [], UAS, SD); _ -> ok end,
    SD;

do_process('CANCEL', _DialogId, _Type, UAS, SD) ->
    case is_cancel(UAS, SD) of
        {true, InvUAS} ->
            case InvUAS of
                #trans{status=Status}=InvUAS ->
                    if
                        Status=:=authorize; Status=:=route ->
                            {_, SD1} = send_reply(ok, UAS, SD),
                            InvUAS1 = InvUAS#trans{cancel=true},
                            update(InvUAS1, SD1);
                        Status=:=invite_proceeding ->
                            {_, SD1} = send_reply(ok, UAS, SD),
                            cancel(launch, InvUAS, SD1);
                        true ->
                            reply(no_transaction, UAS, SD)
                    end
            end;
        false ->
            reply(no_transaction, UAS, SD)
    end;

do_process(_, _DialogId, UAS, uas, #call{app_id=AppId}=SD) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, UAS, SD);

do_process(_, _DialogId, _UAS, proxy, SD) ->
    SD.


cancel(launch, UAS, SD) ->
    app_call(cancel, [], UAS, SD),
    SD;

cancel({reply, Reply}, #trans{status=Status}=UAS, SD) ->
    case Reply of
        true when Status=:=invite_proceeding ->
            reply(request_terminated, UAS, SD);
        _ -> 
            SD
    end.


%% ===================================================================
%% Reply
%% ===================================================================


reply(SipReply, UAS, SD) ->
    {_, SD1} = send_reply(SipReply, UAS, SD),
    SD1.

send_reply(SipReply, UAS, SD) ->
    #trans{
        id = Id, 
        status = Status, 
        method = Method,
        request = Req,
        stateless = Stateless
    } = UAS,
    case 
        Status=:=send_100 orelse Status=:=authorize orelse Status=:=route orelse 
        Status=:=invite_proceeding orelse Status=:=trying orelse 
        Status=:=proceeding
    of
        true ->
            case nksip_transport_uas:send_response(Req, SipReply) of
                {ok, Resp} -> ok;
                error -> Resp = nksip_reply:reply(Req, service_unavailable)
            end,
            #sipmsg{response=Code} = Resp,
            case Stateless of
                true ->
                    ?call_debug("UAS ~p ~p stateless reply ~p", [Id, Method, Code], SD),
                    UAS1 = UAS#trans{status=finished},
                    {{ok, Resp}, update(UAS1, SD)};
                false ->
                    ?call_debug("UAS ~p ~p stateful reply ~p", [Id, Method, Code], SD),
                    {Resp1, SD1} = nksip_call_lib:add_msg(Resp, false, SD),
                    UAS1 = UAS#trans{response=Resp1, code=Code},
                    SD2 = nksip_call_dialog_uas:response(UAS1, SD1),
                    UAS2 = do_reply(Method, Code, UAS1),
                    {{ok, Resp}, update(UAS2, SD2)}
            end;
        false ->
            ?call_info("UAS ~p ~p cannot send ~p response in ~p", 
                       [Id, Method, SipReply, Status], SD),
            {{error, invalid}, SD}
    end.


do_reply('INVITE', Code, UAS) when Code < 200 ->
    UAS;

do_reply('INVITE', Code, UAS) when Code < 300 ->
    #trans{id=Id, request=Req, response=Resp} = UAS,
    UAS1 = case Id < 0 of
        true -> 
            % In old-style transactions, save Id to be used in
            % detecting ACKs
            #sipmsg{to_tag=ToTag} = Resp,
            ACKTrans = transaction_id(Req#sipmsg{to_tag=ToTag}),
            UAS#trans{ack_trans_id=ACKTrans};
        _ ->
            UAS
    end,
    UAS2 = cancel_timers([timeout], UAS1#trans{request=undefined, response=undefined}),
    % RFC6026 accepted state, to wait for INVITE retransmissions
    % Dialog will send 2xx retransmissions
    start_timer(timer_l, UAS2#trans{status=invite_accepted});

do_reply('INVITE', Code, UAS) when Code >= 300 ->
    #trans{proto=Proto} = UAS,
    UAS1 = cancel_timers([timeout], UAS),
    UAS2 = start_timer(timer_h, UAS1#trans{request=undefined, status=invite_completed}),
    case Proto of 
        udp -> 
            start_timer(timer_g, UAS2);
        _ -> 
            UAS2#trans{response=undefined}
    end;

do_reply(_, Code, UAS) when Code < 200 ->
    UAS#trans{status=proceeding};

do_reply(_, Code, UAS) when Code >= 200 ->
    #trans{proto=Proto} = UAS,
    UAS1 = cancel_timers([timeout], UAS),
    case Proto of
        udp -> 
            UAS2 =  UAS1#trans{request=undefined, status=completed},
            start_timer(timer_j, UAS2);
        _ -> 
            UAS1#trans{status=finished}
    end.


%% ===================================================================
%% Timers
%% ===================================================================


timer(timeout, #trans{id=Id, method=Method}=UAS, SD) ->
    ?call_notice("UAS ~p ~p timeout, no SipApp response", [Id, Method], SD),
    reply({internal_error, <<"No SipApp response">>}, UAS, SD);

% INVITE 3456xx retrans
timer(timer_g, #trans{id=Id, response=Resp}=UAS, SD) ->
    #sipmsg{response=Code} = Resp,
    UAS1 = case nksip_trasport_uas:resend_response(Resp) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", 
                       [Id, Code], SD),
            start_timer(timer_g, UAS);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p response", 
                         [Id, Code], SD),
            cancel_timers([timeout], UAS#trans{status=finished})
    end,
    update(UAS1, SD);

% INVITE accepted finished
timer(timer_l, #trans{id=Id}=UAS, SD) ->
    ?call_debug("UAS ~p 'INVITE' Timer L fired", [Id], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, SD);

% INVITE confirmed finished
timer(timer_i, #trans{id=Id}=UAS, SD) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, SD);

% NoINVITE completed finished
timer(timer_j, #trans{id=Id, method=Method}=UAS, SD) ->
    ?call_debug("UAS ~p ~p Timer J fired", [Id, Method], SD),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, SD);

% INVITE completed timeout
timer(timer_h, #trans{id=Id}=UAS, SD) ->
    ?call_notice("UAS ~p 'INVITE' timeout (Timer H) fired, no ACK received", 
                [Id], SD),
    UAS1 = cancel_timers([timeout, retrans], UAS#trans{status=finished}),
    update(UAS1, SD);

timer(expire, UAS, SD) ->
    case UAS of
        #trans{status=invite_proceeding} -> process(cancel, UAS, SD);
        _ -> SD
    end.




%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), #trans{}, #call{}) ->
    ok.

app_call(Fun, Args, UAS, SD) ->
    #trans{id=TransId, request=#sipmsg{id=ReqId}} = UAS,
    #call{app_id=AppId, call_id=CallId} = SD,
    FullReqId = {req, AppId, CallId, ReqId},
    From = {'fun', nksip_call_router, sipapp_reply, [AppId, CallId, Fun, TransId]},
    nksip_sipapp_srv:sipapp_call_async(AppId, Fun, Args++[FullReqId], From).


%% @private
-spec app_cast(atom(), list(), #trans{}, #call{}) ->
    ok.

app_cast(Fun, Args, UAS, SD) ->
    #trans{request=#sipmsg{id=ReqId}} = UAS,
    #call{app_id=AppId, call_id=CallId} = SD,
    FullReqId = {req, AppId, CallId, ReqId},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, Args++[FullReqId]).



%% @doc Checks if `Request' is an ACK matching an existing transaction
%% (for a non 2xx response)
is_trans_ack(#sipmsg{method='ACK'}=Req, #call{trans=Trans}) ->
    TransId = transaction_id(Req#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS -> 
            {true, UAS};
        false when TransId < 0 ->
            % Pre-RFC3261 style
            case lists:keyfind(TransId, #trans.ack_trans_id, Trans) of
                {true, UAS} -> {true, UAS};
                _ -> false
            end;
        false ->
            false
    end;

is_trans_ack(_, _) ->
    false.


is_retrans(Req, #call{trans=Trans}) ->
    TransId = transaction_id(Req),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS -> {true, UAS};
        _ -> {false, TransId}
    end.


is_cancel(#trans{request=CancelReq}, #call{trans=Trans}=SD) -> 
    TransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas, request=InvReq} = InvUAS ->
            #sipmsg{transport=#transport{remote_ip=CancelIp, remote_port=CancelPort}} =
                CancelReq,
            #sipmsg{transport=#transport{remote_ip=InvIp, remote_port=InvPort}} =
                InvReq,
            if
                CancelIp=:=InvIp, CancelPort=:=InvPort ->
                    {true, InvUAS};
                true ->
                    ?call_notice("UAS ~p rejecting CANCEL because it came from ~p:~p, "
                                 "INVITE came from ~p:~p", 
                                 [TransId, CancelIp, CancelPort, InvIp, InvPort], SD),
                    false
            end;
        false ->
            ?call_debug("received unknown CANCEL", [], SD),
            false
    end;
is_cancel(_, _) ->
    false.


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
            erlang:phash2({AppId, CallId, Method, ViaIp, ViaPort, Branch});
        _ ->
            % pre-RFC3261 style
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            -erlang:phash2({AppId, UriIp, UriPort, FromTag, ToTag, CallId, CSeq, 
                            Method, ViaIp, ViaPort})
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
    erlang:phash2({AppId, CallId, FromTag, CSeq, CSeqMethod}).



