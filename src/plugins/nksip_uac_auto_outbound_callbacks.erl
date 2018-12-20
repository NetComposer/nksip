%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([plugin_deps/0, plugin_syntax/0, plugin_config/2, plugin_stop/2]).
-export([service_init/2, service_terminate/2, service_handle_call/3, 
         service_handle_cast/2, service_handle_info/2]).
-export([nksip_uac_auto_register_send_reg/3,
         nksip_uac_auto_register_send_unreg/3,
         nksip_uac_auto_register_upd_reg/4]).


-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").
-include("nksip_uac_auto_outbound.hrl").


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip_uac_auto_register, nksip_outbound].


plugin_syntax() ->
    #{
        sip_uac_auto_outbound_all_fail => {integer, 1, none},
        sip_uac_auto_outbound_any_ok => {integer, 1, none},
        sip_uac_auto_outbound_max_time => {integer, 1, none},
        sip_uac_auto_outbound_default_udp_ttl => {integer, 1, none},
        sip_uac_auto_outbound_default_tcp_ttl => {integer, 1, none}
    }.


plugin_config(Config, _Service) ->
    Cache = #nksip_uac_auto_outbound{
        all_fail =maps:get(sip_uac_auto_outbound_all_fail, Config, 30),
        any_ok = maps:get(sip_uac_auto_outbound_any_ok, Config, 90),
        max_time = maps:get(sip_uac_auto_outbound_max_time, Config, 1800),
        udp_ttl = maps:get(sip_uac_auto_outbound_default_udp_ttl, Config, 25),
        tcp_ttl = maps:get(sip_uac_auto_outbound_default_tcp_ttl, Config, 120)
    },
    {ok, Config, Cache}.


plugin_stop(Config, #{id:=Id}) ->
    gen_server:cast(Id, nksip_uac_auto_outbound_terminate),
    {ok, Config}.


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @doc Called when the service is started 
-spec service_init(nkservice:service(), nkservice_callbacks:user_state()) ->
    {ok, nkservice_callbacks:user_state()}.

service_init(_Service, #{id:=SrvId}=SrvState) ->
    PkgId = <<"Sip">>,
    #config{supported=Supported} = nksip_plugin:get_config(SrvId, PkgId),
    State = #state_ob{
        outbound = lists:member(<<"outbound">>, Supported),
        pos = 1,
        regs = []
    },
    {ok, SrvState#{nksip_uac_auto_outbound=>State}}.


%% @private
service_handle_call(nksip_uac_auto_outbound_get_regs, _From, SrvState) ->
    #{
        nksip_uac_auto_register := RegState, 
        nksip_uac_auto_outbound := State
    } = SrvState,
    #state{regs=Regs} = RegState,
    #state_ob{regs=RegsOb} = State,
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now, Fails} 
        ||
        #sipreg{id=RegId, ok=Ok, next=Next} <- Regs,
            case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false ->
                    Fails=0,
                    false;
                #sipreg_ob{fails=Fails} ->
                    true
            end
    ],
    {reply, Info, SrvState};

service_handle_call(_Msg, _From, _State) ->
    continue.


-spec service_handle_cast(term(), nkservice_callbacks:user_state()) ->
    {noreply, nkservice_callbacks:user_state()} | continue | {continue, list()}.

service_handle_cast(nksip_uac_auto_outbound_terminate, SrvState) ->
    {ok, SrvState1} = service_terminate(normal, SrvState),
    {noreply, SrvState1};

service_handle_cast(_Msg, _State) ->
    continue.


%% @private
-spec service_handle_info(term(), nkservice_callbacks:user_state()) ->
    {noreply, nkservice_callbacks:user_state()} | continue | {continue, list()}.

service_handle_info({'DOWN', Mon, process, _Pid, _}, 
                    #{nksip_uac_auto_outbound:=State}=SrvState) ->
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

service_handle_info({nksip_uac_auto_outbound_notify, RegId}, 
                    #{nksip_uac_auto_outbound:=State}=SrvState) ->
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} -> 
            ?SIP_DEBUG( "connection for register ~p successfully refreshed",
                   [RegId]),
            State1 = State#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            {noreply, SrvState#{nksip_uac_auto_outbound:=State1}};
        false -> 
            continue
    end;

service_handle_info(_Msg, _State) ->
    continue.


%% @doc Called when the plugin is shutdown
-spec service_terminate(nkservice:id(), nkservice_callbacks:user_state()) ->
    {ok, nkservice_callbacks:user_state()}.

service_terminate(_Reason, SrvState) ->  
    case SrvState of
        #{nksip_uac_auto_outbound:=State} ->
            #state_ob{regs=RegsOb} = State,
            lists:foreach(
                fun(#sipreg_ob{conn_monitor=Monitor, conn_pid=Pid}) -> 
                    case is_reference(Monitor) of
                        true ->
                            erlang:demonitor(Monitor);
                        false ->
                            ok
                    end, 
                    case is_pid(Pid) of
                        true ->
                            nksip_protocol:stop_refresh(Pid);
                        false ->
                            ok
                    end
                end,
                RegsOb),
            {ok, maps:remove(nksip_uac_auto_outbound, SrvState)};
        _ ->
            {ok, SrvState}
    end.


%% @private
-spec nksip_uac_auto_register_send_reg(#sipreg{}, boolean(),
                                         nkservice_callbacks:user_state()) -> 
    {ok, #sipreg{}, nkservice_callbacks:user_state()} | continue.

nksip_uac_auto_register_send_reg(Reg, Sync, SrvState) ->
    #{id:=SrvId, nksip_uac_auto_outbound:=State} = SrvState,
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
    #state_ob{outbound=Ob, pos=NextPos, regs=RegsOb} = State,
    User = nklib_util:get_value(user, Opts, []),
    case Ob andalso lists:member(nksip_uac_auto_outbound, User) of
        true ->
            RegOb1 = case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
                false ->
                    Pos = case nklib_util:get_value(reg_id, Opts) of
                        UserPos when is_integer(UserPos), UserPos>0 ->
                            UserPos;
                        _ ->
                            NextPos
                    end,
                    #sipreg_ob{id=RegId, cseq=CSeq, pos=Pos, fails=0};
                #sipreg_ob{pos=Pos} = RegOb0 ->
                    RegOb0#sipreg_ob{cseq=CSeq}
            end,
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb1),
            Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
            Opts1 = [contact, {cseq_num, CSeq}, {get_meta, Meta}, {reg_id, Pos} | Opts],
            Self = self(),
            Fun = fun() ->
                {Code, Meta1} = case nksip_uac:register(SrvId, RUri, Opts1) of
                    {ok, Code0, Meta0} ->
                        {Code0, Meta0};
                    _ ->
                        {500, [{cseq_num, CSeq}]}
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
            ?SIP_DEBUG( "Started auto registration outbound: ~p", [RegId]),
            Reg1 = Reg#sipreg{next=undefined},
            {ok, Reg1, SrvState1#{nksip_uac_auto_outbound:=State1}};
        false ->
            continue
    end.


%% @private
-spec nksip_uac_auto_register_send_unreg(#sipreg{}, boolean(),
                                           nkservice_callbacks:user_state()) -> 
    {ok, nkservice_callbacks:user_state()} | continue | {continue, list()}.

nksip_uac_auto_register_send_unreg(Reg, Sync, SrvState)->
    #{id:=SrvId, nksip_uac_auto_outbound:=State} = SrvState,
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    case lists:keytake(RegId, #sipreg_ob.id, State#state_ob.regs) of
        {value, #sipreg_ob{pos=Pos, conn_monitor=Monitor, conn_pid=Pid}, RegsOb1} -> 
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
            end, 
            case is_pid(Pid) of
                true ->
                    nksip_protocol:stop_refresh(Pid);
                false ->
                    ok
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
            {ok, SrvState1#{nksip_uac_auto_outbound:=State#state_ob{regs=RegsOb1}}};
        false ->
            continue 
    end.

% nksip_uac_auto_register_send_unreg(_Reg, _Sync, _SrvState)->
%     continue.

  
%% @private
-spec nksip_uac_auto_register_upd_reg(#sipreg{}, nksip:sip_code(), nksip:optslist(),
                                        nkservice_callbacks:user_state()) ->
    {ok, #sipreg{}, nkservice_callbacks:user_state()}.

nksip_uac_auto_register_upd_reg(Reg, Code, _Meta, SrvState) when Code<200 ->
    {ok, Reg, SrvState};

nksip_uac_auto_register_upd_reg(Reg, Code, Meta, SrvState) when Code<300 ->
    #{id:=SrvId, nksip_uac_auto_outbound:=State} = SrvState,
    #sipreg{id=RegId, call_id=CallId, opts=Opts} = Reg,
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
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
                            ?SIP_LOG(notice, "could not start outbound keep-alive (~s)", [CallId]),
                            RegOb1
                    end;
                false ->
                    RegOb1
            end,
            State2 = State#state_ob{regs=[RegOb2|RegsOb1]},
            Time = nklib_util:get_value(expires, Opts),
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [Reg1, Code, Meta, SrvState#{nksip_uac_auto_outbound:=State2}]};
        false ->
            continue
    end;

nksip_uac_auto_register_upd_reg(Reg, Code, Meta, SrvState) ->
    #{id:=SrvId, nksip_uac_auto_outbound:=State} = SrvState,
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb} = State,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb1, RegsOb1} ->
            #sipreg_ob{conn_monitor=Monitor, conn_pid=Pid, fails=Fails} = RegOb1,
            case is_reference(Monitor) of
                true ->
                    erlang:demonitor(Monitor);
                false ->
                    ok
            end,
            case is_pid(Pid) of
                true ->
                    nksip_protocol:stop_refresh(Pid);
                false ->
                    ok
            end,
            Config = SrvId:config_nksip_uac_auto_outbound(),
            #nksip_uac_auto_outbound{
                max_time = MaxTime,
                all_fail = AllFail,
                any_ok = AnyOK
            } = Config,
            BaseTime = case [true || #sipreg_ob{fails=0} <- RegsOb] of
                [] ->
                    AllFail;
                _ ->
                    AnyOK
            end,
            Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
            Time = round(nklib_util:rand(50, 101) * Upper / 100),
            ?SIP_LOG(notice, "Outbound registration failed (~s) "
                         "(basetime: ~p, fails: ~p, upper: ~p, time: ~p)",
                         [CallId, BaseTime, Fails+1, Upper, Time]),
            RegOb2 = RegOb1#sipreg_ob{
                conn_monitor = undefined,
                conn_pid = undefined,
                fails = Fails+1
            },
            State1 = State#state_ob{regs=[RegOb2|RegsOb1]},
            Reg1 = Reg#sipreg{interval=Time},
            {continue, [Reg1, Code, Meta, SrvState#{nksip_uac_auto_outbound:=State1}]};
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
        [FlowTimer0] ->
            nklib_util:to_integer(FlowTimer0);
        _ ->
            undefined
    end,
    Config = SrvId:config_nksip_uac_auto_outbound(),
    Secs = case FlowTimer of
        FT when is_integer(FT), FT > 5 ->
            FT;
        _ when Transp==udp ->
            Config#nksip_uac_auto_outbound.udp_ttl;
        _ ->
            Config#nksip_uac_auto_outbound.tcp_ttl
    end,
    Rand = nklib_util:rand(80, 101),
    Time = (Rand*Secs) div 100,
    Ref = {nksip_uac_auto_outbound_notify, RegId},
    case nksip_protocol:start_refresh(Pid, Time, Ref) of
        ok -> 
            ?SIP_LOG(info, "successfully set outbound keep-alive: ~p secs (~s)",
                  [Secs, CallId]),
            ok;
        error -> 
            ?SIP_LOG(notice, "could not start outbound keep-alive (~s)", [CallId]),
            error
    end.


%% @private
do_spawn(Fun, #{nksip_uac_auto_register:=State}=SrvState) ->
    Pid = spawn_link(Fun),
    #state{pids=Pids} = State,
    SrvState#{nksip_uac_auto_register:=State#state{pids=[Pid|Pids]}}.

