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
-export([uas_pre_request/2, uas_request/3, uas_response/4]).
-export([stop/3, create_provisional/2, remove_provisional/2, timer/3]).

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
        #subscription{class=uas} -> ok;
        _ -> {error, no_transaction}
    end;

uac_pre_request(_Req, _Dialog, _Call) ->
    ok.


%% @private
-spec uac_request(nksip:request(), nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

uac_request(#sipmsg{class={req, Method}}=Req, Dialog, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    case find(Req, Dialog) of
        not_found when Method=='SUBSCRIBE' ->
            Dialog;
        #subscription{id=Id} ->
            ?call_warning("Event ~s UAC request ~p", [Id, Method], Call), 
            Dialog
    end;

uac_request(_Req, Dialog, _Call) ->
    Dialog.


%% @private
-spec uac_response(nksip:request(), nksip:response(), 
                   nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

uac_response(#sipmsg{class={req, Method}}=Req, Resp, Dialog, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    case find(Req, Dialog) of
        #subscription{class=Class, id=Id} = Event
            when (Class==uac andalso Method=='SUBSCRIBE') orelse
                 (Class==uas andalso Method=='NOTIFY') ->
            ?call_warning("Event ~s UAC response ~p ~p", [Id, Method, Code], Call),
            uac_do_response(Method, Code, Req, Resp, Event, Dialog, Call);
        _ when Method=='SUBSCRIBE', Code>=200, Code<300 ->
            Event = #subscription{id=Id} = Event = create(uac, Req, Dialog, Call),
            ?call_warning("Event ~s UAC response ~p ~p", [Id, Method, Code], Call),
            uac_do_response(Method, Code, Req, Resp, Event, Dialog, Call);
        _ ->
            Dialog
    end;

uac_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uac_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:event(), nksip:dialog(), 
                      nksip_call:call()) ->
    nksip_dialog:dialog().

uac_do_response('SUBSCRIBE', Code, Req, Resp, Event, Dialog, Call) 
                when Code>=200, Code<300 ->
    case Event#subscription.status of
        notify_wait -> 
            Expires = min(Req#sipmsg.expires, Resp#sipmsg.expires),
            update({neutral, Expires}, Event, Dialog, Call);
        _ -> 
            update(none, Event, Dialog, Call)
    end;

uac_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Dialog, Call) 
                when Code>=300 ->
    case Event#subscription.answered of
        undefined ->
            update({terminated, Code}, Event, Dialog, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Dialog, Call);
        _ ->
            update(none, Event, Dialog, Call)
    end;

uac_do_response('NOTIFY', Code, Req, _Resp, Event, Dialog, Call) 
                when Code>=200, Code<300 ->
    {Status1, Expires} = notify_status(Req),
    update({Status1, Expires}, Event, Dialog, Call);
        
uac_do_response('NOTIFY', Code, _Req, _Resp, Event, Dialog, Call) when 
                Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                Code==604 ->
    update({terminated, Code}, Event, Dialog, Call);

uac_do_response(_, _Code, _Req, _Resp, _Event, Dialog, _Call) ->
    Dialog.



%% ===================================================================
%% UAS
%% ===================================================================


%% @private
-spec uas_pre_request(nksip:request(), nksip_call:call()) ->
    {ok, nksip_call:call()} | {error, bad_event}.

uas_pre_request(#sipmsg{class={req, 'SUBSCRIBE'}}=Req, Call) ->
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    Supported = nksip_lib:get_value(event, AppOpts, []),
    #sipmsg{event={Type, _}} = Req,
    case lists:member(Type, Supported) of
        true -> {ok, Call};
        false -> {error, bad_event}
    end.


%% @private
-spec uas_request(nksip:request(), nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

uas_request(#sipmsg{class={req, Method}}=Req, Dialog, Call)
            when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    case find(Req, Dialog) of
        #subscription{class=uas, id=Id} = _Event ->
            %% CHECK EVENT
            ?call_warning("Event ~s UAS request ~p", [Id, Method], Call), 
            {ok, Dialog};
        _ ->
            ?call_warning("Received event for unknown subscripction", [], Call),
            {error, no_transaction}
    end;

uas_request(_Req, Dialog, _Call) ->
    Dialog.


%% @private
-spec uas_response(nksip:request(), nksip:response(), 
                   nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

uas_response(#sipmsg{class={req, Method}}=Req, Resp, Dialog, Call)
             when Method=='SUBSCRIBE'; Method=='NOTIFY' ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    case find(Resp, Dialog) of
        #subscription{class=uas, id=Id} = Event ->
            ?call_warning("Event ~s UAS response ~p ~p", [Id, Method, Code], Call),
            uas_do_response(Method, Code, Req, Resp, Event, Dialog, Call);
        _ when Code>=200, Code<300 ->
            #subscription{id=Id} = Event = create(uas, Req, Dialog, Call),
            ?call_warning("Event ~s UAS response ~p, ~p", [Id, Method, Code], Call), 
            uas_do_response(Method, Code, Req, Resp, Event, Dialog, Call);
        _ ->
            ?call_warning("UAS Received ~p ~p response for unknown subscription",
                         [Method, Code], Call),
            Dialog
    end;

uas_response(_Req, _Resp, Dialog, _Call) ->
    Dialog.


%% @private
-spec uas_do_response(nksip:method(), nksip:response_code(), nksip:request(), 
                      nksip:response(), nksip:event(), nksip:dialog(), 
                      nksip_call:call()) ->
    nksip_dialog:dialog().

uas_do_response(_, Code, _Req, _Resp, _Event, Dialog, _Call) when Code<200 ->
    Dialog;

uas_do_response('SUBSCRIBE', Code, Req, Resp, Event, Dialog, Call) 
                when Code>=200, Code<300 ->
    case Event#subscription.status of
        notify_wait -> 
            Expires = case min(Req#sipmsg.expires, Resp#sipmsg.expires) of
                Expires0 when is_integer(Expires0), Expires0>=0 -> Expires0;
                _ -> ?DEFAULT_EVENT_EXPIRES
            end,
            update({neutral, Expires}, Event, Dialog, Call);
        _ -> 
            update(none, Event, Dialog, Call)
    end;
        
uas_do_response('SUBSCRIBE', Code, _Req, _Resp, Event, Dialog, Call) 
                when Code>=300 ->
    case Event#subscription.answered of
        undefined ->
            update({terminated, Code}, Event, Dialog, Call);
        _ when Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
               Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
               Code==604 ->
            update({terminated, Code}, Event, Dialog, Call);
        _ ->
            update(none, Event, Dialog, Call)

    end;

uas_do_response('NOTIFY', Code, _Req, Resp, Event, Dialog, Call) 
                when Code>=200, Code<300 ->
    update(notify_status(Resp), Event, Dialog, Call);
        
uas_do_response('NOTIFY', Code, _Req, _Resp, Event, Dialog, Call) when 
                Code==404; Code==405; Code==410; Code==416; Code==480; Code==481;
                Code==482; Code==483; Code==484; Code==485; Code==489; Code==501; 
                Code==604 ->
    update({terminated, Code}, Event, Dialog, Call);

uas_do_response(_, _Code, _Req, _Resp, _Event, Dialog, _Call) ->
    Dialog.
    


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec update(term(), nksip:event(), nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

update(none, Event, Dialog, Call) ->
    store(Event, Dialog, Call);

update({_, 0}, Event, Dialog, Call) ->
    update({terminated, timeout}, Event, Dialog, Call);

update({terminated, Reason}, Event, Dialog, Call) ->
    #subscription{timer_expire=Expire, timer_middle=Middle} = Event,
    cancel_timer(Expire),
    cancel_timer(Middle),
    cast(event_update, {terminated, Reason}, Event, Dialog, Call),
    store(Event#subscription{status={terminated, Reason}}, Dialog, Call);

update({Status, Expires}, Event, Dialog, Call) 
       when Status==neutral; Status==active; Status==pending ->
    #subscription{
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
            ?call_warning("Event ~s ~p -> ~p", [Id, OldStatus, Status], Call),
            cast(event_update, Status, Event, Dialog, Call)
    end,
    Expires1 = case is_integer(Expires) andalso Expires>0 of
        true -> Expires;
        false -> ?DEFAULT_EVENT_EXPIRES
    end,
    case Status of
        neutral ->
            Event1 = Event#subscription{
                status = neutral,
                timer_expire = start_timer(1000*Expires1, {timeout, Id}, Dialog),
                timer_middle = start_timer(500*Expires1, {middle, Id}, Dialog)
            },
            store(Event1, Dialog, Call);
        _ ->
            Answered1 = case Answered of
                undefined -> nksip_lib:timestamp();
                _ -> Answered
            end,
            Event1 = Event#subscription{
                status = Status,
                answered = Answered1,
                timer_expire = start_timer(1000*Expires1, {middle, Id}, Dialog),
                timer_middle = start_timer(500*Expires1, {timeout, Id}, Dialog)
            },
            store(Event1, Dialog, Call)
    end;

update(Status, Event, Dialog, Call) ->
    update({terminated, Status}, Event, Dialog, Call).


%% @private. Create a provisional event and start timer N.
-spec create_provisional(nksip:request(),  nksip_call:call()) ->
    nksip_call:call().

create_provisional(Req, Call) ->
    #sipmsg{event={EvType, EvOpts}, from_tag=Tag} = Req,
    EvId = nksip_lib:get_binary(<<"id">>, EvOpts),
    ?call_warning("Provisional event ~s_~s_~s UAC created", [EvType, EvId, Tag], Call),
    #call{opts=#call_opts{timer_t1=T1}, events=Events} = Call,
    Id = {EvType, EvId, Tag},
    Timer = erlang:start_timer(64*T1, self(), {provisional_event, Id}),
    Event = #provisional_event{id=Id, timer_n=Timer},
    Call#call{events=[Event|Events]}.


%% @private
-spec remove_provisional(nksip:request() | {binary(), binary(), binary()}, 
                     nksip_call:call()) ->
    nksip_call:call().

remove_provisional(#sipmsg{event={EvType, EvOpts}, from_tag=Tag}, Call) ->
    EvId = nksip_lib:get_binary(<<"id">>, EvOpts),
    remove_provisional({EvType, EvId, Tag}, Call);

remove_provisional({EvType, EvId, Tag}=Id, #call{events=Events}=Call) ->
    case lists:keytake(Id, #provisional_event.id, Events) of
        {value, #provisional_event{timer_n=Timer}, Rest} ->
            cancel_timer(Timer),
            ?call_warning("Provisional event ~s_~s_~s destroyed", 
                          [EvType, EvId, Tag], Call),
            Call#call{events=Rest};
        false ->
            Call
    end.


%% @private
stop(#subscription{id=Id}, Dialog, Call) ->
    case do_find(Id, Dialog) of
        not_found -> Call;
        Event -> update({terminated, forced}, Event, Dialog, Call)
    end.


%% @private Called when a dialog timer is fired
-spec timer(middle|timeout, nksip:dialog(), nksip:call()) ->
    nksip:call().

timer({Type, Id}, Dialog, Call) ->
    case find(Id, Dialog) of
        #subscription{} = Event when Type==middle -> 
            cast(event_update, middle_timer, Event, Dialog, Call),
            Call;
        #subscription{} = Event when Type==timeout -> 
            Dialog1 = update({terminated, timeout}, Event, Dialog, Call),
            nksip_call_dialog:update(none, Dialog1, Call);
        not_found -> 
            ?call_warning("Event ~s timer fired for unknown event", [Id], Call),
            Call
    end.



%% ===================================================================
%% Util
%% ===================================================================

%% @private Creates a new event
-spec create(uac|uas, nksip:request(), nksip:dialog(), nksip_call:call()) ->
    nksip:event().

create(Class, Req, Dialog, Call) ->
    #sipmsg{event=Event, app_id=AppId} = Req,
    Id = nksip_subscription:subscription_id(Req#sipmsg.event, Dialog#dialog.id),
    #call{opts=#call_opts{timer_t1=T1}} = Call,
    #subscription{
        id = Id,
        app_id = AppId,
        event = Event,
        status = notify_wait,
        class = Class,
        answered = undefined,
        timer_expire = start_timer(64*T1, {timeout, Id}, Dialog)
    }.

%% @private Finds a event.
-spec find(nksip:request()|nksip:response()|nksip_subscription:id(), nksip:dialog()) ->
    nksip:event() | not_found.

find(#sipmsg{event=Event}, #dialog{id=DialogId, subscriptions=Subs}) ->
    Id = nksip_subscription:subscription_id(Event, DialogId),
    do_find(Id, Subs);
find(Id, #dialog{subscriptions=Subs}) when is_binary(Id) ->
    do_find(Id, Subs);
find(_, _) ->
    not_found.

%% @private 
do_find(_Id, []) -> not_found;
do_find(Id, [#subscription{id=Id}=Event|_]) -> Event;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).



% %% @private Finds a provisional event
% -spec is_provisional(nksip:request(), nksip_call:call()) ->
%     boolean().

% is_provisional(#sipmsg{event=Event, to_tag=Tag}, #call{events=Events}) ->
%     case Event of
%         undefined -> 
%             false;
%         {Type, Opts} ->
%             Id = nksip_lib:get_value(<<"id">>, Opts, <<>>),
%             do_is_provisional({Type, Id, Tag}, Events)
%     end.

% %% @private.
% do_is_provisional(_Id, []) -> false;
% do_is_provisional(Id, [#provisional_event{id=Id}|_]) -> true;
% do_is_provisional(Id, [_|Rest]) -> do_is_provisional(Id, Rest).


%% @private Updates an updated event into dialog
-spec store(nksip:event(), nksip:dialog(), nksip_call:call()) ->
    nksip_dialog:dialog().

store(Event, Dialog, Call) ->
    #subscription{id=Id, status=Status, class=Class} = Event,
    #dialog{subscriptions=Subscriptions} = Dialog,
    case Subscriptions of
        [] -> Rest = [], IsFirst = true;
        [#subscription{id=Id}|Rest] -> IsFirst = true;
        _ -> Rest = [], IsFirst = false
    end,
    UA = case Class of uac -> "UAC"; uas -> "UAS" end,
    case Status of
        {terminated, _Reason} ->
            ?call_warning("~s removing event ~s", [UA, Id], Call),
            Subscriptions1 = case IsFirst of
                true -> Rest;
                false -> lists:keydelete(Id, #subscription.id, Subscriptions)
            end,
            Dialog#dialog{subscriptions=Subscriptions1};
        _ ->
            ?call_warning("~s storing event ~s: ~p", [UA, Id, Status], Call),
            Subscriptions1 = case IsFirst of
                true -> [Event|Rest];
                false -> lists:keystore(Id, #subscription.id, Subscriptions, Event)
            end,
            Dialog#dialog{subscriptions=Subscriptions1}
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
-spec cast(atom(), term(), nksip:event(), nksip:dialog(), nksip:call()) ->
    ok.

cast(Fun, Arg, Event, _Dialog, Call) ->
    #subscription{id=Id} = Event,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    Args1 = [Event, Arg],
    Args2 = [Id, Arg],
    ?call_notice("called event ~s ~p: ~p", [Id, Fun, Arg], Call),
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
-spec start_timer(integer(), atom(), nksip:dialog()) ->
    reference().

start_timer(Time, Tag, #dialog{id=Id}) ->
    erlang:start_timer(Time , self(), {dlg, {event, Tag}, Id}).

