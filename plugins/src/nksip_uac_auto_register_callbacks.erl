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

-export([init/2, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).
-export([nks_sip_uac_auto_register_launch_register/3, 
         nks_sip_uac_auto_register_launch_unregister/3, 
         nks_sip_uac_auto_register_update_register/4, 
         nks_sip_uac_auto_register_launch_ping/2, 
         nks_sip_uac_auto_register_update_ping/4]).

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").
-include("nksip_uac_auto_register.hrl").


%% ===================================================================
%% Plugin Callbacks
%% ===================================================================


%% @doc Called when the service is started 
-spec init(nkservice:spec(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

init(_Spec, #{id:=SrvId}=SrvState) ->
    Timer = 1000 * SrvId:cache_sip_uac_auto_register_timer(),
    erlang:start_timer(Timer, self(), ?MODULE),
    {ok, SrvState#{?MODULE=>#state{pings=[], regs=[]}}}.


%% @doc Called when the service is shutdown
-spec terminate(nkservice:id(), nkservice_server:sub_state()) ->
   {ok, nkservice_server:sub_state()}.

terminate(_Reason, #{id:=SrvId, ?MODULE:=#state{regs=Regs}}=SrvState) ->  
    lists:foreach(
        fun(#sipreg{ok=Ok}=Reg) -> 
            case Ok of
                true -> 
                    SrvId:nks_sip_uac_auto_register_launch_unregister(
                            Reg, true, SrvState);
                false ->
                    ok
            end
        end,
        Regs),
    {ok, maps:remove(?MODULE, SrvState)}.


%% @private 
handle_call({nksip_uac_auto_register_start_register, RegId, Uri, Opts}, 
            From, #{id:=SrvId, ?MODULE:=State}=SrvState) ->
    #state{regs=Regs} = State,
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
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, SrvState#{?MODULE=>State#state{regs=Regs1}}};

handle_call({nksip_uac_auto_register_stop_register, RegId}, 
            _From, #{id:=SrvId, ?MODULE:=State}=SvcState) ->
    #state{regs=Regs} = State,
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs1} -> 
            {ok, SvcState1} = 
                SrvId:nks_sip_uac_auto_register_launch_unregister(Reg, false, SvcState),
            {reply, ok, SvcState1#{?MODULE=>State#state{regs=Regs1}}};
        false -> 
            {reply, not_found, SvcState}
    end;

handle_call(nksip_uac_auto_register_get_registers, _From, #{?MODULE:=State}=SvcState) ->
    #state{regs=Regs} = State,
    Now = nklib_util:timestamp(),
    Info = [
        {RegId, Ok, Next-Now}
        ||  #sipreg{id=RegId, ok=Ok, next=Next} <- Regs
    ],
    {reply, Info, SvcState};

handle_call({nksip_uac_auto_register_start_ping, PingId, Uri, Opts}, From, SvcState) ->
    #{id:=SrvId, ?MODULE:=State} = SvcState,
    #state{pings=Pings} = State,
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
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, SvcState#{?MODULE:=State#state{pings=Pinsg1}}};

handle_call({nksip_uac_auto_register_stop_ping, PingId}, _From, 
            #{?MODULE:=State}=SvcState) ->
    #state{pings=Pings} = State,
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            {reply, ok, SvcState#{?MODULE:=State#state{pings=Pings1}}};
        false -> 
            {reply, not_found, SvcState}
    end;

handle_call(nksip_uac_auto_register_get_pings, _From, #{?MODULE:=State}=SvcState) ->
    #state{pings=Pings} = State,
    Now = nklib_util:timestamp(),
    Info = [
        {PingId, Ok, Next-Now}
        ||  #sipreg{id=PingId, ok=Ok, next=Next} <- Pings
    ],
    {reply, Info, SvcState};

handle_call(_Msg, _From, _SvcState) ->
    continue.


%% @private
handle_cast({nksip_uac_auto_register_answer_register, RegId, Code, Meta}, 
            #{id:=SrvId, ?MODULE:=State}=SvcState) ->
    #state{regs=Regs} = State,
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK}=Reg, Regs1} ->
            {ok, Reg1, SvcState1} = 
                SrvId:nks_sip_uac_auto_register_update_register(
                        Reg, Code, Meta, SvcState),
            #sipreg{ok=Ok} = Reg1,
            case Ok of
                OldOK -> 
                    ok;
                _ -> 
                    SrvId:nks_sip_call(sip_uac_auto_register_updated_register, 
                                       [RegId, Ok, SrvId], SrvId)
            end,
            {noreply, SvcState1#{?MODULE:=State#state{regs=[Reg1|Regs1]}}};
        false ->
            {noreply, SvcState}
    end;

handle_cast({nksip_uac_auto_register_answer_ping, PingId, Code, Meta}, 
            #{id:=SrvId, ?MODULE:=State}=SvcState) ->
    #state{pings=Pings} = State,
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK}=Ping, Pings1} ->
            {ok, #sipreg{ok=OK}=Ping1, SvcState1} = 
                SrvId:nks_sip_uac_auto_register_update_ping(Ping, Code, Meta, SvcState),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    SrvId:nks_sip_call(sip_uac_auto_register_updated_ping, 
                                        [PingId, OK, SrvId], SrvId)
            end,
            {noreply, SvcState1#{?MODULE:=State#state{pings=[Ping1|Pings1]}}};
        false ->
            {noreply, SvcState}
    end;

handle_cast('$nksip_uac_auto_register_force_regs', #{?MODULE:=State}=SvcState) ->
    #state{regs=Regs} = State,
    Regs1 = lists:map(
        fun(#sipreg{next=Next}=SipReg) ->
            case is_integer(Next) of
                true -> SipReg#sipreg{next=0};
                false -> SipReg
            end
        end,
        Regs),
    {noreply, SvcState#{?MODULE:=State#state{regs=Regs1}}};

handle_cast(nksip_uac_auto_register_check, #{?MODULE:=State}=SvcState) ->
    #state{pings=Pings, regs=Regs} = State,
    Now = nklib_util:timestamp(),
    {Pings1, SvcState1} = check_pings(Now, Pings, [], SvcState),
    {Regs1, SvcState2} = check_registers(Now, Regs, [], SvcState1),
    {noreply, SvcState2#{?MODULE:=State#state{pings=Pings1, regs=Regs1}}};

handle_cast(_Msg, _SvcState) ->
    continue.


%% @private
handle_info({timeout, _, ?MODULE}, #{id:=SrvId}=SvcState) ->
    Timer = 1000 * SrvId:cache_sip_uac_auto_register_timer(),
    erlang:start_timer(Timer, self(), ?MODULE),
    gen_server:cast(self(), nksip_uac_auto_register_check),
    {noreply, SvcState};

handle_info(_Msg, _SvcState) ->
    continue.


%% ===================================================================
%% Callbacks offered to second-level plugins
%% ===================================================================


%% @private
-spec nks_sip_uac_auto_register_launch_register(#sipreg{}, boolean(), 
                                                nkservice_server:sub_state()) -> 
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_launch_register(Reg, Sync, #{id:=SrvId}=SvcState)->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, cseq=CSeq} = Reg,    
    Opts1 = [contact, {cseq_num, CSeq}, {meta, [cseq_num, retry_after]}|Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(SrvId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {nksip_uac_auto_register_answer_register, RegId, Code, Meta})
    end,
    case Sync of
        true -> Fun();
        false -> spawn_link(Fun)
    end,
    {ok, Reg#sipreg{next=undefined}, SvcState}.
    

%% @private
-spec nks_sip_uac_auto_register_launch_unregister(#sipreg{}, boolean(), 
                                                  nkservice_server:sub_state()) -> 
    {ok, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_launch_unregister(Reg, Sync, #{id:=SrvId}=SvcState)->
    #sipreg{ruri=RUri, opts=Opts, cseq=CSeq} = Reg,
    Opts1 = [contact, {cseq_num, CSeq}|nklib_util:store_value(expires, 0, Opts)],
    Fun = fun() -> nksip_uac:register(SrvId, RUri, Opts1) end,
    case Sync of
        true -> Fun();
        false -> spawn_link(Fun)
    end,
    {ok, SvcState}.

   
%% @private
-spec nks_sip_uac_auto_register_update_register(#sipreg{}, nksip:sip_code(), 
                                                nksip:optslist(), 
                                                nkservice_server:sub_state()) ->
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_update_register(Reg, Code, _Meta, SvcState) when Code<200 ->
    {ok, Reg, SvcState};

nks_sip_uac_auto_register_update_register(Reg, Code, Meta, SvcState) ->
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
    {ok, Reg1, SvcState}.


%%%%%% Ping

%% @private
-spec nks_sip_uac_auto_register_launch_ping(#sipreg{}, nkservice_server:sub_state()) -> 
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_launch_ping(Ping, #{id:=SrvId}=SvcState)->
    #sipreg{id=PingId, ruri=RUri, opts=Opts, cseq=CSeq} = Ping,
    Opts1 = [{cseq_num, CSeq}, {meta, [cseq_num, retry_after]} | Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:options(SrvId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {nksip_uac_auto_register_answer_ping, PingId, Code, Meta})
    end,
    spawn_link(Fun),
    {ok, Ping#sipreg{next=undefined}, SvcState}.


   
%% @private
-spec nks_sip_uac_auto_register_update_ping(#sipreg{}, nksip:sip_code(), 
                                nksip:optslist(), nkservice_server:sub_state()) ->
    {ok, #sipreg{}, nkservice_server:sub_state()}.

nks_sip_uac_auto_register_update_ping(Ping, Code, _Meta, SvcState) when Code<200 ->
    {ok, Ping, SvcState};

nks_sip_uac_auto_register_update_ping(Ping, Code, Meta, SvcState) ->
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
    {ok, Ping1, SvcState}.



%% ===================================================================
%% Private
%% ===================================================================

%% @private
check_pings(Now, [#sipreg{next=Next}=Ping|Rest], Acc, #{id:=SrvId}=SvcState) ->
    case is_integer(Next) andalso Now>=Next of 
        true -> 
            {ok, Ping1, SvcState1} = 
                SrvId:nks_sip_uac_auto_register_launch_ping(Ping, SvcState),
            check_pings(Now, Rest, [Ping1|Acc], SvcState1);
        false ->
            check_pings(Now, Rest, [Ping|Acc], SvcState)
    end;
    
check_pings(_, [], Acc, SvcState) ->
    {Acc, SvcState}.


%% @private Only one register in each cycle
check_registers(Now, [#sipreg{next=Next}=Reg|Rest], Acc, #{id:=SrvId}=SvcState) ->
    case Now>=Next of
        true -> 
            {ok, Reg1, SvcState1} = 
                SrvId:nks_sip_uac_auto_register_launch_register(Reg, false, SvcState),
            check_registers(-1, Rest, [Reg1|Acc], SvcState1);
        false ->
            check_registers(Now, Rest, [Reg|Acc], SvcState)
    end;

check_registers(_, [], Acc, SvcState) ->
    {Acc, SvcState}.


