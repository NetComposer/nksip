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
-export([init/4, handle_call/3, handle_cast/2, timer/1, terminate/2]).

-include("nksip.hrl").


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
            {ok, call(AppId, Msg)};
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
            {ok, nksip:call(AppId, Msg)};
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
    cseq :: nksip:cseq(),
    ok :: boolean(),
    last :: nksip_lib:timestamp(),
    interval :: non_neg_integer(),
    checking :: boolean(),
    from :: any()
}).


-record(state, {
    app_id :: nksip:app_id(),
    module :: atom(),
    pings :: [#sipreg{}],
    regs :: [#sipreg{}]
}).


%% @private 
init(AppId, Module, _Args, Opts) ->
    case nksip_lib:get_value(register, Opts) of
        undefined ->
            ok;
        Reg ->
            RegTime = nksip_lib:get_integer(register_expires, Opts, 300),
            spawn(
                fun() -> 
                    start_register(AppId, <<"auto">>, Reg, RegTime, Opts) 
                end)
    end,
    #state{app_id=AppId, module=Module, pings=[], regs=[]}.


%% @private
handle_call({'$nksip_start_ping', PingId, Uri, Time, Opts}, From, 
            #state{pings=Pings}=State) ->
    Ping = #sipreg{
        id = PingId,
        ruri = Uri,
        opts = Opts,
        call_id = nksip_lib:luid(),
        cseq = nksip_config:cseq(),
        ok = undefined,
        last = 0,
        interval = Time,
        checking = false,
        from = From
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
    Now = nksip_lib:timestamp(),
    Info = [
        {PingId, Ok, (Last+Interval)-Now}
        ||  #sipreg{id=PingId, ok=Ok, last=Last, interval=Interval} <- Pings
    ],
    gen_server:reply(From, Info),
    State;

handle_call({'$nksip_start_register', RegId, Uri, Time, Opts}, From, 
            #state{regs=Regs}=State) ->
    Reg = #sipreg{
        id = RegId,
        ruri = Uri,
        opts = Opts,
        call_id = nksip_lib:luid(),
        cseq = nksip_config:cseq(),
        ok = undefined,
        last = 0,
        interval = Time,
        checking = false,
        from = From
    },
    timer(State#state{regs=lists:keystore(RegId, #sipreg.id, Regs, Reg)});

handle_call({'$nksip_stop_register', RegId}, From, #state{regs=Regs}=State) ->
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, _, Regs1} -> 
            gen_server:reply(From, ok),
            State#state{regs=Regs1};
        false -> 
            gen_server:reply(From, not_found),
            State
    end;

handle_call('$nksip_get_registers', From, #state{regs=Regs}=State) ->
    Now = nksip_lib:timestamp(),
    Info = [
        {RegId, Ok, (Last+Interval)-Now}
        ||  #sipreg{id=RegId, ok=Ok, last=Last, interval=Interval} <- Regs
    ],
    gen_server:reply(From, Info),
    State;

handle_call(_, _From, _State) ->
    error.


%% @private
handle_cast({'$nksip_ping_update', PingId, OK, CSeq}, 
            #state{app_id=AppId, module=Module, pings=Pings}=State) -> 
    case lists:keytake(PingId, #sipreg.id, Pings) of
        {value, #sipreg{ok=OK0, interval=Interval, from=From}=Ping0, Pings1} ->
            case OK of
                OK0 -> 
                    ok;
                _ -> 
                    Args = [PingId, OK],
                    nksip_sipapp_srv:sipapp_cast(AppId, Module, 
                                                 ping_update, Args, Args)
            end,
            case From of
                undefined -> ok;
                _ -> gen_server:reply(From, OK)
            end,
            case Interval of
                0 ->
                    State#state{pings=Pings1};
                _ -> 
                    Ping1 = Ping0#sipreg{
                        ok = OK, 
                        cseq = CSeq, 
                        checking = false, 
                        from = undefined
                    },
                    State#state{pings=[Ping1|Pings1]}
            end;
        false ->
            State
    end;

handle_cast({'$nksip_register_update', RegId, OK, CSeq}, 
            #state{app_id=AppId, module=Module, regs=Regs}=State) -> 
    case lists:keytake(RegId, #sipreg.id, Regs) of
        {value, #sipreg{ok=OK0, interval=Interval, from=From}=Reg0, Regs1} ->
            case OK of
                OK0 -> 
                    ok;
                _ -> 
                    Args = [RegId, OK],
                    nksip_sipapp_srv:sipapp_cast(AppId, Module, 
                                                 register_update, Args, Args)
            end,
            case From of
                undefined -> ok;
                _ -> gen_server:reply(From, OK)
            end,
            case Interval of
                0 ->
                    State#state{regs=Regs1};
                _ ->
                    Reg1 = Reg0#sipreg{
                        ok = OK, 
                        cseq = CSeq, 
                        checking = false,
                        from = undefined
                    },
                    State#state{regs=[Reg1|Regs1]}
            end;
        false ->
            State
    end;

handle_cast(_, _) ->
    error.


%% @private
timer(#state{pings=Pings, regs=Regs}=State) ->
    Now = nksip_lib:timestamp(),
    Self = self(),
    Pings1 = [
        if
            Now > Last + Interval, Checking==false -> 
                proc_lib:spawn(fun() -> do_ping(Self, Ping, State) end),
                Ping#sipreg{checking=true, last=Now};
            true ->
                Ping
        end
        || #sipreg{last=Last, interval=Interval, checking=Checking}=Ping <- Pings
    ],
    Regs1 = [
        if
            Now > Last + Interval, Checking==false -> 
                proc_lib:spawn(fun() -> do_register(Self, Reg, State) end),
                Reg#sipreg{checking=true, last=Now};
            true ->
                Reg
        end
        || #sipreg{last=Last, interval=Interval, checking=Checking}=Reg <- Regs
    ],
    State#state{pings=Pings1, regs=Regs1}.


%% @private
terminate(_Reason, #state{regs=Regs}=State) ->  
    [do_register(self(), Reg#sipreg{interval=0}, State) || Reg <- Regs].
    


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec call(nksip:app_id(), term()) ->
    term().

call(AppId, Msg) ->
    nksip:call(AppId, Msg).


%% @private
-spec do_ping(pid(), #sipreg{}, #state{}) -> 
    ok.

do_ping(Pid, SipReg, #state{app_id=AppId}) ->
    #sipreg{id=PingId, ruri=RUri, opts=Opts, cseq=CSeq, call_id=CallId} = SipReg,
    Opts1 = [{call_id, CallId}, {cseq, CSeq}, get_response | Opts],
    {OK, CSeq1} = case nksip_uac:options(AppId, RUri, Opts1) of
        {resp, #sipmsg{class={resp, Code, _}, cseq=OK_CSeq}} 
            when Code>=200, Code<300 -> 
            {true, OK_CSeq+1};
        {resp, #sipmsg{cseq=Err_CSeq}} -> 
            {false, Err_CSeq+1};
        {error, _Error} -> 
            {false, CSeq+1}

    end,
    gen_server:cast(Pid, {'$nksip_ping_update', PingId, OK, CSeq1}).
            

%% @private
-spec do_register(pid(), #sipreg{}, #state{}) -> 
    ok.

do_register(Pid, SipReg, #state{app_id=AppId})->
    #sipreg{id=RegId, ruri=RUri, opts=Opts, interval=Interval, cseq=CSeq, 
            call_id=CallId} = SipReg,
    Opts1 = [make_contact, {call_id, CallId}, {cseq, CSeq}, 
                {expires, Interval}, get_response | Opts],
    {OK, CSeq1} = case nksip_uac:register(AppId, RUri, Opts1) of
        {resp, #sipmsg{class={resp, Code, _}, cseq=OK_CSeq}} 
            when Code>=200, Code<300 -> 
            {true, OK_CSeq+1};
        {resp, #sipmsg{cseq=Err_CSeq}}-> 
            {false, Err_CSeq+1};
        {error, _Error} -> 
            {false, CSeq+1}
    end,
    gen_server:cast(Pid, {'$nksip_register_update', RegId, OK, CSeq1}).
