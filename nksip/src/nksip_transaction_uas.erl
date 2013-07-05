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
-module(nksip_transaction_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_fsm).

-export([total/0, total/1, is_retrans/1, is_ack/1, is_cancel/1, is_loop/1]).
-export([start/1, stop/1, response/2]).
-export([invite_proceeding/2, invite_accepted/2, invite_completed/2, invite_confirmed/2]).
-export([trying/2, proceeding/2, completed/2]).
-export([init/1, terminate/3, handle_event/3, handle_info/3, 
            handle_sync_event/4, code_change/4]).
-export([get_state/1, all_pids/0, stop_all/0]).

-include("nksip.hrl").

-define(INVITE_TIMEOUT, (1000*nksip_config:get(ringing_timeout))).
-define(NOINVITE_TIMEOUT, 60000).


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets the total number of active UAS transactions.
-spec total() -> 
    integer().

total() -> 
    nksip_counters:value(nksip_transactions_uas).


%% @doc Gets the total number of active UAS transactions for a SipApp.
-spec total(nksip:sipapp_id()) -> 
    integer().

total(AppId) -> 
    nksip_counters:value({nksip_transactions_uas, AppId}).


%% @doc Checks if `Request' is a retransmission of an existing transaction. 
-spec is_retrans(Request::nksip:request()) ->
    boolean().

is_retrans(#sipmsg{sipapp_id=AppId, call_id=CallId, method=Method}=Request) ->
    {_, TransId} = transaction_id(Request),
    case nksip_proc:whereis_name({nksip_transaction_uas, TransId}) of
        undefined ->
            ?debug(AppId, CallId, "UAC Trans ~s (~p) is NOT retrans", 
                   [TransId, Method]),
            false;
        Pid ->
            ?debug(AppId, CallId, "UAC Trans ~s (~p) IS retrans", 
                   [TransId, Method]),
            gen_fsm:send_event(Pid, req_retrans),
            true
    end.
        

%% @doc Checks if `Request' is an ACK matching an existing transaction. 
-spec is_ack(Request::nksip:request()) ->
    boolean().

is_ack(#sipmsg{method='ACK'}=Request) ->
    {Type, TransId} = transaction_id(Request#sipmsg{method='INVITE'}),
    case nksip_proc:whereis_name({nksip_transaction_uas, TransId}) of
        undefined when Type=:=old ->
            case nksip_proc:values({nksip_transaction_uas_ack, TransId}) of
                [{_, Pid}|_] ->
                    gen_fsm:send_all_state_event(Pid, ack),
                    true;
                _ -> 
                    false
            end;
        undefined ->
            false;
        Pid ->
            gen_fsm:send_all_state_event(Pid, ack),
            true
    end.


%% @doc Checks if `Request' is a CANCEL matching an existing transaction. 
%% Returns UAS FSM's pid()
-spec is_cancel(Request::nksip:request()) ->
    {true, pid()} | false | invalid.

is_cancel(#sipmsg{method='CANCEL'}=Request) ->
    {_, TransId} = transaction_id(Request#sipmsg{method='INVITE'}),
    case nksip_proc:whereis_name({nksip_transaction_uas, TransId}) of
        undefined ->
            false;
        Pid ->
            case catch
                gen_fsm:sync_send_all_state_event(Pid, {check_cancel, Request}, 30000) 
            of
                {true, UasPid} -> {true, UasPid};
                invalid -> invalid;
                _ -> false
            end
    end.


%% @doc Checks if `Request' is looping in the server
-spec is_loop(nksip:request()) ->
    boolean().

is_loop(#sipmsg{sipapp_id=AppId, call_id=CallId, to_tag=(<<>>)}=Request) ->
    case nksip_proc:values({nksip_transaction_uas_loop, loop_id(Request)}) of
        [] ->
            false;
        _ ->
            ?notice(AppId, CallId, "UAS Trans detected a loop in call", []),
            true
    end;

is_loop(_) ->
    false.


%% @private Starts a new UAS server transaction for a received `Request'
-spec start(nksip:request()) ->
    pid().

start(#sipmsg{sipapp_id=AppId, call_id=CallId}=Request) ->
    {Type, TransId} = transaction_id(Request),
    Name = {nksip_transaction_uas, TransId},
    case nksip_proc:start(fsm, Name, ?MODULE, [Type, TransId, Request]) of
        {ok, Pid} -> 
            Pid;
        {error, {already_started, Pid}} -> 
            ?notice(AppId, CallId, "UAC Trans already started: ~p", [Pid]),
            Pid
    end.


%% @private Stops a UAS server transaction
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).


%% @private Sends a response through a started server transaction
-spec response(pid(), nksip:response()) -> 
    ok.

response(Pid, Response) when is_pid(Pid) ->
    gen_fsm:send_event(Pid, {response, Response}).


%% @private
-spec get_state(pid()) ->
    invite_proceeding | invite_accepted | invite_completed | invite_confirmed |
    trying | proceeding | completed | unknown.

get_state(Pid) ->
    case catch gen_fsm:sync_send_all_state_event(Pid, get_state, 30000) of
        {ok, StateName} -> StateName;
        _ -> unknown
    end.


%% @private Get all dialog Ids and Pids.
-spec all_pids() ->
    [pid()].

all_pids() ->
    Fun = fun
            ({nksip_transaction_uas, _}, [{val, _, Pid}], Acc) -> [Pid|Acc];
            (_, _, Acc) -> Acc
    end,
    nksip_proc:fold_names(Fun, []).

%% @private
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun(Pid) -> stop(Pid) end, all_pids()).




%% ===================================================================
%% gen_fsm
%% ===================================================================


-record(state, {
    sipapp_id :: nksip:sipapp_id(),
    old_type :: boolean(),
    call_id :: nksip:call_id(),
    method :: nksip:method(),
    proto :: nksip:protocol(),
    request :: nksip:request(),
    response :: nksip:response(),
    timeout_timer :: reference(),
    retrans_timer :: reference(),
    next_retrans :: non_neg_integer()
}).


%% @private Style is old (old-style transactions) or new
init([Style, TransId, Req]) ->
    #sipmsg{
            sipapp_id = AppId, 
            transport = #transport{proto=Proto}, 
            method = Method,
            call_id = CallId
        } = Req,
    SD = #state{
        sipapp_id = AppId,
        call_id = CallId,
        method = Method,
        old_type = (Style =:= old),
        proto = Proto,
        request = Req,
        response = undefined
    },
    nksip_proc:put({nksip_transaction_uas_loop, loop_id(Req)}),
    nksip_counters:async([nksip_transactions_uas, {nksip_transactions_uas, AppId}]),
    nksip_sipapp_srv:register(AppId, transaction_uas),
    ?debug(AppId, CallId, "UAS Trans ~s started (~p): ~p", 
           [TransId, Method, self()]),
    case Method of
        'INVITE' ->
            Timer = gen_fsm:start_timer(?INVITE_TIMEOUT, timer_invite),
            {ok, invite_proceeding,  SD#state{timeout_timer=Timer}};
        _ ->
            Timer = gen_fsm:start_timer(?NOINVITE_TIMEOUT, timer_timeout),
            {ok, trying, SD#state{timeout_timer=Timer}}
    end.


%%% ------ INVITE FSM ------------------------------------------------


%% @private
invite_proceeding(req_retrans, SD) ->
    resend_response(<<"invite_proceeding">>, SD),
    {next_state, invite_proceeding, SD};

invite_proceeding({response, #sipmsg{response=Code}=Resp}, SD) -> 
    #state{
        sipapp_id = AppId,
        call_id = CallId,
        old_type = OldType, 
        proto = Proto, 
        request = Request, 
        timeout_timer = Timeout
    } = SD,
    ?debug(AppId, CallId, "UAS Trans reply in invite_proceeding: ~p", [Code]),
    SD1 = SD#state{response=Resp},
    if 
        Code < 200 -> 
            {next_state, invite_proceeding, SD1};
        Code < 300 ->
            nksip_lib:cancel_timer(Timeout),
            case OldType of
                true ->
                    % In old-style transactions, save TransId to be used in
                    % detecting ACKs
                    ToTag = nksip_lib:get_binary(to_tag, Request#sipmsg.opts),
                    {_, TransId} = transaction_id(Request#sipmsg{to_tag=ToTag}),
                    nksip_proc:put({nksip_transaction_uas_ack, TransId});
                _ ->
                    ok
            end,
            case Proto of
                udp ->
                    T1 = nksip_config:get(timer_t1),
                    SD2 = SD1#state{
                        request = undefined,    % They are no longer necessary
                        response = undefined,
                        timeout_timer = gen_fsm:start_timer(64*T1, timer_l)
                    },
                    {next_state, invite_accepted, SD2, hibernate};
                _ ->
                    % Any reason to keep the TCP transaction?
                    {stop, normal, SD}
            end;
        true ->
            nksip_lib:cancel_timer(Timeout),
            T1 = nksip_config:get(timer_t1),
            SD2 = case Proto of 
                udp ->
                    T2 = nksip_config:get(timer_t2),
                    SD1#state{
                        retrans_timer = gen_fsm:start_timer(T1, timer_g), 
                        next_retrans = min(2*T1, T2),
                        timeout_timer = gen_fsm:start_timer(64*T1, timer_h)
                    };
                _ ->
                    SD1#state{timeout_timer=gen_fsm:start_timer(64*T1, timer_h)}
            end,
            {next_state, invite_completed, SD2, hibernate}
    end;

invite_proceeding({timeout, _, timer_invite}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId} = SD,
    ?warning(AppId, CallId, 
             "UAS Trans didn't receive any reply in invite_proceeding", []),
    {stop, normal, SD}.


%% @private: new state by rfc6026, to wait for INVITE retransmissions
invite_accepted(req_retrans, SD) ->
    #state{sipapp_id=AppId, call_id=CallId} = SD,
    ?info(AppId, CallId, "UAS Trans received retransmission in invite_accepted", []),
    {next_state, invite_accepted, SD};

invite_accepted({response, #sipmsg{response=Code}}, SD) ->
    #state{sipapp_id=AppId, call_id=CallId} = SD,
    ?notice(AppId, CallId, 
           "UAS Trans received new response in invite_accepted: ~p", [Code]),
    {next_state, invite_accepted, SD};

invite_accepted({timeout, _, timer_l}, SD) ->
    {stop, normal, SD}.


%% @private: waiting for non 2xx ACK
invite_completed(req_retrans, SD) ->
    case resend_response(<<"invite_completed">>, SD) of
        ok -> {next_state, invite_completed, SD};
        error -> {stop, normal, SD}
    end;

invite_completed({response, _}, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?warning(AppId, CallId, "UAS Trans ignoring new response in invite_completed", []),
    {next_state, invite_completed, SD};

invite_completed({timeout, _, timer_g}, #state{next_retrans=Next}=SD) ->
    case resend_response(<<"invite_completed">>, SD) of
        ok ->
            T2 = nksip_config:get(timer_t2),
            SD1 = SD#state{
                retrans_timer = gen_fsm:start_timer(Next, timer_g),
                next_retrans = min(2*Next, T2)
            },
            {next_state, invite_completed, SD1};
        error ->
            {stop, normal, SD}
    end;

invite_completed({timeout, _, timer_h}, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?notice(AppId, CallId, "UAS Trans did not receive ACK in invite_completed", []),
    {stop, normal, SD}.


%% @private: Non 2xx ACK received with UDP, waiting for any retransmission
invite_confirmed(req_retrans, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?info(AppId, CallId, "UAS Trans received retransmission in invite_confirmed", []),
    {next_state, invite_confirmed, SD};

invite_confirmed({response, #sipmsg{response=Code}}, 
                #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?info(AppId, CallId, 
          "UAS Trans received new response in invite_confirmed: ~p", [Code]),
    {next_state, invite_confirmed, SD};

invite_confirmed({timeout, _, timer_i}, SD) ->
    {stop, normal, SD}.



%%% ------ Non-INVITE FSM ------------------------------------------------


%% @private
trying(req_retrans, #state{sipapp_id=AppId, call_id=CallId, method=Method}=SD) ->
    ?info(AppId, CallId, "UAS Trans received ~p retransmission in trying", [Method]),
    {next_state, trying, SD};

trying({response, Response}, SD) ->
    proceeding({response, Response}, SD);

trying({timeout, _, timer_timeout}, 
        #state{sipapp_id=AppId, call_id=CallId, request=#sipmsg{method=Method}}=SD) ->
    ?warning(AppId, CallId, 
            "UAS Trans Transaction ~p didn't receive any answer in trying", [Method]),
    {stop, normal, SD}.


%% @private
proceeding(req_retrans, SD) ->
    resend_response(<<"proceeding">>, SD),
    {next_state, proceeding, SD};

proceeding({response, #sipmsg{response=Code}=Resp}, SD) -> 
    #state{sipapp_id=AppId, call_id=CallId, proto=Proto, timeout_timer=Timeout} = SD,
    ?debug(AppId, CallId, "Trans UAS reply in proceeding: ~p", [Code]),
    SD1 = SD#state{response=Resp},
    if 
        Code < 200 -> 
            {next_state, proceeding, SD1};
        Proto =:= udp -> 
            nksip_lib:cancel_timer(Timeout), 
            T1 = nksip_config:get(timer_t1),
            SD2 = SD1#state{timeout_timer=gen_fsm:start_timer(64*T1, timer_j)}, 
            {next_state, completed, SD2, hibernate};
        true ->
            {stop, normal, SD1}
    end;

proceeding({timeout, _, timer_timeout}, SD) ->
    {stop, normal, SD}.


%% @private
completed(req_retrans, SD) ->
    case resend_response(<<"completed">>, SD) of
        ok -> {next_state, completed, SD};
        error -> {stop, normal, SD}
    end;

completed({response, _}, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    ?warning(AppId, CallId, "UAS Trans ignoring new response in completed", []),
    {next_state, completed, SD};

completed({timeout, _, timer_j}, SD) ->
    {stop, normal, SD}.



%%% ------ Common ------------------------------------------------


%% @private
handle_sync_event(
        {check_cancel, 
            #sipmsg{transport=#transport{remote_ip=CancelIp, remote_port=CancelPort}}},
        _From, StateName, 
        #state{
            sipapp_id = AppId, call_id = CallId,
            request = #sipmsg{transport = #transport{
                                remote_ip = RequestIp, 
                                remote_port = RequestPort},
                                pid = Pid}
        }=SD) ->
    if
        CancelIp=:=RequestIp, CancelPort=:=RequestPort ->
            {reply, {true, Pid}, StateName, SD};
        true ->
            ?notice(AppId, CallId, "UAS Trans rejecting CANCEL because came from ~p:~p, "
                  "request came from ~p:~p", 
                  [CancelIp, CancelPort, RequestIp, RequestPort]),
            {reply, invalid, StateName, SD}
    end;

handle_sync_event({check_cancel, _}, _From, StateName, SD) ->
    % We have already deleted request
    {reply, false, StateName, SD};
    
handle_sync_event(get_state, _From, StateName, #state{timeout_timer=Timer}=SD) -> 
    {reply, {ok, StateName, erlang:read_timer(Timer), SD}, StateName, SD};

handle_sync_event(Info, _From, StateName, SD) ->
    lager:error("Module ~p received unexpected sync event ~p (~p)", 
                [?MODULE, Info, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_event(ack, invite_completed, 
                #state{proto=udp, retrans_timer=TimerG, timeout_timer=TimerH}=SD) ->
    nksip_lib:cancel_timer(TimerG),
    nksip_lib:cancel_timer(TimerH),
    T4 = nksip_config:get(timer_t4), 
    gen_fsm:start_timer(T4, timer_i), 
    {next_state, invite_confirmed, SD};

handle_event(ack, invite_completed, SD) ->
    {stop, normal, SD};

handle_event(ack, StateName, #state{sipapp_id=AppId, call_id=CallId}=SD) ->
    case StateName of
        invite_confirmed -> ok;
        _ -> ?notice(AppId, CallId, "UAS Trans received ACK in ~p", [StateName])
    end,
    {next_state, StateName, SD};

handle_event(stop, _StateName, SD) ->
    {stop, normal, SD};

handle_event(Info, StateName, SD) ->
    lager:error("Module ~p received unexpected event ~p (~p)", 
                [?MODULE, Info, StateName]),
    {next_state, StateName, SD}.


%% @private
handle_info(Info, StateName, SD) ->
    lager:warning("Module ~p received unexpected info: ~p (~p)", 
                  [?MODULE, Info, StateName]),
    {next_state, StateName, SD}.


%% @private
code_change(_OldVsn, StateName, SD, _Extra) -> 
    {ok, StateName, SD}.


%% @private
terminate(_Reason, _StateName, #state{sipapp_id=AppId, call_id=CallId}) ->
    ?debug(AppId, CallId, "UAS Trans Transaction stopped: ~p", [self()]),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================
    
%% @private
-spec transaction_id(nksip:request()) ->
    {new|old, binary()}.
    
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
            {new, nksip_lib:lhash({AppId, Method, ViaIp, ViaPort, Branch})};
        _ ->
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            {old, nksip_lib:lhash({AppId, UriIp, UriPort, FromTag, ToTag, CallId, CSeq, 
                                    Method, ViaIp, ViaPort})}
    end.


%% @private
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
-spec resend_response(binary(), #state{}) ->
    ok | error.

resend_response(StateText, #state{response=#sipmsg{}=Resp}) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, cseq_method=Method, response=Code}=Resp,
    case nksip_transport_uas:resend_response(Resp) of
        {ok, _} -> 
            ?info(AppId, CallId, 
                  "UAS Trans retransmitting ~p ~p response in ~s", 
                  [Method, Code, StateText]),
            ok;
        error ->
            ?notice(AppId, CallId, 
                    "UAS Trans could not retransmit ~p ~p response in ~s", 
                    [Method, Code, StateText]),
            error
    end;
resend_response(_, _) ->
    ok.








