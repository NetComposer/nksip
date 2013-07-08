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

%% @doc UAC Transaction FSM

-module(nksip_transaction_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_fsm).

-export([total/0, total/1, start/1, stop/1]).
-export([request/2, response/1]).
-export([wait_request/2, 
         invite_calling/2, invite_proceeding/2, invite_accepted/2, invite_completed/2, 
         trying/2, proceeding/2, completed/2]).
-export([init/1, terminate/3, handle_event/3, handle_info/3, 
            handle_sync_event/4, code_change/4]).

-include("nksip.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets the total number of active UAC transactions
-spec total() -> 
    integer().

total() ->
    nksip_counters:value(nksip_transactions_uac).


%% @doc Gets the total number of active UAC transactions for a SipApp
-spec total(nksip:sipapp_id()) -> 
    integer().

total(AppId) -> 
    nksip_counters:value({nksip_transactions_uac, AppId}).


%% @private Starts a new UAC Transaction for a 'Request'. 
-spec start(nksip:request()) ->
    pid().

start(#sipmsg{sipapp_id=AppId, call_id=CallId}=Req) ->
    TransId = transaction_id(Req),
    Name = {nksip_transaction_uac, TransId},
    case nksip_proc:start(fsm, Name, ?MODULE, [AppId, CallId, TransId]) of
        {ok, Pid} ->
            Pid;
        {error, {already_started, Pid}} ->
            ?notice(AppId, CallId, "UAC Trans ~p already started", [Pid]),
            Pid
    end.

        
%% @private
-spec stop(pid()) -> 
    ok.

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).


%% @private
-spec request(nksip:request(), function()) ->
    ok | no_transaction.

request(Req, Fun) when is_function(Fun, 1) ->
    case nksip_proc:whereis_name({nksip_transaction_uac, transaction_id(Req)}) of
        undefined -> no_transaction;
        Pid -> gen_fsm:send_event(Pid, {request, Req, Fun})
    end.


%% @private Called from nksip_transport_uac to check if an incoming response
%% belongs to a current transaction
-spec response(nksip:response()) ->
    ok | no_transaction.

response(#sipmsg{sipapp_id=AppId, call_id=CallId}=Resp) ->
    TransId = transaction_id(Resp),
    case nksip_proc:whereis_name({nksip_transaction_uac, TransId}) of
        undefined -> 
            ?debug(AppId, CallId, "transaction ~s not found", [TransId]),
            no_transaction;
        Pid -> 
            gen_fsm:send_event(Pid, {response, Resp})
    end.


%% ===================================================================
%% gen_fsm
%% ===================================================================


-record(state, {
    sipapp_id :: nksip:sipapp_id(),
    call_id :: nksip:call_id(),
    proto :: nksip:protocol(),
    request :: nksip:request(),
    respfun :: function(),
    retrans_timer :: reference(),
    next_retrans :: nksip_lib:timestamp(),
    timeout_timer :: reference(),
    tags :: [binary()],                  % Received To tags
    responses :: [nksip:response()]
}).


%% @private
init([AppId, CallId, TransId]) ->
    nksip_counters:async([nksip_transactions_uac, {nksip_transactions_uac, AppId}]),
    nksip_sipapp_srv:register(AppId, transaction_uac),
    SD = #state{
        sipapp_id = AppId,
        call_id = CallId,
        tags = [],
        responses = []
    },
    ?debug(AppId, CallId, "UAC Trans ~s started (~p)", [TransId, self()]),
    {ok, wait_request, SD, 60000}.


%%% ------ INVITE FSM ------------------------------------------------


%% @private
wait_request({request, Req, RespFun}, #state{responses=Responses}=SD) ->
    #sipmsg{method=Method, transport=#transport{proto=Proto}}=Req,
    lists:foreach(fun(Resp) -> response(Resp) end, Responses),
    SD1 = SD#state{proto=Proto, request=Req, respfun=RespFun, responses=[]},
    T1 = nksip_config:get(timer_t1), 
    case Method of
        'INVITE' when Proto=:=udp ->
            SD2 = SD1#state{
                retrans_timer = gen_fsm:start_timer(T1, timer_a),
                next_retrans = 2*T1,
                timeout_timer = gen_fsm:start_timer(64*T1, timer_b)},
            {next_state, invite_calling, SD2};
        'INVITE' ->
            SD2 = SD1#state{timeout_timer=gen_fsm:start_timer(64*T1, timer_b)},
            {next_state, invite_calling, SD2};
        _ when Proto=:=udp -> 
            T2 = nksip_config:get(timer_t2), 
            SD2 = SD1#state{
                retrans_timer = gen_fsm:start_timer(T1, timer_e),
                next_retrans = min(2*T1, T2),
                timeout_timer = gen_fsm:start_timer(64*T1, timer_f)
            },
            {next_state, trying, SD2};
        _ -> 
            SD2 = SD1#state{timeout_timer=gen_fsm:start_timer(64*T1, timer_f)},
            {next_state, trying, SD2}
    end;

wait_request({response, Resp}, #state{responses=Responses}=SD) ->
    {next_state, wait_request, SD#state{responses=[Resp|Responses]}, 60000};

wait_request(timeout, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?error(AppId, CallId, "UAC Trans Wait Request Timeout", []),
    {stop, normal, SD}.



%% @private
invite_calling({response, Resp}, SD) ->
    #state{retrans_timer=TimerA, timeout_timer=TimeoutTimer} = SD,
    nksip_lib:cancel_timer(TimerA),
    nksip_lib:cancel_timer(TimeoutTimer),
    Timeout = 1000 * nksip_config:get(ringing_timeout),
    SD1 = SD#state{timeout_timer=gen_fsm:start_timer(Timeout, timer_invite)},
    invite_proceeding({response, Resp}, SD1);

invite_calling({timeout, _, timer_a}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=Req, next_retrans=Next} = SD,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} -> 
            ?info(AppId, CallId, 
                  "UAC Trans resending INVITE in invite_calling", []),
            SD1 = SD#state{
                retrans_timer = gen_fsm:start_timer(Next, timer_a),
                next_retrans = 2 * Next
            },
            {next_state, invite_calling, SD1};
        error ->
            ?info(AppId, CallId, 
                  "UAC Trans could not resend INVITE in invite_calling", []),
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            reply(Resp, SD),
            {stop, normal, SD}
    end;

invite_calling({timeout, _, timer_b}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=Req} = SD,
    ?notice(AppId, CallId, "UAC Trans Timer B timeout in invite_calling", []),
    Resp = nksip_reply:error(Req, 408, <<"Timer B Timeout Calling State">>),
    reply(Resp, SD),
    {stop, normal, SD}.


%% @private
invite_proceeding({response, Resp}, SD) ->
    #sipmsg{response=Code, to_tag=ToTag} = Resp,
    #state{proto=Proto, timeout_timer=TimeoutTimer, tags=Tags} = SD,
    reply(Resp, SD),
    SD1 = SD#state{tags=[ToTag|Tags]},
    if
        Code < 200 -> 
            {next_state, invite_proceeding, SD1};
        Code < 300 ->
            % In TCP we can also receive 200 retransmissions, if the ACK is not 
            % sent inmediatly
            nksip_lib:cancel_timer(TimeoutTimer), 
            T1 = nksip_config:get(timer_t1), 
            SD2 = SD1#state{
                request = undefined,
                timeout_timer=gen_fsm:start_timer(64*T1, timer_m)
            },
            {next_state, invite_accepted, SD2, hibernate};
        true ->
            nksip_lib:cancel_timer(TimeoutTimer), 
            SD2 = case Proto of
                udp -> SD1#state{timeout_timer=gen_fsm:start_timer(32*1000, timer_d)};
                _ -> SD1
            end,
            invite_completed({response, Resp}, SD2)
    end;

invite_proceeding({timeout, _, timer_invite}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=Req} = SD,
    ?notice(AppId, CallId, "UAC Trans Timer B timeout in invite_proceeding", []),
    Resp = nksip_reply:error(Req, 408, <<"Timer B Timeout Proceeding State">>),
    reply(Resp, SD),
    {stop, normal, SD}.


%% @private New state per rfc6026, to wait for 2xx secondary responses (due to forking)
%% It is also used to detect 2xx retransmissions, so that the dialog can resend the ACK
invite_accepted({response, Resp}, SD) ->
    #sipmsg{response=Code, to_tag=ToTag, opts=Opts} = Resp,
    #state{sipapp_id=AppId, call_id=CallId, tags=Tags} = SD,
    SD1 = if
        Code < 200 ->
            SD;
        Code < 300 ->
            case lists:member(ToTag, Tags) of
                true ->
                    ?info(AppId, CallId, "UAC Trans received 2xx retransmission in "
                                           "invite_accepted", []),
                    reply(Resp, SD),
                    SD;
                false ->
                    ?info(AppId, CallId, "UAC Trans received secondary 2xx response "
                                           "in invite_accepted", []),
                        reply(Resp#sipmsg{opts=[secondary_response|Opts]}, SD),
                        SD#state{tags=[ToTag|Tags]}
            end;
        true ->
            ?info(AppId, CallId, "UAC Trans received ~p in invite_accepted", [Code]),
            SD
    end,
    {next_state, invite_accepted, SD1};

invite_accepted({timeout, _, timer_m}, SD) ->
    {stop, normal, SD}.


%% @private
invite_completed({response, #sipmsg{response=Code}=Resp}, SD) when Code >= 300 ->
    #state{sipapp_id=AppId, call_id=CallId, proto=Proto, 
           request = #sipmsg{vias=[Via|_]}=Req} = SD,
    AckReq = Req#sipmsg{
        method = 'ACK',
        to = Resp#sipmsg.to,
        vias = [Via],
        cseq_method = 'ACK',
        forwards = 70,
        routes = [],
        contacts = [],
        headers = [],
        content_type = [],
        body = <<>>
    },
    case nksip_transport_uac:resend_request(AckReq) of
        {ok, _} when Proto =:= udp -> 
            {next_state, invite_completed, SD, hibernate};
        {ok, _} ->
            {stop, normal, SD};
        error ->
            ?notice(AppId, CallId, "UAC Trans could not send non-2xx ACK", []),
            {stop, normal, SD}
    end;

invite_completed({response, #sipmsg{response=Code}}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId} = SD,
    ?info(AppId, CallId, "UAC Trans received response ~p in invite_completed", [Code]),
    {next_state, invite_completed, SD, hibernate};

invite_completed({timeout, _, timer_d}, SD) ->
    {stop, normal, SD}.



%%% ------ Non-INVITE FSM ------------------------------------------------


%% @private
trying({response, Resp}, SD) ->
    proceeding({response, Resp}, SD);
    
trying({timeout, _, timer_e}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=#sipmsg{method=Method}=Req, 
           next_retrans=Next} = SD,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} -> 
            ?info(AppId, CallId, "UAC Trans resending ~p in trying", [Method]),
            T2 = nksip_config:get(timer_t2), 
            SD1 = SD#state{
                retrans_timer = gen_fsm:start_timer(Next, timer_e),
                next_retrans = min(2*Next, T2)
            },
            {next_state, trying, SD1};
        error ->
            ?notice(AppId, CallId, "UAC Trans could not resend ~p in trying", [Method]),
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            reply(Resp, SD),
            {stop, normal, SD}
    end;

trying({timeout, _, timer_f}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=Req} = SD,
    ?notice(AppId, CallId, "UAC Trans Timer F timeout in trying", []),
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout Trying State">>),
    reply(Resp, SD),
    {stop, normal, SD}.


%% @private
proceeding({response, Resp}, SD) ->
    #sipmsg{response=Code, to_tag=ToTag} = Resp,
    #state{proto=Proto, retrans_timer=TimerE, timeout_timer=TimerF, tags=Tags} = SD,
    reply(Resp, SD),
    SD1 = SD#state{tags=[ToTag|Tags]},
    if
        Code < 200 ->
            {next_state, proceeding, SD1};
        Proto =:= udp -> 
            nksip_lib:cancel_timer(TimerE),
            nksip_lib:cancel_timer(TimerF),
            T4 = nksip_config:get(timer_t4), 
            gen_fsm:start_timer(T4, timer_k), 
            {next_state, completed, SD1};
        true ->
            {stop, normal, SD1}
    end;

proceeding({timeout, _, timer_e}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=#sipmsg{method=Method}=Req} = SD,
    case nksip_transport_uac:resend_request(Req) of
        {ok, _} -> 
            ?info(AppId, CallId, "UAC Trans resending ~p in proceeding", [Method]),
            T2 = nksip_config:get(timer_t2), 
            TimerE = gen_fsm:start_timer(T2, timer_e),  
            {next_state, proceeding, SD#state{retrans_timer=TimerE}};
        error ->
            ?notice(AppId, CallId, 
                    "UAC Trans could not resend ~p in proceeding", [Method]),
            Resp = nksip_reply:error(Req, 503, <<"Resend Error">>),
            reply(Resp, SD),
            {stop, normal, SD}
    end;

proceeding({timeout, _, timer_f}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId, request=Req} = SD,
    ?notice(AppId, CallId, "UAC Trans Timer F timeout in proceeding"),
    Resp = nksip_reply:error(Req, 408, <<"Timer F Timeout Proceeding State">>),
    reply(Resp, SD),
    {stop, normal, SD}.


%% @private
completed({response, Resp}, SD) ->
    #sipmsg{to_tag=ToTag, cseq_method=Method} = Resp,
    #state{sipapp_id=AppId, call_id=CallId, tags=Tags} = SD,
    case lists:member(ToTag, Tags) of
        false ->
            % Forked response
            ?debug(AppId, CallId, 
                   "UAC Trans ignoring forked response in completed", []),
            {next_state, completed, SD#state{tags=[ToTag|Tags]}};
        true ->
            ?info(AppId, CallId, 
                  "UAC Trans received ~p retransmission in completed", [Method]),
            {next_state, completed, SD}
    end;

completed({timeout, _, timer_k}, SD) ->
    {stop, normal, SD}.



%%% ------ Common ------------------------------------------------


%% @private
handle_sync_event(Msg, _From, StateName, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_event(stop, _StateName, FsmData) ->
    {stop, normal, FsmData};

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
terminate(_Reason, _StateName, #state{sipapp_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, {trans_uac_stop, self()}),
    ?debug(AppId, CallId, "UAC Trans stopped: ~p", [self()]).



%% ===================================================================
%% Internal
%% ===================================================================
    
%% @private
-spec transaction_id(nksip:request()) -> binary().

transaction_id(#sipmsg{sipapp_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    nksip_lib:lhash({AppId, Method, CallId, Branch}).
    % ?debug(AppId, CallId, "UAC TRANS ~s: ~p, ~p, ~p, ~p", [Id, AppId, Method, CallId, Branch]),


%% @private
-spec reply(nksip:response(), #state{}) ->
    ok.

reply(Resp, #state{respfun=Fun}) when is_function(Fun, 1) ->
    Fun(Resp#sipmsg{pid=self()});
reply(_, _) ->
    ok.



