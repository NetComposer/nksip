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

%% @doc Call Process utilities

-module(nksip_call_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([check/2, update/2, start_timer/2, cancel_timers/2, trace/2]).

-define(MAX_TRANS, 900).


check(Now, #call{trans=Trans, msgs=Msgs}=SD) ->
    {Trans1, Msgs1} = do_check(Now, Trans, [], Msgs),
    SD#call{trans=Trans1, msgs=Msgs1}.
    

do_check(_Now, [], Trans, Msgs) ->
    {Trans, Msgs};

do_check(Now, [#trans{start=Start, trans_id=TransId, request=Req}|Rest], Trans, Msgs) 
         when Start+?MAX_TRANS =< Now ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, method=Method} = Req,
    ?error(AppId, CallId, "Transaction ~p (~p) timeout", [Method, TransId]),
    Msgs1 = [Msg || #msg{trans_id=TId}=Msg <- Msgs, TId=/=TransId],
    do_check(Now, Rest, Trans, Msgs1);

do_check(Now, [Trans|Rest], Trans, Msgs) -> 
    #trans{
        class = Class,
        status = Status, 
        trans_id = Id, 
        request = Req, 
        responses = Resps, 
        timeout = Timeout
    } = Trans,
    #sipmsg{
        id = ReqId, 
        sipapp_id = AppId, 
        call_id = CallId, 
        method = Method, 
        expire = ReqExp
    } = Req,
    {Removed, Resps1, Msgs1} = remove_resps(Now, Resps, [], 0, Msgs),
    case Removed of
        0 -> 
            ok;
        _ -> 
            ?debug(AppId, CallId, "Removed ~p response(s) from transaction ~p (~p, ~p)", 
                       [Removed, Method, Id, Status]),
            nksip_counters:async([{nksip_msgs, -Removed}])
    end,
    case Status=:=finished andalso Resps1=:=[] andalso ReqExp=<Now of
        true ->
            ?debug(AppId, CallId, "Removed finished transaction ~p (~p)", [Method, Id]),
            nksip_counters:async([{nksip_msg, -1}]),    % for the request
            Msgs2 = lists:keydelete(ReqId, #msg.msg_id, Msgs1),
            do_check(Now, Rest, Trans, Msgs2);
        false ->
            Trans1 = case Timeout of
                {Tag, Time} when Time=<Now -> 
                    self() ! {timeout, none, {Class, Tag, Id}},
                    Trans#trans{timeout=undefined};
                _ -> 
                    Trans
            end,
            do_check(Now, Rest, [Trans1#trans{responses=Resps1}|Trans], Msgs1)
    end.


remove_resps(_Now, [], Resps, Removed, Msgs) ->
    {Removed, Resps, Msgs};

remove_resps(Now, [#sipmsg{id=Id, expire=Exp}|Rest], Resps, Removed, Msgs) 
             when Exp=<Now ->
    Msgs1 = lists:keydelete(Id, #msg.msg_id, Msgs),
    remove_resps(Now, Rest, Resps, Removed+1, Msgs1);

remove_resps(Now, [Resp|Rest], Resps, Removed, Msgs) ->
    remove_resps(Now, Rest, [Resp|Resps], Removed, Msgs).



update(#trans{trans_id=Id}=Trans, #call{trans=[#trans{trans_id=Id}|Rest]}=SD) ->
    SD#call{trans=[Trans|Rest]};
    
update(#trans{trans_id=Id}=Trans, #call{trans=Trans}=SD) ->
    Rest = lists:keydelete(Id, #trans.trans_id, Trans),
    SD#call{trans=[Trans|Rest]}.

trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).



%% ===================================================================
%% Util - Timers
%% ===================================================================


start_timer(timer_a, #trans{next_retrans=Next}=UAC) ->
    Time = case is_integer(Next) of
        true -> Next;
        false -> nksip_config:get(timer_t1)
    end,
    UAC#trans{
        retrans_timer = start_timer(Time, timer_a, UAC),
        next_retrans = 2*Time
    };

start_timer(Tag, Trans) 
            when Tag=:=timer_b; Tag=:=timer_f; Tag=:=timer_m;
                 Tag=:=timer_h; Tag=:=timer_j; Tag=:=timer_l ->
    T1 = nksip_config:get(timer_t1),
    Time = nksip_lib:timestamp() + round(64*T1/1000),
    Trans#trans{timeout={Tag, Time}};

start_timer(timer_d, UAC) ->
    Time = nksip_lib:timestamp() + 32,
    UAC#trans{timeout={timer_d, Time}};

start_timer(Tag, #trans{next_retrans=Next}=Trans) when Tag=:=timer_e; Tag=:=timer_g ->
    Time = case is_integer(Next) of
        true -> Next;
        false -> nksip_config:get(timer_t1)
    end,
    Trans#trans{
        retrans_timer = start_timer(Time, Tag, Trans),
        next_retrans = min(2*Time, nksip_config:get(timer_t2))
    };

start_timer(Tag, Trans) when Tag=:=timer_k; Tag=:=timer_i ->
    T4 =  nksip_config:get(timer_t4),
    Time = nksip_lib:timestamp() + round(T4/1000),
    Trans#trans{timeout={timer_k, Time}};

start_timer(expire, #trans{request=Req}=Trans) ->
    ExpireTimer = case nksip_parse:header_integers(<<"Expires">>, Req) of
        [Expires|_] when Expires > 0 -> 
            case lists:member(no_auto_expire, Req#sipmsg.opts) of
                true -> undefined;
                _ -> start_timer(1000*Expires, expire, Trans)
            end;
        _ ->
            undefined
    end,
    Trans#trans{expire_timer=ExpireTimer}.




start_timer(Time, Tag, #trans{class=Class, trans_id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {Class, Tag, Id})}.

cancel_timers([timeout|Rest], Trans) ->
    cancel_timers(Rest, Trans#trans{timeout=undefined});

cancel_timers([retrans|Rest], #trans{retrans_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{retrans_timer=undefined});

cancel_timers([expire|Rest], #trans{expire_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{expire_timer=undefined});

cancel_timers([], Trans) ->
    Trans.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    erlang:cancel_timer(Ref);
cancel_timer(_) -> ok.


