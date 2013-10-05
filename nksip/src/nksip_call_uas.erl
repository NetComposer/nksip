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

%% @doc Call UAS Management
-module(nksip_call_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/2, timer/3, app_reply/4, fork_reply/3, send_reply/4]).
-export_type([status/0, id/0]).
-import(nksip_call_lib, [update/2, update_auth/2,
                         timeout_timer/3, retrans_timer/3, expire_timer/3, 
                         app_timer/3, cancel_timers/2]).

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

%% @doc Called when a new request is received.
-spec request(nksip:request(), call()) ->
    #call{}.

request(Req, #call{opts=#call_opts{global_id=GlobalId}}=Call) -> 
    case is_trans_ack(Req, Call) of
        {true, UAS} -> 
            process_trans_ack(UAS, Call);
        false ->
            case is_retrans(Req, Call) of
                {true, UAS} ->
                    process_retrans(UAS, Call);
                {false, ReqTransId} ->
                    case nksip_uas_lib:preprocess(Req, GlobalId) of
                        own_ack -> Call;
                        Req1 -> do_request(Req1, ReqTransId, Call)
                    end
            end
    end.


%% @private
-spec process_trans_ack(trans(), call()) ->
    call().

process_trans_ack(UAS, Call) ->
    #trans{id=Id, status=Status, proto=Proto} = UAS,
    case Status of
        invite_completed ->
            UAS1 = cancel_timers([retrans, timeout], UAS#trans{response=undefined}),
            UAS2 = case Proto of 
                udp -> 
                    timeout_timer(timer_i, UAS1#trans{status=invite_confirmed}, Call);
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



%% @private Called by {@link nksip_call_router} when there is a SipApp response available
-spec app_reply(atom(), id(), nksip:sipreply(), call()) ->
    call().

app_reply(Fun, Id, Reply, #call{trans=Trans}=Call) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uas}=UAS when Fun=:=ignore ->
            UAS1 = cancel_timers([app], UAS),
            update(UAS1, Call);
        #trans{class=uas, app_timer={Fun, _}, request=Req}=UAS ->
            UAS1 = cancel_timers([app], UAS),
            Call1 = update(UAS1, Call),
            case Fun of
                authorize -> 
                    authorize_reply(Reply, UAS1, Call1);
                route -> 
                    route_reply(Reply, UAS1, Call1);
                ack ->
                    Call1;
                _ when not is_record(Req, sipmsg) ->
                    Call1;
                _ when Fun=:=invite; Fun=:=bye; Fun=:=options; Fun=:=register ->
                    {Resp, Opts} = nksip_reply:reply(Req, Reply),
                    {Resp1, Opts1} = case Resp#sipmsg.response >= 200 of
                        true -> 
                            {Resp, Opts};
                        false -> 
                            Reply1 = {internal_error, <<"Invalid SipApp reply">>},
                            nksip_reply:reply(Req, Reply1)
                    end,
                    reply({Resp1, Opts1}, UAS1, Call1)
            end;
        _ ->
            ?call_debug("Unknown UAS ~p received SipApp ~p reply",
                        [Id, Fun], Call),
            Call
    end.



%% @private Called by a fork when it has a response available.
-spec fork_reply(id(), {nksip:response(), nksip_lib:proplist()}, call()) ->
    call().

fork_reply(TransId, Reply, #call{trans=Trans}=Call) ->
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            reply(Reply, UAS, Call);
        _ ->
            ?call_debug("Unknown UAS ~p received fork reply",
                        [TransId], Call),
            Call
    end.


% @doc Sends a syncrhonous request reply
-spec send_reply(nksip:sipreply(), trans(), {srv, from()}|none, call()) ->
    call().

send_reply(Reply, UAS, From, Call) ->
    {Result, Call1} = send_reply(Reply, UAS, Call),
    case From of
        {srv, SrvFrom} -> gen_server:reply(SrvFrom, Result);
        _ -> ok
    end,
    Call1.




%% ===================================================================
%% Request cycle
%% ===================================================================

%% @private
-spec do_request(nksip:request(), id(), call()) ->
    call().

do_request(Req, TransId, #call{trans=Trans, next=Id, msgs=Msgs}=Call) ->
    #sipmsg{id=MsgId, method=Method, ruri=RUri, to_tag=ToTag, transport=Transp} = Req,
    ?call_debug("UAS ~p started for ~p (~s)", [Id, Method, MsgId], Call),
    LoopId = loop_id(Req),
    UAS = #trans{
        id = Id,
        class = uas,
        status = authorize,
        opts = [],
        start = nksip_lib:timestamp(),
        from = undefined,
        trans_id = TransId, 
        request = Req,
        method = Method,
        ruri = RUri,
        proto = Transp#transport.proto,
        stateless = true,
        response = undefined,
        code = 0,
        loop_id = LoopId
    },
    UAS1 = case Method of
        'INVITE' -> timeout_timer(timer_c, UAS, Call);
        'ACK' -> UAS;
        _ -> timeout_timer(noinvite, UAS, Call)
    end,
    Msg = {MsgId, Id, nksip_dialog:id(Req)},
    Call1 = Call#call{trans=[UAS1|Trans], next=Id+1, msgs=[Msg|Msgs]},
    case ToTag=:=(<<>>) andalso lists:keymember(LoopId, #trans.loop_id, Trans) of
        true -> reply(loop_detected, UAS1, Call1);
        false -> send_100(UAS1, Call1)
    end.


%% @private 
-spec send_100(trans(), call()) ->
    call().

send_100(UAS, #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}}=Call) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    case Method=:='INVITE' andalso (not lists:member(no_100, AppOpts)) of 
        true ->
            case nksip_transport_uas:send_user_response(Req, 100, GlobalId, AppOpts) of
                {ok, _} -> 
                    check_cancel(UAS, Call);
                error ->
                    ?call_notice("UAS ~p ~p could not send '100' response", 
                                 [Id, Method], Call),
                    reply(service_unavailable, UAS, Call)
            end;
        false -> 
            check_cancel(UAS, Call)
    end.
        

%% @private
-spec check_cancel(trans(), call()) ->
    call().

check_cancel(#trans{id=Id}=UAS, Call) ->
    case is_cancel(UAS, Call) of
        {true, #trans{id=InvId, status=Status}=InvUAS} ->
            ?call_debug("UAS ~p matched 'CANCEL' as ~p (~p)", 
                        [Id, InvId, Status], Call),
            if
                Status=:=authorize; Status=:=route; Status=:=invite_proceeding ->
                    Call1 = reply(ok, UAS, Call),
                    terminate_request(InvUAS, Call1);
                true ->
                    reply(no_transaction, UAS, Call)
            end;
        false ->
            % Only for case of stateless proxy
            authorize_launch(UAS, Call)
    end.


%% @private
-spec authorize_launch(trans(), call()) ->
    call().

authorize_launch(#trans{request=Req}=UAS, Call) ->
    IsDialog = case nksip_call_lib:check_auth(Req, Call) of
        true -> dialog;
        false -> []
    end,
    IsRegistered = case nksip_registrar:is_registered(Req) of
        true -> register;
        false -> []
    end,
    IsDigest = nksip_auth:get_authentication(Req),
    Auth = lists:flatten([IsDialog, IsRegistered, IsDigest]),
    app_call(authorize, [Auth], UAS, Call).


%% @private
-spec authorize_reply(term(), trans(), call()) ->
    call().

authorize_reply(Reply, #trans{status=authorize}=UAS, Call) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    ?call_debug("UAS ~p ~p authorize reply: ~p", [Id, Method, Reply], Call),
    case Reply of
        ok -> route_launch(UAS, update_auth(Req, Call));
        true -> route_launch(UAS, update_auth(Req, Call));
        false -> reply(forbidden, UAS, Call);
        authenticate -> reply(authenticate, UAS, Call);
        {authenticate, Realm} -> reply({authenticate, Realm}, UAS, Call);
        proxy_authenticate -> reply(proxy_authenticate, UAS, Call);
        {proxy_authenticate, Realm} -> reply({proxy_authenticate, Realm}, UAS, Call);
        Other -> reply(Other, UAS, Call)
    end;

% Request has been already answered (i.e. cancelled)
authorize_reply(_Reply, UAS, Call) ->
    update(UAS, Call).



%% @private
-spec route_launch(trans(), call()) -> 
    call().

route_launch(#trans{ruri=RUri}=UAS, Call) ->
    UAS1 = UAS#trans{status=route},
    #uri{scheme=Scheme, user=User, domain=Domain} = RUri,
    app_call(route, [Scheme, User, Domain], UAS1, update(UAS1, Call)).
    

%% @private
-spec route_reply(term(), trans(), call()) ->
    call().

route_reply(Reply, #trans{status=route}=UAS, Call) ->
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
    end;

% Request has been already answered
route_reply(_Reply, UAS, Call) ->
    update(UAS, Call).


%% @private
-spec do_route({response, nksip:sipreply(), nksip_lib:proplist()} |
               {process, nksip_lib:proplist()} |
               {proxy, nksip:uri_set(), nksip_lib:proplist()} |
               {strict_proxy, nksip_lib:proplist()}, trans(), call()) -> 
    call().

do_route({response, Reply, Opts}, #trans{method=Method}=UAS, Call) ->
    Stateless = case Method of
        'INVITE' -> false;
        _ -> lists:member(stateless, Opts)
    end,
    UAS1 = UAS#trans{stateless=Stateless},
    reply(Reply, UAS1, update(UAS1, Call));

%% CANCEL should have been processed already
do_route({process, _Opts}, #trans{method='CANCEL'}=UAS, Call) ->
    reply(no_transaction, UAS, Call);

do_route({process, Opts}, #trans{request=Req, method=Method}=UAS, Call) ->
    Stateless = case Method of
        'INVITE' -> false;
        _ -> lists:member(stateless, Opts)
    end,
    UAS1 = UAS#trans{stateless=Stateless},
    UAS2 = case nksip_lib:get_value(headers, Opts) of
        Headers1 when is_list(Headers1) -> 
            #sipmsg{headers=Headers} = Req,
            Req1 = Req#sipmsg{headers=Headers1++Headers},
            UAS1#trans{request=Req1};
        _ -> 
            UAS1
    end,
    process(UAS2, update(UAS2, Call));

% We want to proxy the request
do_route({proxy, UriList, ProxyOpts}, UAS, Call) ->
    #trans{id=Id, opts=Opts, method=Method} = UAS,
    case nksip_call_proxy:check(UAS, UriList, ProxyOpts, Call) of
        stateless_proxy ->
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call);
        {fork, _, _} when Method=:='CANCEL' ->
            reply(no_transaction, UAS, Call);
        {fork, UAS1, UriSet} ->
            % ProxyOpts may include record_route
            % TODO 16.6.4: If ruri or top route has sips, and not received with 
            % tls, must record_route. If received with tls, and no sips in ruri
            % or top route, must record_route also
            UAS2 = UAS1#trans{opts=[no_dialog|Opts], stateless=false, from={fork, Id}},
            UAS3 = case Method of
                'ACK' -> UAS2#trans{status=finished};
                _ -> UAS2
            end,
            nksip_call_fork:start(UAS3, UriSet, ProxyOpts, update(UAS3, Call));
        {reply, SipReply} ->
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
-spec process(trans(), call()) ->
    call().
    
process(#trans{stateless=false, opts=Opts}=UAS, Call) ->
    #trans{id=Id, method=Method, request=Req} = UAS,
    case nksip_call_dialog_uas:request(Req, Call) of
       {ok, DialogId, Call1} -> 
            % Caution: for first INVITEs, DialogId is not yet created!
            do_process(Method, DialogId, UAS, Call1);
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

process(#trans{stateless=true, method=Method}=UAS, Call) ->
    do_process(Method, <<>>, UAS, Call).


%% @private
-spec do_process(nksip:method(), nksip_dialog:id(), trans(), call()) ->
    call().

do_process('INVITE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> ->
            reply(no_transaction, UAS, Call);
        _ ->
            UAS1 = expire_timer(expire, UAS, Call),
            app_call(invite, [], UAS1, update(UAS1, Call))
    end;
    
do_process('ACK', DialogId, UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    case DialogId of
        <<>> -> 
            ?call_notice("received out-of-dialog ACK", [], Call),
            update(UAS1, Call);
        _ -> 
            app_call(ack, [], UAS1, update(UAS1, Call))
    end;

do_process('BYE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> -> reply(no_transaction, UAS, Call);
        _ -> app_call(bye, [], UAS, Call)
    end;

do_process('OPTIONS', _DialogId, UAS, Call) ->
    app_call(options, [], UAS, Call); 

do_process('REGISTER', _DialogId, UAS, Call) ->
    app_call(register, [], UAS, Call); 

do_process(_Method, _DialogId, UAS, #call{app_id=AppId}=Call) ->
    reply({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, UAS, Call).


%% ===================================================================
%% Response Reply
%% ===================================================================

%% @private Sends a transaction reply
-spec reply(nksip:response()|nksip:sipreply(), trans(), call()) ->
    call().

reply(Reply, UAS, Call) ->
    {_, Call1} = send_reply(Reply, UAS, Call),
    Call1.


%% @private Sends a transaction reply
-spec send_reply(nksip:sipreply()|{nksip:response(), nksip_lib:proplist()}, 
                  trans(), call()) ->
    {{ok, nksip:response()} | {error, invalid_call}, call()}.

send_reply(Reply, #trans{method='ACK', id=Id, status=Status}=UAS, Call) ->
    ?call_notice("UAC ~p 'ACK' (~p) trying to send a reply ~p", 
                 [Id, Status, Reply], Call),
    UAS1 = UAS#trans{status=finished},
    {{error, invalid_call}, update(UAS1, Call)};

send_reply(Reply, #trans{status=Status, method=Method}=UAS, Call)
          when Status=:=authorize; Status=:=route ->
    UAS1 = case Method of
        'INVITE' -> UAS#trans{status=invite_proceeding};
        _ -> UAS#trans{status=trying}
    end,
    send_reply(Reply, UAS1, update(UAS1, Call));

send_reply({#sipmsg{id=MsgId, response=Code}=Resp, SendOpts}, 
           #trans{status=Status, code=LastCode}=UAS, 
           #call{msgs=Msgs}=Call)
           when Status=:=invite_proceeding orelse 
                Status=:=trying orelse 
                Status=:=proceeding orelse
                (
                    (
                        Status=:=invite_accepted orelse Status=:=invite_confirmed orelse
                        Status=:=completed
                    ) andalso (
                        Code>=200 andalso Code<300 andalso 
                        LastCode>=200 andalso LastCode<300
                    )
                ) ->

    #trans{
        id = Id, 
        opts = Opts,
        method = Method,
        request = Req,
        stateless = Stateless,
        code = LastCode
    } = UAS,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    case nksip_transport_uas:send_response(Resp, GlobalId, SendOpts++AppOpts) of
        {ok, Resp1} -> ok;
        error -> {Resp1, _} = nksip_reply:reply(Req, service_unavailable)
    end,
    #sipmsg{response=Code1} = Resp1,
    % We could have selected a different proto/ip/port form request
    Call1 = case Code1>=200 andalso Code<300 of
        true -> update_auth(Resp1, Call);
        false -> Call
    end,
    Call2 = case lists:member(no_dialog, Opts) of
        true -> Call;
        false -> nksip_call_dialog_uas:response(Req, Resp1, Call1)
    end,
    UAS1 = case LastCode < 200 of
        true -> UAS#trans{response=Resp1, code=Code};
        false -> UAS
    end,
    Msg = {MsgId, Id, nksip_dialog:id(Resp1)},
    Call3 = Call2#call{msgs=[Msg|Msgs]},
    case Stateless of
        true when Method=/='INVITE' ->
            ?call_debug("UAS ~p ~p stateless reply ~p", 
                        [Id, Method, Code1], Call3),
            UAS2 = cancel_timers([timeout], UAS1#trans{status=finished}),
            {{ok, Resp1}, update(UAS2, Call3)};
        _ ->
            ?call_debug("UAS ~p ~p stateful reply ~p", 
                        [Id, Method, Code1], Call3),
            UAS2 = stateful_reply(Status, Code1, UAS1, Call3),
            {{ok, Resp1}, update(UAS2, Call3)}
    end;

send_reply({#sipmsg{response=Code}, _}, #trans{code=LastCode}=UAS, Call) ->
    #trans{status=Status, id=Id, method=Method} = UAS,
    ?call_info("UAS ~p ~p cannot send ~p response in ~p (last code was ~p)", 
               [Id, Method, Code, Status, LastCode], Call),
    {{error, invalid_call}, Call};

send_reply(SipReply, #trans{request=#sipmsg{}=Req}=UAS, Call) ->
    send_reply(nksip_reply:reply(Req, SipReply), UAS, Call);

send_reply(SipReply, #trans{id=Id, method=Method, status=Status}, Call) ->
    ?call_info("UAS ~p ~p cannot send ~p response in ~p (no stored request)", 
               [Id, Method, SipReply, Status], Call),
    {{error, invalid_call}, Call}.



%% @private
-spec stateful_reply(status(), nksip:response_code(), trans(), call()) ->
    trans().

stateful_reply(invite_proceeding, Code, UAS, Call) when Code < 200 ->
    UAS1 = cancel_timers([timeout], UAS),
    timeout_timer(timer_c, UAS1, Call);

stateful_reply(invite_proceeding, Code, UAS, Call) when Code < 300 ->
    #trans{id=Id, request=Req, response=Resp, app_timer=AppTimer} = UAS,
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
    % If the invite/3 call has not returned, maintain values
    UAS2 = case AppTimer of
        undefined -> UAS1#trans{request=undefined, response=undefined};
        _ -> UAS1
    end,
    UAS3 = cancel_timers([timeout, expire], UAS2),
    % RFC6026 accepted state, to wait for INVITE retransmissions
    % Dialog will send 2xx retransmissionshrl
    timeout_timer(timer_l, UAS3#trans{status=invite_accepted}, Call);

stateful_reply(invite_proceeding, Code, UAS, Call) when Code >= 300 ->
    #trans{proto=Proto, app_timer=AppTimer} = UAS,
    UAS1 = cancel_timers([timeout, expire], UAS#trans{status=invite_completed}),
    UAS2 = case AppTimer of
        undefined -> UAS1#trans{request=undefined};
        _ -> UAS1
    end,
    UAS3 = timeout_timer(timer_h, UAS2, Call),
    case Proto of 
        udp -> 
            retrans_timer(timer_g, UAS3, Call);
        _ -> 
            UAS3#trans{response=undefined}
    end;

stateful_reply(trying, Code, UAS, Call) ->
    stateful_reply(proceeding, Code, UAS#trans{status=proceeding}, Call);

stateful_reply(proceeding, Code, UAS, _Call) when Code < 200 ->
    UAS;

stateful_reply(proceeding, Code, UAS, Call) when Code >= 200 ->
    #trans{proto=Proto, app_timer=AppTimer} = UAS,
    UAS1 = cancel_timers([timeout], UAS#trans{request=undefined, status=completed}),
    case Proto of
        udp -> 
            UAS2 = case AppTimer of
                undefined ->  UAS1#trans{request=undefined};
                _ -> UAS1
            end,
            timeout_timer(timer_j, UAS2, Call);
        _ -> 
            UAS1#trans{status=finished}
    end;

stateful_reply(_, _Code, UAS, _Call) ->
    UAS.



%% @private
-spec terminate_request(trans(), call()) ->
    call().

terminate_request(#trans{status=Status, from=From}=UAS, Call) ->
    if 
        Status=:=authorize; Status=:=route ->
            case From of
                {fork, _ForkId} -> ok;
                _ -> app_cast(cancel, [], UAS, Call)
            end,
            UAS1 = UAS#trans{cancel=cancelled},
            reply(request_terminated, UAS1, update(UAS1, Call));
        Status=:=invite_proceeding ->
            case From of
                {fork, ForkId} -> 
                    nksip_call_fork:cancel(ForkId, Call);
                _ -> 
                    app_cast(cancel, [], UAS, Call),
                    UAS1 = UAS#trans{cancel=cancelled},
                    reply(request_terminated, UAS, update(UAS1, Call))
            end;
        true ->
            Call
    end.


%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), trans(), call()) ->
    call().

timer(timer_c, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p Timer C fired", [Id, Method], Call),
    reply({timeout, <<"Timer C Timeout">>}, UAS, Call);

timer(noinvite, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p No-INVITE timer fired", [Id, Method], Call),
    reply({timeout, <<"No-INVITE Timeout">>}, UAS, Call);

% INVITE 3456xx retrans
timer(timer_g, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{response=Code} = Resp,
    UAS1 = case nksip_transport_uas:resend_response(Resp) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", 
                       [Id, Code], Call),
            retrans_timer(timer_g, UAS, Call);
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
timer(timer_i, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id], Call),
    UAS1 = cancel_timers([timeout], UAS#trans{status=finished}),
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
    ?call_debug("UAS ~p ~p (~p) Timer Expire fired: sending 487",
                [Id, Method, Status], Call),
    terminate_request(UAS, Call);

timer(Timer, #trans{id=Id, method=Method}=UAS, Call)
      when Timer=:=authorize; Timer=:=route; Timer=:=invite; Timer=:=bye;
           Timer=:=options; Timer=:=register ->
    UAS1 = cancel_timers([app], UAS),
    ?call_notice("UAS ~p ~p timeout, no SipApp response", [Id, Method], Call),
    reply({internal_error, <<"No SipApp Response">>}, UAS1, update(UAS1, Call)).


%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec app_call(atom(), list(), trans(), call()) ->
    call().

app_call(Fun, Args, UAS, Call) ->
    #trans{id=Id, request=Req, method=Method, status=Status} = UAS,
    #call{app_id=AppId, call_id=CallId} = Call,
    #sipmsg{id=ReqId} = Req,
    ?call_debug("UAS ~p ~p (~p) calling SipApp's ~p ~p", 
               [Id, Method, Status, Fun, Args], Call),
    From = {'fun', nksip_call, app_reply, [AppId, CallId, Fun, Id]},
    nksip_sipapp_srv:sipapp_call_async(AppId, Fun, Args++[ReqId], From),
    UAS1 = app_timer(Fun, UAS, Call),
    update(UAS1, Call).


%% @private
-spec app_cast(atom(), list(), trans(), call()) ->
    call().

app_cast(Fun, Args, UAS, Call) ->
    #trans{id=Id, request=Req, method=Method, status=Status} = UAS,
    #call{app_id=AppId} = Call,
    #sipmsg{id=ReqId} = Req,
    ?call_debug("UAS ~p ~p (~p) casting SipApp's ~p ~p", 
                [Id, Method, Status, Fun, Args], Call),
    nksip_sipapp_srv:sipapp_cast(AppId, Fun, Args++[ReqId]),
    Call.



%% @doc Checks if `Req' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(nksip:request(), call()) ->
    {true, trans()} | false.

 is_trans_ack(#sipmsg{method='ACK'}=Req, #call{trans=Trans}) ->
    ReqTransId = transaction_id(Req#sipmsg{method='INVITE'}),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> 
            {true, UAS};
        false when ReqTransId < 0 ->
            % Pre-RFC3261 style
            case lists:keyfind(ReqTransId, #trans.ack_trans_id, Trans) of
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
    ReqTransId = transaction_id(Req),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> {true, UAS};
        _ -> {false, ReqTransId}
    end.


%% @doc Finds the INVITE transaction belonging to a CANCEL transaction
-spec is_cancel(trans(), call()) ->
    {true, trans()} | false.

is_cancel(#trans{method='CANCEL', request=CancelReq}, #call{trans=Trans}=Call) -> 
    ReqTransId = transaction_id(CancelReq#sipmsg{method='INVITE'}),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{id=Id, class=uas, request=InvReq} = InvUAS ->
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
                                 [Id, CancelIp, CancelPort, InvIp, InvPort], Call),
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


%% @private
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



