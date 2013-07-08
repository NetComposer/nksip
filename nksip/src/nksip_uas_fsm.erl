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

%% @doc UAS process FSM
-module(nksip_uas_fsm).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_fsm).

-export([start/1, reply/2]).
-export([init/2, authorize/2, route/2, process/2, cancel/2, cancelled/2]).
-export([init/1, terminate/3, handle_event/3, handle_info/3, 
            handle_sync_event/4, code_change/4]).

-include("nksip.hrl").

-define(CALLBACK_TIMEOUT, 30000).

%% ===================================================================
%% Private
%% ===================================================================


-record(state, {
    req :: nksip:request(),
    core_module :: atom(),
    core_pid :: pid(),
    transaction_pid :: pid(),
    cancel_pid :: pid(),
    timer :: reference(),
    timer_100 :: reference()
}).


-type statename() :: init | authorize | route | process.

-type fsm_out() :: {next_state, statename(), #state{}} |
                   {next_state, statename(), #state{}, integer()} | 
                   {stop, term(), #state{}}.

%% @doc Sends a reply to an already started UAS FSM.
-spec reply(pid(), nksip:sipreply()) ->
    {ok, nksip:response()} | {error, Error}
    when Error :: network_error | unknown_request | invalid_request.

reply(Pid, SipReply) ->
    case catch gen_fsm:sync_send_all_state_event(Pid, {reply, SipReply}) of
        {ok, Resp} -> {ok, Resp};
        {error, Error} -> {error, Error};
        {'EXIT', _} -> {error, unknown_request}
    end.

%% @doc Starts a new UAS request processing.
-spec start(nksip:request()) ->
    ok.

start(#sipmsg{method='ACK', sipapp_id=AppId, call_id=CallId}=Req) ->
    case nksip_transaction_uas:is_ack(Req) of
        true -> 
            ?debug(AppId, CallId, "UAS received ACK is for transaction", []),
            ok;
        false -> 
            launch(Req)
    end;

start(#sipmsg{method=Method, sipapp_id=AppId, call_id=CallId}=Req) ->
    case nksip_transaction_uas:is_retrans(Req) of
        true -> 
            ?debug(AppId, CallId, "UAS received ~p is retransmission", [Method]),
            ok;
        false -> 
            launch(Req)
    end.


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec launch(nksip:request()) ->
    ok.

launch(#sipmsg{sipapp_id=AppId}=Req) ->
    case nksip_sipapp_srv:get_module(AppId) of
        {Module, Pid} ->
            case nksip_uas_lib:preprocess(Req) of
                {ok, Req1} -> 
                    SD = #state{
                        req = Req1#sipmsg{pid=self()},
                        core_module = Module,
                        core_pid = Pid
                    },
                    gen_fsm:enter_loop(?MODULE, [], init, SD, 0);
                ignore -> 
                    % It is an own-generated ACK without transaction
                    ok
            end;
        not_found ->
            Reply = {internal_error, "Unknown SipApp"},
            nksip_transport_uas:send_response(Req, Reply),
            ok
    end.


%% ===================================================================
%% gen_fsm
%% ===================================================================

% @private Only to match gen_fsm beahaviour
init([]) ->
    {stop, not_used}.


%% @private
-spec init(timeout, #state{}) -> 
    fsm_out().

init(timeout, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, method=Method, call_id=CallId,
            auth=Auth, start=Start, opts=Opts} = Req,
    nksip_counters:async([nksip_msgs, nksip_uas_fsm]),
    nksip_sipapp_srv:register(AppId, uas_fsm),
    ?debug(AppId, CallId, "UAS FSM started for ~p: ~p", [Method, self()]),
    case nksip_transaction_uas:is_loop(Req) of
        true -> 
            stop(loop_detected, SD);
        false when Method=:='ACK' ->
            nksip_trace:insert(Req, ack_authorize),
            corecall(authorize, [Auth], SD),
            start_timer(authorize, SD);
        false ->
            nksip_trace:insert(Req, authorize),
            case lists:member(no_100, Opts) of 
                false ->
                    Elapsed = round((nksip_lib:l_timestamp()-Start)/1000),
                    case 100 - Elapsed of
                        Time when Time > 0 -> 
                            Timer100 = gen_fsm:start_timer(Time, timer_100);
                        _ -> 
                            Timer100 = undefined,
                            send_reply(100, SD)
                    end;
                true ->
                    Timer100 = undefined
            end,
            corecall(authorize, [Auth], SD),
            start_timer(authorize, SD#state{timer_100=Timer100})
    end.


%% @private
-spec authorize(timeout | {reply, term()}, #state{}) -> 
    fsm_out().

authorize({timeout, _, authorize}, SD) ->
    stop(core_error, SD);

authorize({timeout, _, timer_100}, SD) ->
    send_reply(100, SD),
    {next_state, authorize, SD};

authorize({reply, Reply}, #state{req=#sipmsg{method=Method, to_tag=ToTag}=Req}=SD) ->
    nksip_trace:insert(Req, authorize_reply),
    Stop = fun(Reason) ->
        if
            % If we are going to send a non 2xx response to an INVITE belonging
            % to a valid dialog, start a transaction to detect and absorb the ACK.
            % If not, the ACK will not be absorbed (its to tag is not known to us)
            % and it will go to the user
            Method =:= 'INVITE', ToTag =/= <<>> ->
                case nksip_dialog:field(state, Req) of
                    error -> 
                        stop(Reason, SD);
                    _ -> 
                        Pid = nksip_transaction_uas:start(Req),
                        stop(Reason, SD#state{transaction_pid=Pid})
                end;
            true ->
                stop(Reason, SD)
        end
    end,
    case Reply of
        ok -> route(launch, SD);
        true -> route(launch, SD);
        false -> Stop(forbidden);
        authenticate -> Stop(authenticate);
        {authenticate, Realm} -> Stop({authenticate, Realm});
        proxy_authenticate -> Stop(proxy_authenticate);
        {proxy_authenticate, Realm} -> Stop({proxy_authenticate, Realm});
        Other -> Stop(Other)
    end.


%% @private
-spec route(launch | timeout | {reply, term()} | 
            {response, nksip:sipreply(), nksip_lib:proplist()} |
            {process, nksip_lib:proplist()} |
            {proxy, nksip:uri_set(), nksip_lib:proplist()} |
            {strict_proxy, nksip_lib:proplist()}, #state{}) -> fsm_out().

route(launch, #state{req=#sipmsg{ruri=RUri}=Req}=SD) ->
    nksip_trace:insert(Req, route),
    corecall(route, [RUri#uri.scheme, RUri#uri.user, RUri#uri.domain], SD),
    start_timer(route, SD);

route({timeout, _, route}, SD) ->
    stop(core_error, SD);

route({timeout, _, timer_100}, SD) ->
    send_reply(100, SD),
    {next_state, route, SD};

route({reply, Reply}, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, method=Method, ruri=RUri} = Req,
    nksip_trace:insert(Req, route_reply),
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
    ?debug(AppId, CallId, "FSM UAS ~p route: ~p", [Method, Route]),
    case Route of
        {process, _} when Method=/='CANCEL', Method=/='ACK' ->
            case nksip_parse:header_tokens(<<"Require">>, Req) of
                [] -> 
                    route(Route, SD);
                Requires -> 
                    RequiresTxt = nksip_lib:bjoin([T || {T, _} <- Requires]),
                    stop({bad_extension,  RequiresTxt}, SD)
            end;
        _ ->
            route(Route, SD)
    end;

route({response, Reply, Opts}, #state{req=Req}=SD) ->
    Pid = case lists:member(stateless, Opts) of
        true -> undefined;
        false -> nksip_transaction_uas:start(Req)
    end,
    stop(Reply, SD#state{transaction_pid=Pid});

route({process, Opts}, #state{req=Req}=SD) ->
    #sipmsg{method=Method, headers=Headers, to_tag=ToTag} = Req,
    Req1 = case nksip_lib:get_value(headers, Opts, []) of
        [] ->  Req;
        Headers1 -> Req#sipmsg{headers=Headers1++Headers}
    end,
    case 
        Method=:='ACK' orelse
        (lists:member(stateless, Opts) andalso ToTag=:=(<<>>) andalso Method=/='INVITE') 
    of
        true ->
            process(launch, SD#state{req=Req1});
        false ->
            Pid = nksip_transaction_uas:start(Req1),
            process(launch, SD#state{req=Req1, transaction_pid=Pid})
    end;

% We want to proxy the request
route({proxy, UriList, Opts}, #state{req=Req}=SD) ->
    case nksip_uas_proxy:proxy(Req, UriList, Opts) of
        ignore -> {stop, normal, SD};
        Reply -> stop(Reply, SD)
    end;

% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
route({strict_proxy, Opts}, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, routes=Routes} = Req,
    case Routes of
        [Next|_] ->
            ?info(AppId, CallId, "strict routing to ~p", [Next]),
            route({proxy, Next, [stateless|Opts]}, SD);
        _ ->
            stop({internal_error, <<"Invalid Srict Routing">>}, SD)
    end.


%% @private
-spec process(launch | timeout | {reply, nksip:sipreply()}, #state{}) ->
    fsm_out().

% Process for INVITEs or in-dialog requests
process(launch, #state{req=#sipmsg{method=Method, to_tag=ToTag}=Req}=SD) 
        when Method=:='INVITE'; ToTag=/=(<<>>) ->
    nksip_trace:insert(Req, launch_dialog),
    #sipmsg{sipapp_id=AppId, call_id=CallId}=Req,
    DialogId = nksip_dialog:id(Req),
    case nksip_dialog_uas:request(Req) of
        ok ->
            nksip_trace:insert(Req, {uas_dialog_request_ok, Method}),
            nksip_queue:remove(Req), % Allow new requests
            case Method of
                'INVITE' -> 
                    corecall(invite, [DialogId], SD),
                    case nksip_parse:header_integers(<<"Expires">>, Req) of
                        [Expires|_] when Expires > 0 -> 
                            gen_fsm:start_timer(1000*Expires+100, timer_expire);
                        _ ->
                            ok
                    end,
                    start_timer(process, SD);
                'ACK' ->
                    % Wait for user response to give time to read headers, etc.
                    corecall(ack, [DialogId], SD),
                    start_timer(process, SD);
                'BYE' ->
                    corecall(bye, [DialogId], SD),
                    start_timer(process, SD);
                'OPTIONS' ->
                    corecall(options, [], SD),
                    start_timer(process, SD);
                'REGISTER' ->
                    corecall(register, [], SD),
                    start_timer(process, SD);
                _ ->
                    stop({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD)
            end;
        {error, invalid_dialog} when Method=:='ACK' ->
            {stop, normal, SD};
        {error, Error} ->
            ?notice(AppId, CallId, "UAS ~p dialog request error ~p", [Method, Error]),
            Stop = case Error of
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
            stop(Stop, SD)
    end;

process(launch, #state{req=Req}=SD) ->
    #sipmsg{method=Method, sipapp_id=AppId, call_id=CallId} = Req,
    nksip_trace:insert(Req, launch_no_dialog),
    nksip_queue:remove(Req), % Allow new requests
    case Method of
        'CANCEL' ->
            case nksip_transaction_uas:is_cancel(Req) of
                {true, InvPid} ->
                    send_reply(ok, SD),
                    corecall(cancel, [], SD),
                    start_timer(cancel, SD#state{cancel_pid=InvPid});
                false ->
                    ?debug(AppId, CallId, "received unknown CANCEL", []),
                    stop(no_transaction, SD);
                invalid ->
                    ?info(AppId, CallId, "received invalid CANCEL", []),
                    stop(no_transaction, SD)
            end;
        'ACK' ->
            ?notice(AppId, CallId, "received out-of-dialog ACK", []),
            {stop, normal, SD};
        'BYE' ->
            stop(no_transaction, SD);
        'OPTIONS' ->
            corecall(options, [], SD),
            start_timer(process, SD);
        'REGISTER' ->
            corecall(register, [], SD),
            start_timer(process, SD);
        _ ->
            stop({method_not_allowed, nksip_sipapp_srv:allowed(AppId)}, SD)
    end;

process({timeout, _, process}, SD) ->
    stop(core_error, SD);

process({timeout, _, timer_100}, SD) ->
    send_reply(100, SD),
    {next_state, process, SD};

process({timeout, _, timer_expire}, SD) ->
    process_reply(request_terminated, SD),
    {next_state, cancelled, SD};

process({reply, _}, #state{req=#sipmsg{method='ACK'}=Req}=SD) ->
    nksip_trace:insert(Req, reply_ack),
    {stop, normal, SD};

process({reply, Reply}, #state{req=#sipmsg{sipapp_id=AppId, call_id=CallId}}=SD) ->
    ?debug(AppId, CallId, "UAS FSM replied ~p", [Reply]),
    case process_reply(Reply, SD) of
        {ok, #sipmsg{response=Code}} when Code < 200 -> start_timer(process, SD);
        _ -> {stop, normal, SD}
    end.


%% @private
cancel({timeout, _, cancel}, SD) ->
    {stop, normal, SD};

cancel({reply, Reply}, #state{cancel_pid=Pid}=SD) ->
    case Reply of
        true -> gen_fsm:send_all_state_event(Pid, cancelled);
        _ -> ok
    end,
    {stop, normal, SD}.


%% @private
cancelled({timeout, _, process}, SD) ->
    {stop, normal, SD};
    
cancelled({timeout, _, _}, SD) ->
    {next_state, cancelled, SD};

cancelled({reply, _}, SD) ->
    {stop, normal, SD}.


%% @private
handle_sync_event({reply, SipReply}, From, process, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
    ?debug(AppId, CallId, "UAS FSM replied sync ~p", [SipReply]),
    case process_reply(SipReply, SD) of
        {ok, #sipmsg{response=Code}=Resp} when Code < 200 -> 
            gen_fsm:reply(From, {ok, Resp}),
            start_timer(process, SD);
        {ok, Resp} ->
            gen_fsm:reply(From, {ok, Resp}),
            {stop, normal, SD};
        error ->
            {reply, error, process, SD}
    end;

handle_sync_event({reply, _SipReply}, _From, StateName, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
    ?warning(AppId, CallId, "UAS FSM received reply in ~p", [StateName]),
    {reply, {error, invalid_request}, StateName, SD};

handle_sync_event(get_sipmsg, _From, StateName, #state{req=Req}=SD) ->
    {reply, Req, StateName, SD};

handle_sync_event({get_fields, Fields}, _From, StateName, #state{req=Req}=SD) ->
    {reply, nksip_sipmsg:fields(Fields, Req), StateName, SD};

handle_sync_event({get_headers, Name}, _From, StateName, #state{req=Req}=SD) ->
    {reply, nksip_sipmsg:headers(Name, Req), StateName, SD};

handle_sync_event(Msg, _From, StateName, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_event(cancelled, process, SD) ->
    process_reply(request_terminated, SD),
    % Enter in cancelled (for the remaining timer's time) to wait SipApp's response
    {next_state, cancelled, SD};

handle_event(cancelled, StateName, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
    case StateName of
        cancelled -> ok;
        _ -> ?notice(AppId, CallId, "UAS FSM received cancelled in ~p", [StateName])
    end,
    {next_state, StateName, SD};

handle_event(Msg, StateName, SD) ->
    lager:error("Module ~p received unexpected event: ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_info(Info, StateName, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p (~p)", 
        [?MODULE, Info, StateName]),
    {next_state, StateName, FsmData}.


%% @private
code_change(_OldVsn, StateName, FsmData, _Extra) -> 
    {ok, StateName, FsmData}.


%% @private
terminate(_Reason, _StateName, #state{req=#sipmsg{sipapp_id=AppId, call_id=CallId}}) ->
    ?debug(AppId, CallId, "UAS FSM stopped", []),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec corecall(atom(), list(), #state{}) ->
    ok.

corecall(Fun, Args, #state{core_module=Module, core_pid=CorePid}) ->
    Self = self(),
    ReqId = {req, Self},
    nksip_sipapp_srv:sipapp_call_async(CorePid, Module, Fun, Args++[ReqId], {fsm, reply, Self}).


%% @private
start_timer(StateName, SD) ->
    start_timer(StateName, StateName, ?CALLBACK_TIMEOUT, SD).


%% @private
start_timer(StateName, Name, Time, SD) ->
    nksip_lib:cancel_timer(SD#state.timer),
    Timer = gen_fsm:start_timer(Time, Name),
    {next_state, StateName, SD#state{timer=Timer}}.


%% @private
-spec stop(nksip:sipreply(), #state{}) ->
    {stop, normal, #state{}}.

stop(Reply, SD) ->
    case Reply of
        core_error -> send_reply({internal_error, <<"Error Calling SipApp">>}, SD);
        _ -> send_reply(Reply, SD)
    end,
    {stop, normal, SD}.


%% @private
-spec process_reply(nksip:sipreply(), #state{}) ->
    {ok, nksip:response()} | error.

process_reply(Reply, #state{req=Req, timer_100=Timer100}=SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, method=Method} = Req,
    nksip_lib:cancel_timer(Timer100),
    nksip_trace:insert(Req, {uas_user_reply, Method, Reply}),
    Return = send_reply(Reply, SD),
    case Return of
        {ok, Resp} -> ok;
        error -> Resp = nksip_reply:reply(Req, 503)
    end,
    case nksip_dialog_uas:response(Req, Resp) of
        ok ->
            ?debug(AppId, CallId, "UAS FSM dialog response ok", []),
            ok;
        {error, Error} ->
            ?notice(AppId, CallId, "UAS FSM ~p dialog response error ~p", 
                [Method, Error])
    end,
    Return.


%% @private
-spec send_reply(nksip:sipreply() | nksip:response(), #state{}) ->
    {ok, nksip:response()} | error.

send_reply(Reply, #state{req=#sipmsg{sipapp_id=AppId, call_id=CallId, method='ACK'}}) ->
    ?notice(AppId, CallId, "UAS FSM tried to reply ~p to ACK", [Reply]),
    error;

send_reply(#sipmsg{}=Resp, #state{transaction_pid=Pid}) ->
    case nksip_transport_uas:send_response(Resp) of
        {ok, #sipmsg{response=Code}=Resp1} when is_pid(Pid), Code > 100 -> 
            nksip_transaction_uas:response(Pid, Resp1),
            {ok, Resp1};
        {ok, Resp1} ->
            {ok, Resp1};
        error when is_pid(Pid) ->
            nksip_transaction_uas:stop(Pid),
            error;
        error ->
            error
    end;

send_reply(Reply, #state{req=Req}=SD) ->
    send_reply(nksip_reply:reply(Req, Reply), SD).


