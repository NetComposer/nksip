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
-module(nksip_uac_auto_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([nkcb_init/2, nkcb_handle_call/4, nkcb_handle_cast/3, 
         nkcb_handle_info/3, nkcb_terminate/3]).

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-include("nksip_uac_auto.hrl").

%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @private 
nkcb_init(AppId, PluginsState) ->
    Config = AppId:config(),
    Timer = 1000 * nksip_lib:get_value(nksip_uac_auto_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_timer'),
    RegTime = nksip_lib:get_integer(nksip_uac_auto_expires, Config),
    case nksip_lib:get_value(register, Config) of
        undefined ->
            ok;
        RegUris ->
            Regs = lists:zip(lists:seq(1, length(RegUris)), RegUris),
            lists:foreach(
                fun({Pos, Uri}) ->
                    Name = <<"auto-", (nksip_lib:to_binary(Pos))/binary>>,
                    spawn_link(
                        fun() -> 
                            nksip_uac_auto:start_register(AppId, Name, Uri, RegTime, Config) 
                        end)
                end,
                Regs)
    end,
    Supported = AppId:config_supported(),
    State = #state{
        app_id = AppId, 
        outbound = lists:member(<<"outbound">>, Supported),
        ob_base_time = nksip_lib:get_value(nksip_uac_outbound_any_ok, Config),
        pos = 1,
        pings = [], 
        regs = []
    },
    {continue, [AppId, set_state(State, PluginsState)]}.


%% @private 
nkcb_handle_call(AppId, {'$nksip_uac_auto_start_register', RegId, Uri, Time, Opts}, 
                   From, PluginsState) ->
    State = get_state(PluginsState),
    #state{app_id=AppId, outbound=Outbound, pos=Pos, regs=Regs} = State,
    Opts1 = case lists:keymember(reg_id, 1, Opts) of
        false when Outbound -> [{reg_id, Pos}];
        _ -> Opts
    end,
    CallId = nksip_lib:luid(),
    Reg = #sipreg{
        id = RegId,
        pos = Pos,
        ruri = Uri,
        opts = Opts1,
        call_id = CallId,
        interval = Time,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined,
        fails = 0
    },
    Regs1 = lists:keystore(RegId, #sipreg.id, Regs, Reg),
    ?debug(AppId, CallId, "Started auto registration: ~p", [Reg]),
    State1 = timer(State#state{pos=Pos+1, regs=Regs1}),
    {ok, set_state(State1, PluginsState)};

nkcb_handle_call(AppId, {'$nksip_uac_auto_stop_register', RegId}, 
                   From, PluginsState) ->
    #state{app_id=AppId, regs=Regs} = State = get_state(PluginsState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{conn_monitor=Monitor}=Reg, Regs1} -> 
            gen_server:reply(From, ok),
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end, 
            spawn(fun() -> nksip_uac_auto_lib:launch_unregister(AppId, Reg) end),
            {ok, set_state(State#state{regs=Regs1}, PluginsState)};
        false -> 
            gen_server:reply(From, not_found),
            {ok, PluginsState}
    end;

nkcb_handle_call(AppId, '$nksip_uac_auto_get_registers', From, PluginsState) ->
    #state{app_id=AppId, regs=Regs} = get_state(PluginsState),
    Now = nksip_lib:timestamp(),
    Info = [
        {RegId, Ok, Next-Now}
        ||  #sipreg{id=RegId, ok=Ok, next=Next} <- Regs
    ],
    gen_server:reply(From, Info),
    {ok, PluginsState};

nkcb_handle_call(AppId, {'$nksip_uac_auto_start_ping', PingId, Uri, Time, Opts}, 
                   From,  PluginsState) ->
    #state{app_id=AppId, pings=Pings} = State = get_state(PluginsState),
    CallId = nksip_lib:luid(),
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts,
        call_id = CallId,
        interval = Time,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined
    },
    ?debug(AppId, CallId, "Started auto ping: ~p", [Ping]),
    Pinsg1 = lists:keystore(PingId, #sipreg.id, Pings, Ping),
    State1 = timer(State#state{pings=Pinsg1}),
    {ok, set_state(State1, PluginsState)};

nkcb_handle_call(AppId, {'$nksip_uac_auto_stop_ping', PingId}, From, PluginsState) ->
    #state{app_id=AppId, pings=Pings} = State = get_state(PluginsState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            gen_server:reply(From, ok),
            {ok, set_state(State#state{pings=Pings1}, PluginsState)};
        false -> 
            gen_server:reply(From, not_found),
            {ok, PluginsState}
    end;

nkcb_handle_call(AppId, '$nksip_uac_auto_get_pings', From, PluginsState) ->
    #state{app_id=AppId, pings=Pings} = get_state(PluginsState),
    Now = nksip_lib:timestamp(),
    Info = [
        {PingId, Ok, Next-Now}
        ||  #sipreg{id=PingId, ok=Ok, next=Next} <- Pings
    ],
    gen_server:reply(From, Info),
    {ok, PluginsState};

nkcb_handle_call(_AppId, _Msg, _From, _PluginsState) ->
    continue.


%% @private
nkcb_handle_cast(AppId, {'$nksip_uac_auto_register_answer', RegId, Code, Meta}, 
                   PluginsState) ->
    #state{app_id=AppId, regs=Regs} = State = get_state(PluginsState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK}=Reg, Regs1} ->
            #sipreg{ok=OK} = Reg1 = 
                nksip_uac_auto_lib:update_register(Reg, Code, Meta, State),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    AppId:nkcb_call(sip_uac_auto_register_update, [RegId, OK, AppId], AppId)
            end,
            State1 = nksip_uac_auto_lib:update_basetime(State#state{regs=[Reg1|Regs1]}),
            {ok, set_state(State1, PluginsState)};
        false ->
            {ok, PluginsState}
    end;

nkcb_handle_cast(AppId, {'$nksip_uac_auto_ping_answer', PingId, Code, Meta}, 
                    PluginsState) ->
    #state{app_id=AppId, pings=Pings} = State = get_state(PluginsState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK}=Ping, Pings1} ->
            #sipreg{ok=OK} = Ping1 = 
                nksip_uac_auto_lib:update_ping(Ping, Code, Meta, State),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    AppId:nkcb_call(sip_uac_auto_ping_update, [PingId, OK, AppId], AppId)
            end,
            State1 = State#state{pings=[Ping1|Pings1]},
            {ok, set_state(State1, PluginsState)};
        false ->
            {ok, PluginsState}
    end;

nkcb_handle_cast(AppId, '$nksip_uac_auto_force_regs', PluginsState) ->
    #state{app_id=AppId, regs=Regs} = State = get_state(PluginsState),
    Regs1 = lists:map(
        fun(#sipreg{next=Next}=SipReg) ->
            case is_integer(Next) of
                true -> SipReg#sipreg{next=0};
                false -> SipReg
            end
        end,
        Regs),
    {ok, set_state(State#state{regs=Regs1}, PluginsState)};

nkcb_handle_cast(_ApId, _Msg, _PluginsState) ->
    continue.


%% @private
nkcb_handle_info(AppId, {timeout, _, '$nksip_uac_auto_timer'}, PluginsState) ->
    Config = AppId:config(),
    Timer = 1000 * nksip_lib:get_value(nksip_uac_auto_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_timer'),
    State = get_state(PluginsState),
    State1 = timer(State),
    {ok, set_state(State1,  PluginsState)};

nkcb_handle_info(AppId, {'DOWN', Mon, process, _Pid, _}, PluginsState) ->
    #state{app_id=AppId, regs=Regs} = get_state(PluginsState),
    case lists:keyfind(Mon, #sipreg.conn_monitor, Regs) of
        #sipreg{id=RegId, cseq=CSeq, call_id=CallId} ->
            ?info(AppId, CallId, "register outbound flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            Msg = {'$nksip_uac_auto_register_answer', RegId, 503, Meta},
            gen_server:cast(self(), Msg),
            {ok, PluginsState};
        false ->
            continue
    end;

nkcb_handle_info(AppId, {'$nksip_uac_auto_register_notify', RegId}, PluginsState) ->
    #state{app_id=AppId, regs=Regs} = State = get_state(PluginsState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs1} -> 
            State1 = State#state{regs=[Reg#sipreg{fails=0}|Regs1]},
            {ok, set_state(nksip_uac_auto_lib:update_basetime(State1), PluginsState)};
        false -> 
            continue
    end;

nkcb_handle_info(_AppId, _Msg, _PluginsState) ->
    continue.


%% @private
nkcb_terminate(_AppId, _Reason, PluginsState) ->  
    #state{app_id=AppId, regs=Regs} = get_state(PluginsState),
    lists:foreach(
        fun(#sipreg{ok=Ok}=Reg) -> 
            case Ok of
                true -> nksip_uac_auto_lib:launch_unregister(AppId, Reg);
                _ -> ok
            end
        end,
        Regs),
    continue.



%% ===================================================================
%% Private
%% ===================================================================


%% @private
timer(#state{app_id=AppId, pings=Pings, regs=Regs}=State) ->
    Now = nksip_lib:timestamp(),
    Pings1 = lists:map(
        fun(#sipreg{next=Next}=Ping) ->
            case is_integer(Next) andalso Now>=Next of 
                true -> nksip_uac_auto_lib:launch_ping(AppId, Ping);
                false -> Ping
            end
        end,
        Pings),
    Regs1 = timer_register(AppId, Now, Regs, []),
    State#state{pings=Pings1, regs=Regs1}.


%% @private Only one register in each cycle
timer_register(AppId, Now, [#sipreg{next=Next}=Reg|Rest], Acc) ->
    case Now>=Next of
        true -> 
            Reg1 = nksip_uac_auto_lib:launch_register(AppId, Reg),
            timer_register(AppId, -1, Rest, [Reg1|Acc]);
        false ->
            timer_register(AppId, Now, Rest, [Reg|Acc])
    end;

timer_register(_, _, [], Acc) ->
    Acc.


%% @private
get_state(PluginsState) ->
    {nksip_uac_auto, State} = lists:keyfind(nksip_uac_auto, 1, PluginsState),
    State.


%% @private
set_state(State, PluginsState) ->
    lists:keystore(nksip_uac_auto, 1, PluginsState, {nksip_uac_auto, State}).


