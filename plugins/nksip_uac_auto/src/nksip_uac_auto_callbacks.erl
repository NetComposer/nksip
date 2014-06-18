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
-export([nkcb_uac_auto_launch_register/2, nkcb_uac_auto_launch_unregister/2, 
         nkcb_uac_auto_update_register/4, 
         nkcb_uac_auto_launch_ping/2, nkcb_uac_auto_update_ping/4]).

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-include("nksip_uac_auto.hrl").



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @private 
nkcb_init(AppId, AllState) ->
    Config = AppId:config(),
    Timer = 1000 * nksip_lib:get_value(nksip_uac_auto_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_timer'),
    RegTime = nksip_lib:get_integer(nksip_uac_auto_register_expires, Config),
    case nksip_lib:get_value(nksip_uac_auto_register, Config) of
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
    State = #state{pings=[], regs=[]},
    {continue, [AppId, set_state(State, AllState)]}.


%% @private 
nkcb_handle_call(AppId, {'$nksip_uac_auto_start_register', RegId, Uri, Opts}, 
                   From, AllState) ->
    #state{regs=Regs} = State = get_state(AllState),
    case nksip_lib:get_value(call_id, Opts) of
        undefined -> 
            CallId = nksip_lib:luid(),
            Opts1 = [{call_id, CallId}|Opts];
        CallId -> 
            Opts1 = Opts
    end,
    case nksip_lib:get_value(expires, Opts) of
        undefined -> 
            Expires = 300,
            Opts2 = [{expires, Expires}|Opts1];
        Expires -> 
            Opts2 = Opts1
    end,
    Opts3 = [contact, {meta, [cseq_num]}|Opts2],
    Reg = #sipreg{
        id = RegId,
        ruri = Uri,
        opts = Opts3,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined
    },
    Regs1 = lists:keystore(RegId, #sipreg.id, Regs, Reg),
    ?debug(AppId, CallId, "Started auto registration: ~p", [Reg]),
    gen_server:cast(self(), '$nksip_uac_auto_check'),
    State1 = State#state{regs=Regs1},
    {ok, set_state(State1, AllState)};

nkcb_handle_call(AppId, {'$nksip_uac_auto_stop_register', RegId}, 
                   From, AllState) ->
    #state{regs=Regs} = State = get_state(AllState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs1} -> 
            gen_server:reply(From, ok),
            spawn(fun() -> AppId:nkcb_uac_auto_launch_unregister(AppId, Reg, ) end),
            {ok, set_state(State#state{regs=Regs1}, AllState)};
        false -> 
            gen_server:reply(From, not_found),
            {ok, AllState}
    end;

nkcb_handle_call(_AppId, '$nksip_uac_auto_get_registers', From, AllState) ->
    #state{regs=Regs} = get_state(AllState),
    Now = nksip_lib:timestamp(),
    Info = [
        {RegId, Ok, Next-Now}
        ||  #sipreg{id=RegId, ok=Ok, next=Next} <- Regs
    ],
    gen_server:reply(From, Info),
    {ok, AllState};

nkcb_handle_call(AppId, {'$nksip_uac_auto_start_ping', PingId, Uri, Opts}, 
                   From,  AllState) ->
    #state{pings=Pings} = State = get_state(AllState),
    case nksip_lib:get_value(call_id, Opts) of
        undefined -> 
            CallId = nksip_lib:luid(),
            Opts1 = [{call_id, CallId}|Opts];
        CallId -> 
            Opts1 = Opts
    end,
    case nksip_lib:get_value(expires, Opts) of
        undefined -> 
            Expires = 300,
            Opts2 = Opts1;
        Expires -> 
            Opts2 = nksip_lib:delete(Opts1, expires)
    end,
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts2,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined
    },
    ?debug(AppId, CallId, "Started auto ping: ~p", [Ping]),
    Pinsg1 = lists:keystore(PingId, #sipreg.id, Pings, Ping),
    gen_server:cast(self(), '$nksip_uac_auto_check'),
    State1 = State#state{pings=Pinsg1},
    {ok, set_state(State1, AllState)};

nkcb_handle_call(_AppId, {'$nksip_uac_auto_stop_ping', PingId}, From, AllState) ->
    #state{pings=Pings} = State = get_state(AllState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            gen_server:reply(From, ok),
            {ok, set_state(State#state{pings=Pings1}, AllState)};
        false -> 
            gen_server:reply(From, not_found),
            {ok, AllState}
    end;

nkcb_handle_call(_AppId, '$nksip_uac_auto_get_pings', From, AllState) ->
    #state{pings=Pings} = get_state(AllState),
    Now = nksip_lib:timestamp(),
    Info = [
        {PingId, Ok, Next-Now}
        ||  #sipreg{id=PingId, ok=Ok, next=Next} <- Pings
    ],
    gen_server:reply(From, Info),
    {ok, AllState};

nkcb_handle_call(_AppId, _Msg, _From, _AllState) ->
    continue.


%% @private
nkcb_handle_cast(AppId, {'$nksip_uac_auto_register_answer', RegId, Code, Meta}, 
                   AllState) ->
    #state{regs=Regs} = State = get_state(AllState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK}=Reg, Regs1} ->
            #sipreg{ok=OK} = Reg1 = 
                AppId:nkcb_uac_auto_update_register(Reg, Code, Meta, State),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    AppId:nkcb_call(sip_uac_auto_register_update, [RegId, OK, AppId], AppId)
            end,
            State1 = State#state{regs=[Reg1|Regs1]},
            {ok, set_state(State1, AllState)};
        false ->
            {ok, AllState}
    end;

nkcb_handle_cast(AppId, {'$nksip_uac_auto_ping_answer', PingId, Code, Meta}, 
                    AllState) ->
    #state{pings=Pings} = State = get_state(AllState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK}=Ping, Pings1} ->
            #sipreg{ok=OK} = Ping1 = 
                AppId:nkcb_uac_auto_update_ping(Ping, Code, Meta, State),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    AppId:nkcb_call(sip_uac_auto_ping_update, [PingId, OK, AppId], AppId)
            end,
            State1 = State#state{pings=[Ping1|Pings1]},
            {ok, set_state(State1, AllState)};
        false ->
            {ok, AllState}
    end;

nkcb_handle_cast(_AppId, '$nksip_uac_auto_force_regs', AllState) ->
    #state{regs=Regs} = State = get_state(AllState),
    Regs1 = lists:map(
        fun(#sipreg{next=Next}=SipReg) ->
            case is_integer(Next) of
                true -> SipReg#sipreg{next=0};
                false -> SipReg
            end
        end,
        Regs),
    {ok, set_state(State#state{regs=Regs1}, AllState)};

nkcb_handle_cast(AppId, '$nksip_uac_auto_check', AllState) ->
    #state{pings=Pings, regs=Regs} = State = get_state(AllState),
    Now = nksip_lib:timestamp(),
    Pings1 = check_pings(AppId, Now, Pings, []),
    Regs1 = check_registers(AppId, Now, Regs, []),
    State1 = State#state{pings=Pings1, regs=Regs1},
    {ok, set_state(State1, AllState)};

nkcb_handle_cast(_ApId, _Msg, _AllState) ->
    continue.


%% @private
nkcb_handle_info(AppId, {timeout, _, '$nksip_uac_auto_timer'}, _AllState) ->
    Config = AppId:config(),
    Timer = 1000 * nksip_lib:get_value(nksip_uac_auto_timer, Config),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_timer'),
    gen_server:cast(self(), '$nksip_uac_auto_check'),
    continue;

nkcb_handle_info(_AppId, _Msg, _AllState) ->
    continue.


%% @private
nkcb_terminate(AppId, _Reason, AllState) ->  
    #state{regs=Regs} = get_state(AllState),
    lists:foreach(
        fun(#sipreg{ok=Ok}=Reg) -> 
            case Ok of
                true -> AppId:nkcb_uac_auto_launch_unregister(AppId, Reg);
                _ -> ok
            end
        end,
        Regs),
    continue.



%% ===================================================================
%% Callbacks offered to second-level plugins
%% ===================================================================


%% @private
-spec nkcb_uac_auto_launch_register(nksip:app_id(), #sipreg{}) -> 
    #sipreg{}.

nkcb_uac_auto_launch_register(AppId, Reg)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,    
    Opts1 = [{cseq_num, CSeq}, {meta, [cseq_num, retry_after]}|Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_register_answer', RegId, Code, Meta})
    end,
    spawn_link(Fun),
    Reg#sipreg{next=undefined}.
    

%% @private
-spec nkcb_uac_auto_launch_unregister(nksip:app_id(), #sipreg{}) -> 
    ok.

nkcb_uac_auto_launch_unregister(AppId, Reg)->
    #sipreg{ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts1 = [{cseq_num, CSeq}|lists:keystore(expires, 1, Opts, {expires, 0})],
    nksip_uac:register(AppId, RUri, Opts1),
    ok.

   
%% @private
-spec nkcb_uac_auto_update_register(#sipreg{}, nksip:sip_code(), nksip:optslist(), #state{}) ->
    #sipreg{}.

nkcb_uac_auto_update_register(Reg, Code, _Meta, _State) when Code<200 ->
    Reg;

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


%%%%%% Ping

%% @private
-spec nkcb_uac_auto_launch_ping(nksip:app_id(), #sipreg{}) -> 
    #sipreg{}.

nkcb_uac_auto_launch_ping(AppId, Ping)->
    #sipreg{id=PingId, ruri=RUri, opts=Opts, cseq=CSeq} = Ping,
    Opts1 = [{cseq_num, CSeq}, {meta, [cseq_num, retry_after]} | Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:options(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_ping_answer', PingId, Code, Meta})
    end,
    spawn_link(Fun),
    Ping#sipreg{next=undefined}.


   
%% @private
-spec nkcb_uac_auto_update_ping(#sipreg{}, nksip:sip_code(), nksip:optslist(), #state{}) ->
    #sipreg{}.

nkcb_uac_auto_update_ping(Ping, Code, _Meta, _State) when Code<200 ->
    Ping;

nkcb_uac_auto_update_ping(Ping, Code, Meta, _State) ->
    #sipreg{from=From, interval=Interval} = Ping,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nksip:get_value(retry_after, Meta) of
        false -> Interval;
        undefined -> Interval;
        Retry -> Retry
    end,
    Ping#sipreg{
        ok = Code < 300,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nksip_lib:timestamp() + Time
    }.


%% ===================================================================
%% Private
%% ===================================================================

%% @private
check_pings(AppId, Now, [#sipreg{next=Next}=Ping|Rest], Acc) ->
    Acc1 = case is_integer(Next) andalso Now>=Next of 
        true -> 
            [AppId:nkcb_uac_auto_launch_ping(AppId, Ping)|Acc];
        false ->
            [Ping|Acc]
    end,
    check_pings(AppId, Now, Rest, Acc1);

check_pings(_, _, [], Acc) ->
    Acc.


%% @private Only one register in each cycle
check_registers(AppId, Now, [#sipreg{next=Next}=Reg|Rest], Acc) ->
    case Now>=Next of
        true -> 
            Reg1 = AppId:nkcb_uac_auto_launch_register(AppId, Reg),
            check_registers(AppId, -1, Rest, [Reg1|Acc]);
        false ->
            check_registers(AppId, Now, Rest, [Reg|Acc])
    end;

check_registers(_, _, [], Acc) ->
    Acc.


%% @private
get_state(AllState) ->
    nksip_sipapp_srv:get_plugin_state(nksip_uac_auto, AllState).


%% @private
set_state(State, AllState) ->
    nksip_sipapp_srv:set_plugin_state(nksip_uac_auto, State, AllState).

