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
-module(nksip_uac_auto_outbound_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_config/3]).
-export([launch_register/2, launch_unregister/2, update_register/4, update_basetime/1]).
-export([launch_ping/2, update_ping/4]).

-include("../../../include/nksip.hrl").
-include("nksip_uac_auto_outbound.hrl").




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
        contact, {call_id, CallId}, {cseq_num, CSeq}, {expires, Interval}, 
        {meta, [cseq_num, remote, require, <<"retry-after">>, <<"flow-timer">>]} 
        | Opts
    ],   
    Self = self(),
    Fun = fun() ->
        case nksip_uac:register(AppId, RUri, Opts1) of
            {ok, Code, Meta} -> ok;
            _ -> Code=500, Meta=[{cseq_num, CSeq}]
        end,
        gen_server:cast(Self, {'$nksip_uac_auto_register_answer', RegId, Code, Meta})
    end,
    Pid = spawn_link(Fun),
    Reg#sipreg{next=undefined, req_pid=Pid}.
    

%% @private
-spec launch_unregister(nksip:app_id(), #sipreg{}) -> 
    ok.

launch_unregister(AppId, Reg)->
    #sipreg{
        ruri = RUri,
        opts = Opts, 
        cseq = CSeq,
        call_id = CallId,
        conn_pid = Pid
    } = Reg,
    Opts1 = [
        contact, {call_id, CallId}, {cseq_num, CSeq}, {expires, 0}
        | Opts
    ],
    nksip_uac:register(AppId, RUri, Opts1),
    case is_pid(Pid) of
        true -> nksip_connection:stop_refresh(Pid);
        false -> ok
    end.

   
%% @private
-spec update_register(#sipreg{}, nksip:sip_code(), nksip:optslist(), #state{}) ->
    #sipreg{}.

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



