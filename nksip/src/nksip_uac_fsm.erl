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

%% @doc UAC Process FSM

-module(nksip_uac_fsm).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_fsm).

-export([request/1, get_cancel/1]).
-export([pre_send/2, send/2, accept/2]).
-export([init/1, terminate/3, handle_event/3, handle_info/3, 
            handle_sync_event/4, code_change/4]).

-include("nksip.hrl").

-define(MAX_AUTH_TRIES, 5).


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an already generated outbound UAC request.
-spec request(nksip:request()) ->
    pid().

request(Req) ->
    {ok, Pid} = gen_fsm:start(?MODULE, [Req], []),
    Pid.


%% @doc Generates a new CANCEL Request.
-spec get_cancel(nksip_request:id()) ->
    {ok, nksip:request()} | error.

get_cancel(InvPid) ->
    case catch gen_fsm:sync_send_all_state_event(InvPid, cancel, 30000) of
        {ok, CancelReq} -> {ok, CancelReq};
        _ -> error
    end.


%% ===================================================================
%% Private
%% ===================================================================

-record(state, {
    req :: nksip:request(),
    transaction_pid :: pid(),
    auth_tries = ?MAX_AUTH_TRIES :: integer(),
    timer :: reference(),
    user_fun :: function(),
    exp_timer :: reference(),
    prov_received = false :: boolean(),
    cancel_wait = [] :: [{reference(), pid()}]
}).


%% @private
init([#sipmsg{sipapp_id=AppId, method=Method, call_id=CallId, opts=Opts}=Req]) ->
    nksip_counters:async([nksip_msgs, nksip_uac_fsm]),
    nksip_sipapp_srv:register(AppId, uac_fsm),
    ?debug(AppId, CallId, "UAC FSM started for ~p: ~p", [Method, self()]),
    case nksip_lib:get_value(respfun, Opts) of
        Fun when is_function(Fun, 1) -> ok;
        _ -> Fun = fun(_) -> ok end
    end,
    {ok, pre_send, #state{req=Req, user_fun=Fun}, 0}.


%% @private
pre_send(timeout, #state{req=#sipmsg{method=Method, opts=Opts}=Req}=SD) ->
    case 
        Method=:='INVITE' andalso
        lists:member(dialog_force_send, Opts)=:=false andalso 
        nksip_dialog_uac:pre_request(Req) 
    of
        false ->
            send(launch, SD);
        ok ->
            send(launch, SD);
        {error, Error} ->
            stop({error, Error}, SD)
    end.


%% @private
send(launch, #state{req=Req}=SD) ->
    #sipmsg{sipapp_id=AppId, method=Method, call_id=CallId, headers=Hds,
            opts=Opts} = Req,
    Req1 = case Method of
        'CANCEL' -> Req;    % CANCEL must have Via already generated
        _ -> nksip_transport_uac:add_via(Req)
    end,
    Pid = case Method of
        'ACK' -> undefined;
        _ -> nksip_transaction_uac:start(Req1)
    end,
    Send = case Method of 
        'CANCEL' -> nksip_transport_uac:resend_request(Req1);
        _ -> nksip_transport_uac:send_request(Req1)
    end,
    case Send of
        {ok, SentReq} -> 
            case Pid of
                undefined -> ok;
                _ -> nksip_transaction_uac:request(SentReq, get_respfun(SentReq))
            end,
            case nksip_dialog_uac:request(SentReq) of
                ok ->
                    ok;
                {error, terminated_dialog} when Method=:='BYE' ->
                    ok;
                {error, unknown_dialog} when Method=:='BYE' ->
                    ok;
                {error, Error} ->
                    case lists:keymember(<<"X-Nksip-No-Error">>, 1, Hds) of
                        true ->
                            ok;
                        false ->
                             ?notice(AppId, CallId, 
                                     "UAC FSM dialog request error for ~p: ~p",
                                     [Method, Error])
                    end
            end,
            SD1 = SD#state{req=SentReq},
            reply(request, SD1),
            ExpTimer = case Method of
                'INVITE' ->
                    case nksip_parse:header_integers(<<"Expires">>, Req) of
                        [Expires|_] when Expires > 0 -> 
                            case lists:member(no_uac_expire, Opts) of
                                true -> undefined;
                                _ -> gen_fsm:start_timer(1000*Expires, expire)
                            end;
                        _ ->
                            undefined
                    end;
                _ ->
                    undefined
            end,
            case Method of
                'ACK' ->
                    {stop, normal, SD1};
                _ ->
                    T1 = nksip_config:get(timer_t1),
                    SD2 = SD1#state{
                        req = SentReq,
                        transaction_pid = Pid, 
                        timer = gen_fsm:start_timer(64*T1, accept), 
                        exp_timer = ExpTimer
                    },
                    {next_state, accept, SD2}
            end;
        error ->
            case Pid of
                undefined -> ok;
                _ -> nksip_transaction_uac:stop(Pid)
            end,
            case Method of
                'INVITE' -> ok = nksip_dialog_uac:pre_request_error(Req);
                _ -> ok
            end,
            stop({error, network_error}, SD)
    end.


%% @private
accept({timeout, _, accept}, #state{req=Req, transaction_pid=Pid}=SD) ->
    nksip_transaction_uac:stop(Pid),
    Resp = nksip_reply:reply(Req, timeout),
    stop(Resp, SD);

accept({timeout, _, expire}, SD) ->
    Self = self(),
    proc_lib:spawn_link(fun() -> nksip_uac:cancel({cancel, Self}, [async]) end),
    {next_state, accept, SD};

accept({reply, #sipmsg{response=Code}=Resp}, SD) ->
    #state{req=Req, auth_tries=Tries, timer=Timer, exp_timer=ExpTimer} = SD,
    #sipmsg{sipapp_id=AppId, call_id=CallId, method=Method, opts=Opts} = Req, 
    ?debug(AppId, CallId, "UAC FSM ~p received ~p", [Method, Code]),
    nksip_lib:cancel_timer(Timer),
    if Code >= 200 -> nksip_lib:cancel_timer(ExpTimer); true -> ok end,
    SD1 = check_cancel(Code, SD),
    if
        (Code=:=401 orelse Code=:=407) andalso Tries > 0 ->
            case nksip_auth:make_request(Req, Resp) of
                {ok, #sipmsg{vias=[_|Vias]}=Req1} ->
                    Req2 = Req1#sipmsg{
                        vias = Vias, 
                        opts = nksip_lib:delete(Opts, make_contact)
                    },
                    SD2 = SD1#state{req=Req2, auth_tries=Tries-1},
                    pre_send(timeout, SD2);
                error ->    
                    stop_secondary_dialogs(Resp),
                    stop(Resp, SD1)
            end;
        Code < 200 -> 
            reply(Resp, SD1),
            T1 = nksip_config:get(timer_t1),
            Timer1 = gen_fsm:start_timer(64*T1, accept),
            {next_state, accept, SD1#state{timer=Timer1, prov_received=true}};
        Code >= 200, Method=:='INVITE' ->
            stop_secondary_dialogs(Resp),
            stop(Resp, SD1);
        true ->
            stop(Resp, SD1)
    end.


%% @private
handle_sync_event(cancel, _From, accept, #state{prov_received=true, req=Req}=SD) ->
    {reply, {ok, nksip_uac_lib:make_cancel(Req)}, accept, SD};

handle_sync_event(cancel, From, StateName, #state{cancel_wait=Wait}=SD) ->
    {next_state, StateName, SD#state{cancel_wait=[From|Wait]}};

handle_sync_event(get_sipmsg, _From, StateName, #state{req=Req}=SD) ->
    {reply, Req, StateName, SD};

handle_sync_event({get_fields, Fields}, _From, StateName, #state{req=Req}=SD) ->
    {reply, nksip_sipmsg:fields(Fields, Req), StateName, SD};

handle_sync_event({get_headers, Name}, _From, StateName, #state{req=Req}=SD) ->
    {reply, nksip_sipmsg:headers(Name, Req), StateName, SD};

handle_sync_event(Msg, _From, StateName, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p (~p)", 
        [?MODULE, Msg, StateName]),
    {reply, error, StateName, SD}.


%% @private
handle_event(stop, _StateName, #state{transaction_pid=Pid}=SD) ->
    nksip_transaction_uac:stop(Pid),
    {stop, normal, SD};

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
terminate(_Reason, _StateName, 
          #state{req=#sipmsg{sipapp_id=AppId, call_id=CallId}}=SD) ->
    check_cancel(500, SD),
    ?debug(AppId, CallId, "UAS FSM stopped", []),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================

%% @private
stop(Reply, SD) ->
    reply(Reply, SD),
    {stop, normal, SD}.


%% @private
reply(Reply, #state{user_fun=Fun, req=#sipmsg{method=Method, opts=Opts}=Req}) ->
    case Reply of
        #sipmsg{response=Code} when Code < 101 ->
            ok;
        #sipmsg{response=Code}=Resp ->
            case lists:member(full_response, Opts) of
                true ->
                    Fun({reply, Resp#sipmsg{ruri=Resp#sipmsg.ruri}});
                false when Method=:='INVITE' ->
                    Fun({ok, Code, nksip_dialog:id(Resp)});
                false -> 
                    Fun({ok, Code})
            end;
        request ->
            case lists:member(full_request, Opts) of
                true when Method=:='ACK' -> Fun({ok, Req});
                false when Method=:='ACK' -> Fun(ok);
                true -> Fun({request, Req});
                false -> ok
            end;
        {error, Error} ->
            Fun({error, Error})
    end.


%% @private
check_cancel(Code, #state{cancel_wait=Wait, req=Req}=SD) ->
    Reply = if
        Code < 200 -> {ok, nksip_uac_lib:make_cancel(Req)};
        true -> error
    end,
    lists:foreach(fun(From) -> gen_fsm:reply(From, Reply) end, Wait),
    SD#state{cancel_wait=[]}.


%% @private
get_respfun(#sipmsg{ruri=RUri}=Req) ->
    Self = self(),
    fun(#sipmsg{sipapp_id=AppId, call_id=CallId, response=Code, cseq_method=Method, 
                opts=Opts}=Resp) ->
        Resp1 = Resp#sipmsg{ruri=RUri},
        case nksip_dialog_uac:response(Req, Resp1) of
            ok -> 
                ok;
            {error, DlgErr} ->
                ?notice(AppId, CallId, "UAC FSM dialog response error: ~p", [DlgErr])
        end,
        case 
            Method=:='INVITE' andalso Code >= 200 andalso Code < 300 
            andalso lists:member(secondary_response, Opts)
        of
            true ->
                % BYE any secondary response
                spawn(
                    fun() ->
                        DialogId = nksip_dialog:id(Resp1),
                        ?info(AppId, CallId, "UAC sending ACK and BYE to secondary "
                              "Response (Dialog ~s)", [DialogId]),
                        case nksip_uac:ack(DialogId, []) of
                            ok -> nksip_uac:bye(DialogId, [async]);
                            _ -> error
                        end
                    end);
            false ->
                gen_fsm:send_event(Self, {reply, Resp1})
        end
    end.


%% @private
stop_secondary_dialogs(#sipmsg{sipapp_id=AppId, call_id=CallId}=Resp) ->
    DialogId = nksip_dialog:id(Resp),
    Fun = fun(Id) ->
        case Id of
            DialogId -> 
                ok;
            _ -> 
                ?info(AppId, CallId, "UAC FSM stopping secondary early dialog ~s "
                      "(primary is ~s)", [Id, DialogId]),
                nksip_dialog:stop(Id)
        end
    end,
    lists:foreach(Fun, nksip_dialog:find_callid(AppId, CallId)).






