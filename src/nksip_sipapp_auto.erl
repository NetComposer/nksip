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

%% @doc Automatic pings and registrations support for SipApps.
%% This module allows a SipApp to program automatic periodic sending of
%% <i>OPTION</i> or <i>REGISTER</i> requests and related functions.

-module(nksip_sipapp_auto).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_ping/5, stop_ping/2, get_pings/1]).
-export([start_register/5, stop_register/2, get_registers/1]).
-export([init/4, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([timer/1]).


-include("nksip.hrl").

-define(DEFAULT_OB_TIME_ALL_FAIL, 3).
-define(DEFAULT_OB_TIME_OK, 9).
-define(DEFAULT_OB_TIME_MAX, 1800).



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Programs the SipApp to start a series of <i>pings</i> (OPTION requests) 
%% to the SIP element at `Uri', at `Time' (in seconds) intervals.
%% `PingId' indentifies this request to stop it later.
%% Use {@link get_pings/1} to know about ping status, or the callback function
%% {@link nksip_sipapp:register_update/3}.
-spec start_ping(nksip:app_id(), term(), nksip:user_uri(), pos_integer(),
                    nksip_lib:proplist()) -> 
    {ok, boolean()} | {error, invalid_uri}.

start_ping(AppId, PingId, Uri, Time, Opts) 
            when is_integer(Time), Time > 0, is_list(Opts) ->
    case nksip_parse:uris(Uri) of
        [ValidUri] -> 
            Msg = {'$nksip_start_ping', PingId, ValidUri, Time, Opts},
            case catch nksip:call(AppId, Msg) of
                {ok, Reply} -> {ok, Reply};
                {'EXIT', _} -> {error, sipapp_not_found}
            end;
        _ -> 
            {error, invalid_uri}
    end.


%% @doc Stops a previously started ping request.
-spec stop_ping(nksip:app_id(), term()) -> 
    ok | not_found.

stop_ping(AppId, PingId) ->
    nksip:call(AppId, {'$nksip_stop_ping', PingId}).
    

%% @doc Get current ping status, including if last ping was successful and time 
%% remaining to next one.
-spec get_pings(nksip:app_id()) -> 
    [{PingId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_pings(AppId) ->
    nksip:call(AppId, '$nksip_get_pings', 5000).


%% @doc Programs the SipApp to start a series of <i>registrations</i>
%% to the registrar at `Uri', at `Time' (in seconds) intervals.
%% `RegId' indentifies this request to stop it later.
%% Use {@link get_regs/1} to know about registration status, or the 
%% callback function {@link nksip_sipapp:ping_update/3}.
-spec start_register(nksip:app_id(), term(), nksip:user_uri(), pos_integer(),
                        nksip_lib:proplist()) -> 
    {ok, boolean()} | {error, invalid_uri}.

start_register(AppId, RegId, Uri, Time, Opts) 
                when is_integer(Time), Time > 0, is_list(Opts) ->
    case nksip_parse:uris(Uri) of
        [ValidUri] -> 
            Msg = {'$nksip_start_register', RegId, ValidUri, Time, Opts},
            case catch nksip:call(AppId, Msg) of
                {ok, Reply} -> {ok, Reply};
                {'EXIT', E} -> {error, sipapp_not_found, E}
            end;
        _ -> 
            {error, invalid_uri}
    end.


%% @doc Stops a previously started registration series.
-spec stop_register(nksip:app_id(), term()) -> 
    ok | not_found.

stop_register(AppId, RegId) ->
    nksip:call(AppId, {'$nksip_stop_register', RegId}).
    

%% @doc Get current registration status, including if last registration was successful 
%% and time remaining to next one.
-spec get_registers(nksip:app_id()) -> 
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(AppId) ->
    nksip:call(AppId, '$nksip_get_registers').



%% ===================================================================
%% Private
%% ===================================================================

-record(sipreg, {
    id :: term(),
    ruri :: nksip:uri(),
    opts :: nksip_lib:proplist(),
    call_id :: nksip:call_id(),
    interval :: non_neg_integer(),
    from :: any(),
    cseq :: nksip:cseq(),
    next :: nksip_lib:timestamp(),
    ok :: boolean(),
    monitor :: reference(),
    pid :: pid(),
    fails :: non_neg_integer()
}).


-record(state, {
    app_id :: nksip:app_id(),
    module :: atom(),
    base_time :: pos_integer(),     % For outbound support
    pings :: [#sipreg{}],
    regs :: [#sipreg{}]
}).


%% @private 
init(AppId, Module, _Args, Opts) ->
    RegTime = nksip_lib:get_integer(register_expires, Opts, 300),
    case nksip_lib:get_value(register, Opts) of
        undefined ->
            ok;
        Reg ->
            spawn_link(
                fun() -> 
                    start_register(AppId, <<"auto">>, Reg, RegTime, Opts) 
                end)
    end,
    case nksip_lib:get_value(outbound_proxies, Opts) of
        undefined ->
            ok;
        ObRegs ->
            lists:foreach(
                fun({Pos, Uri}) ->
                    Opts1 = [{reg_id, Pos}],
                    spawn_link(
                        fun() -> 
                            start_register(AppId, <<"auto">>, Uri, RegTime, Opts1) 
                        end)
                end,
                ObRegs)
    end,
    #state{
        app_id = AppId, 
        module = Module, 
        base_time = ?DEFAULT_OB_TIME_OK,
        pings = [], 
        regs = []
    }.


%% @private
handle_call({'$nksip_start_ping', PingId, Uri, Time, Opts}, From, 
            #state{pings=Pings}=State) ->
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts,
        call_id = nksip_lib:luid(),
        interval = Time,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined
    },
    timer(State#state{pings=lists:keystore(PingId, #sipreg.id, Pings, Ping)});

handle_call({'$nksip_stop_ping', PingId}, From, #state{pings=Pings}=State) ->
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, _, Pings1} -> 
            gen_server:reply(From, ok),
            State#state{pings=Pings1};
        false -> 
            gen_server:reply(From, not_found),
            State
    end;

handle_call('$nksip_get_pings', From, #state{pings=Pings}=State) ->
    % Now = nksip_lib:timestamp(),
    % Info = [
    %     {PingId, Ok, (Last+Interval)-Now}
    %     ||  #sipreg{id=PingId, ok=Ok, last=Last, interval=Interval} <- Pings
    % ],
    gen_server:reply(From, Pings),
    State;

handle_call({'$nksip_start_register', RegId, Uri, Time, Opts}, From, 
            #state{regs=Regs}=State) ->
    Reg = #sipreg{
        id = RegId,
        ruri = Uri,
        opts = Opts,
        call_id = nksip_lib:luid(),
        interval = Time,
        from = From,
        cseq = nksip_config:cseq(),
        next = 0,
        ok = undefined,
        fails = 0
    },
    timer(State#state{regs=lists:keystore(RegId, #sipreg.id, Regs, Reg)});

handle_call({'$nksip_stop_register', RegId}, From, State) ->
    #state{app_id=AppId, regs=Regs} = State,
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{monitor=Monitor}=Reg, Regs1} -> 
            gen_server:reply(From, ok),
            case is_reference(Monitor) of
                true -> erlang:demonitor(Monitor);
                false -> ok
            end, 
            spawn(fun() -> launch_unregister(AppId, Reg) end),
            State#state{regs=Regs1};
        false -> 
            gen_server:reply(From, not_found),
            State
    end;

handle_call('$nksip_get_registers', From, #state{regs=Regs}=State) ->
    % Now = nksip_lib:timestamp(),
    % Info = [
    %     {RegId, Ok, (Last+Interval)-Now}
    %     ||  #sipreg{id=RegId, ok=Ok, last=Last, interval=Interval} <- Regs
    % ],
    gen_server:reply(From, {State#state.base_time, Regs}),
    State;

handle_call(_, _From, _State) ->
    error.


%% @private
handle_cast({'$nksip_ping_answer', PingId, Code, Meta}, 
            #state{app_id=AppId, module=Module, pings=Pings}=State) -> 
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OldOK, interval=Interval}=Ping, Pings1} ->
            #sipreg{ok=OK} = Ping1 = update_ping(Ping, Code, Meta, State),
            case OK of
                OldOK -> 
                    ok;
                _ -> 
                    Args = [PingId, OK],
                    nksip_sipapp_srv:sipapp_cast(AppId, Module, 
                                                 ping_update, Args, Args)
            end,
            case Interval of
                0 -> State#state{pings=Pings1};
                _ -> State#state{pings=[Ping1|Pings1]}
            end;
        false ->
            State
    end;

handle_cast({'$nksip_register_answer', RegId, Code, Meta}, 
            #state{app_id=AppId, module=Module, regs=Regs}=State) -> 
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OldOK, interval=Interval}=Reg, Regs1} ->
            #sipreg{ok=OK} = Reg1 = update_register(Reg, Code, Meta, State),
            case OK of
                OldOK ->
                    ok;
                _ -> 
                    Args = [RegId, OK],
                    nksip_sipapp_srv:sipapp_cast(AppId, Module, 
                                                 register_update, Args, Args)
            end,
            State1 = case Interval of
                0 -> State#state{regs=Regs1};
                _ -> State#state{regs=[Reg1|Regs1]}
            end,
            update_basetime(State1);
        false ->
            State
    end;

handle_cast(_, _) ->
    error.


%% @private
handle_info({'DOWN', Mon, process, _Pid, _}, #state{app_id=AppId, regs=Regs}=State) ->
    case lists:keyfind(Mon, #sipreg.monitor, Regs) of
        #sipreg{id=RegId, cseq=CSeq} ->
            ?info(AppId, "flow ~p has failed", [RegId]),
            Meta = [{cseq_num, CSeq}],
            gen_server:cast(self(), {'$nksip_register_answer', RegId, 503, Meta});
        false ->
            ok
    end,
    State;

handle_info({'$nksip_register_notify', RegId}, #state{regs=Regs}=State) ->
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, Reg, Regs1} -> 
            State1 = State#state{regs=[Reg#sipreg{fails=0}|Regs1]},
            update_basetime(State1);
        false -> 
            State
    end;

handle_info(_, _) ->
    error.


%% @private
terminate(_Reason, #state{app_id=AppId, regs=Regs}) ->  
    lists:foreach(fun(Reg) -> launch_unregister(AppId, Reg) end, Regs).



%% ===================================================================
%% Private
%% ===================================================================


%% @private
timer(#state{app_id=AppId, pings=Pings, regs=Regs}=State) ->
    Now = nksip_lib:timestamp(),
    Pings1 = lists:map(
        fun(#sipreg{next=Next}=Ping) ->
            case is_integer(Next) andalso Now>=Next of 
                true -> launch_ping(AppId, Ping);
                false -> Ping
            end
        end,
        Pings),
    Regs1 = lists:map(
        fun(#sipreg{next=Next}=Reg) ->
            case is_integer(Next) andalso Now>=Next of 
                true -> launch_register(AppId, Reg);
                false -> Reg
            end
        end,
        Regs),
    State#state{pings=Pings1, regs=Regs1}.


%%%%%% Register

%% @private
-spec launch_register(nksip:app_id(), #sipreg{}) -> 
    #sipreg{}.

launch_register(AppId, Reg)->
    #sipreg{
        id = RegId, 
        ruri = RUri,
        opts = Opts, 
        interval = Interval, 
        cseq = CSeq,
        call_id = CallId
    } = Reg,
    Opts1 = [
        make_contact, {call_id, CallId}, {cseq, CSeq}, {expires, Interval}, 
        {fields, [cseq_num, remote, parsed_require, <<"Retry-After">>]} 
        | Opts
    ],   
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_register_answer', RegId, Code, Meta})
    end,
    spawn_link(Fun),
    Reg#sipreg{next=undefined}.
    

%% @private
-spec launch_unregister(nksip:app_id(), #sipreg{}) -> 
    ok.

launch_unregister(AppId, Reg)->
    #sipreg{
        ruri = RUri,
        opts = Opts, 
        cseq = CSeq,
        call_id = CallId,
        pid = Pid
    } = Reg,
    Opts1 = [
        make_contact, {call_id, CallId}, {cseq, CSeq}, {expires, 0}
        | Opts
    ],
    nksip_uac:register(AppId, RUri, Opts1),
    case is_pid(Pid) of
        true -> nksip_transport_conn:stop_refresh(Pid);
        false -> ok
    end.

   
%% @private
-spec update_register(#sipreg{}, nksip:code(), nksip_lib:proplist(), #state{}) ->
    #sipreg{}.

update_register(Reg, Code, Meta, #state{app_id=AppId}) when Code>=200, Code<300 ->
    #sipreg{id=RegId, monitor=Monitor, interval=Interval, from=From} = Reg,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, true})
    end,
    case is_reference(Monitor) of
        true -> erlang:demonitor(Monitor);
        false -> ok
    end,
    {Proto, Ip, Port} = nksip_lib:get_value(remote, Meta),
    Require = nksip_lib:get_value(parsed_require, Meta),
    {Monitor1, Pid1} = case lists:member(<<"outbound">>, Require) of
        true ->
            Ref = {'$nksip_register_notify', RegId},
            case nksip_transport:start_refresh(AppId, Proto, Ip, Port, Ref) of
                {ok, Pid} -> {erlang:monitor(process, Pid), Pid};
                error -> {undefined, undefined}
            end;
        _ ->
            {undefined, undefined}
    end,
    % 'fails' is not updated until the connection confirmation arrives
    % (or process down)
    Reg#sipreg{
        ok = true,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        monitor = Monitor1,
        pid = Pid1,
        next = nksip_lib:timestamp() + Interval
    };

update_register(Reg, Code, Meta, #state{base_time=BaseTime}) ->
    #sipreg{monitor=Monitor, fails=Fails, from=From} = Reg,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, false})
    end,
    case is_reference(Monitor) of
        true -> erlang:demonitor(Monitor);
        false -> ok
    end,
    Upper = min(?DEFAULT_OB_TIME_MAX, BaseTime*math:pow(2, Fails+1)),
    Elap = round(crypto:rand_uniform(50, 101) * Upper / 100),
    Add = case Code==503 andalso nksip_lib:get_value(<<"Retry-After">>, Meta) of
        [Retry1] ->
            case nksip_lib:to_integer(Retry1) of
                Retry2 when Retry2 > 0 -> Retry2;
                _ -> 0
            end;
        _ -> 
            0
    end,
    lager:warning("REG FAIL: ~p, ~p, ~p, ~p, ~p", [BaseTime, Fails, Upper, Elap, Add]),

    Reg#sipreg{
        ok = false,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        monitor = undefined,
        next = nksip_lib:timestamp() + Elap + Add,
        fails = Fails+1
    }.

%% @private
update_basetime(#state{regs=Regs}=State) ->
    Base = case [true || #sipreg{fails=0} <- Regs] of
        [] -> ?DEFAULT_OB_TIME_ALL_FAIL;
        _ -> ?DEFAULT_OB_TIME_OK
    end,
    lager:warning("BaseTime: ~p", [Base]),
    State#state{base_time=Base}.



%%%%%% Ping

%% @private
-spec launch_ping(nksip:app_id(), #sipreg{}) -> 
    #sipreg{}.

launch_ping(AppId, Ping)->
    #sipreg{
        id = PingId,
        ruri = RUri, 
        opts = Opts, 
        cseq = CSeq,
        call_id = CallId
    } = Ping,
    Opts1 = [{call_id, CallId}, {cseq, CSeq}, {fields, [cseq_num]} | Opts],
    Self = self(),
    Fun = fun() ->
        case nksip_uac:options(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_ping_answer', PingId, Code, Meta})
    end,
    spawn_link(Fun),
    Ping#sipreg{next=undefined}.


   
%% @private
-spec update_ping(#sipreg{}, nksip:code(), nksip_lib:proplist(), #state{}) ->
    #sipreg{}.

update_ping(Ping, Code, Meta, _State) ->
    Ok = Code>=200 andalso Code<300,
    #sipreg{from=From, interval=Interval} = Ping,
    case From of
        undefined -> ok;
        _ -> gen_server:reply(From, {ok, Ok})
    end,
    Add = case Code==503 andalso nksip_lib:get_value(<<"Retry-After">>, Meta) of
        [Retry1] ->
            case nksip_lib:to_integer(Retry1) of
                Retry2 when Retry2 > 0 -> Retry2;
                _ -> 0
            end;
        _ -> 
            0
    end,
    Ping#sipreg{
        ok = Ok,
        cseq = nksip_lib:get_value(cseq_num, Meta) + 1,
        from = undefined,
        next = nksip_lib:timestamp() + Interval + Add
    }.






