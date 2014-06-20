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

-export([nkcb_handle_call/3, nkcb_handle_info/2]).
-export([nkcb_uac_auto_launch_register/3, nkcb_uac_auto_launch_unregister/3, 
         nkcb_uac_auto_update_register/4]).

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-include("../../../plugins/nksip_uac_auto/include/nksip_uac_auto.hrl").
-include("nksip_uac_auto_outbound.hrl").



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @private
nkcb_handle_call('$nksip_uac_auto_outbound_get_registers', From, SipAppState) ->
    #state{regs=Regs} = nksip_sipapp_srv:get_meta(nksip_uac_auto, SipAppState),
    #state_ob{regs=RegsOb} = get_state(SipAppState),
    gen_server:reply(From, {Regs, RegsOb}),
    {ok, SipAppState};

nkcb_handle_call(_Msg, _From, _SipAppState) ->
    continue.


%% @private
-spec nkcb_handle_info(term(), nksip_sipapp_srv:state()) ->
    {ok, nksip_sipapp_srv:state()} | continue | {continue, list()}.

nkcb_handle_info({'DOWN', Mon, process, _Pid, _}, SipAppState) ->
    #state_ob{regs=RegsOb} = get_state(SipAppState),
    case lists:keyfind(Mon, #sipreg_ob.conn_monitor, RegsOb) of
        #sipreg_ob{id=RegId, cseq=CSeq} ->
            #sipapp_srv{app_id=AppId} = SipAppState,
            ?info(AppId, <<>>, "register outbound flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            Msg = {'$nksip_uac_auto_register_answer', RegId, 503, Meta},
            gen_server:cast(self(), Msg),
            {ok, SipAppState};
        false ->
            continue
    end;

nkcb_handle_info({'$nksip_uac_auto_register_notify', RegId}, SipAppState) ->
    #state_ob{regs=RegsOb} = StateOb = get_state(SipAppState),
    #sipapp_srv{app_id=AppId} = SipAppState,
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} -> 
            State1 = StateOb#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            State2 = update_basetime(AppId, State1),
            {ok, set_state(State2, SipAppState)};
        false -> 
            continue
    end;

nkcb_handle_info(_Msg, _SipAppState) ->
    continue.


%% @private
-spec nkcb_uac_auto_launch_register(#sipreg{}, boolean(), nksip_sipapp_srv:state()) -> 
    {ok, #sipreg{}, nksip_sipapp_srv:state()} | continue.

nkcb_uac_auto_launch_register(Reg, Sync, SipAppState)->
    lager:warning("LAUNCH"),
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
    UserOpts = nksip_lib:get_value(user, Opts, []),
    #state_ob{outbound=Ob, pos=Pos, regs=RegsOb} = StateOb = get_state(SipAppState),
    case Ob andalso lists:member('$nksip_uac_auto_outbound', UserOpts) of
        true ->
            Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
            Opts1 = [contact, {cseq_num, CSeq}, {meta, Meta}, {reg_id, Pos} | Opts],
            Self = self(),
            #sipapp_srv{app_id=AppId} = SipAppState,
            Fun = fun() ->
                case nksip_uac:register(AppId, RUri, Opts1) of
                    {ok, Code, Meta1} -> ok;
                    _ -> Code=500, Meta1=[{cseq_num, CSeq}]
                end,
                Msg1 = {'$nksip_uac_auto_register_answer', RegId, Code, Meta1},
                gen_server:cast(Self, Msg1)
            end,
            Pid = case Sync of
                true -> Fun(), self();
                false -> spawn_link(Fun)
            end,
            RegOb = #sipreg_ob{id=RegId, cseq=CSeq, req_pid=Pid, pos=Pos, fails=0},
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb),
            StateOb1 = StateOb#state_ob{pos=Pos+1, regs=RegsOb1},
            ?debug(AppId, <<>>, "Started auto registration outbound: ~p", [RegId]),
            {ok, Reg#sipreg{next=undefined}, set_state(StateOb1, SipAppState)};
        false ->
            continue
    end.


%% @private
-spec nkcb_uac_auto_launch_unregister(#sipreg{}, boolean(), nksip_sipapp_srv:state()) -> 
    {ok, nksip_sipapp_srv:state()} | continue | {continue, list()}.

nkcb_uac_auto_launch_unregister(Reg, Sync, SipAppState)->
    #state_ob{regs=RegsOb} = StateOb = get_state(SipAppState),
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
            SipAppState1 = set_state(StateOb#state_ob{regs=RegsOb1}, SipAppState),
            {continue, [Reg, Sync, SipAppState1]};
        false ->
            continue 
    end.


  
%% @private
-spec nkcb_uac_auto_update_register(#sipreg{}, nksip:sip_code(), 
                                    nksip:optslist(), nksip_sipapp_srv:state()) ->
    {ok, #sipreg{}, nksip_sipapp_srv:state()}.

nkcb_uac_auto_update_register(Reg, Code, _Meta, SipAppState) when Code<200 ->
    {ok, Reg, SipAppState};

nkcb_uac_auto_update_register(Reg, Code, Meta, SipAppState) when Code<300 ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #sipapp_srv{app_id=AppId} = SipAppState,
    #state_ob{regs=RegsOb} = StateOb = get_state(SipAppState),
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
                                    ?notice(AppId, CallId, 
                                            "successfully set outbound keep-alive", []),
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
            {continue, [Reg, Code, Meta, set_state(StateOb2, SipAppState)]};
        false ->
            continue
    end;

nkcb_uac_auto_update_register(Reg, Code, Meta, SipAppState) ->
    #sipreg{id=RegId, call_id=CallId} = Reg,
    #state_ob{regs=RegsOb, ob_base_time=BaseTime} = StateOb = get_state(SipAppState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor, fails=Fails}=RegOb1, RegsOb1} ->
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end,
            #sipapp_srv{app_id=AppId} = SipAppState,
            Config = nksip_sipapp_srv:config(AppId),
            MaxTime = nksip_lib:get_value(nksip_uac_auto_outbound_max_time, Config),
            Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
            Elap = round(crypto:rand_uniform(50, 101) * Upper / 100),
            ?notice(AppId, CallId, "Outbound registration failed "
                         "(basetime: ~p, fails: ~p, upper: ~p, time: ~p)",
                         [BaseTime, Fails+1, Upper, Elap]),
            RegOb2 = RegOb1#sipreg_ob{
                conn_monitor = undefined,
                conn_pid = undefined,
                fails = Fails+1
            },
            StateOb2 = StateOb#state_ob{regs=[RegOb2|RegsOb1]},
            SipAppState1 = set_state(StateOb2, SipAppState),
            Reg1 = Reg#sipreg{interval=Elap},
            {continue, [Reg1, Code, Meta, SipAppState1]};
        false ->
            continue
    end.

    
%% ===================================================================
%% Private
%% ===================================================================

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


%% @private
get_state(SipAppState) ->
    nksip_sipapp_srv:get_meta(nksip_uac_auto_outbound, SipAppState).


%% @private
set_state(State, SipAppState) ->
    nksip_sipapp_srv:set_meta(nksip_uac_auto_outbound, State, SipAppState).

