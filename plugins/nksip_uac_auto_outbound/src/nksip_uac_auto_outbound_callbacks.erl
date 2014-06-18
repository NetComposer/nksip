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

-export([nkcb_init/2, nkcb_handle_call/4, nkcb_handle_cast/3, 
         nkcb_handle_info/3, nkcb_terminate/3]).

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
        app_id = AppId,
        outbound = lists:member(<<"outbound">>, Supported),
        ob_base_time = nksip_lib:get_value(nksip_uac_auto_outbound_any_ok, Config),
        pos = 1,
        regs = []
    },
    StateOb1 = set_state(StateOb, AllState),
    {continue, [AppId, StateOb1]}.


%% @private 
nkcb_handle_call(AppId, {'$nksip_uac_auto_start_register', RegId, Uri, Time, Opts}, 
                 From, AllState) ->
    StateOb = get_state(AllState),
    case StateOb of
        #state_ob{outbound=true, pos=Pos, regs=RegsOb} ->
            Opts1 = [{reg_id, Pos}|Opts],
            RegOb = #sipreg_ob{id=RegId, pos=Pos, fails=0},
            RegsOb1 = lists:keystore(RegId, #sipreg_ob.id, RegsOb, RegOb),
            StateOb1 = StateOb#state_ob{pos=Pos+1, regs=RegsOb1},
            ?debug(AppId, <<>>, "Started auto registration outbound: ~p", [RegId]),
            Args1 = [
                AppId, 
                {'$nksip_uac_auto_start_register', RegId, Uri, Time, Opts1},
                From,
                set_state(StateOb1, AllState)
            ],
            {continue, Args1};
        _ ->
            continue
    end;

nkcb_handle_call(AppId, {'$nksip_uac_auto_stop_register', RegId}, From, AllState) ->
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, #sipreg_ob{conn_monitor=Monitor}, RegsOb1} -> 
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end, 
            Args1 = [
                AppId,
                {'$nksip_uac_auto_stop_register', RegId},
                From,
                set_state(StateOb#state_ob{regs=RegsOb1}, AllState)
            ],
            {continue, Args1};
        false ->
            continue 
    end;

nkcb_handle_call(_ApId, _Msg, _From, _AllState) ->
    continue.


%% @private
nkcb_handle_cast(_AppId, {'$nksip_uac_auto_register_answer', RegId, Code, Meta}, 
                 AllState) ->
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    case lists:keyfind(RegId, #sipreg_ob.id, RegsOb) of
        #sipreg_ob{} = RegOb ->
            nksip_uac_auto_outbound_lib:update_register(RegOb, Code, Meta, StateOb);
        false ->
            ok
    end,
    continue;

nkcb_handle_cast(_ApId, _Msg, _AllState) ->
    continue.


%% @private
nkcb_handle_info(AppId, {'DOWN', Mon, process, _Pid, _}, AllState) ->
    #state_ob{regs=RegsOb} = get_state(AllState),
    case lists:keyfind(Mon, #sipreg_ob.conn_monitor, RegsOb) of
        #sipreg_ob{id=RegId} ->
            ?info(AppId, <<>>, "register outbound flow ~p has failed", [RegId]),
            % Meta = [{cseq_num, CSeq}],
            Msg = {'$nksip_uac_auto_register_answer', RegId, 503, []},
            gen_server:cast(self(), Msg),
            {ok, AllState};
        false ->
            continue
    end;

nkcb_handle_info(_AppId, {'$nksip_uac_auto_register_notify', RegId}, AllState) ->
    #state_ob{regs=RegsOb} = StateOb = get_state(AllState),
    case lists:keytake(RegId, #sipreg_ob.id, RegsOb) of
        {value, RegOb, RegsOb1} -> 
            State1 = StateOb#state_ob{regs=[RegOb#sipreg_ob{fails=0}|RegsOb1]},
            State2 = nksip_uac_auto_outbound_lib:update_basetime(State1),
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
-spec nkcb_uac_auto_launch_register(nksip:app_id(), #sipreg{}) -> 
    #sipreg{}.

nkcb_uac_auto_launch_register(AppId, Reg)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,   
    Meta = [cseq_num, retry_after, remote, require, <<"flow-timer">>],
    Opts1 = [{cseq_num, CSeq}, {meta, Meta} | Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_register_answer', RegId, Code, Meta})
    end,
    _Pid = spawn_link(Fun),
    Reg#sipreg{next=undefined}.
    


%% @private
-spec launch_unregister(nksip:app_id(), #sipreg{}) -> 
    ok.

nkcb_uac_auto_launch_unregister(AppId, Reg)->
    #sipreg{ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts1 = [{cseq_num, CSeq}|lists:keystore(expires, 1, Opts, {expires, 0})],
    nksip_uac:register(AppId, RUri, Opts1),
    % case is_pid(Pid) of
    %     true -> nksip_connection:stop_refresh(Pid);
    %     false -> ok
    % end.
    ok.

  
%% @private
-spec update_register(#sipreg{}, nksip:sip_code(), nksip:optslist(), #state{}) ->
    #sipreg{}.


nkcb_uac_auto_update_register(Reg, Code, Meta, _State) ->
    #sipreg{interval=Interval, from=From} = Reg,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nksip:get_value(retry_after, Meta) of
        false -> Interval;
        undefined -> Interval;
        Retry -> Retry
    end,
    Reg#sipreg{
        ok = Code < 300,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nksip_lib:timestamp() + Time
    }.


update_register(Reg, Code, Meta, #state{app_id=AppId}) when Code>=200, Code<300 ->
    #sipreg{id=RegId, conn_monitor=Monitor, interval=Interval, 
            from=From, call_id=CallId} = Reg,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, true})
    end,
    case is_reference(Monitor) of
        true -> erlang:demonitor(Monitor);
        false -> ok
    end,
    {Proto, Ip, Port, Res} = nksip_lib:get_value(remote, Meta),
    Require = nksip_lib:get_value(require, Meta),
    % 'fails' is not updated until the connection confirmation arrives
    % (or process down)
    Reg1 = Reg#sipreg{
        ok = true,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nksip_lib:timestamp() + Interval
    },
    case lists:member(<<"outbound">>, Require) of
        true ->
            case nksip_transport:get_connected(AppId, Proto, Ip, Port, Res) of
                [{_, Pid}|_] -> 
                    Secs = case nksip_lib:get_integer(<<"flow-timer">>, Meta) of
                        FT when is_integer(FT), FT > 5 -> FT;
                        _ when Proto==udp -> ?DEFAULT_UDP_KEEPALIVE;
                        _ -> ?DEFAULT_TCP_KEEPALIVE
                    end,
                    Ref = {'$nksip_uac_auto_register_notify', RegId},
                    case nksip_connection:start_refresh(Pid, Secs, Ref) of
                        ok -> 
                            Mon = erlang:monitor(process, Pid),
                            Reg1#sipreg{conn_monitor=Mon, conn_pid=Pid};
                        error -> 
                            ?notice(AppId, CallId, 
                                    "could not start outbound keep-alive", []),
                            Reg1
                    end;
                [] -> 
                    Reg1
            end;
        false ->
            Reg1
    end;

update_register(Reg, Code, Meta, State) ->
    #sipreg{conn_monitor=Monitor, fails=Fails, from=From, call_id=CallId} = Reg,
    #state{app_id=AppId, ob_base_time=BaseTime} = State,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, false})
    end,
    case is_reference(Monitor) of
        true -> erlang:demonitor(Monitor);
        false -> ok
    end,
    Config = nksip_sipapp_srv:config(AppId),
    MaxTime = nksip_lib:get_value(nksip_uac_auto_outbound_max_time, Config),
    Upper = min(MaxTime, BaseTime*math:pow(2, Fails+1)),
    Elap = round(crypto:rand_uniform(50, 101) * Upper / 100),
    Add = case Code==503 andalso nksip_lib:get_value(<<"retry-after">>, Meta) of
        [Retry1] ->
            case nksip_lib:to_integer(Retry1) of
                Retry2 when Retry2 > 0 -> Retry2;
                _ -> 0
            end;
        _ -> 
            0
    end,
    ?notice(AppId, CallId, "Outbound registration failed "
                 "Basetime: ~p, fails: ~p, upper: ~p, time: ~p",
                 [BaseTime, Fails+1, Upper, Elap]),
    Reg#sipreg{
        ok = false,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        conn_monitor = undefined,
        conn_pid = undefined,
        next = nksip_lib:timestamp() + Elap + Add,
        fails = Fails+1
    }.

%% @private
update_basetime(#state{app_id=AppId, regs=Regs}=State) ->
    Key = case [true || #sipreg{fails=0} <- Regs] of
        [] -> 
            ?notice(AppId, <<>>, "all outbound flows have failed", []),
            nksip_uac_auto_outbound_all_fail;
        _ -> 
            nksip_uac_auto_outbound_any_ok
    end,
    Config = nksip_sipapp_srv:config(AppId),
    State#state{ob_base_time=nksip_lib:get_value(Key, Config)}.














































%% ===================================================================
%% Private
%% ===================================================================

%% @private
get_state(AllState) ->
    nksip_sipapp_srv:get_plugin_state(nksip_uac_auto_outbound, AllState).


%% @private
set_state(State, AllState) ->
    nksip_sipapp_srv:set_plugin_state(nksip_uac_auto_outbound, State, AllState).

