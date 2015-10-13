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

%% @private nksip_uac_auto_register plugin callbacksuests and related functions.
-module(nksip_uac_auto_register_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([nks_uac_auto_register_launch_register/3, 
         nks_uac_auto_register_launch_unregister/3, 
         nks_uac_auto_register_update_register/4, 
         nks_uac_auto_register_launch_ping/2, 
         nks_uac_auto_register_update_ping/4]).

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").



%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @private 
handle_call({'$nksip_uac_auto_register_start_register', RegId, Uri, Opts}, 
            From, #{srv_id:=SrvId}=ServiceState) ->
    #state{regs=Regs} = State = get_state(ServiceState),
    case nklib_util:get_value(call_id, Opts) of
        undefined -> 
            CallId = nklib_util:luid(),
            Opts1 = [{call_id, CallId}|Opts];
        CallId -> 
            Opts1 = Opts
    end,
    case nklib_util:get_value(expires, Opts) of
        undefined -> 
            Expires = 300,
            Opts2 = [{expires, Expires}|Opts1];
        Expires -> 
            Opts2 = Opts1
    end,
    Reg = #sipreg{
        id = RegId,
        ruri = Uri,
        opts = Opts2,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_util:get_cseq(),
        next = 0,
        ok = undefined
    },
    Regs1 = lists:keystore(RegId, #sipreg.id, Regs, Reg),
    ?debug(SrvId, CallId, "Started auto registration: ~p", [Reg]),
    gen_server:cast(self(), '$nksip_uac_auto_register_check'),
    State1 = State#state{regs=Regs1},
    {noreply, set_state(State1, ServiceState)};

handle_call({'$nksip_uac_auto_register_stop_register', RegId}, 
            _From, #{srv_id:=SrvId}=ServiceState) ->
    #state{regs=Regs} = State = get_state(ServiceState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs1} -> 
            {ok, ServiceState1} = 
                SrvId:nks_uac_auto_register_launch_unregister(Reg, false, ServiceState),
            {reply, ok, set_state(State#state{regs=Regs1}, ServiceState1)};
        false -> 
            {reply, not_found, ServiceState}
    end;

handle_call('$nksip_uac_auto_register_get_registers', _From, ServiceState) ->
    #state{regs=Regs} = get_state(ServiceState),
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now}
        ||  #sipreg{id=RegId, ok=Ok, next=Next} <- Regs
    ],
    {reply, Info, ServiceState};

handle_call({'$nksip_uac_auto_register_start_ping', PingId, Uri, Opts}, 
            From,  #{srv_id:=SrvId}=ServiceState) ->
    #state{pings=Pings} = State = get_state(ServiceState),
    case nklib_util:get_value(call_id, Opts) of
        undefined -> 
            CallId = nklib_util:luid(),
            Opts1 = [{call_id, CallId}|Opts];
        CallId -> 
            Opts1 = Opts
    end,
    case nklib_util:get_value(expires, Opts) of
        undefined -> 
            Expires = 300,
            Opts2 = Opts1;
        Expires -> 
            Opts2 = nklib_util:delete(Opts1, expires)
    end,
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts2,
        call_id = CallId,
        interval = Expires,
        from = From,
        cseq = nksip_util:get_cseq(),
        next = 0,
        ok = undefined
    },
    ?info(SrvId, CallId, "Started auto ping: ~p", [Ping]),
    Pinsg1 = lists:keystore(PingId, #sipreg.id, Pings, Ping),
    gen_server:cast(self(), '$nksip_uac_auto_register_check'),
    State1 = State#state{pings=Pinsg1},
    {noreply, set_state(State1, ServiceState)};

handle_call({'$nksip_uac_auto_register_stop_ping', PingId}, _From, ServiceState) ->
    #state{pings=Pings} = State = get_state(ServiceState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            {reply, ok, set_state(State#state{pings=Pings1}, ServiceState)};
        false -> 
            {reply, not_found, ServiceState}
    end;

handle_call('$nksip_uac_auto_register_get_pings', _From, ServiceState) ->
    #state{pings=Pings} = get_state(ServiceState),
    Now = nklib_util:timestamp(),
    Info = [
        {PingId, Ok, Next-Now}
        ||  #sipreg{id=PingId, ok=Ok, next=Next} <- Pings
    ],
    {reply, Info, ServiceState};

handle_call(_Msg, _From, _ServiceState) ->
    continue.


%% @private
handle_cast({'$nksip_uac_auto_register_answer_register', RegId, Code, Meta}, 
                 #{srv_id:=SrvId}=ServiceState) ->
    #state{regs=Regs} = State = get_state(ServiceState),
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK}=Reg, Regs1} ->
            {ok, Reg1, ServiceState1} = 
                SrvId:nks_uac_auto_register_update_register(Reg, Code, Meta, ServiceState),
            #sipreg{ok=Ok} = Reg1,
            case Ok of
                OldOK -> 
                    ok;
                _ -> 
                    SrvId:nks_call(sip_uac_auto_register_updated_register, 
                                    [RegId, Ok, SrvId], SrvId)
            end,
            State1 = State#state{regs=[Reg1|Regs1]},
            {noreply, set_state(State1, ServiceState1)};
        false ->
            {noreply, ServiceState}
    end;

handle_cast({'$nksip_uac_auto_register_answer_ping', PingId, Code, Meta}, 
            #{srv_id:=SrvId}=ServiceState) ->
    #state{pings=Pings} = State = get_state(ServiceState),
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK}=Ping, Pings1} ->
            {ok, #sipreg{ok=OK}=Ping1, ServiceState1} = 
                SrvId:nks_uac_auto_register_update_ping(Ping, Code, Meta, ServiceState),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    SrvId:nks_call(sip_uac_auto_register_updated_ping, [PingId, OK, SrvId], SrvId)
            end,
            State1 = State#state{pings=[Ping1|Pings1]},
            {noreply, set_state(State1, ServiceState1)};
        false ->
            {noreply, ServiceState}
    end;

handle_cast('$nksip_uac_auto_register_force_regs', ServiceState) ->
    #state{regs=Regs} = State = get_state(ServiceState),
    Regs1 = lists:map(
        fun(#sipreg{next=Next}=SipReg) ->
            case is_integer(Next) of
                true -> SipReg#sipreg{next=0};
                false -> SipReg
            end
        end,
        Regs),
    {noreply, set_state(State#state{regs=Regs1}, ServiceState)};

handle_cast('$nksip_uac_auto_register_check', ServiceState) ->
    #state{pings=Pings, regs=Regs} = State = get_state(ServiceState),
    Now = nklib_util:timestamp(),
    {Pings1, ServiceState1} = check_pings(Now, Pings, [], ServiceState),
    {Regs1, ServiceState2} = check_registers(Now, Regs, [], ServiceState1),
    State1 = State#state{pings=Pings1, regs=Regs1},
    {noreply, set_state(State1, ServiceState2)};

handle_cast(_Msg, _ServiceState) ->
    continue.


%% @private
handle_info({timeout, _, '$nksip_uac_auto_register_timer'}, 
            #{srv_id:=SrvId}=ServiceState) ->
    Timer = 1000 * SrvId:cache_sip_uac_auto_register_timer(),
    erlang:start_timer(Timer, self(), '$nksip_uac_auto_register_timer'),
    gen_server:cast(self(), '$nksip_uac_auto_register_check'),
    {noreply, ServiceState};

handle_info(_Msg, _ServiceState) ->
    continue.


%% ===================================================================
%% Callbacks offered to second-level plugins
%% ===================================================================


%% @private
-spec nks_uac_auto_register_launch_register(#sipreg{}, boolean(), nkservice_server:sub_state()) -> 
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_uac_auto_register_launch_register(Reg, Sync, #{srv_id:=SrvId}=ServiceState)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,    
    Opts1 = [contact, {cseq_num, CSeq}, {meta, [cseq_num, retry_after]}|Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(SrvId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_register_answer_register', RegId, Code, Meta})
    end,
    case Sync of
        true -> Fun();
        false -> spawn_link(Fun)
    end,
    {ok, Reg#sipreg{next=undefined}, ServiceState}.
    

%% @private
-spec nks_uac_auto_register_launch_unregister(#sipreg{}, boolean(), nkservice_server:sub_state()) -> 
    {ok, nkservice_server:sub_state()}.

nks_uac_auto_register_launch_unregister(Reg, Sync, #{srv_id:=SrvId}=ServiceState)->
    #sipreg{ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts1 = [contact, {cseq_num, CSeq}|nklib_util:store_value(expires, 0, Opts)],
    Fun = fun() -> nksip_uac:register(SrvId, RUri, Opts1) end,
    case Sync of
        true -> Fun();
        false -> spawn_link(Fun)
    end,
    {ok, ServiceState}.

   
%% @private
-spec nks_uac_auto_register_update_register(#sipreg{}, nksip:sip_code(), 
                                    nksip:optslist(), nkservice_server:sub_state()) ->
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_uac_auto_register_update_register(Reg, Code, _Meta, ServiceState) when Code<200 ->
    {ok, Reg, ServiceState};

nks_uac_auto_register_update_register(Reg, Code, Meta, ServiceState) ->
    #sipreg{interval=Interval, from=From} = Reg,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nklib_util:get_value(retry_after, Meta) of
        false -> Interval;
        undefined -> Interval;
        Retry -> Retry
    end,
    Reg1 = Reg#sipreg{
        ok = Code < 300,
        cseq = nklib_util:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nklib_util:timestamp() + Time
    },
    {ok, Reg1, ServiceState}.


%%%%%% Ping

%% @private
-spec nks_uac_auto_register_launch_ping(#sipreg{}, nkservice_server:sub_state()) -> 
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_uac_auto_register_launch_ping(Ping, #{srv_id:=SrvId}=ServiceState)->
    #sipreg{id=PingId, ruri=RUri, opts=Opts, cseq=CSeq} = Ping,
    Opts1 = [{cseq_num, CSeq}, {meta, [cseq_num, retry_after]} | Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:options(SrvId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_register_answer_ping', PingId, Code, Meta})
    end,
    spawn_link(Fun),
    {ok, Ping#sipreg{next=undefined}, ServiceState}.


   
%% @private
-spec nks_uac_auto_register_update_ping(#sipreg{}, nksip:sip_code(), 
                                nksip:optslist(), nkservice_server:sub_state()) ->
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_uac_auto_register_update_ping(Ping, Code, _Meta, ServiceState) when Code<200 ->
    {ok, Ping, ServiceState};

nks_uac_auto_register_update_ping(Ping, Code, Meta, ServiceState) ->
    #sipreg{from=From, interval=Interval} = Ping,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, Code<300})
    end,
    Time = case Code==503 andalso nklib_util:get_value(retry_after, Meta) of
        false -> Interval;
        undefined -> Interval;
        Retry -> Retry
    end,
    Ping1 = Ping#sipreg{
        ok = Code < 300,
        cseq = nklib_util:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nklib_util:timestamp() + Time
    },
    {ok, Ping1, ServiceState}.



%% ===================================================================
%% Private
%% ===================================================================

%% @private
check_pings(Now, [#sipreg{next=Next}=Ping|Rest], Acc, #{srv_id:=SrvId}=ServiceState) ->
    case is_integer(Next) andalso Now>=Next of 
        true -> 
            {ok, Ping1, ServiceState1} = 
                SrvId:nks_uac_auto_register_launch_ping(Ping, ServiceState),
            check_pings(Now, Rest, [Ping1|Acc], ServiceState1);
        false ->
            check_pings(Now, Rest, [Ping|Acc], ServiceState)
    end;
    
check_pings(_, [], Acc, ServiceState) ->
    {Acc, ServiceState}.


%% @private Only one register in each cycle
check_registers(Now, [#sipreg{next=Next}=Reg|Rest], Acc, #{srv_id:=SrvId}=ServiceState) ->
    case Now>=Next of
        true -> 
            {ok, Reg1, ServiceState1} = 
                SrvId:nks_uac_auto_register_launch_register(Reg, false, ServiceState),
            check_registers(-1, Rest, [Reg1|Acc], ServiceState1);
        false ->
            check_registers(Now, Rest, [Reg|Acc], ServiceState)
    end;

check_registers(_, [], Acc, ServiceState) ->
    {Acc, ServiceState}.


%% @private
get_state(#{nksip_uac_auto_register:=State}) ->
    State.


%% @private
set_state(State, ServiceState) ->
    ServiceState#{nksip_uac_auto_register=>State}.

