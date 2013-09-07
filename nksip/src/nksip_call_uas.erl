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

-export([request/2, timer/3, app_reply/4, fork_reply/3, sync_reply/4]).
-export_type([status/0, id/0]).
-import(nksip_call_lib, [update/2, new_sipmsg/3, update_sipmsg/2, 
                         timeout_timer/2, retrans_timer/2, expire_timer/2, 
                         cancel_timers/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-type status() ::  authorize | route | ack |
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed | finished.

-type id() :: integer().

-type trans() :: nksip_call:trans().

-type call() :: nksip_call:call().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Called when a new request is received
-spec request(nksip:request(), call()) ->
    #call{}.

request(Req, Call) -> 
    case is_trans_ack(Req, Call) of
        {true, UAS} -> 
            process_trans_ack(UAS, Call);
        false ->
            case is_retrans(Req, Call) of
                {true, UAS} ->
                    process_retrans(UAS, Call);
                {false, TransId} ->
                    case nksip_uas_lib:preprocess(Req) of
                        own_ack -> Call;
                        Req1 -> do_request(Req1, TransId, Call)
                    end
            end
    end.


%% @private
-spec process_trans_ack(trans(), call()) ->
    call().

process_trans_ack(UAS, Call) ->
    #trans{id=Id, status=Status, proto=Proto, cancel=Cancel} = UAS,
    case Status of
        invite_completed ->
            UAS1 = cancel_timers([retrans, timeout], UAS#trans{response=undefined}),
            UAS2 = case Proto of 
                udp -> 
                    timeout_timer(timer_i, UAS1#trans{status=invite_confirmed});
                _ when Cancel=:=cancelled ->
                    timeout_timer(wait_sipapp, UAS1#trans{status=invite_confirmed});
                _ -> 
                    UAS1#trans{status=finished}
            end,
            ?call_debug("UAS ~p received in-transaction ACK", [Id], Call),
            update(UAS2, Call);
        _ ->
            ?call_notice("UAS ~p received non 2xx ACK in ~p", [Id, Status], Call),
            Call
    end.


%% @private
-spec process_retrans(trans(), call()) ->
    call().

process_retrans(UAS, Call) ->
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
                               [Id, Method, Status, Code], Call);
                error ->
                    ?call_info("UAS ~p ~p (~p) could not send ~p retransmission", 
                               [Id, Method, Status, Code], Call)
            end;
        _ ->
            ?call_info("UAS ~p ~p received retransmission in ~p", 
                       [Id, Method, Status], Call)
    end,
    Call.


%% ===================================================================
%% App/Fork reply
%% ===================================================================


%% @private Called by a fork when it has a response available
-spec fork_reply(id(), nksip:response(), call()) ->
    call().

fork_reply(TransId, Reply, Call) ->
    app_reply(fork, TransId, Reply, Call).


%% @private Called by {@nksip_call_router} when there is a SipApp response available
-spec app_reply(atom(), id(), nksip:sipreply(), call()) ->
    call().

app_reply(Fun, TransId, Reply, #call{trans=Trans}=Call) ->
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas, status=Status}=UAS ->
            do_app_reply(Fun, Status, Reply, UAS, Call);
        _ ->
            ?call_notice("Unknown UAS ~p received unexpected reply ~p",
                          [TransId, {Fun, Reply}], Call),
            Call
    end.


%% @private
-spec do_app_reply(atom(), atom(), term(), trans(), call()) ->
    call().

do_app_reply(Fun, finished, Reply, #trans{id=Id, method=Method}, Call) ->
    ?call_info("UAS ~p ~p received reply ~p in finished", 
               [Id, Method, {Fun, Reply}], Call),
    Call;

do_app_reply(authorize, authorize, Reply, UAS, Call) ->
    authorize_reply(Reply, UAS, Call);

do_app_reply(route, route, Reply, UAS, Call) ->
    route_reply(Reply, UAS, Call);

do_app_reply(cancel, _, Reply, UAS, Call) ->
    cancel_reply(Reply, UAS, Call);

do_app_reply(Fun, Status, Reply, UAS, Call)
             when Fun=:=invite; Fun=:=bye; Fun=:=options; Fun=:=register; Fun=:=fork ->
    #trans{id=Id, method=Method, cancel=Cancel} = UAS,
    if
        Status=:=invite_proceeding; Status=:=trying; Status=:=proceeding ->
            reply(Reply, UAS, Call);
        Status=:=invite_completed; Status=:=invite_confirmed ->
            case Cancel of
                cancelled ->
                    ?call_debug("UAS ~p ~p (cancelled) discarding reply ~p in ~p",
                                [Id, Method, {Fun, Reply}, Status], Call),
                    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
                    update(UAS1, Call);
                _ ->
                    ?call_info("UAS ~p ~p received reply ~p in ~p",
                                [Id, Method, {Fun, Reply}, Status], Call),
                    Call
            end;
        true ->
           ?call_info("UAS ~p ~p received unexpected reply ~p in ~p",
                       [Id, Method, {Fun, Reply}, Status], Call),
           Call
    end.


% @doc Sends a syncrhonous request reply
-spec sync_reply(nksip:sipreply(), trans(), from(), call()) ->
    call().

sync_reply(Reply, UAS, From, Call) ->
    {Result, Call1} = send_reply(Reply, UAS, Call),
    gen_server:reply(From, Result),
    Call1.




%% ===================================================================
%% Request cycle
%% ===================================================================

%% @private
-spec do_request(nksip:request(), id(), call()) ->
    call().

do_request(Req, TransId, Call) ->
    #sipmsg{opts=Opts} = Req,
    #call{trans=Trans} = Call,
    {Req1, Call1} = new_sipmsg(Req, false, Call),
    #sipmsg{id=MsgId, method=Method, ruri=RUri, transport=Transp} = Req1,
    LoopId = loop_id(Req1),
    UAS = #trans{
        class = uas,
        id = TransId, 
        status = authorize,
        start = nksip_lib:timestamp(),
        from = none,
        request = Req1#sipmsg{opts=Opts},
        method = Method,
        ruri = RUri,
        proto = Transp#transport.proto,
        opts = Opts,
        stateless = true,
        response = undefined,
        code = 0,
        loop_id = LoopId,
        cancel = undefined
    },
    UAS1 = timeout_timer(timeout, UAS),
    Call2 = Call1#call{trans=[UAS1|Trans]},
    ?call_debug("UAS ~p received SipMsg ~p (~p)", [TransId, MsgId, Method], Call2),
    case lists:keymember(LoopId, #trans.loop_id, Trans) of
        true -> reply(loop_detected, UAS1, Call2);
        false when Method=:='INVITE' -> send_100(UAS1, Call2);
        false -> authorize_launch(UAS1, Call2)
    end.


%% @private 
-spec send_100(trans(), call()) ->
    call().

send_100(UAS, Call) ->
    #trans{id=Id, method=Method, request=Req, opts=Opts} = UAS,
    case Method=:='INVITE' andalso (not lists:member(no_100, Opts)) of 
        true ->
            case nksip_transport_uas:send_response(Req, 100) of
                {ok, _} -> 
                    authorize_launch(UAS, Call);
                error ->
                    ?call_notice("UAS ~p ~p could not send '100' response", 
                                 [Id, Method], Call),
                    reply(service_unavailable, UAS, Call)
            end;
        false -> 
            authorize_launch(UAS, Call)
    end.
        

%% @private
-spec authorize_launch(trans(), call()) ->
    call().

authorize_launch(#trans{request=Req, id=Id, method=Method}=UAS, Call) ->
    IsDialog = case nksip_call_dialog_uas:is_authorized(Req, Call) of
        true -> dialog;
        false -> []
    end,
    IsRegistered = case nksip_registrar:is_registered(Req) of
        true -> register;
        false -> []
    end,
    IsDigest = nksip_auth:get_authentication(Req),
    Auth = lists:flatten([IsDialog, IsRegistered, IsDigest]),
    ?call_debug("UAS ~p ~p calling authorize: ~p", [Id, Method, Auth],Call),
    app_call(authorize, [Auth], UAS, Call),
    Call.


%% @private
-spec authorize_reply(term(), trans(), call()) ->
    call().

authorize_reply(Reply, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_debug("UAS ~p ~p authorize reply: ~p", [Id, Method, Reply], Call),
    case Reply of
        ok -> route_launch(UAS, Call);
        true -> route_launch(UAS, Call);
        false -> reply(forbidden, UAS, Call);
        authenticate -> reply(authenticate, UAS, Call);
        {authenticate, Realm} -> reply({authenticate, Realm}, UAS, Call);
        proxy_authenticate -> reply(proxy_authenticate, UAS, Call);
        {proxy_authenticate, Realm} -> reply({proxy_authenticate, Realm}, UAS, Call);
        Other -> reply(Other, UAS, Call)
    end.


%% @private
-spec route_launch(trans(), call()) -> 
    call().

route_launch(#trans{id=Id, method=Method, ruri=RUri}=UAS, Call) ->
    #uri{scheme=Scheme, user=User, domain=Domain} = RUri,
    ?call_debug("UAS ~p ~p calling route", [Id, Method], Call),
    app_call(route, [Scheme, User, Domain], UAS, Call),
    update(UAS#trans{status=route}, Call).


%% @private
-spec route_reply(term(), trans(), call()) ->
    call().

route_reply(Reply, UAS, Call) ->
    #trans{id=Id, method=Method, ruri=RUri, request=Req} = UAS,
    ?call_debug("UAS ~p ~p route reply: ~p", [Id, Method, Reply], Call),
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
    Call1 = update(UAS1, Call),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_sipmsg:header(Req, <<"Require">>, tokens) of
                [] -> 
                    do_route(Route, UAS1, Call1);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    reply({bad_extension,  RequiresTxt}, UAS1, Call1)
            end;
        _ ->
            do_route(Route, UAS1, Call1)
    end.


%% @private
-spec do_route({response, nksip:sipreply(), nksip_lib:proplist()} |
               {process, nksip_lib:proplist()} |
               {proxy, nksip:uri_set(), nksip_lib:proplist()} |
               {strict_proxy, nksip_lib:proplist()}, trans(), call()) -> 
    call().

do_route({response, Reply, Opts}, UAS, Call) ->
    UAS1 = UAS#trans{stateless=lists:member(stateless, Opts)},
    reply(Reply, UAS1, update(UAS1, Call));

do_route({process, Opts}, #trans{request=Req}=UAS, Call) ->
    UAS1 = UAS#trans{stateless=lists:member(stateless, Opts)},
    UAS2 = case nksip_lib:get_value(headers, Opts, []) of
        [] -> 
            UAS1;
        Headers1 -> 
            #sipmsg{headers=Headers} = Req,
            UAS1#trans{request=Req#sipmsg{headers=Headers1++Headers}}
    end,
    process(UAS2, uas, update(UAS2, Call));

% We want to proxy the request
do_route({proxy, UriList, Opts}, UAS, Call) ->
    case nksip_call_proxy:start(UAS, UriList, Opts, Call) of
        {stateless, Call1} ->
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call1);
        {stateful, {fork, ForkId}, Call1} ->
            UAS1 = UAS#trans{from={fork, ForkId}, stateless=false},
            process(UAS1, fork, update(UAS1, Call1));
        SipReply ->
            reply(SipReply, UAS, Call)
    end;


% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
do_route({strict_proxy, Opts}, #trans{request=Req}=UAS, Call) ->
    case Req#sipmsg.routes of
       [Next|_] ->
            ?call_info("strict routing to ~p", [Next], Call),
            do_route({proxy, Next, [stateless|Opts]}, UAS, Call);
        _ ->
            reply({internal_error, <<"Invalid Srict Routing">>}, UAS, Call)
    end.


%% @private 
-spec process(trans(), uas|fork, call()) ->
    call().

process(#trans{stateless=false, opts=Opts}=UAS, Type, Call) ->
    #trans{id=Id, method=Method} = UAS,
    case nksip_call_dialog_uas:request(UAS, Call) of
        {ok, DialogId, Call1} -> 
            % Caution: for first INVITEs, DialogId is not yet created!
            ?call_debug("UAS ~p ~p dialog id: ~p", [Id, Method, DialogId], Call),
            do_process(Method, DialogId, Type, UAS, Call1);
        {error, Error} when Method=/='ACK' ->
            Reply = case Error of
                proceeding_uac ->
                    request_pending;
                proceeding_uas -> 
                    {500, [{<<"Retry-After">>, crypto:rand_uniform(0, 11)}], 
                                <<>>, [{reason, <<"Processing Previous INVITE">>}]};
                old_cseq ->
                    {internal_error, <<"Old CSeq in Dialog">>};
                _ ->
                    ?call_info("UAS ~p ~p dialog request error: ~p", 
                                [Id, Method, Error], Call),
                    no_transaction
            end,
            reply(Reply, UAS#trans{opts=[no_dialog|Opts]}, Call);
        {error, Error} when Method=:='ACK' ->
            ?call_notice("UAS ~p 'ACK' dialog request error: ~p", [Id, Error], Call),
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call)
    end;

process(#trans{method=Method}=UAS, uas, Call) ->
    do_process(Method, undefined, uas, UAS, Call).


%% @private
-spec do_process(nksip:method(), nksip_dialog:id()|undefined, uas|fork, 
                 trans(), call()) ->
    call().

do_process('INVITE', undefined, _Type, UAS, Call) ->
    reply({internal_error, <<"INVITE without dialog">>}, UAS, Call);

do_process('INVITE', DialogId, Type, #trans{cancel=Cancelled}=UAS, Call) ->
    #call{app_id=AppId, call_id=CallId} = Call,
    case Type of uas -> 
        app_call(invite, [{dlg, AppId, CallId, DialogId}], UAS, Call); 
        _ -> ok 
    end,
    UAS1 = expire_timer(expire, UAS),
    Call1 = update(UAS1, Call),
    case Cancelled of
        cancelled -> cancel_launch(Type, UAS1, Call1);
        undefined -> Call1
    end;

do_process('ACK', DialogId, Type, UAS, Call) ->
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    #call{app_id=AppId, call_id=CallId} = Call,
    case DialogId of
        undefined -> 
            ?call_notice("received out-of-dialog ACK", [], Call);
        _ when Type=:=uas -> 
            app_cast(ack, [{dlg, AppId, CallId, DialogId}], UAS, Call);
        _ -> 
            ok
    end,
    update(UAS1, Call);

do_process('BYE', DialogId, Type, UAS, Call) ->
    #call{app_id=AppId, call_id=CallId} = Call,
    case DialogId of
        undefined -> 
            reply(no_transaction, UAS, Call);
        _ when Type=:=uas ->
            app_call(bye, [{dlg, AppId, CallId, DialogId}], UAS, Call),
            Call;
        _ ->
            Call
    end;

do_process('OPTIONS', _DialogId, Type, UAS, Call) ->
    case Type of uas -> app_call(options, [], UAS, Call); _ -> ok end,
    Call;

do_process('REGISTER', _DialogId, Type, UAS, Call) ->
    case Type of uas -> app_call(register, [], UAS, Call); _ -> ok end,
    Call;

do_process('CANCEL', _DialogId, Type, UAS, Call) ->
    case is_cancel(UAS, Call) of
        {true, InvUAS} ->
            case InvUAS of
                #trans{status=Status}=InvUAS ->
                    if
                        Status=:=authorize; Status=:=route ->
                            {_, Call1} = send_reply(ok, UAS, Call),
                            InvUAS1 = InvUAS#trans{cancel=cancelled},
                            update(InvUAS1, Call1);
                        Status=:=invite_proceeding ->
                            {_, Call1} = send_reply(ok, UAS, Call),
                            cancel_launch(Type, InvUAS, Call1);
                        true ->
                            reply(no_transaction, UAS, Call)
                    end
            end;
        false ->
            reply(no_transaction, UAS, Call)
    end;

do_process(_Method, _DialogId, uas, UAS, #call{app_id=AppId}=Call) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, UAS, Call);

do_process(_Method, _DialogId, fork, _UAS, Call) ->
    Call.


%% @private
-spec cancel_launch(uas|fork, trans(), call()) ->
    call().

cancel_launch(uas, UAS, Call) ->
    app_call(cancel, [], UAS, Call),
    Call; 

cancel_launch(fork, #trans{from={from, ForkId}}, Call) ->
    nksip_call_fork:cancel(ForkId, Call).


%% @private
-spec cancel_reply(term(), trans(), call()) ->
    call().

cancel_reply(Reply, UAS, Call) ->
    case Reply of
        true -> terminate_request(UAS, Call);
        _ -> Call
    end.


%% ===================================================================
%% Response Reply
%% ===================================================================

%% @private Sends a transaction reply
-spec reply(nksip:response()|nksip:sipreply(), trans(), call()) ->
    call().

reply(SipReply, UAS, Call) ->
    {_, Call1} = send_reply(SipReply, UAS, Call),
    Call1.


%% @private Sends a transaction reply
-spec send_reply(nksip:response()|nksip:sipreply(), trans(), call()) ->
    {{ok, nksip:response()} | {error, invalid_call}, call()}.

send_reply(_, #trans{code=487}, Call) ->
    {{error, invalid_call}, Call};

send_reply(Reply, #trans{method='ACK',id=Id, status=Status}, Call) ->
    ?call_notice("UAC ~p 'ACK' (~p) trying to send a reply ~p", 
                 [Id, Status, Reply], Call),
    {{error, invalid_call}, Call};

send_reply(#sipmsg{response=Code}=Resp, UAS, Call) ->
    #trans{
        id = Id, 
        status = Status, 
        method = Method,
        request = Req,
        stateless = Stateless,
        opts = Opts
    } = UAS,
    case 
        Status=:=authorize orelse Status=:=route orelse 
        Status=:=invite_proceeding orelse Status=:=trying orelse 
        Status=:=proceeding
    of
        true ->
            case nksip_transport_uas:send_response(Resp) of
                {ok, Resp1} -> ok;
                error -> Resp1 = nksip_reply:reply(Req, service_unavailable)
            end,
            #sipmsg{response=Code1} = Resp1,
            {Resp2, Call1} = new_sipmsg(Resp1, false, Call),
            UAS1 = UAS#trans{response=Resp2, code=Code},
            case Stateless of
                true when Method=/='INVITE' ->
                    ?call_debug("UAS ~p ~p stateless reply ~p", 
                                [Id, Method, Code1], Call),
                    UAS2 = cancel_timers([timeout], UAS1#trans{status=finished}),
                    {{ok, Resp2}, update(UAS2, Call1)};
                _ ->
                    ?call_debug("UAS ~p ~p stateful reply ~p", 
                                [Id, Method, Code1], Call),
                    Call2 = case lists:member(no_dialog, Opts) of
                        true -> Call1;
                        false -> nksip_call_dialog_uas:response(UAS1, Call1)
                    end,
                    UAS2 = do_reply(Method, Code1, UAS1),
                    {{ok, Resp2}, update(UAS2, Call2)}
            end;
        false ->
            ?call_info("UAS ~p ~p cannot send ~p response in ~p", 
                       [Id, Method, Code, Status], Call),
            {{error, invalid_call}, Call}
    end;

send_reply(SipReply, #trans{request=#sipmsg{}=Req}=UAS, Call) ->
    send_reply(nksip_reply:reply(Req, SipReply), UAS, Call);

send_reply(SipReply, #trans{id=Id, method=Method, status=Status}, Call) ->
    ?call_info("UAS ~p ~p cannot send ~p response in ~p", 
               [Id, Method, SipReply, Status], Call),
    {{error, invalid_call}, Call}.



%% @private
-spec do_reply(nksip:method(), nksip:response_code(), trans()) ->
    trans().

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
    UAS2 = UAS1#trans{request=undefined, response=undefined},
    UAS3 = cancel_timers([timeout, expire], UAS2),
    % RFC6026 accepted state, to wait for INVITE retransmissions
    % Dialog will send 2xx retransmissions
    timeout_timer(timer_l, UAS3#trans{status=invite_accepted});

do_reply('INVITE', Code, UAS) when Code >= 300 ->
    #trans{proto=Proto} = UAS,
    UAS1 = cancel_timers([timeout, expire], UAS),
    UAS2 = timeout_timer(timer_h, UAS1#trans{request=undefined, status=invite_completed}),
    case Proto of 
        udp -> 
            retrans_timer(timer_g, UAS2);
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
            timeout_timer(timer_j, UAS2);
        _ -> 
            UAS1#trans{status=finished}
    end.


%% @private
-spec terminate_request(trans(), call()) ->
    call().

terminate_request(#trans{status=Status}=UAS, Call) ->
    if 
        Status=:=authorize; Status=:=route ->
            % SipApp callback has not been called yet
            reply(request_terminated, UAS, Call);
        Status=:=invite_proceeding ->
            % Setting cancel=cancelled will make wait for SipApp response after ACK
            reply(request_terminated, UAS#trans{cancel=cancelled}, Call);
        true ->
            Call
    end.




%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), trans(), call()) ->
    call().

timer(timeout, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p timeout, no SipApp response", [Id, Method], Call),
    reply({internal_error, <<"No SipApp response">>}, UAS, Call);

timer(wait_sipapp, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p (cancelled) timeout, no SipApp response", [Id, Method], Call),
    update(UAS#trans{status=terminated}, Call);

% INVITE 3456xx retrans
timer(timer_g, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{response=Code} = Resp,
    UAS1 = case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", 
                       [Id, Code], Call),
            retrans_timer(timer_g, UAS);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p response", 
                         [Id, Code], Call),
            cancel_timers([timeout], UAS#trans{status=finished})
    end,
    update(UAS1, Call);

% INVITE accepted finished
timer(timer_l, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer L fired", [Id], Call),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE confirmed finished
timer(timer_i, #trans{id=Id, cancel=Cancel}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id], Call),
    UAS1 = case Cancel of
        cancelled -> timeout_timer(wait_sipapp, UAS);
        _ -> cancel_timers([timeout], UAS#trans{status=finished})
    end,
    update(UAS1, Call);

% NoINVITE completed finished
timer(timer_j, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_debug("UAS ~p ~p Timer J fired", [Id, Method], Call),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE completed timeout
timer(timer_h, #trans{id=Id}=UAS, Call) ->
    ?call_notice("UAS ~p 'INVITE' timeout (Timer H) fired, no ACK received", 
                [Id], Call),
    UAS1 = cancel_timers([timeout, retrans], UAS#trans{status=finished}),
    update(UAS1, Call);

timer(expire, #trans{id=Id, method=Method, status=Status}=UAS, Call) ->
    ?call_debug("UAS ~p ~p (~p) expire timer timeout: sending 487",
                [Id, Method, Status], Call),
    terminate_request(UAS, Call).




%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), trans(), call()) ->
    ok.

app_call(Fun, Args, UAS, Call) ->
    #trans{id=TransId, request=#sipmsg{id=ReqId}} = UAS,
    #call{app_id=AppId, call_id=CallId} = Call,
    FullReqId = {req, AppId, CallId, ReqId},
    From = {'fun', nksip_call_router, app_reply, [AppId, CallId, Fun, TransId]},
    nksip_sipapp_srv:sipapp_call_async(AppId, Fun, Args++[FullReqId], From).


%% @private
-spec app_cast(atom(), list(), trans(), call()) ->
    ok.

app_cast(Fun, Args, UAS, Call) ->
    #trans{request=#sipmsg{id=ReqId}} = UAS,
    #call{app_id=AppId, call_id=CallId} = Call,
    FullReqId = {req, AppId, CallId, ReqId},
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, Args++[FullReqId]).



%% @doc Checks if `Req' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(nksip:request(), call()) ->
    {true, trans()} | false.

 is_trans_ack(#sipmsg{method='ACK'}=Req, #call{trans=Trans}) ->
    TransId = transaction_id(Req#sipmsg{method='INVITE'}),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS -> 
            {true, UAS};
        false when TransId < 0 ->
            % Pre-RFC3261 style
            case lists:keyfind(TransId, #trans.ack_trans_id, Trans) of
                #trans{}=UAS -> {true, UAS};
                false -> false
            end;
        false ->
            false
    end;

is_trans_ack(_, _) ->
    false.


%% @doc Checks if `Req' is a retransmission
-spec is_retrans(nksip:request(), call()) ->
    {true, trans()} | {false, integer()}.

is_retrans(Req, #call{trans=Trans}) ->
    TransId = transaction_id(Req),
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS -> {true, UAS};
        _ -> {false, TransId}
    end.


%% @doc Finds the INVITE transaction belonging to a CANCEL transaction
-spec is_cancel(trans(), call()) ->
    {true, trans()} | false.

is_cancel(#trans{method='CANCEL', request=CancelReq}, #call{trans=Trans}=Call) -> 
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
                                 [TransId, CancelIp, CancelPort, InvIp, InvPort], Call),
                    false
            end;
        false ->
            ?call_debug("received unknown CANCEL", [], Call),
            false
    end;

is_cancel(_, _) ->
    false.


%% @private
-spec transaction_id(nksip:request()) ->
    integer().
    
transaction_id(Req) ->
        #sipmsg{
            app_id = AppId, 
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


%% @privaye
-spec loop_id(nksip:request()) ->
    integer().
    
loop_id(Req) ->
    #sipmsg{
        app_id = AppId, 
        from_tag = FromTag, 
        call_id = CallId, 
        cseq = CSeq, 
        cseq_method = CSeqMethod
    } = Req,
    erlang:phash2({AppId, CallId, FromTag, CSeq, CSeqMethod}).



