%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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
-export([stop/3, create_prov_event/2, remove_prov_event/2, is_prov_event/2, timer/3]).
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
    case nksip_subscription_lib:find(Req, Dialog) of
        not_found ->  
            % lager:warning("PRE REQ: ~p, ~p", 
            %         [nksip_subscription_lib:make_id(Req), Dialog#dialog.subscriptions]),
            {error, no_transaction};
        #subscription{class=uas} ->
            ok;
        _ ->
            {error, no_transaction}
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
    case nksip_subscription_lib:find(Req, Dialog) of
        #subscription{class=Class} = Subs
            when (Class==uac andalso Method=='SUBSCRIBE') orelse
                 (Class==uac andalso Method=='REFER') orelse
                 (Class==uas andalso Method=='NOTIFY') ->
            ?CALL_DEBUG("Subscription ~s UAC response ~p ~p", [Subs#subscription.id, Method, Code], Call),
            uac_do_response(Method, Code, Req, Resp, Subs, Dialog, Call);
        not_found when Code>=200 andalso Code<300 andalso
                       (Method=='SUBSCRIBE' orelse Method=='REFER') ->
            Subs = create(uac, Req, Dialog, Call),
            ?CALL_DEBUG("Subscription ~s UAC response ~p ~p", [Subs#subscription.id, Method, Code], Call),
            uac_do_response(Method, Code, Req, Resp, Subs, Dialog, Call);
        _ ->
            case Code>=200 andalso Code<300 of
                true ->
                    ?CALL_LOG(notice, "UAC event ignoring ~p ~p", [Method, Code], Call);
                false ->
                    ok
            end,
            Dialog
    end;

uac_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uac_do_response(nksip:method(), nksip:sip_code(), nksip:request(), 
                      nksip:response(), #subscription{}, nksip:dialog(), 
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
            % update({active, 10}, Subs, Dialog, Call);
            update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);
        _ when Code==405; Code==408; Code==481; Code==501 ->
            update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);
        _ ->
            store(Subs, Dialog, Call)
    end;

uac_do_response('NOTIFY', Code, Req, _Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({notify, Req}, Subs, Dialog, Call);
        
uac_do_response('NOTIFY', Code, _Req, _Resp, Subs, Dialog, Call)
                when Code==405; Code==408; Code==481; Code==501 ->
    update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);

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
    case nksip_subscription_lib:find(Req, Dialog) of
        #subscription{class=Class, id=_Id} when
            (Method=='SUBSCRIBE' andalso Class==uas) orelse
            (Method=='REFER' andalso Class==uas) orelse
            (Method=='NOTIFY' andalso Class==uac) ->
            ?CALL_DEBUG("Subscription ~s UAS request ~p", [_Id, Method], Call),
            {ok, Dialog};
        not_found when Method=='SUBSCRIBE' andalso
                element(1, Req#sipmsg.event) == <<"refer">> ->
            {error, forbidden};
        not_found when Method=='SUBSCRIBE'; Method=='REFER' ->
            {ok, Dialog};
        not_found when Method=='NOTIFY' ->
            case is_prov_event(Req, Call) of
                true ->
                    {ok, Dialog};
                false ->
                    {error, no_transaction}
            end;
        _ ->
            ?CALL_LOG(notice, "UAS event ignoring ~p", [Method], Call),
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
    case nksip_subscription_lib:find(Req, Dialog) of
        #subscription{class=Class, id=_Id} = Subs when
            (Method=='SUBSCRIBE' andalso Class==uas) orelse
            (Method=='REFER' andalso Class==uas) orelse
            (Method=='NOTIFY' andalso Class==uac) ->
            ?CALL_DEBUG("Subscription ~s UAS response ~p ~p", [_Id, Method, Code], Call),
            uas_do_response(Method, Code, Req, Resp, Subs, Dialog, Call);
        not_found when Code>=200, Code<300 ->
            Class = case Method of 
                'SUBSCRIBE' -> uas; 
                'REFER' -> uas; 
                'NOTIFY' -> uac 
            end,
            Subs = create(Class, Req, Dialog, Call),
            ?CALL_DEBUG("Subscription ~s UAS response ~p, ~p", [Subs#subscription.id, Method, Code], Call),
            uas_do_response(Method, Code, Req, Resp, Subs, Dialog, Call);
        _ ->
            case Code>=200 andalso Code<300 of
                true ->
                    ?CALL_LOG(notice, "UAS event ignoring ~p ~p", [Method, Code], Call);
                false ->
                    ok
            end,
            Dialog
    end;

uas_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uas_do_response(nksip:method(), nksip:sip_code(), nksip:request(), 
                      nksip:response(), #subscription{}, nksip:dialog(), 
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
            update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);
        _ when Code==405; Code==408; Code==481; Code==501 ->
            update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);
        _ ->
            store(Subs, Dialog, Call)
    end;

uas_do_response('NOTIFY', Code, Req, _Resp, Subs, Dialog, Call) 
                when Code>=200, Code<300 ->
    update({notify, Req}, Subs, Dialog, Call);
        
uas_do_response('NOTIFY', Code, _Req, _Resp, Subs, Dialog, Call) 
                when Code==405; Code==408; Code==481; Code==501 ->
    update({terminated, {code, Code}, undefined}, Subs, Dialog, Call);

uas_do_response('REFER', Code, Req, Resp, Subs, Dialog, Call) ->
    uas_do_response('SUBSCRIBE', Code, Req, Resp, Subs, Dialog, Call);

uas_do_response(_, _Code, _Req, _Resp, _Subs, Dialog, _Call) ->
    Dialog.
    


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec update(term(), #subscription{}, nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

update({subscribe, #sipmsg{class={req, Method}}=Req, Resp}, Subs, Dialog, Call) ->
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
    #call{ pkg_id=PkgId, times=#call_times{t1=T1, tc=TC}} = Call,
    Config = nksip_config:pkg_config(PkgId),
    ReqExpires = case Req#sipmsg.expires of
        RE0 when is_integer(RE0), RE0>=0 ->
            RE0;
        _ when Method=='REFER' ->
            TC;
        _ ->
            Config#config.event_expires
    end,
    RespExpires = case Resp#sipmsg.expires of
        SE0 when is_integer(SE0), SE0>=0 ->
            SE0;
        _ when Method=='REFER' ->
            TC;
        _ ->
            Config#config.event_expires
    end,
    Expires = min(ReqExpires, RespExpires),
    ?CALL_DEBUG("Event ~s expires updated to ~p", [Id, Expires], Call),
    TimerN1 = case NotifyCSeq > element(1, Req#sipmsg.cseq) of
        true when Expires>0 ->
            undefined;     % NOTIFY already received
        _ ->
            start_timer(64*T1, {timeout, Id}, Dialog)
    end,
    TimerExpire1 = case Expires of
        0 ->
            undefined;
        _ ->
            Offset = Config#config.event_expires_offset,
            start_timer(1000*(Expires+Offset), {timeout, Id}, Dialog)
    end,
    TimerMiddle1= case Expires of
        0 ->
            undefined;
        _ ->
            start_timer(500*Expires, {middle, Id}, Dialog)
    end,
    Subs1 = Subs#subscription{
        expires = Expires,
        timer_n = TimerN1,
        timer_expire = TimerExpire1,
        timer_middle = TimerMiddle1
    },
    store(Subs1, Dialog, Call);

update({notify, Req}, Subs, Dialog, Call) ->
    Subs1 = Subs#subscription{last_notify_cseq=element(1, Req#sipmsg.cseq)},
    Status = case nksip_subscription_lib:state(Req) of
        invalid ->
            ?CALL_LOG(notice, "Invalid subscription state", [], Call),
            {terminated, {code, 400}, undefined};
        SE ->
            SE
    end,
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
            ?CALL_DEBUG("Subscription ~s ~p -> ~p", [Id, OldStatus, Status], Call),
            dialog_update(Status, Subs, Dialog, Call)
    end,
    cancel_timer(TimerN),
    cancel_timer(TimerExpire),
    cancel_timer(TimerMiddle),
    ?CALL_DEBUG("Event ~s expires updated to ~p", [Id, Expires], Call),
    Answered1 = case Answered of
        undefined ->
            nklib_util:timestamp();
        _ ->
            Answered
    end,
    #call{ pkg_id=PkgId} = Call,
    Config = nksip_config:pkg_config(PkgId),
    Offset = Config#config.event_expires_offset,
    Subs1 = Subs#subscription{
        status = Status,
        answered = Answered1,
        timer_n = undefined,
        timer_expire = start_timer(1000*(Expires+Offset), {timeout, Id}, Dialog),
        timer_middle = start_timer(500*Expires, {middle, Id}, Dialog)
    },
    store(Subs1, Dialog, Call);

update({terminated, Reason, Retry}, Subs, Dialog, Call) ->
    #subscription{
        timer_n = N,
        timer_expire = Expire, 
        timer_middle = Middle
    } = Subs,
    cancel_timer(N),
    cancel_timer(Expire),
    cancel_timer(Middle),
    ?CALL_DEBUG("Subscription ~s ~p -> {terminated, ~p}",
        [Subs#subscription.id, Subs#subscription.status, Reason], Call),
    dialog_update({terminated, Reason, Retry}, Subs, Dialog, Call),
    store(Subs#subscription{status={terminated, Reason}}, Dialog, Call).


%% @private. Create a provisional event and start timer N.
-spec create_prov_event(nksip:request(), nksip_call:call()) ->
    nksip_call:call().

create_prov_event(#sipmsg{from={_, FromTag}}=Req, Call) ->
    Id = nksip_subscription_lib:make_id(Req),
    ?CALL_DEBUG("Provisional event ~s (~s) UAC created", [Id, FromTag], Call),
    #call{times=#call_times{t1=T1}, events=Events} = Call,
    Timer = erlang:start_timer(64*T1, self(), {remove_prov_event, {Id, FromTag}}),
    ProvEvent = #provisional_event{id={Id, FromTag}, timer_n=Timer},
    Call#call{events=[ProvEvent|Events]}.


%% @private Removes a stored provisional event.
-spec remove_prov_event(nksip:request() | {binary(), binary()}, nksip_call:call()) ->
    nksip_call:call().

remove_prov_event(#sipmsg{from={_, FromTag}}=Req, Call) ->
    Id = nksip_subscription_lib:make_id(Req),
    remove_prov_event({Id, FromTag}, Call);

remove_prov_event({Id, FromTag}, #call{events=Events}=Call) ->
    case lists:keytake({Id, FromTag}, #provisional_event.id, Events) of
        {value, #provisional_event{timer_n=Timer}, Rest} ->
            cancel_timer(Timer),
            ?CALL_DEBUG("Provisional event ~s (~s) destroyed", [Id, FromTag], Call),
            Call#call{events=Rest};
        false ->
            Call
    end.


%% @private
stop(#subscription{id=Id}, Dialog, Call) ->
    case nksip_subscription_lib:find(Id, Dialog) of
        not_found ->
            Call;
        Subs ->
            update({terminated, forced, undefined}, Subs, Dialog, Call)
    end.


%% @private
-spec request_uac_opts(nksip:method(), nksip:optslist(), nksip:dialog()) ->
    {ok, nksip:optslist()} | {error, unknown_subscription}.

request_uac_opts(Method, Opts, Dialog) ->
    case lists:keytake(subscription, 1, Opts) of
        false ->
            {ok, Opts};
        {value, {_, Id}, Opts1} ->
            {_PkgId, SubsId, _DialogId, _CallId} = nksip_subscription_lib:parse_handle(Id),
            case nksip_subscription_lib:find(SubsId, Dialog) of
                #subscription{} = Subs ->
                    {ok, request_uac_opts(Method, Opts1, Dialog, Subs)};
                not_found ->
                    {error, unknown_subscription}
            end
    end.


-spec request_uac_opts(nksip:method(), nksip:optslist(), nksip:dialog(),
                       #subscription{}) ->
    nksip:optslist().

request_uac_opts('SUBSCRIBE', Opts, _Dialog, Subs) ->
    #subscription{event=Event, expires=Expires} = Subs,
    [{event, Event}, {expires, Expires} | Opts];

request_uac_opts('NOTIFY', Opts, Dialog, Subs) ->
    #subscription{event=Event, timer_expire=Timer} = Subs,
    #dialog{ pkg_id=PkgId} = Dialog,
    Config = nksip_config:pkg_config(PkgId),
    Offset = Config#config.event_expires_offset,
    {value, {_, SS}, Opts1} = lists:keytake(subscription_state, 1, Opts),
    SS1 = case SS of
        State when State==active; State==pending ->
            case is_reference(Timer) of
                true ->
                    Expires = round(erlang:read_timer(Timer)/1000) - Offset,
                    {State, Expires};
                false ->
                    {terminated, timeout, undefined}
            end;
        {State, _Expire} when State==active; State==pending ->
            case is_reference(Timer) of
                true ->
                    Expires = round(erlang:read_timer(Timer)/1000) - Offset,
                    {State, Expires};
                false ->
                    {terminated, timeout, undefined}
            end;
        _ ->
            SS
    end,
    [{event, Event}, {subscription_state, SS1} | Opts1].


%% @private Called when a dialog timer is fired
-spec timer({middle|timeout, nksip_subscription_lib:id()}, 
            nksip:dialog(), nksip_call:call()) ->
    nksip_call:call().

timer({Type, Id}, Dialog, Call) ->
    case nksip_subscription_lib:find(Id, Dialog) of
        #subscription{} = Subs when Type==middle ->
            dialog_update(middle_timer, Subs, Dialog, Call),
            Call;
        #subscription{} = Subs when Type==timeout ->
            Dialog1 = update({terminated, timeout, undefined}, Subs, Dialog, Call),
            nksip_call_dialog:store(Dialog1, Call);
        not_found ->
            ?CALL_LOG(notice, "Subscription ~s timer fired for unknown event", [Id], Call),
            Call
    end.



%% ===================================================================
%% Util
%% ===================================================================

%% @private Creates a new event
-spec create(uac|uas, nksip:request(), nksip:dialog(), nksip_call:call()) ->
    #subscription{}.

create(Class, #sipmsg{class={req, Method}}=Req, Dialog, Call) ->
    Event = case Method of
        'REFER' ->
            #sipmsg{cseq={CSeq, _}} = Req,
            {<<"refer">>, [{<<"id">>, nklib_util:to_binary(CSeq)}]};
        _ ->
            Req#sipmsg.event
    end,        
    Id = nksip_subscription_lib:make_id(Req),
    #call{times=#call_times{t1=T1}} = Call,
    Subs = #subscription{
        id = Id,
        event = Event,
        status = init,
        class = Class,
        answered = undefined,
        timer_n = start_timer(64*T1, {timeout, Id}, Dialog)
    },
    dialog_update(init, Subs, Dialog, Call),
    Subs.


%% @private Finds a provisional event
-spec is_prov_event(nksip:request(), nksip_call:call()) ->
    boolean().

is_prov_event(#sipmsg{class={req, 'NOTIFY'}, to={_, ToTag}}=Req, #call{events=Events}) ->
    Id = nksip_subscription_lib:make_id(Req),
    do_is_prov_event({Id, ToTag}, Events);

is_prov_event(_, _) ->
    false.


%% @private.
do_is_prov_event(_, []) -> false;
do_is_prov_event(Id, [#provisional_event{id=Id}|_]) -> true;
do_is_prov_event(Id, [_|Rest]) -> do_is_prov_event(Id, Rest).


%% @private Updates an updated event into dialog
-spec store(#subscription{}, nksip:dialog(), nksip_call:call()) ->
    nksip:dialog().

store(Subs, Dialog, Call) ->
    #subscription{id=Id, status=Status, class=_Class} = Subs,
    #dialog{subscriptions=Subscriptions} = Dialog,
    {Rest, IsFirst} = case Subscriptions of
        [] ->
            {[], true};
        [#subscription{id=Id}|Rest0] ->
            {Rest0, true};
        _ ->
            {[], false}
    end,
    case Status of
        {terminated, _Reason} ->
            ?CALL_DEBUG("~s removing event ~s", [_Class, Id], Call),
            Subscriptions1 = case IsFirst of
                true ->
                    Rest;
                false ->
                    lists:keydelete(Id, #subscription.id, Subscriptions)
            end,
            Dialog#dialog{subscriptions=Subscriptions1};
        _ ->
            ?CALL_DEBUG("~s storing event ~s: ~p", [_Class, Id, Status], Call),
            Subscriptions1 = case IsFirst of
                true ->
                    [Subs|Rest];
                false ->
                    lists:keystore(Id, #subscription.id, Subscriptions, Subs)
            end,
            Dialog#dialog{subscriptions=Subscriptions1}
    end.



%% @private
-spec dialog_update(term(), #subscription{}, nksip:dialog(), nksip_call:call()) ->
    ok.

dialog_update(Status, Subs, Dialog, #call{pkg_id=PkgId}=Call) ->
    Status1 = case Status of
        {terminated, Reason, undefined} ->
            {terminated, Reason};
        _ ->
            Status
    end,
    Args = [{subscription_status, Status1, {user_subs, Subs, Dialog}}, Dialog, Call],
    nksip_util:user_callback(PkgId, sip_dialog_update, Args).


%% @private
cancel_timer(Ref) ->
    nklib_util:cancel_timer(Ref).


%% @private
-spec start_timer(integer(), {atom(), nksip_subscription_lib:id()}, nksip:dialog()) ->
    reference().

start_timer(Time, Tag, #dialog{id=Id}) ->
    erlang:start_timer(Time , self(), {dlg, {event, Tag}, Id}).

