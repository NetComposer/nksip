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

%% @private nksip_uac_auto plugin callbacksuests and related functions.
-module(nksip_uac_auto_outbound_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([nkcb_init/2, nkcb_sipapp_updated/2, nkcb_handle_info/3, nkcb_terminate/3]).
-export([nkcb_uac_auto_launch_register/4, nkcb_uac_auto_launch_unregister/4, 
         nkcb_uac_auto_update_register/5]).

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-include("../../../plugins/nksip_uac_auto/include/nksip_uac_auto.hrl").
-include("nksip_uac_auto_outbound.hrl").

%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @private 
nkcb_init(AppId, AllState) ->
    Config = AppId:config(),
    Supported = AppId:config_supported(),
    StateOb = #state_ob{
        outbound = lists:member(<<"outbound">>, Supported),
        ob_base_time = nksip_lib:get_value(nksip_uac_auto_outbound_any_ok, Config),
        pos = 1,
        regs = []
    },
    StateOb1 = set_state(StateOb, AllState),
    {continue, [AppId, StateOb1]}.


%% @private
nkcb_sipapp_updated(AppId, AllState) ->
    case lists:keymember(nksip_uac_auto_outbound, 1, AllState) of
        true -> continue;
        false -> nkcb_init(AppId, AllState)
    end.


%% @private
nkcb_handle_info(AppId, {'DOWN', Mon, process, _Pid, _}, AllState) ->
    #state_ob{regs=RegsOb} = get_state(AllState),
    case lists:keyfind(Mon, #sipreg_ob.conn_monitor, RegsOb) of
        #sipreg_ob{id=RegId, cseq=CSeq} ->
            ?info(AppId, <<>>, "register outbound flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            Msg = {'$nksip_uac_auto_register_answer', RegId, 503, Meta},
            gen_server:cast(self(), Msg),
            {ok, AllState};
        false ->
            continue
    end;

nkcb_handle_info(AppId, {'$nksip_uac_auto_register_notify', RegId}, AllState) ->
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} -> 
            State1 = StateOb#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            State2 = update_basetime(AppId, State1),
            {ok, set_state(State2, AllState)};
        false -> 
            continue
    end;

nkcb_handle_info(_AppId, _Msg, _AllState) ->
    continue.


%% @private
nkcb_terminate(AppId, _Reason, AllState) ->  
    #state_ob{regs=RegsOb} = get_state(AllState),
    lists:foreach(
        fun(Reg) -> nksip_uac_auto_outbound_lib:launch_unregister(AppId, Reg) end,
        RegsOb),
    continue.


%% @private
-spec nkcb_uac_auto_launch_register(nksip:app_id(), #sipreg{}, boolean(), list()) -> 
    {ok, #sipreg{}, list()} | continue.

nkcb_uac_auto_launch_register(AppId, Reg, Sync, AllState)->
    StateOb = get_state(AllState),
    case StateOb of
        #state_ob{outbound=true, pos=Pos, regs=RegsOb} ->
            #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
            Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
            Opts1 = [{cseq_num, CSeq}, {meta, Meta}, {reg_id, Pos} | Opts],
            Self = self(),
            Fun = fun() ->
                case nksip_uac:register(AppId, RUri, Opts1) of
                    {ok, Code, Meta} -> ok;
                    _ -> Code=500, Meta=[{cseq_num, CSeq}]
                end,
                gen_server:cast(Self, {'$nksip_uac_auto_register_answer', RegId, Code, Meta})
            end,
            Pid = case Sync of
                true -> Fun(), self();
                false -> spawn_link(Fun)
            end,
            #sipreg{cseq=CSeq} = Reg,
            RegOb = #sipreg_ob{id=RegId, cseq=CSeq, req_pid=Pid, pos=Pos, fails=0},
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb),
            StateOb1 = StateOb#state_ob{pos=Pos+1, regs=RegsOb1},
            ?debug(AppId, <<>>, "Started auto registration outbound: ~p", [RegId]),
            {ok, Reg#sipreg{next=undefined}, set_state(StateOb1, AllState)};
        _ ->
            continue
    end.


%% @private
-spec nkcb_uac_auto_launch_unregister(nksip:app_id(), #sipreg{}, boolean(), list()) -> 
    {ok, list()} | continue | {continue, list()}.

nkcb_uac_auto_launch_unregister(AppId, Reg, Sync, AllState)->
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    #sipreg{id=RegId} = Reg,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor, req_pid=Pid}, RegsOb1} -> 
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end, 
            case is_pid(Pid) of
                true -> nksip_connection:stop_refresh(Pid);
                false -> ok
            end,
            AllState1 = set_state(StateOb#state_ob{regs=RegsOb1}, AllState),
            {continue, [AppId, Reg, Sync, AllState1]};
        false ->
            continue 
    end.


  
%% @private
-spec nkcb_uac_auto_update_register(nksip:app_id(), #sipreg{}, nksip:sip_code(), 
                                    nksip:optslist(), list()) ->
    {ok, #sipreg{}, list()}.

nkcb_uac_auto_update_register(_AppId, Reg, Code, _Meta, AllState) when Code<200 ->
    {ok, Reg, AllState};

nkcb_uac_auto_update_register(AppId, Reg, Code, Meta, AllState) when Code<300 ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end,
            {Proto, Ip, Port, Res} = nksip_lib:get_value(remote, Meta),
            Require = nksip_lib:get_value(require, Meta),
            % 'fails' is not updated until the connection confirmation arrives
            % (or process down)
            RegOb2 = case lists:member(<<"outbound">>, Require) of
                true ->
                    case nksip_transport:get_connected(AppId, Proto, Ip, Port, Res) of
                        [{_, Pid}|_] -> 
                            Secs = case nksip_lib:get_integer(<<"flow-timer">>, Meta) of
                                FT when is_integer(FT), FT > 5 -> FT;
                                _ when Proto==udp -> ?DEFAULT_UDP_KEEPALIVE;
                                _ -> ?DEFAULT_TCP_KEEPALIVE
                            end,
                            Ref = {'$nksip_uac_auto_outbound_notify', RegId},
                            case 
                                nksip_connection:start_refresh(Pid, Secs, Ref) 
                            of
                                ok -> 
                                    Mon = erlang:monitor(process, Pid),
                                    RegOb1#sipreg_ob{conn_monitor=Mon, conn_pid=Pid};
                                error -> 
                                    ?notice(AppId, CallId, 
                                            "could not start outbound keep-alive", []),
                                    RegOb1
                            end;
                        [] -> 
                            RegOb1
                    end;
                false ->
                    RegOb1
            end,
            StateOb2 = StateOb#state_ob{regs=[RegOb2|RegsOb1]},
            {continue, Reg, Code, Meta, set_state(StateOb2, AllState)};
        _ ->
            continue
    end;

nkcb_uac_auto_update_register(AppId, Reg, Code, Meta, AllState) ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb, ob_base_time=BaseTime} = StateOb = 
        get_state(AllState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor, fails=Fails}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end,
            Config = nksip_sipapp_srv:config(AppId),
            MaxTime = nksip_lib:get_value(nksip_uac_auto_outbound_max_time, Config),
            Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
            Elap = round(crypto:rand_uniform(50, 101) * Upper / 100),
            ?notice(AppId, CallId, "Outbound registration failed "
                         "Basetime: ~p, fails: ~p, upper: ~p, time: ~p",
                         [BaseTime, Fails+1, Upper, Elap]),
            RegOb2 = RegOb1#sipreg_ob{
                conn_monitor = undefined,
                conn_pid = undefined,
                fails = Fails+1
            },
            StateOb2 = StateOb#state_ob{regs=[RegOb2|RegsOb1]},
            AllState1 = set_state(StateOb2, AllState),
            Reg1 = Reg#sipreg{interval=Elap},
            {continue, [Reg1, Code, Meta, AllState1]};
        false ->
            continue
    end.

    
%% @private
update_basetime(AppId, #state_ob{regs=Regs}=StateOb) ->
    Key = case [true || #sipreg_ob{fails=0} <- Regs] of
        [] -> 
            ?notice(AppId, <<>>, "all outbound flows have failed", []),
            nksip_uac_auto_outbound_all_fail;
        _ -> 
            nksip_uac_auto_outbound_any_ok
    end,
    BaseTime = nksip_lib:get_value(Key, AppId:config()),
    StateOb#state_ob{ob_base_time=BaseTime}.














































%% ===================================================================
%% Private
%% ===================================================================

%% @private
get_state(AllState) ->
    nksip_sipapp_srv:get_plugin_state(nksip_uac_auto_outbound, AllState).


%% @private
set_state(State, AllState) ->
    nksip_sipapp_srv:set_plugin_state(nksip_uac_auto_outbound, State, AllState).

