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

%% @doc User Subscriptions Management Module.
%% This module implements several utility functions related to subscriptions.

-module(nksip_subscription).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([field/3, field/2, fields/3, id/1, id/2, dialog_id/1, subscription_id/2]).
-export([get_subscription/2, get_all/0, get_all/2, notify_status/1, remote_id/2]).
-export_type([id/0, status/0, terminated_reason/0]).

-include("nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% SIP dialog Event ID
-type id() :: 
    binary().

%% All the ways to specify an event
-type spec() :: 
    id() | nksip_request:id() | nksip_response:id().

-type field() :: 
    subscription_id | event | parsed_event | class | answered | expires.

-type terminated_reason() :: 
    {deactivated, undefined|non_neg_integer()} | probation | rejected | timeout |
    {giveup, undefined|non_neg_integer()} | noresource | invariant | forced | 
    undefined | {code, nksip:response_code()} | binary().

%% All dialog event states
-type status() :: 
    init | active | pending | {terminated, terminated_reason()} | binary().



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets specific information from the subscription indicated by `SubscriptionSpec'. 
%% The available fields are:
%%  
%% <table border="1">
%%      <tr><th>Field</th><th>Type</th><th>Description</th></tr>
%%      <tr>
%%          <td>`app_id'</td>
%%          <td>{link nksip:app_id()}</td>
%%          <td>SipApp that created the subscription</td>
%%      </tr>
%%      <tr>
%%          <td>`status'</td>
%%          <td>{@link status()}</td>
%%          <td>Status</td>
%%      </tr>
%%      <tr>
%%          <td>`event'</td>
%%          <td>`binary()'</td>
%%          <td>Full <i>Event</i> header</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_event'</td>
%%          <td>{@link nksip:token()}</td>
%%          <td>Parsed <i>Event</i> header</td>
%%      </tr>
%%      <tr>
%%          <td>`class'</td>
%%          <td>`uac|uas'</td>
%%          <td>Class of the event, as a UAC or a UAS</td>
%%      </tr>
%%      <tr>
%%          <td>`answered'</td>
%%          <td><code>{@link nksip_lib:timestamp()}|undefined</code></td>
%%          <td>Time first NOTIFY was received</td>
%%      </tr>
%%      <tr>
%%          <td>`expires'</td>
%%          <td>integer()</td>
%%          <td>Seconds reamaining to subscription expiration</td>
%%      </tr>
%% </table>

-spec field(nksip:app_id(), spec(), field()) -> 
    term() | error.

field(AppId, SubscriptionSpec, Field) -> 
    case fields(AppId, SubscriptionSpec, [Field]) of
        [{_, Value}] -> Value;
        error -> error
    end.


%% @doc Extracts a specific field from a #subscription structure
-spec field(nksip:subscription(), field()) -> 
    any().

field(#subscription{}=U, Field) ->
    case Field of
        id -> U#subscription.id;
        app_id -> U#subscription.app_id;
        status -> U#subscription.status;
        event -> nksip_unparse:token(U#subscription.event);
        parsed_event -> U#subscription.event;
        class -> U#subscription.class;
        answered -> U#subscription.answered;
        expires -> round(erlang:read_timer(U#subscription.timer_expire)/1000);
        _ -> invalid_field 
    end.


%% @doc Gets a number of fields from the Subscription as described in {@link field/3}.
-spec fields(nksip:app_id(), spec(), [field()]) -> 
    [{atom(), term()}] | error.
    
fields(AppId, SubscriptionSpec, Fields) when is_list(Fields) ->
    case id(AppId, SubscriptionSpec) of
        <<>> ->
            error;
        SubscriptionId ->
            Fun = fun(Dialog) -> 
                case find(SubscriptionId, Dialog) of
                    #subscription{} = Subs ->
                        {ok, [{Field, field(Subs, Field)} || Field <- Fields]};
                    not_found ->
                        error
                end
            end,
            DialogId = dialog_id(SubscriptionId),
            case nksip_call_router:apply_dialog(AppId, DialogId, Fun) of
                {ok, Values} -> Values;
                _ -> error
            end
    end.


%% @doc Get the subscripion's id from a request or response.
-spec id(nksip:app_id(), id()|nksip_request:id()|nksip_response:id()) ->
    id().

id(_, <<"U_", _/binary>>=SubscriptionId) ->
    SubscriptionId;

id(AppId, <<Class, $_, _/binary>>=MsgId) when Class==$R; Class==$S ->
    Fun = fun(#sipmsg{}=SipMsg) -> {ok, id(SipMsg)} end,
    case nksip_call_router:apply_sipmsg(AppId, MsgId, Fun) of
        {ok, SubscriptionId} -> SubscriptionId;
        {error, _} -> <<>>
    end.


%% @private
-spec dialog_id(id()) ->
    nksip_dialog:id().

dialog_id(<<"U_", Rest/binary>>) ->
    [CallId, Dlg | _] = lists:reverse(binary:split(Rest, <<"_">>, [global])),
    <<"D_", Dlg/binary, $_, CallId/binary>>.


%% @doc Gets a full subscription record.
-spec get_subscription(nksip:app_id(), spec()) ->
    nksip:dialog() | error.

get_subscription(AppId, SubscriptionSpec) ->
    case id(AppId, SubscriptionSpec) of
        <<>> ->
            error;
        SubscriptionId ->
            Fun = fun(#dialog{}=Dialog) ->
                case find(SubscriptionId, Dialog) of
                    #subscription{} = Event -> {ok, Event};
                    _ -> error
                end
            end,
            DialogId = dialog_id(SubscriptionId),
            ?P("DLGID: ~p", [DialogId]),
            case nksip_call_router:apply_dialog(AppId, DialogId, Fun) of
                {ok, Event} -> Event;
                _ -> error
            end
    end.


%% @doc Gets all started subscription ids.
-spec get_all() ->
    [{nksip:app_id(), id()}].

get_all() ->
    lists:flatten([ 
        [{AppId, nksip_dialog:field(AppId, DlgId, subscriptions)}]
        || {AppId, DlgId} <- nksip_call_router:get_all_dialogs()
    ]).


%% @doc Finds all existing subscriptions having a `Call-ID'.
-spec get_all(nksip:app_id(), nksip:call_id()) ->
    [id()].

get_all(AppId, CallId) ->
    lists:flatten([
        nksip_dialog:field(AppId, DlgId, subscriptions)
        || {_, DlgId} <- nksip_call_router:get_all_dialogs(AppId, CallId)
    ]).

%% @private
-spec notify_status(nksip:request()) ->
    {active|pending, non_neg_integer()} | 
    {terminated, nksip_subscription:terminated_reason()}.

notify_status(#sipmsg{}=SipMsg) ->
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
                    Retry = case nksip_lib:get_value(<<"retry_after">>, Opts) of
                        undefined ->
                            undefined;
                        Retry0 ->
                            case nksip_lib:to_integer(Retry0) of
                                Retry1 when is_integer(Retry1), Retry1>=0 -> Retry1;
                                _ -> undefined
                            end
                    end, 
                    case nksip_lib:get_value(<<"reason">>, Opts) of
                        undefined -> 
                            {terminated, undefined};
                        Reason0 ->
                            Reason1 = case catch 
                                binary_to_existing_atom(Reason0, latin1) 
                            of
                                {'EXIT', _} -> undefined;
                                probation -> {probation, Retry};
                                giveup -> {giveup, Retry};
                                Reason -> Reason
                            end,
                            {terminated, Reason1}
                    end;
                _ ->
                    {terminated, undefined}
            end;
        _ ->
            {terminated, undefined}
    end.


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec id(nksip:request()|nksip:response()) ->
    id().

id(#sipmsg{cseq_method='REFER', cseq=CSeq, dialog_id=DialogId}) ->
    Event = {<<"refer">>, [{<<"id">>, nksip_lib:to_binary(CSeq)}]},
    subscription_id(Event, DialogId);

id(#sipmsg{event = Event, dialog_id = <<"D_", _/binary>>=DialogId}) ->
    subscription_id(Event, DialogId).


%% @private
-spec subscription_id(nksip:token()|undefined, nksip_dialog:id()) ->
    id().

subscription_id({Type, Opts}, <<"D_", DialogId/binary>>)
                when is_binary(Type), is_list(Opts) ->
    Id = nksip_lib:get_binary(<<"id">>, Opts, <<>>),
    <<$U, $_, Type/binary, $_, Id/binary, $_, DialogId/binary>>;

subscription_id(_, _) ->
    <<>>.


%% @private Finds a event.
-spec find(id(), nksip:dialog()) ->
    nksip:subscription() | not_found.

find(<<"U_", _/binary>>=Id, #dialog{subscriptions=Subscriptions}) ->
    do_find(Id, Subscriptions).

%% @private 
do_find(_Id, []) -> not_found;
do_find(Id, [#subscription{id=Id}=Event|_]) -> Event;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).


%% @private Hack to find the UAS subscription from the UAC and the opposite way
remote_id(AppId, SubsId) ->
    [_, _ | Rest] = lists:reverse(binary:split(SubsId, <<"_">>, [global])),
    <<"D_", RemoteDlg/binary>> = nksip_dialog:field(AppId, dialog_id(SubsId), remote_id),
    Base = nksip_lib:bjoin(lists:reverse(Rest), <<"_">>),
    <<Base/binary, $_, RemoteDlg/binary>>.


