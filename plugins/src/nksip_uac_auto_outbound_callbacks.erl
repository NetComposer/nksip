%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @private
-module(nksip_uac_auto_outbound_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/2, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).
-export([nks_sip_uac_auto_register_send_reg/3, 
         nks_sip_uac_auto_register_send_unreg/3, 
         nks_sip_uac_auto_register_upd_reg/4]).


-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").
-include("nksip_uac_auto_outbound.hrl").

-define(OB_SKEY, nksip_uac_auto_outbound).
-define(REG_SKEY, nksip_uac_auto_register).


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @doc Called when the service is started 
-spec init(nkservice:spec(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

init(_ServiceSpec, #{id:=SrvId}=SrvState) ->
    Supported = SrvId:cache_sip_supported(),
    State = #state_ob{
        outbound = lists:member(<<"outbound">>, Supported),
        pos = 1,
        regs = []
    },
    {ok, SrvState#{?OB_SKEY=>State}}.


%% @private
handle_call(nksip_uac_auto_outbound_get_regs, _From, 
            #{?REG_SKEY:=RegState, ?OB_SKEY:=State}=SrvState) ->
    #state{regs=Regs} = RegState,
    #state_ob{regs=RegsOb} = State,
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now, Fails} 
        ||
        #sipreg{id=RegId, ok=Ok, next=Next} <- Regs,
            case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false -> Fails=0, false;
                #sipreg_ob{fails=Fails} -> true
            end
    ],
    {reply, Info, SrvState};

handle_call(_Msg, _From, _State) ->
    continue.


-spec handle_cast(term(), nkservice_server:sub_state()) ->
    {noreply, nkservice_server:sub_state()} | continue | {continue, list()}.

handle_cast(nksip_uac_auto_outbound_terminate, SrvState) ->
    {ok, SrvState1} = terminate(normal, SrvState),
    {noreply, SrvState1};

handle_cast(_Msg, _State) ->
    continue.


%% @private
-spec handle_info(term(), nkservice_server:sub_state()) ->
    {noreply, nkservice_server:sub_state()} | continue | {continue, list()}.

handle_info({'DOWN', Mon, process, _Pid, _}, #{?OB_SKEY:=State}=SrvState) ->
    #state_ob{regs=RegsOb} = State,
    case lists:keyfind(Mon, #sipreg_ob.conn_monitor, RegsOb) of
        #sipreg_ob{id=RegId, cseq=CSeq} ->
            % ?info(SrvId, <<>>, "register outbound flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            Msg = {nksip_uac_auto_register_reg_reply, RegId, 503, Meta},
            gen_server:cast(self(), Msg),
            {noreply, SrvState};
        false ->
            continue
    end;

handle_info({nksip_uac_auto_outbound_notify, RegId}, 
            #{id:=SrvId, ?OB_SKEY:=State}=SrvState) ->
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} -> 
            ?debug(SrvId, <<>>, "connection for register ~p successfully refreshed",
                   [RegId]),
            State1 = State#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            {noreply, SrvState#{?OB_SKEY:=State1}};
        false -> 
            continue
    end;

handle_info(_Msg, _State) ->
    continue.


%% @doc Called when the plugin is shutdown
-spec terminate(nksip:srv_id(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

terminate(_Reason, SrvState) ->  
    case SrvState of
        #{?OB_SKEY:=State} ->
            #state_ob{regs=RegsOb} = State,
            lists:foreach(
                fun(#sipreg_ob{conn_monitor=Monitor, conn_pid=Pid}) -> 
                    case is_reference(Monitor) of
                        true -> erlang:demonitor(Monitor);
                        false -> ok
                    end, 
                    case is_pid(Pid) of
                        true -> nksip_protocol:stop_refresh(Pid);
                        false -> ok
                    end
                end,
                RegsOb),
            {ok, maps:remove(?OB_SKEY, SrvState)};
        _ ->
            {ok, SrvState}
    end.


%% @private
-spec nks_sip_uac_auto_register_send_reg(#sipreg{}, boolean(), 
                                                nkservice_server:sub_state()) -> 
    {ok, #sipreg{}, nkservice_server:sub_state()} | continue.

nks_sip_uac_auto_register_send_reg(Reg, Sync, #{id:=SrvId, ?OB_SKEY:=State}=SrvState)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
    #state_ob{outbound=Ob, pos=NextPos, regs=RegsOb} = State,
    User = nklib_util:get_value(user, Opts, []),
    case Ob andalso lists:member(nksip_uac_auto_outbound, User) of
        true ->
            RegOb1 = case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false ->
                    Pos = case nklib_util:get_value(reg_id, Opts) of
                        UserPos when is_integer(UserPos), UserPos>0 -> UserPos;
                        _ -> NextPos
                    end,
                    #sipreg_ob{id=RegId, cseq=CSeq, pos=Pos, fails=0};
                #sipreg_ob{pos=Pos} = RegOb0 ->
                    RegOb0#sipreg_ob{cseq=CSeq}
            end,
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb1),
            Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
            Opts1 = [contact, {cseq_num, CSeq}, {meta, Meta}, {reg_id, Pos} | Opts],
            Self = self(),
            Fun = fun() ->
                case nksip_uac:register(SrvId, RUri, Opts1) of
                    {ok, Code, Meta1} -> ok;
                    _ -> Code=500, Meta1=[{cseq_num, CSeq}]
                end,
                Msg1 = {nksip_uac_auto_register_reg_reply, RegId, Code, Meta1},
                gen_server:cast(Self, Msg1)
            end,
            SrvState1 = case Sync of
                true -> 
                    Fun(),
                    SrvState;
                false -> 
                    do_spawn(Fun, SrvState)
            end,
            State1 = State#state_ob{pos=max(NextPos, Pos+1), regs=RegsOb1},
            ?debug(SrvId, <<>>, "Started auto registration outbound: ~p", [RegId]),
            Reg1 = Reg#sipreg{next=undefined},
            {ok, Reg1, SrvState1#{?OB_SKEY:=State1}};
        false ->
            continue
    end.


%% @private
-spec nks_sip_uac_auto_register_send_unreg(#sipreg{}, boolean(), 
                                                  nkservice_server:sub_state()) -> 
    {ok, nkservice_server:sub_state()} | continue | {continue, list()}.

nks_sip_uac_auto_register_send_unreg(Reg, Sync, #{id:=SrvId, ?OB_SKEY:=State}=SrvState)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    case lists:keytake(RegId, #sipreg_ob.id, State#state_ob.regs) of
        {value, #sipreg_ob{pos=Pos, conn_monitor=Monitor, conn_pid=Pid}, RegsOb1} -> 
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end, 
            case is_pid(Pid) of
                true -> nksip_protocol:stop_refresh(Pid);
                false -> ok
            end,
            Opts1 = [contact, {cseq_num, CSeq}, {reg_id, Pos} |
                     nklib_util:store_value(expires, 0, Opts)],
            Fun = fun() -> nksip_uac:register(SrvId, RUri, Opts1) end,
            SrvState1 = case Sync of
                true -> 
                    Fun(),
                    SrvState;
                false -> 
                    do_spawn(Fun, SrvState)
            end,
            {ok, SrvState1#{?OB_SKEY:=State#state_ob{regs=RegsOb1}}};
        false ->
            continue 
    end.


  
%% @private
-spec nks_sip_uac_auto_register_upd_reg(#sipreg{}, nksip:sip_code(), 
                                                nksip:optslist(), 
                                                nkservice_server:sub_state()) ->
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_upd_reg(Reg, Code, _Meta, SrvState) when Code<200 ->
    {ok, Reg, SrvState};

nks_sip_uac_auto_register_upd_reg(Reg, Code, Meta, 
                                  #{id:=SrvId, ?OB_SKEY:=State}=SrvState) 
                                  when Code<300 ->
    #sipreg{id=RegId, call_id=CallId, opts=Opts} = Reg,
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end,
            {Transp, Ip, Port, Path} = nklib_util:get_value(remote, Meta),
            Require = nklib_util:get_value(require, Meta),
            % 'fails' is not updated until the connection confirmation arrives
            % (or process down)
            RegOb2 = case lists:member(<<"outbound">>, Require) of
                true ->
                    case nksip_util:get_connected(SrvId, Transp, Ip, Port, Path) of
                        [Pid|_] -> 
                            case start_refresh(SrvId, Meta, Transp, Pid, Reg) of
                                ok -> 
                                    Mon = erlang:monitor(process, Pid),
                                    RegOb1#sipreg_ob{conn_monitor=Mon, conn_pid=Pid};
                                error -> 
                                    RegOb1
                            end;
                        [] -> 
                            ?notice(SrvId, CallId, 
                                    "could not start outbound keep-alive", []),
                            RegOb1
                    end;
                false ->
                    RegOb1
            end,
            State2 = State#state_ob{regs=[RegOb2|RegsOb1]},
            Time = nklib_util:get_value(expires, Opts),
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [Reg1, Code, Meta, SrvState#{?OB_SKEY:=State2}]};
        false ->
            continue
    end;

nks_sip_uac_auto_register_upd_reg(Reg, Code, Meta, 
                                  #{id:=SrvId, ?OB_SKEY:=State}=SrvState) ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb1, RegsOb1} ->
            #sipreg_ob{conn_monitor=Monitor, conn_pid=Pid, fails=Fails} = RegOb1,
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end,
            case is_pid(Pid) of
                true -> nksip_protocol:stop_refresh(Pid);
                false -> ok
            end,
            MaxTime = SrvId:cache_sip_uac_auto_outbound_max_time(),
            BaseTime = case [true || #sipreg_ob{fails=0} <- RegsOb] of
                [] -> SrvId:cache_sip_uac_auto_outbound_all_fail();
                _ -> SrvId:cache_sip_uac_auto_outbound_any_ok()
            end,
            Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
            Time = round(crypto:rand_uniform(50, 101) * Upper / 100),
            ?notice(SrvId, CallId, "Outbound registration failed "
                         "(basetime: ~p, fails: ~p, upper: ~p, time: ~p)",
                         [BaseTime, Fails+1, Upper, Time]),
            RegOb2 = RegOb1#sipreg_ob{
                conn_monitor = undefined,
                conn_pid = undefined,
                fails = Fails+1
            },
            State1 = State#state_ob{regs=[RegOb2|RegsOb1]},
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [Reg1, Code, Meta, SrvState#{?OB_SKEY:=State1}]};
        false ->
            continue
    end.

    
%% ===================================================================
%% Private
%% ===================================================================



%% @private
start_refresh(SrvId, Meta, Transp, Pid, Reg) ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    FlowTimer = case nklib_util:get_value(<<"flow-timer">>, Meta) of
        [FlowTimer0] -> nklib_util:to_integer(FlowTimer0);
        _ -> undefined
    end,
    Secs = case FlowTimer of
        FT when is_integer(FT), FT > 5 -> 
            FT;
        _ when Transp==udp -> 
            SrvId:cache_sip_uac_auto_outbound_default_udp_ttl();
        _ -> 
            SrvId:cache_sip_uac_auto_outbound_default_tcp_ttl()
    end,
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    Ref = {nksip_uac_auto_outbound_notify, RegId},
    case nksip_protocol:start_refresh(Pid, Time, Ref) of
        ok -> 
            ?info(SrvId, CallId, "successfully set outbound keep-alive: ~p secs", 
                  [Secs]),
            ok;
        error -> 
            ?notice(SrvId, CallId, "could not start outbound keep-alive", []),
            error
    end.


%% @private
do_spawn(Fun, #{?REG_SKEY:=State}=SrvState) ->
    Pid = spawn_link(Fun),
    #state{pids=Pids} = State,
    SrvState#{?REG_SKEY:=State#state{pids=[Pid|Pids]}}.

