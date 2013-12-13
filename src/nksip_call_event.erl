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

%% @private Call dialog event library module.
-module(nksip_call_event).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([uac_pre_request/3, uac_request/3, uac_response/4]).
-export([uas_request/3, uas_response/4]).
-export([stop/3, create_event/2, remove_event/2, is_event/2, timer/3]).
-export([request_uac_opts/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% UAC
%% ===================================================================


%% @private
-spec uac_pre_request(nksip:request(), nksip:dialog(), nksip_call:call()) ->
    ok | {error, no_transaction}.

uac_pre_request(#sipmsg{class={req, 'NOTIFY'}}=Req, Dialog, _Call) ->
    case find(Req, Dialog) of
        not_found ->  {error, no_transaction};
        #subscription{class=uas} -> ok;
        _ -> {error, no_transaction}
    end;

uac_pre_request(_Req, _Dialog, _Call) ->
    ok.


%% @private
-spec uac_request(nksip:request(), nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

uac_request(_Req, Dialog, _Call) ->
    Dialog.


%% @private
-spec uac_response(nksip:request(), nksip:response(), 
                   nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

uac_response(#sipmsg{class={req, Method}}=Req, Resp, Dialog, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY'; Method=='REFER' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    Req1 = add_refer_event(Req, Call),
    case find(Req1, Dialog) of
        #subscription{class=Class, id=Id} = Subs
            when (Class==uac andalso Method=='SUBSCRIBE') orelse
                 (Class==uac andalso Method=='REFER') orelse
                 (Class==uas andalso Method=='NOTIFY') ->
            ?call_debug("Subscription ~s UAC response ~p ~p", 
                          [Id, Method, Code], Call),
            uac_do_response(Method, Code, Req1, Resp, Subs, Dialog, Call);
        not_found when Code>=200 andalso Code<300 andalso
                       (Method=='SUBSCRIBE' orelse Method=='REFER') ->
            Subs = #subscription{id=Id} = Subs = create(uac, Req1, Dialog, Call),
            ?call_debug("Subscription ~s UAC response ~p ~p", 
                          [Id, Method, Code], Call),
            uac_do_response(Method, Code, Req1, Resp, Subs, Dialog, Call);
        _ ->
            case Code>=200 andalso Code<300 of
                true -> 
                    ?call_notice("UAC event ignoring ~p ~p", [Method, Code], Call);
                false ->
                    ok
            end,
            Dialog
    end;

uac_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uac_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:subscription(), nksip:dialog(), 
                      nksip_call:call()) ->
    nksip:dialog().

uac_do_response('SUBSCRIBE', Code, Req, Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({subscribe, Req, Resp}, Subs, Dialog, Call);

%% See RFC5070 for termination codes
uac_do_response('SUBSCRIBE', Code, _Req, _Resp, Subs, Dialog, Call) 
                when Code>=300 ->
    case Subs#subscription.answered of
        undefined ->
            update({terminated, {code, Code}}, Subs, Dialog, Call);
        _ when Code==405; Code==408; Code==481; Code==501 ->
            update({terminated, {code, Code}}, Subs, Dialog, Call);
        _ ->
            update(none, Subs, Dialog, Call)
    end;

uac_do_response('NOTIFY', Code, Req, _Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({notify, Req}, Subs, Dialog, Call);
        
uac_do_response('NOTIFY', Code, _Req, _Resp, Subs, Dialog, Call)
                when Code==405; Code==408; Code==481; Code==501 ->
    update({terminated, {code, Code}}, Subs, Dialog, Call);

uac_do_response('REFER', Code, Req, Resp, Subs, Dialog, Call) ->
    uac_do_response('SUBSCRIBE', Code, Req, Resp, Subs, Dialog, Call);

uac_do_response(_, _Code, _Req, _Resp, _Subs, Dialog, _Call) ->
    Dialog.



%% ===================================================================
%% UAS
%% ===================================================================


%% @private
-spec uas_request(nksip:request(), nksip:dialog(), nksip_call:call()) ->
    {ok, nksip:dialog()} | {error, no_transaction}.

uas_request(#sipmsg{class={req, Method}}=Req, Dialog, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY'; Method=='REFER' ->
    Req1 = add_refer_event(Req, Call),
    case find(Req1, Dialog) of
        #subscription{class=Class, id=Id} when
            (Method=='SUBSCRIBE' andalso Class==uas) orelse
            (Method=='REFER' andalso Class==uas) orelse
            (Method=='NOTIFY' andalso Class==uac) ->
            ?call_debug("Subscription ~s UAS request ~p", [Id, Method], Call), 
            {ok, Dialog};
        not_found when Method=='SUBSCRIBE' andalso
                       element(1, Req1#sipmsg.event) == <<"refer">> ->
            {error, forbidden};
        not_found when Method=='SUBSCRIBE'; Method=='REFER' ->
            {ok, Dialog};
        not_found when Method=='NOTIFY' ->
            case is_event(Req1, Call) of
                true -> {ok, Dialog};
                false -> {error, no_transaction}
            end;
        _ ->
            ?call_notice("UAS event ignoring ~p", [Method], Call),
            {error, no_transaction}
    end;

uas_request(_Req, Dialog, _Call) ->
    Dialog.


%% @private
-spec uas_response(nksip:request(), nksip:response(), 
                   nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

uas_response(#sipmsg{class={req, Method}}=Req, Resp, Dialog, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY'; Method=='REFER' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    Req1 = add_refer_event(Req, Call),
    case find(Req1, Dialog) of
        #subscription{class=Class, id=Id} = Subs when
            (Method=='SUBSCRIBE' andalso Class==uas) orelse
            (Method=='REFER' andalso Class==uas) orelse
            (Method=='NOTIFY' andalso Class==uac) ->
            ?call_debug("Subscription ~s UAS response ~p ~p", 
                          [Id, Method, Code], Call),
            uas_do_response(Method, Code, Req1, Resp, Subs, Dialog, Call);
        not_found when Code>=200, Code<300 ->
            Class = case Method of 
                'SUBSCRIBE' -> uas; 
                'REFER' -> uas; 
                'NOTIFY' -> uac 
            end,
            #subscription{id=Id} = Subs = create(Class, Req1, Dialog, Call),
            ?call_debug("Subscription ~s UAS response ~p, ~p", 
                          [Id, Method, Code], Call), 
            uas_do_response(Method, Code, Req1, Resp, Subs, Dialog, Call);
        _ ->
            case Code>=200 andalso Code<300 of
                true ->
                    ?call_notice("UAS event ignoring ~p ~p", [Method, Code], Call);
                false ->
                    ok
            end,
            Dialog
    end;

uas_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uas_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:subscription(), nksip:dialog(), 
                      nksip_call:call()) ->
    nksip:dialog().

uas_do_response(_, Code, _Req, _Resp, _Subs, Dialog, _Call) when Code<200 ->
    Dialog;

uas_do_response('SUBSCRIBE', Code, Req, Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({subscribe, Req, Resp}, Subs, Dialog, Call);
        
uas_do_response('SUBSCRIBE', Code, _Req, _Resp, Subs, Dialog, Call) 
                when Code>=300 ->
    case Subs#subscription.answered of
        undefined ->
            update({terminated, {code, Code}}, Subs, Dialog, Call);
        _ when Code==405; Code==408; Code==481; Code==501 ->
            update({terminated, {code, Code}}, Subs, Dialog, Call);
        _ ->
            update(none, Subs, Dialog, Call)

    end;

uas_do_response('NOTIFY', Code, Req, _Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({notify, Req}, Subs, Dialog, Call);
        
uas_do_response('NOTIFY', Code, _Req, _Resp, Subs, Dialog, Call) 
                when Code==405; Code==408; Code==481; Code==501 ->
    update({terminated, {code, Code}}, Subs, Dialog, Call);

uas_do_response('REFER', Code, Req, Resp, Subs, Dialog, Call) ->
    uas_do_response('SUBSCRIBE', Code, Req, Resp, Subs, Dialog, Call);

uas_do_response(_, _Code, _Req, _Resp, _Subs, Dialog, _Call) ->
    Dialog.
    


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec update(term(), nksip:subscription(), nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

update(none, Subs, Dialog, Call) ->
    store(Subs, Dialog, Call);

update({subscribe, Req, Resp}, Subs, Dialog, Call) ->
    #subscription{
        id = Id, 
        timer_n = TimerN,
        timer_expire = TimerExpire,
        timer_middle = TimerMiddle,
        last_notify_cseq = NotifyCSeq
    } = Subs,
    cancel_timer(TimerN),
    cancel_timer(TimerExpire),
    cancel_timer(TimerMiddle),
    Expires1 = min(Req#sipmsg.expires, Resp#sipmsg.expires),
    % Expires can be 0, in that case we use only timer N
    Expires2 = case is_integer(Expires1) andalso Expires1>=0 of
        true -> Expires1;
        false -> ?DEFAULT_EVENT_EXPIRES
    end,
    ?call_debug("Event ~s expires updated to ~p", [Id, Expires2], Call),
    #call{opts=#call_opts{timer_t1=T1}} = Call,
    TimerN1 = case NotifyCSeq > Req#sipmsg.cseq of
        true -> undefined;
        false -> start_timer(64*T1, {timeout, Id}, Dialog)
    end,
    TimerExpire1 = case Expires2 of
        0 -> undefined;
        _ -> start_timer(1000*Expires2, {timeout, Id}, Dialog)
    end,
    TimerMiddle1= case Expires2 of
        0 -> undefined;
        _ -> start_timer(500*Expires2, {middle, Id}, Dialog)
    end,
    Subs1 = Subs#subscription{
        expires = Expires2,
        timer_n = TimerN1,
        timer_expire = TimerExpire1,
        timer_middle = TimerMiddle1
    },
    store(Subs1, Dialog, Call);

update({notify, Req}, Subs, Dialog, Call) ->
    Subs1 = Subs#subscription{last_notify_cseq=Req#sipmsg.cseq},
    Status = nksip_subscription:notify_status(Req),
    update(Status, Subs1, Dialog, Call);

update({Status, Expires}, Subs, Dialog, Call) 
        when Status==active; Status==pending ->
    #subscription{
        id = Id, 
        status = OldStatus,
        answered = Answered,
        timer_n = TimerN,
        timer_expire = TimerExpire,
        timer_middle = TimerMiddle
    } = Subs,
    case Status==OldStatus of
        true -> 
            ok;
        false -> 
            ?call_debug("Subscription ~s ~p -> ~p", [Id, OldStatus, Status], Call),
            cast(Status, Subs, Dialog, Call)
    end,
    Expires1 = case is_integer(Expires) andalso Expires>0 of
        true -> Expires;
        false -> ?DEFAULT_EVENT_EXPIRES
    end,
    cancel_timer(TimerN),
    cancel_timer(TimerExpire),
    cancel_timer(TimerMiddle),
    ?call_debug("Event ~s expires updated to ~p", [Id, Expires1], Call),
    Answered1 = case Answered of
        undefined -> nksip_lib:timestamp();
        _ -> Answered
    end,
    Subs1 = Subs#subscription{
        status = Status,
        answered = Answered1,
        timer_n = undefined,
        timer_expire = start_timer(1000*Expires1, {timeout, Id}, Dialog),
        timer_middle = start_timer(500*Expires1, {middle, Id}, Dialog)
    },
    store(Subs1, Dialog, Call);

update({terminated, Reason}, Subs, Dialog, Call) ->
    #subscription{
        id = Id,
        status = OldStatus,
        timer_n = N, 
        timer_expire = Expire, 
        timer_middle = Middle
    } = Subs,
    cancel_timer(N),
    cancel_timer(Expire),
    cancel_timer(Middle),
    ?call_debug("Subscription ~s ~p -> {terminated, ~p}", [Id, OldStatus, Reason], Call),
    cast({terminated, Reason}, Subs, Dialog, Call),
    store(Subs#subscription{status={terminated, Reason}}, Dialog, Call);

update(_Status, Subs, Dialog, Call) ->
    update({terminated, undefined}, Subs, Dialog, Call).


%% @private. Create a provisional event and start timer N.
-spec create_event(nksip:request(),  nksip_call:call()) ->
    nksip_call:call().

create_event(Req, Call) ->
    #sipmsg{event={EvType, EvOpts}, from_tag=Tag} = add_refer_event(Req, Call),
    EvId = nksip_lib:get_binary(<<"id">>, EvOpts),
    ?call_debug("Event ~s_~s_~s UAC created", [EvType, EvId, Tag], Call),
    #call{opts=#call_opts{timer_t1=T1}, events=Events} = Call,
    Id = {EvType, EvId, Tag},
    Timer = erlang:start_timer(64*T1, self(), {remove_event, Id}),
    Event = #provisional_event{id=Id, timer_n=Timer},
    Call#call{events=[Event|Events]}.


%% @private Removes a stored provisional event.
%% Searches for all current subscriptions, if any of them is based on this
%% event and is in 'wait_notify' status, it is deleted.
-spec remove_event(nksip:request() | {binary(), binary(), binary()}, 
                     nksip_call:call()) ->
    nksip_call:call().

remove_event(#sipmsg{}=Req, Call) ->
    #sipmsg{event={EvType, EvOpts}, from_tag=Tag} = add_refer_event(Req, Call),
    EvId = nksip_lib:get_binary(<<"id">>, EvOpts),
    remove_event({EvType, EvId, Tag}, Call);

remove_event({EvType, EvId, Tag}=Id, #call{events=Events}=Call) ->
    case lists:keytake(Id, #provisional_event.id, Events) of
        {value, #provisional_event{timer_n=Timer}, Rest} ->
            cancel_timer(Timer),
            ?call_debug("Provisional event ~s_~s_~s destroyed", 
                          [EvType, EvId, Tag], Call),
            Call#call{events=Rest};
        false ->
            Call
    end.


%% @private
stop(#subscription{id=Id}, Dialog, Call) ->
    case find(Id, Dialog) of
        not_found -> Call;
        Subs -> update({terminated, forced}, Subs, Dialog, Call)
    end.


%% @private
-spec request_uac_opts(nksip:method(), nksip_lib:proplist(), 
                       nksip:dialog() | nksip:subscription()) ->
    {ok, nksip_lib:proplist()} | {error, unknown_subscription}.

request_uac_opts(Method, Opts, #dialog{}=Dialog) ->
    case nksip_lib:get_value(subscription_id, Opts) of
        undefined ->
            {ok, Opts};
        SubsId ->
            case find(SubsId, Dialog) of
                #subscription{} = Subs ->
                    {ok, request_uac_opts(Method, Opts, Subs)};
                not_found ->
                    {error, unknown_subscription}
            end
    end;

request_uac_opts('SUBSCRIBE', Opts, #subscription{event=Event, expires=Expires}) ->
    case lists:keymember(expires, 1, Opts) of
        true -> [{event, Event} | Opts];
        false -> [{event, Event}, {expires, Expires} | Opts]
    end;

request_uac_opts('NOTIFY', Opts, #subscription{event=Event, timer_expire=Timer}) ->
    PSS = case nksip_lib:get_value(subscription_state, Opts) of
        State when State==active; State==pending ->
            case is_reference(Timer) of
                true -> 
                    Expires = round(erlang:read_timer(Timer)/1000),
                    {State, [{expires, Expires}]};
                false ->
                    {terminated, [{reason, timeout}]}
            end;
        {terminated, {Reason, Retry}} ->
            {terminated, [{reason, Reason}, {retry_after, Retry}]};
        {terminated, Reason} ->
            {terminated, [{reason, Reason}]}
    end,
    [{event, Event}, {parsed_subscription_state, PSS} | Opts].


%% @private
add_refer_event(#sipmsg{class={req, 'REFER'}, cseq=CSeq}=Req, Call) ->
    #call{opts=#call_opts{timer_c=TimerC}} = Call,
    Req#sipmsg{
        event = {<<"refer">>, [{<<"id">>, nksip_lib:to_binary(CSeq)}]},
        expires = round(TimerC/1000)
    };

add_refer_event(Req, _) ->
    Req.


%% @private Called when a dialog timer is fired
-spec timer({middle|timeout, nksip_subscription:id()}, nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

timer({Type, Id}, Dialog, Call) ->
    case find(Id, Dialog) of
        #subscription{} = Subs when Type==middle -> 
            cast(middle_timer, Subs, Dialog, Call),
            Call;
        #subscription{} = Subs when Type==timeout -> 
            Dialog1 = update({terminated, timeout}, Subs, Dialog, Call),
            nksip_call_dialog:update(none, Dialog1, Call);
        not_found -> 
            ?call_notice("Subscription ~s timer fired for unknown event", [Id], Call),
            Call
    end.



%% ===================================================================
%% Util
%% ===================================================================

%% @private Creates a new event
-spec create(uac|uas, nksip:request(), nksip:dialog(), nksip_call:call()) ->
    nksip:subscription().

create(Class, Req, Dialog, Call) ->
    #sipmsg{event=Event, app_id=AppId} = Req,
    Id = nksip_subscription:subscription_id(Event, Dialog#dialog.id),
    #call{opts=#call_opts{timer_t1=T1}} = Call,
    Subs = #subscription{
        id = Id,
        app_id = AppId,
        event = Event,
        status = init,
        class = Class,
        answered = undefined,
        timer_n = start_timer(64*T1, {timeout, Id}, Dialog)
    },
    cast(init, Subs, Dialog, Call),
    Subs.


%% @private Finds a event.
-spec find(nksip:request()|nksip:response()|nksip_subscription:id(), nksip:dialog()) ->
    nksip:subscription() | not_found.

find(#sipmsg{event=Event}, #dialog{id=DialogId, subscriptions=Subs}) ->
    Id = nksip_subscription:subscription_id(Event, DialogId),
    do_find(Id, Subs);
find(<<"U_", _/binary>>=Id, #dialog{subscriptions=Subs}) ->
    do_find(Id, Subs);
find(_, _) ->
    not_found.

%% @private 
do_find(_Id, []) -> not_found;
do_find(Id, [#subscription{id=Id}=Subs|_]) -> Subs;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).



%% @private Finds a provisional event
-spec is_event(nksip:request(), nksip_call:call()) ->
    boolean().

is_event(#sipmsg{event=Event, to_tag=Tag}, #call{events=Events}) ->
    case Event of
        {Name, Opts} when is_list(Opts) ->
            Id = nksip_lib:get_value(<<"id">>, Opts, <<>>),
            do_is_event({Name, Id, Tag}, Events);
        _ ->
            false
    end.

%% @private.
do_is_event(_Id, []) -> false;
do_is_event(Id, [#provisional_event{id=Id}|_]) -> true;
do_is_event(Id, [_|Rest]) -> do_is_event(Id, Rest).


%% @private Updates an updated event into dialog
-spec store(nksip:subscription(), nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

store(Subs, Dialog, Call) ->
    #subscription{id=Id, status=Status, class=Class} = Subs,
    #dialog{subscriptions=Subscriptions} = Dialog,
    case Subscriptions of
        [] -> Rest = [], IsFirst = true;
        [#subscription{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest = [], IsFirst = false
    end,
    UA = case Class of uac -> "UAC"; uas -> "UAS" end,
    case Status of
        {terminated, _Reason} ->
            ?call_debug("~s removing event ~s", [UA, Id], Call),
            Subscriptions1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #subscription.id, Subscriptions)
            end,
            Dialog#dialog{subscriptions=Subscriptions1};
        _ ->
            ?call_debug("~s storing event ~s: ~p", [UA, Id, Status], Call),
            Subscriptions1 = case IsFirst of
                true -> [Subs|Rest];
                false -> lists:keystore(Id, #subscription.id, Subscriptions, Subs)
            end,
            Dialog#dialog{subscriptions=Subscriptions1}
    end.



%% @private
-spec cast(term(), nksip:subscription(), nksip:dialog(), nksip_call:call()) ->
    ok.

cast(Arg, #subscription{id=SubsId}, Dialog, Call) ->
    nksip_call_dialog:cast(dialog_update, {subscription_status, SubsId, Arg}, 
                           Dialog, Call).


%% @private
cancel_timer(Ref) when is_reference(Ref) -> 
    case erlang:cancel_timer(Ref) of
        false -> receive {timeout, Ref, _} -> ok after 0 -> ok end;
        _ -> ok
    end;

cancel_timer(_) ->
    ok.


%% @private
-spec start_timer(integer(), {atom(), nksip_subscription:id()}, nksip:dialog()) ->
    reference().

start_timer(Time, Tag, #dialog{id=Id}) ->
    erlang:start_timer(Time , self(), {dlg, {event, Tag}, Id}).

