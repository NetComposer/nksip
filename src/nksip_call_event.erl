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
-export([stop/2, timer/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% UAC
%% ===================================================================


%% @private
uac_pre_request(#sipmsg{class={req, Method}}=Req, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    EventId = id(Req),
    case find(EventId, Call) of
        not_found when Method=='SUBSCRIBE' -> ok;
        not_found -> {error, unknown_subscription};
        #event{} -> ok
    end;

uac_pre_request(_Req, _Call) ->
    ok.


%% @private
uac_request(#sipmsg{class={req, Method}}=Req, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    EventId = id(Req),
    ?call_debug("Event ~p UAC request ~p", [EventId, Method], Call), 
    case find(EventId, Call) of
        not_found when Method=='SUBSCRIBE' ->
            Event1 = create(uac, Req, Call),
            uac_do_request(Req, Event1, Call);
        #event{} = Event1 ->
            uac_do_request(Req, Event1, Call)
    end;

uac_request(_Req, Call) ->
    Call.


%% @private
uac_do_request(_Req, Event, Call) ->
    update(none, Event, Call).


%% @private
uac_response(#sipmsg{class={req, Method}}=Req, Resp, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    EventId = id(Req),
    case find(EventId, Call) of
        #event{class=uac} = Event1 ->
            ?call_debug("Event ~p UAC response ~p ~p", [EventId, Method, Code], Call),
            uac_do_response(Method, Code, Req, Resp, Event1, Call);
        _ ->
            ?call_notice("Received ~p ~p response for unknown subscription",
                         [Method, Code], Call),
            Call
    end;

uac_response(_Req, _Resp, Call) ->
    Call.


%% @private
uac_do_response(_, Code, _Req, _Resp, _Event, Call) when Code<200 ->
    Call;

uac_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Call) when Code>=200, Code<300 ->
    update(neutral, Event, Call);
        
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

uac_do_response('NOTIFY', Code, _Req, Resp, Event, Call) when Code>=200, Code<300 ->
    {Status1, _Expires} = nksip_parse:notify_status(Resp),
    update(Status1, Event, Call);
        
uac_do_response('NOTIFY', Code, _Req, _Resp, Event, Call) when Code>=300 ->
    case Event#event.answered of
        undefined ->
            update({terminated, Code}, Event, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Call);
        _ ->
            update(none, Event, Call)
    end.


%% ===================================================================
%% UAS
%% ===================================================================


%% @private
uas_request(#sipmsg{class={req, Method}}=Req, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    EventId = id(Req),
    ?call_debug("Event ~p UAS request ~p", [EventId, Method], Call), 
    case find(EventId, Call) of
        #event{} = Event1 ->
            {ok, uas_do_request(Req, Event1, Call)};
        not_found when Method=='SUBSCRIBE' ->
            #call{opts=#call_opts{app_opts=AppOpts}} = Call,
            Sup = nksip_lib:get_value(supported_events, AppOpts, []),
            case lists:member(element(1, EventId), Sup) of
                true ->
                    Event1 = create(uas, Req, Call),
                    {ok, uas_do_request(Req, Event1, Call)};
                false ->
                    {error, bad_event}
            end;
        not_found ->
            {error, no_transaction}
    end;

uas_request(_Req, Call) ->
    Call.

%% @private

uas_do_request(_Req, Event, Call) ->
    update(none, Event, Call).


%% @private
uas_response(#sipmsg{class={req, Method}}=Req, Resp, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    EventId = id(Req),
    case find(EventId, Call) of
        #event{class=uas} = Event ->
            ?call_debug("Event ~p UAS response ~p ~p", [EventId, Method, Code], Call),
            uas_do_response(Method, Code, Req, Resp, Event, Call);
        _ ->
            ?call_notice("Received ~p ~p response for unknown subscription",
                         [Method, Code], Call),
            Call
    end;

uas_response(_Req, _Resp, Call) ->
    Call.


%% @private
uas_do_response(_, Code, _Req, _Resp, _Event, Call) when Code<200 ->
    Call;

uas_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Call) when Code>=200, Code<300 ->
    update(neutral, Event, Call);
        
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
    {Status1, _Expires} = nksip_parse:notify_status(Resp),
    update(Status1, Event, Call);
        
uas_do_response('NOTIFY', Code, _Req, _Resp, Event, Call) when Code>=300 ->
    case Event#event.answered of
        undefined ->
            update({terminated, Code}, Event, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Call);
        _ ->
            update(none, Event, Call)
    end.



%% ===================================================================
%% Private
%% ===================================================================


%% @private
id(#sipmsg{event=Event}) ->
    case Event of
        undefined -> {<<"undefined">>, <<>>};
        {Type, Opts} -> {Type, nksip_lib:get_value(<<"id">>, Opts, <<>>)}
    end.


%% @private Creates a new event
-spec create(uac|uas, nksip:request(), nksip_call:call()) ->
    nksip:event().

create(Class, Req, Call) ->
    #sipmsg{expires=Expires, from_tag=Tag} = Req,
    EventId = id(Req),
    Expires1 = case Expires of 
        undefined -> ?DEFAULT_EVENT_EXPIRES;
        _ -> Expires
    end,
    #call{opts=#call_opts{timer_t1=T1}} = Call,
    ?call_notice("Event ~p (~p) created", [EventId, Class], Call),
    Timer = erlang:start_timer(64*T1 , self(), {event, timeout, EventId}),
    #event{
        id = EventId,
        dialog_id = nksip_dialog:class_id(Class, Req),
        tag = Tag,
        status = notify_wait,
        class = Class,
        answered = undefined,
        expires = Expires1,
        timer = Timer
    }.


%% @private
-spec update(term(), nksip:event(), nksip_call:call()) ->
    nksip_call:call().

update(none, Event, Call) ->
    store(Event, Call);

update({terminated, Reason}, Event, Call) ->
    #event{id=EventId, timer=OldTimer} = Event,
    cancel_timer(OldTimer),
    ?call_debug("Event ~p terminated", [EventId], Call),
    cast(event_update, {terminated, Reason}, Event, Call),
    store(Event, Call);

update(Status, Event, Call) ->
    #event{
        id = EventId, 
        status = OldStatus,
        answered = Answered,
        expires = Expires,
        timer = OldTimer
    } = Event,
    cancel_timer(OldTimer),
    case Status==OldStatus of
        true -> 
            ok;
        false -> 
            ?call_debug("Event ~p ~p -> ~p", [EventId, OldStatus, Status], Call),
            cast(event_update, Status, Event, Call)
    end,
    Event1 = case Status of
        neutral ->
            #call{opts=#call_opts{timer_t1=T1}} = Call,
            Event#event{
                status = neutral,
                timer = start_timer(64*T1, {event_timeout, EventId}, Event)
            };
        _ when Status==active; Status==pending ->
            Answered1 = case Answered of
                undefined -> nksip_lib:timestamp();
                _ -> Answered
            end,
            Event#event{
                status = Status,
                answered = Answered1,
                timer = start_timer(1000*Expires, {event_timeout, EventId}, Event)
            };
        {terminated, _Reason} ->
            Event#event{status=Status};
        _ ->
            Event#event{status={terminated, Status}}
    end,
    store(Event1, Call).


%% @private
stop(EventId, Call) ->
    case find(EventId, Call) of
        not_found -> Call;
        Event -> update({terminated, forced}, Event, Call)
    end.


%% @private Called when a dialog timer is fired
-spec timer(timeout, nksip:event(), nksip:call()) ->
    nksip:call().

timer(timeout, #event{}=Event, Call) ->
    Event1 = update({terminated, timeout}, Event, Call),
    store(Event1, Call).





%% ===================================================================
%% Util
%% ===================================================================

%% @private Finds a event
-spec find(nksip_dialog:event_id(), nksip_call:call()) ->
    nksip:event() | not_found.

find(EventId, #call{events=Events}) ->
    do_find(EventId, Events).


%% @private 
do_find(_EventId, []) -> not_found;
do_find(EventId, [#event{id=EventId}=Event|_]) -> Event;
do_find(EventId, [_|Rest]) -> do_find(EventId, Rest).


%% @private Updates an updated event into dialog
-spec store(nksip:event(), nksip_call:call()) ->
    nksip_call:call().

store(Event, Call) ->
    #event{id=EventId, status=Status, dialog_id=DialogId} = Event,
    #call{events=Events} = Call,
    case Events of
        [] -> Rest = [], IsFirst = true;
        [#event{id=EventId}|Rest] -> IsFirst = true;
        _ -> Rest = [], IsFirst = false
    end,
    case Status of
        {terminated, _Reason} ->
            Events1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(EventId, #event.id, Events)
            end,
            Call1 = Call#call{events=Events1},
            case nksip_call_dialog:find(DialogId, Call) of
                not_found ->
                    Call1;
                #dialog{events=Events}=Dialog ->
                    Dialog1 = Dialog#dialog{events=Events--[EventId]},
                    nksip_call_dialog:update(none, Dialog1, Call1)
            end;
        _ ->
            Events1 = case IsFirst of
                true -> [Event|Rest];
                false -> lists:keystore(EventId, #event.id, Event, Events)
            end,
            Call#call{events=Events1}
    end.


%% @private
-spec cast(atom(), term(), nksip:event(), nksip:call()) ->
    ok.

cast(Fun, Arg, Event, Call) ->
    #event{id=EventId} = Event,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    Args1 = [Event, Arg],
    Args2 = [EventId, Arg],
    ?call_debug("called event ~s ~p: ~p", [EventId, Fun, Arg], Call),
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

start_timer(Time, Tag, #event{id=Id}) ->
    erlang:start_timer(Time , self(), {event, Tag, Id}).

