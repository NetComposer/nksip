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

-export([update_sipmsg/2, update/2]).
-export([update_auth/2, check_auth/2]).
-export([timeout_timer/3, retrans_timer/3, expire_timer/3, app_timer/3, 
         cancel_timers/2]).
-export_type([timeout_timer/0, retrans_timer/0, expire_timer/0, timer/0]).


-include("nksip.hrl").
-include("nksip_call.hrl").

-type timeout_timer() :: timer_b | timer_c | timer_d | timer_f | timer_h | 
                         timer_i | timer_j | timer_k | timer_l | timer_m | 
                         noinvite.

-type retrans_timer() :: timer_a | timer_e | timer_g.

-type expire_timer() ::  expire.

-type timer() :: timeout_timer() | retrans_timer() | expire_timer().

-type call() :: nksip_call:call().

-type trans() :: nksip_call:trans().




%% ===================================================================
%% Private
%% ===================================================================


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

update(New, Call) ->
    #trans{
        id = Id, 
        class = Class, 
        status = NewStatus, 
        method = Method, 
        app_timer = AppTimer
    } = New,
    #call{trans=Trans} = Call,
    case Trans of
        [#trans{id=Id, status=OldStatus}|Rest] -> 
            ok;
        _ -> 
            case lists:keytake(Id, #trans.id, Trans) of 
                {value, #trans{status=OldStatus}, Rest} -> ok;
                false -> OldStatus=finished, Rest=Trans
            end
    end,
    CS = case Class of uac -> "UAC"; uas -> "UAS" end,
    Call1 = case NewStatus of
        finished ->
            case AppTimer of
                undefined ->
                    ?call_debug("~s ~p ~p (~p) removed", 
                                [CS, Id, Method, OldStatus], Call),
                    Call#call{trans=Rest};
                {Fun, _} ->
                    ?call_debug("~s ~p ~p (~p) is not removed because it is "
                               "waiting for ~p reply", 
                               [CS, Id, Method, NewStatus, Fun], Call),
                    Call#call{trans=[New|Rest]}
            end;
        _ when NewStatus=:=OldStatus -> 
            Call#call{trans=[New|Rest]};
        _ -> 
            ?call_debug("~s ~p ~p ~p -> ~p", 
                        [CS, Id, Method, OldStatus, NewStatus], Call),
            Call#call{trans=[New|Rest]}
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
-spec update_auth(nksip:request()|nksip:response(), call()) ->
    call().

update_auth(#sipmsg{transport=#transport{}=Transp}=SipMsg, Call) ->
    case nksip_dialog:id(SipMsg) of
        <<>> ->
            Call;
        DialogId ->
            #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
            #call{auths=Auths} = Call,
            case lists:member({DialogId, Proto, Ip, Port}, Auths) of
                true ->
                    Call;
                false -> 
                    ?call_debug("Added cached auth for dialog ~s (~p:~p:~p)", 
                                [DialogId, Proto, Ip, Port], Call),
                    Auths1 = [{DialogId, Proto, Ip, Port}|Auths],
                    Call#call{auths=Auths1}
            end
    end;

update_auth(_Resp, Call) ->
    Call.


%% @private
-spec check_auth(nksip:request()|nksip:response(), call()) ->
    boolean().

check_auth(#sipmsg{transport=#transport{}=Transp}=SipMsg, Call) ->
    case nksip_dialog:id(SipMsg) of
        <<>> ->
            false;
        DialogId ->
            #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
            #call{auths=Auths} = Call,
            case lists:member({DialogId, Proto, Ip, Port}, Auths) of
                true ->
                    ?call_debug("Origin ~p:~p:~p is in dialog ~s authorized list", 
                                [Proto, Ip, Port, DialogId], Call),
                    true;
                false ->
                    AuthList = [{O, I, P} || {D, O, I, P}<-Auths, D==DialogId],
                    ?call_debug("Origin ~p:~p:~p is NOT in dialog ~s "
                                "authorized list (~p)", 
                                [Proto, Ip, Port, DialogId, AuthList], Call),
                    false
            end
    end;

check_auth(_, _) ->
    false.


%% ===================================================================
%% Util - Timers
%% ===================================================================


%% @private
-spec timeout_timer(timeout_timer(), trans(), call()) ->
    trans().

timeout_timer(Tag, Trans, #call{opts=#call_opts{timer_t1=T1}}) 
            when Tag=:=timer_b; Tag=:=timer_f; Tag=:=timer_m;
                 Tag=:=timer_h; Tag=:=timer_j; Tag=:=timer_l;
                 Tag=:=noinvite ->
    Trans#trans{timeout_timer=start_timer(64*T1, Tag, Trans)};

timeout_timer(timer_d, Trans, _) ->
    Trans#trans{timeout_timer=start_timer(32000, timer_d, Trans)};

timeout_timer(Tag, Trans, #call{opts=#call_opts{timer_t4=T4}}) 
                when Tag=:=timer_k; Tag=:=timer_i ->
    Trans#trans{timeout_timer=start_timer(T4, Tag, Trans)};

timeout_timer(timer_c, Trans, #call{opts=#call_opts{timer_c=TC}}) ->
    Trans#trans{timeout_timer=start_timer(TC, timer_c, Trans)};

timeout_timer(sipapp_call, Trans, #call{opts=#call_opts{timer_sipapp=Time}}) ->
    Trans#trans{timeout_timer=start_timer(Time, sipapp_call, Trans)}.

%% @private
-spec retrans_timer(retrans_timer(), trans(), call()) ->
    trans().

retrans_timer(timer_a, #trans{next_retrans=Next}=Trans, Call) ->
    #call{opts=#call_opts{timer_t1=T1}} = Call,
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
    #call{opts=#call_opts{timer_t1=T1, timer_t2=T2}} = Call, 
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

expire_timer(expire, Trans, Call) ->
    #trans{id=Id, class=Class, request=Req, opts=Opts} = Trans,
    #call{app_id=AppId, call_id=CallId} = Call,
    Timer = case nksip_sipmsg:header(Req, <<"Expires">>, integers) of
        [Expires] when is_integer(Expires), Expires > 0 -> 
            case lists:member(no_auto_expire, Opts) of
                true -> 
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
-spec app_timer(atom(), trans(), call()) ->
    trans(). 

app_timer(Fun, Trans, #call{opts=#call_opts{timer_sipapp=Time}}) ->
    Trans#trans{app_timer=start_timer(Time, Fun, Trans)}.


%% @private
-spec start_timer(integer(), timer(), trans()) ->
    {timer(), reference()}.

start_timer(Time, Tag, #trans{class=Class, id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {Class, Tag, Id})}.


%% @private
-spec cancel_timers([timeout|retrans|expire|app], trans()) ->
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

cancel_timers([app|Rest], #trans{app_timer=Timer}=Trans) ->
    cancel_timer(Timer),
    cancel_timers(Rest, Trans#trans{app_timer=undefined});

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


