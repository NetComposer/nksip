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

%% @private Call process utilities
-module(nksip_call_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([store_sipmsg/2, update_sipmsg/2, update/2]).
-export([timeout_timer/3, retrans_timer/3, expire_timer/3, cancel_timers/2]).
-export([trace/2]).
-export_type([timeout_timer/0, retrans_timer/0, expire_timer/0, timer/0]).


-include("nksip.hrl").
-include("nksip_call.hrl").

-type timeout_timer() :: timer_b | timer_d | timer_f | timer_h | timer_i | 
                         timer_j | timer_k | timer_l | timer_m | timeout |
                         wait_sipapp.

-type retrans_timer() :: timer_a | timer_e | timer_g.

-type expire_timer() ::  expire.

-type timer() :: timeout_timer() | retrans_timer() | expire_timer().

-type call() :: nksip_call:call().

-type trans() :: nksip_call:trans().




%% ===================================================================
%% Private
%% ===================================================================


%% @private Adds a new SipMsg to the call's store
-spec store_sipmsg(nksip:request()|nksip:response(), call()) ->
    call().

store_sipmsg(#sipmsg{id=MsgId}=SipMsg, #call{keep_time=KeepTime, msgs=Msgs}=Call) ->
    case KeepTime > 0 of
        true ->
            ?call_debug("Storing sipmsg ~p", [MsgId], Call),
            erlang:start_timer(1000*KeepTime, self(), {remove_msg, MsgId}),
            nksip_counters:async([nksip_msgs]),
            Call#call{msgs=[SipMsg|Msgs]};
        false ->
            Call
    end.



%% @private
-spec update_sipmsg(nksip:request()|nksip:response(), call()) -> 
    call().

update_sipmsg(#sipmsg{id=MsgId}=Msg, #call{msgs=Msgs}=Call) ->
    ?call_debug("Updating sipmsg ~p", [MsgId], Call),
    Msgs1 = lists:keyreplace(MsgId, #sipmsg.id, Msgs, Msg),
    Call#call{msgs=Msgs1}.


%% @private
-spec update(trans(), call()) ->
    call().

update(#trans{id=Id, class=Class}=New, #call{trans=[#trans{id=Id}=Old|Rest]}=Call) ->
    #trans{status=NewStatus, method=Method} = New,
    #trans{status=OldStatus} = Old,
    CS = case Class of uac -> "UAC"; uas -> "UAS" end,
    Call1 = case NewStatus of
        finished ->
            ?call_debug("~s ~p ~p (~p) removed", 
                        [CS, Id, Method, OldStatus], Call),
            Call#call{trans=Rest};
        OldStatus -> 
            Call#call{trans=[New|Rest]};
        _ -> 
            ?call_debug("~s ~p ~p ~p -> ~p", 
                        [CS, Id, Method, OldStatus, NewStatus], Call),
            Call#call{trans=[New|Rest]}
    end,
    hibernate(New, Call1);
    
update(New, #call{trans=Trans}=Call) ->
    #trans{id=Id, class=Class, status=NewStatus, method=Method} = New,
    CS = case Class of uac -> "UAC"; uas -> "UAS" end,
    Call1 = case lists:keytake(Id, #trans.id, Trans) of
        {value, #trans{status=OldStatus}, Rest} -> 
            case NewStatus of
                finished ->
                    ?call_debug("~s ~p ~p (~p) removed!", 
                                [CS, Id, Method, OldStatus], Call),
                    Call#call{trans=Rest};
                OldStatus -> 
                    Call#call{trans=[New|Rest]};
                _ -> 
                    ?call_debug("~s ~p ~p ~p -> ~p!", 
                        [CS, Id, Method, OldStatus, NewStatus], Call),
                    Call#call{trans=[New|Rest]}
            end;
        false ->
            Call#call{trans=[New|Trans]}
    end,
    hibernate(New, Call1).


%% @private 
-spec hibernate(trans(), call()) ->
    call().

hibernate(#trans{status=Status}, Call) 
          when Status=:=invite_accepted; Status=:=completed; 
               Status=:=finished ->
    Call#call{hibernate=Status};

hibernate(#trans{class=uac, status=invite_completed}, Call) ->
    Call#call{hibernate=invite_completed};

hibernate(_, Call) ->
    Call.


%% @private
trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).



%% ===================================================================
%% Util - Timers
%% ===================================================================


%% @private
-spec timeout_timer(timeout_timer(), trans(), call()) ->
    trans().

timeout_timer(Tag, Trans, #call{global=#global{t1=T1}}) 
            when Tag=:=timer_b; Tag=:=timer_f; Tag=:=timer_m;
                 Tag=:=timer_h; Tag=:=timer_j; Tag=:=timer_l;
                 Tag=:=wait_sipapp ->
    Trans#trans{timeout_timer=start_timer(64*T1, Tag, Trans)};

timeout_timer(timer_d, Trans, _) ->
    Trans#trans{timeout_timer=start_timer(32000, timer_d, Trans)};


timeout_timer(Tag, Trans, #call{global=#global{t4=T4}}) 
                when Tag=:=timer_k; Tag=:=timer_i ->
    Trans#trans{timeout_timer=start_timer(T4, Tag, Trans)};

timeout_timer(timeout, #trans{method=Method}=Trans, Call) ->
    #call{global=#global{tc=TC, t1=T1}} = Call,
    Time = case Method of
        'INVITE' -> 1000*TC;
         _ -> 64*T1
    end,
    Trans#trans{timeout_timer=start_timer(Time, timeout, Trans)}.



%% @private
-spec retrans_timer(retrans_timer(), trans(), call()) ->
    trans().

retrans_timer(timer_a, #trans{next_retrans=Next}=Trans, Call) ->
    #call{global=#global{t1=T1}} = Call,
    Time = case is_integer(Next) of
        true -> Next;
        false -> T1
    end,
    Trans#trans{
        retrans_timer = start_timer(Time, timer_a, Trans),
        next_retrans = 2*Time
    };

retrans_timer(Tag, #trans{next_retrans=Next}=Trans, Call)
                when Tag=:=timer_e; Tag=:=timer_g ->
    #call{global=#global{t1=T1, t2=T2}} = Call, 
    Time = case is_integer(Next) of
        true -> Next;
        false -> T1
    end,
    Trans#trans{
        retrans_timer = start_timer(Time, Tag, Trans),
        next_retrans = min(2*Time, T2)
    }.



%% @private
-spec expire_timer(expire_timer(), trans(), call()) ->
    trans().

expire_timer(expire, #trans{id=Id, class=Class, request=Req, opts=Opts}=Trans, _) ->
    Timer = case nksip_sipmsg:header(Req, <<"Expires">>, integers) of
        [Expires] when is_integer(Expires), Expires > 0 -> 
            case lists:member(no_auto_expire, Opts) of
                true -> 
                    #sipmsg{app_id=AppId, call_id=CallId} = Req,
                    ?debug(AppId, CallId, "UAC ~p skipping INVITE expire", [Id]),
                    undefined;
                _ -> 
                    Time = case Class of 
                        uac -> 1000*Expires;
                        uas -> 1000*Expires+100     % UAC fires first
                    end,
                    start_timer(Time, expire, Trans)
            end;
        _ ->
            undefined
    end,
    Trans#trans{expire_timer=Timer}.


%% @private
-spec start_timer(integer(), timer(), trans()) ->
    {timer(), reference()}.

start_timer(Time, Tag, #trans{class=Class, id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {Class, Tag, Id})}.


%% @private
-spec cancel_timers([timeout|retrans|expire], trans()) ->
    trans().

cancel_timers([timeout|Rest], #trans{timeout_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{timeout_timer=undefined});

cancel_timers([retrans|Rest], #trans{retrans_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{retrans_timer=undefined});

cancel_timers([expire|Rest], #trans{expire_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{expire_timer=undefined});

cancel_timers([], Trans) ->
    Trans.


%% @private
-spec cancel_timer({timer(), reference()}|undefined) -> 
    ok.

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    case erlang:cancel_timer(Ref) of
        false -> 
            receive 
                {timeout, Ref, _} -> ok
            after 0 -> 
                ok
            end;
        _Time -> 
            ok
    end;

cancel_timer(_) -> 
    ok.


