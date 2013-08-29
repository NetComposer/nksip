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

-export([add_msg/3, update_msg/2, update/2, start_timer/2, cancel_timers/2, trace/2]).


add_msg(SipMsg, NoStore, #call{next=MsgId, keep_time=KeepTime, msgs=Msgs}=SD) ->
    SipMsg1 = SipMsg#sipmsg{id=MsgId},
    case KeepTime > 0 andalso (not NoStore) of
        true ->
            ?call_debug("Storing sipmsg ~p", [MsgId], SD),
            erlang:start_timer(1000*KeepTime, self(), {remove_msg, MsgId}),
            nksip_counters:async([nksip_msgs]),
            {SipMsg1, SD#call{msgs=[SipMsg1|Msgs], next=MsgId+1}};
        false ->
            {SipMsg1, SD#call{next=MsgId+1}}
    end.
    
update_msg(#sipmsg{id=MsgId}=Msg, #call{msgs=Msgs}=SD) ->
    Msgs1 = lists:keyreplace(MsgId, #sipmsg.id, Msgs, Msg),
    SD#call{msgs=Msgs1}.


update(#trans{id=Id}=New, #call{trans=[#trans{id=Id}=Old|Rest]}=SD) ->
    #trans{status=NewStatus, method=Method} = New,
    #trans{status=OldStatus} = Old,
    SD1 = case NewStatus of
        finished ->
            ?call_debug("UAS ~p ~p (~p) finished", 
                        [Id, Method, OldStatus], SD),
            SD#call{trans=Rest};
        OldStatus -> 
            SD#call{trans=[New|Rest]};
        _ -> 
            ?call_debug("UAS ~p ~p (~p) switched to ~p", 
                        [Id, Method, OldStatus, NewStatus], SD),
            SD#call{trans=[New|Rest]}
    end,
    hibernate(New, SD1);
    
update(New, #call{trans=Trans}=SD) ->
    #trans{id=Id, status=NewStatus, method=Method} = New,
    SD1 = case lists:keytake(Id, #trans.id, Trans) of
        {value, #trans{status=OldStatus}, Rest} -> 
            case NewStatus of
                finished ->
                    ?call_debug("UAS ~p ~p (~p) finished!", 
                                [Id, Method, OldStatus], SD),
                    SD#call{trans=Rest};
                OldStatus -> 
                    SD#call{trans=[New|Rest]};
                _ -> 
                    ?call_debug("UAS ~p ~p (~p) switched to ~p!", 
                        [Id, Method, OldStatus, NewStatus], SD),
                    SD#call{trans=[New|Rest]}
            end;
        false ->
            SD#call{trans=[New|Trans]}
    end,
    hibernate(New, SD1).


hibernate(#trans{status=Status}, SD) 
          when Status=:=invite_accepted; Status=:=completed; 
               Status=:=finished ->
    ?call_debug("Hibernating (~p)", [Status], SD),
    SD#call{hibernate=true};

hibernate(#trans{class=uac, status=invite_completed}, SD) ->
    ?call_debug("Hibernating (invite_completed)", [], SD),
    SD#call{hibernate=true};

hibernate(_, SD) ->
    SD.




trace(Msg, #call{app_id=AppId, call_id=CallId}) ->
    nksip_trace:insert(AppId, CallId, Msg).



%% ===================================================================
%% Util - Timers
%% ===================================================================

start_timer(timeout, #trans{method=Method}=Trans) ->
    Time = case Method of
        'INVITE' -> 1000*nksip_config:get(timer_c);
         _ -> 64*nksip_config:get(timer_t1)
    end,
    Trans#trans{timeout_timer=start_timer(Time, timeout, Trans)};

start_timer(timer_a, #trans{next_retrans=Next}=Trans) ->
    Time = case is_integer(Next) of
        true -> Next;
        false -> nksip_config:get(timer_t1)
    end,
    Trans#trans{
        retrans_timer = start_timer(Time, timer_a, Trans),
        next_retrans = 2*Time
    };

start_timer(Tag, Trans) 
            when Tag=:=timer_b; Tag=:=timer_f; Tag=:=timer_m;
                 Tag=:=timer_h; Tag=:=timer_j; Tag=:=timer_l ->
    Time = 64*nksip_config:get(timer_t1),
    Trans#trans{timeout_timer=start_timer(Time, Tag, Trans)};

start_timer(timer_d, Trans) ->
    Trans#trans{timeout_timer=start_timer(32000, timer_d, Trans)};

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
    Time = nksip_config:get(timer_t4),
    Trans#trans{timeout_timer=start_timer(Time, Tag, Trans)};

start_timer(expire, #trans{request=#sipmsg{opts=Opts}=Req}=Trans) ->
    Timer = case nksip_sipmsg:header(Req, <<"Require">>, integer) of
        {ok, Expires} when Expires > 0 -> 
            case lists:member(no_auto_expire, Opts) of
                true -> undefined;
                _ -> start_timer(1000*Expires, expire, Trans)
            end;
        _ ->
            undefined
    end,
    Trans#trans{expire_timer=Timer}.




start_timer(Time, Tag, #trans{class=Class, id=Id}) ->
    {Tag, erlang:start_timer(Time, self(), {Class, Tag, Id})}.

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

cancel_timer({_Tag, Ref}) when is_reference(Ref) -> 
    case erlang:cancel_timer(Ref) of
        false -> receive {timeout, Ref, _} -> ok after 0 -> ok end;
        _ -> ok
    end;

cancel_timer(_) -> 
    ok.


