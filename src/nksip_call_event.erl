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

-export([uac_pre_request/2, uac_request/2, uac_response/3]).
-export([uas_request/2, uas_response/3]).
-export([stop/3, timer/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% UAC
%% ===================================================================


%% @private
-spec uac_pre_request(nksip:request(), nksip_call:call()) ->
    ok | {error, no_transaction}.

uac_pre_request(#sipmsg{class={req, 'NOTIFY'}}=Req, Call) ->
    case find(id(Req), Call) of
        #event{class=uas} -> ok;
        _ -> {error, no_transaction}
    end;

uac_pre_request(_Req, _Call) ->
    ok.


%% @private
-spec uac_request(nksip:request(), nksip_call:call()) ->
    nksip_call:call().

uac_request(#sipmsg{class={req, Method}}=Req, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    case find(Req, Call) of
        not_found when Method=='SUBSCRIBE' ->
            % Create and start timer N. Will not have dialog id yet.
            Event = create(uac, Req, Call),
            update(none, Event, Call);
        #event{id={EventType, EventId}} ->
            ?call_debug("Event ~s (id ~s) UAC request ~p", 
                        [EventType, EventId, Method], Call), 
            Call
    end;

uac_request(_Req, Call) ->
    Call.


%% @private
-spec uac_response(nksip:request(), nksip:response(), nksip_call:call()) ->
    nksip_call:call().

uac_response(#sipmsg{class={req, Method}}=Req, Resp, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}, dialog_id=DialogId} = Resp,
    case find(Req, Call) of
        #event{class=Class, id={EventType, EventId}} = Event
            when (Class==uac andalso Method=='SUBSCRIBE') orelse
                 (Class==uas andalso Method=='NOTIFY') ->
            ?call_debug("Event ~s (id ~s) UAC response ~p ~p", 
                        [EventType, EventId, Method, Code], Call),
            Event1 = case Event#event.dialog_id of
                DialogId -> Event;
                _ -> Event#event{dialog_id=DialogId}
            end,
            uac_do_response(Method, Code, Req, Resp, Event1, Call);
        _ ->
            ?call_warning("Received ~p ~p response for unknown subscription",
                         [Method, Code], Call),
            Call
    end;

uac_response(_Req, _Resp, Call) ->
    Call.


%% @private
-spec uac_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:event(), nksip_call:call()) ->
    nksip_call:call().

uac_do_response('SUBSCRIBE', Code, Req, Resp, Event, Call) when Code>=200, Code<300 ->
    case Code==204 of
        true -> cancel_timer(Event#event.timer_n);
        false -> ok
    end,
    case Event#event.status of
        notify_wait -> 
            Expires = min(Req#sipmsg.expires, Resp#sipmsg.expires),
            update({neutral, Expires}, Event, Call);
        _ -> 
            update(none, Event, Call)
    end;

uac_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Call) when Code>=300 ->
    case Event#event.answered of
        undefined ->
            update({terminated, Code}, Event, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Call);
        _ ->
            update(none, Event, Call)
    end;

uac_do_response('NOTIFY', Code, Req, _Resp, Event, Call) when Code>=200, Code<300 ->
    {Status1, Expires} = notify_status(Req),
    update({Status1, Expires}, Event, Call);
        
uac_do_response('NOTIFY', Code, _Req, _Resp, Event, Call) when 
                Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                Code==604 ->
    update({terminated, Code}, Event, Call);

uac_do_response(_, _Code, _Req, _Resp, _Event, Call) ->
    Call.



%% ===================================================================
%% UAS
%% ===================================================================


%% @private
-spec uas_request(nksip:request(), nksip_call:call()) ->
    nksip_call:call().

uas_request(#sipmsg{class={req, Method}}=Req, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    case find(Req, Call) of
        #event{id={EventType, EventId}} = Event ->
            ?call_debug("Event ~s (id ~s) UAS request ~p", 
                        [EventType, EventId, Method], Call), 
            {ok, update(none, Event, Call)};
        {not_found, Id} when Method=='SUBSCRIBE' ->
            #call{opts=#call_opts{app_opts=AppOpts}} = Call,
            Supported = nksip_lib:get_value(event, AppOpts, []),
            {EventType, _} = Id,
            case lists:member(EventType, Supported) of
                true ->
                    Event = create(uas, Req, Call),
                    {ok, update(none, Event, Call)};
                false ->
                    {error, bad_event}
            end;
        not_found when Method=='NOTIFY' ->
            {error, no_transaction}
    end;

uas_request(_Req, Call) ->
    Call.


%% @private
-spec uas_response(nksip:request(), nksip:response(), nksip_call:call()) ->
    nksip_call:call().

uas_response(#sipmsg{class={req, Method}}=Req, Resp, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    case find(Resp, Call) of
        #event{class=uas, id={EventType, EventId}} = Event ->
            ?call_debug("Event ~s (id ~s) UAS response ~p ~p", 
                        [EventType, EventId, Method, Code], Call),
            uas_do_response(Method, Code, Req, Resp, Event, Call);
        _ ->
            ?call_warning("Received ~p ~p response for unknown subscription",
                         [Method, Code], Call),
            Call
    end;

uas_response(_Req, _Resp, Call) ->
    Call.


%% @private
-spec uas_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:event(), nksip_call:call()) ->
    nksip_call:call().

uas_do_response(_, Code, _Req, _Resp, _Event, Call) when Code<200 ->
    Call;

uas_do_response('SUBSCRIBE', Code, Req, Resp, Event, Call) when Code>=200, Code<300 ->
    case Code==204 of
        true -> cancel_timer(Event#event.timer_n);
        false -> ok
    end,
    case Event#event.status of
        notify_wait -> 
            Expires = min(Req#sipmsg.expires, Resp#sipmsg.expires),
            update({neutral, Expires}, Event, Call);
        _ -> 
            update(none, Event, Call)
    end;
        
uas_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Call) when Code>=300 ->
    case Event#event.answered of
        undefined ->
            update({terminated, Code}, Event, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Call);
        _ ->
            update(none, Event, Call)

    end;

uas_do_response('NOTIFY', Code, _Req, Resp, Event, Call) when Code>=200, Code<300 ->
    update(notify_status(Resp), Event, Call);
        
uas_do_response('NOTIFY', Code, _Req, _Resp, Event, Call) when 
                Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                Code==604 ->
    update({terminated, Code}, Event, Call);

uas_do_response(_, _Code, _Req, _Resp, _Event, Call) ->
    Call.
    


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec id(nksip:request()|nksip:response()) ->
    nksip_dialog:event_id().

id(#sipmsg{event=Event}) ->
    case Event of
        undefined -> {<<"undefined">>, <<>>};
        {Type, Opts} -> {Type, nksip_lib:get_value(<<"id">>, Opts, <<>>)}
    end.


%% @private Creates a new event
-spec create(uac|uas, nksip:request(), nksip_call:call()) ->
    nksip:event().

create(Class, Req, Call) ->
    #sipmsg{from_tag=Tag} = Req,
    {EventType, EventId} = Id = id(Req),
    UA = case Class of uac -> "UAC"; uas -> "UAS" end,
    ?call_debug("Event ~s (id ~s) ~s created", [EventType, EventId, UA], Call),
    #call{opts=#call_opts{timer_t1=T1}} = Call,
    Timer = start_timer(64*T1, timer_n, Id),
    #event{
        id = {EventType, EventId},
        dialog_id = nksip_dialog:class_id(Class, Req),
        tag = Tag,
        status = notify_wait,
        class = Class,
        answered = undefined,
        timer_n = Timer
    }.


%% @private
-spec update(term(), nksip:event(), nksip_call:call()) ->
    nksip_call:call().

update(none, Event, Call) ->
    store(Event, Call);

update({_, 0}, Event, Call) ->
    update({terminated, timeout}, Event, Call);

update({terminated, Reason}, Event, Call) ->
    #event{timer_n=N, timer_expire=Expire, timer_middle=Middle} = Event,
    cancel_timer(N),
    cancel_timer(Expire),
    cancel_timer(Middle),
    cast(event_update, {terminated, Reason}, Event, Call),
    store(Event#event{status={terminated, Reason}}, Call);

update(Status, Event, Call) ->
    #event{
        id = Id, 
        status = OldStatus,
        answered = Answered,
        timer_expire = Timer1,
        timer_middle = Timer2
    } = Event,
    cancel_timer(Timer1),
    cancel_timer(Timer2),
    case Status==OldStatus of
        true -> 
            ok;
        false -> 
            ?call_debug("Event ~p ~p -> ~p", [Id, OldStatus, Status], Call),
            cast(event_update, Status, Event, Call)
    end,
    case Status of
        {neutral, Expires} ->
            Expires1 = case is_integer(Expires) andalso Expires>0 of
                true -> Expires;
                false -> ?DEFAULT_EVENT_EXPIRES
            end,
            #call{opts=#call_opts{timer_t1=T1}} = Call,
            Event1 = Event#event{
                status = neutral,
                timer_n = start_timer(64*T1, timer_n, Id),
                timer_expire = start_timer(1000*Expires1, timeout, Id),
                timer_middle = start_timer(500*Expires1, timeout, Id)
            },
            store(Event1, Call);
        {Type, Expires} when Type==active; Type==pending ->
            Expires1 = case is_integer(Expires) andalso Expires>0 of
                true -> Expires;
                false -> ?DEFAULT_EVENT_EXPIRES
            end,
            Answered1 = case Answered of
                undefined -> nksip_lib:timestamp();
                _ -> Answered
            end,
            Event1 = Event#event{
                status = Status,
                answered = Answered1,
                timer_expire = start_timer(1000*Expires1, timeout, Id),
                timer_middle = start_timer(500*Expires1, timeout, Id)
            },
            store(Event1, Call);
        _ ->
            update({terminated, unknown}, Event, Call)
    end.


%% @private
stop(EventId, DlgId, Call) ->
    case do_find_dialog(EventId, DlgId, Call) of
        not_found -> Call;
        Event -> update({terminated, forced}, Event, Call)
    end.


%% @private Called when a dialog timer is fired
-spec timer(timeout, nksip:event(), nksip:call()) ->
    nksip:call().

timer(timer_n, #event{id=EvId, status=Status}=Event, Call) ->
    {EventType, EventId} = EvId,
    ?call_notice("Event ~s (id ~s) Timer N fired", [EventType, EventId], Call),
    case Status of
        notify_wait -> update({terminated, timeout}, Event, Call);
        _ -> update(none, Event#event{timer_n=undefined}, Call)
    end;

timer(middle, Event, Call) ->
    cast(event_update, middle_timer, Event, Call),
    Call;

timer(timeout, #event{id={EventType, EventId}}=Event, Call) ->
    ?call_notice("Event ~s (id ~s) TIMEOUT fired", [EventType, EventId], Call),
    update({terminated, timeout}, Event, Call).





%% ===================================================================
%% Util
%% ===================================================================

%% @private Finds a event. First tries same dialog id, if not found same From tag
-spec find(nksip_dialog:event_id(), nksip_call:call()) ->
    nksip:event() | {not_found, nksip_dialog:event_id()}.

find(#sipmsg{event=Event, to_tag=Tag, dialog_id=DlgId}, #call{events=Events}) ->
    EvId = id(Event),
    case do_find_dialog(EvId, DlgId, Events) of
        not_found -> 
            case do_find_nodialog(EvId, Tag, Events) of
                not_found -> {not_found, EvId};
                #event{} = Event -> Event
            end;
        #event{} = Event -> 
            Event
    end.


%% @private 
do_find_dialog(_EvId, _DlgId, []) -> 
    not_found;
do_find_dialog(EvId, DlgId, [#event{id=EvId, dialog_id=DlgId}=Event|_]) -> 
    Event;
do_find_dialog(EvId, DlgId, [_|Rest]) -> 
    do_find_dialog(EvId, DlgId, Rest).


%% @private. Timer N must be active.
do_find_nodialog(_EvId, _Tag, []) -> 
    not_found;
do_find_nodialog(EvId, Tag, [#event{id=EvId, tag=Tag, timer_n=TimerN}=Event|_])
    when TimerN/=undefined ->Event;
do_find_nodialog(EvId, Tag, [_|Rest]) -> 
    do_find_nodialog(EvId, Tag, Rest).



%% @private Updates an updated event into dialog
-spec store(nksip:event(), nksip_call:call()) ->
    nksip_call:call().

store(Event, Call) ->
    #event{id=Id, status=Status, class=Class, dialog_id=DialogId} = Event,
    #call{events=Events} = Call,
    {EventType, EventId} = Id,
    case Events of
        [] -> Rest = [], IsFirst = true;
        [#event{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest = [], IsFirst = false
    end,
    UA = case Class of uac -> "UAC"; uas -> "UAS" end,
    case Status of
        {terminated, _Reason} ->
            ?call_warning("~s removing event ~s (id ~s)", 
                        [UA, EventType, EventId], Call),
            Events1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #event.id, Events)
            end,
            Call1 = Call#call{events=Events1},
            case nksip_call_dialog:find(DialogId, Call) of
                not_found ->
                    Call1;
                #dialog{events=DlgEvents}=Dialog ->
                    Dialog1 = Dialog#dialog{events=DlgEvents--[Id]},
                    nksip_call_dialog:update(none, Dialog1, Call1)
            end;
        _ ->
            ?call_warning("~s storing event ~s (id ~s): ~p", 
                        [UA, EventType, EventId, Status], Call),
            Events1 = case IsFirst of
                true -> [Event|Rest];
                false -> lists:keystore(Id, #event.id, Events, Event)
            end,
            Call1 = Call#call{events=Events1},
            case nksip_call_dialog:find(DialogId, Call) of
                not_found ->
                    Call1;
                #dialog{events=DlgEvents}=Dialog ->
                    case lists:member(Id, DlgEvents) of
                        true -> 
                            Call1;
                        false -> 
                            Dialog1 = Dialog#dialog{events=[Id|DlgEvents]},
                            nksip_call_dialog:update(none, Dialog1, Call1)
                    end
            end
    end.


%% @private
-spec notify_status(nksip:sipmsg()) ->
    {active|pending, non_neg_integer()} | {terminated, term()}.

notify_status(SipMsg) ->
    case nksip_sipmsg:header(SipMsg, <<"Subscription-State">>, tokens) of
        [{Status, Opts}] ->
            case nksip_lib:get_list(<<"expires">>, Opts) of
                "" -> 
                    Expires = undefined;
                Expires0 ->
                    case catch list_to_integer(Expires0) of
                        Expires when is_integer(Expires) -> Expires;
                        _ -> Expires = undefined
                    end
            end,
            case Status of
                <<"active">> -> 
                    {active, Expires};
                <<"pending">> -> 
                    {pending, Expires};
                <<"terminated">> ->
                    case nksip_lib:get_value(<<"reason">>, Opts) of
                        undefined -> 
                            {{terminated, undefined}, undefined};
                        Reason0 ->
                            case catch 
                                binary_to_existing_atom(Reason0, latin1) 
                            of
                                {'EXIT', _} -> {{terminated, undefined}, undefined};
                                Reason -> {{terminated, Reason}, undefined}
                            end
                    end;
                _ ->
                    {Status, Expires}
            end;
        _ ->
            {terminated, invalid}
    end.



%% @private
-spec cast(atom(), term(), nksip:event(), nksip:call()) ->
    ok.

cast(Fun, Arg, Event, Call) ->
    #event{id={EventType, EventId}=Id} = Event,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    Args1 = [Event, Arg],
    Args2 = [Id, Arg],
    ?call_notice("called event ~s (id ~s) ~p: ~p", [EventType, EventId, Fun, Arg], Call),
    nksip_sipapp_srv:sipapp_cast(AppId, Module, Fun, Args1, Args2),
    ok.


%% @private
cancel_timer(Ref) when is_reference(Ref) -> 
    case erlang:cancel_timer(Ref) of
        false -> receive {timeout, Ref, _} -> ok after 0 -> ok end;
        _ -> ok
    end;

cancel_timer(_) ->
    ok.


%% @private
-spec start_timer(integer(), atom(), nksip:event()) ->
    reference().

start_timer(Time, Tag, Id) ->
    erlang:start_timer(Time , self(), {event, Tag, Id}).

