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

-export([get_id/1, app_id/1, app_name/1, call_id/1, meta/2]).
-export([get_all/0, get_all/2, get_subscription/2]).
-export([parse_id/1, get_subscription/1, make_id/1, find/2, subscription_state/1, remote_id/2]).
-export_type([id/0, status/0, subscription_state/0, terminated_reason/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% SIP dialog Event ID (can be <<"event">> or <<"event;id=my_id">>)
-type id() :: 
    binary().

-type field() :: 
    id | internal_id | status | event | class | answered | expires |
    nksip_dialog:field().

-type subscription_state() ::
    {active, undefined|non_neg_integer()} | {pending, undefined|non_neg_integer()}
    | {terminated, terminated_reason(), undefined|non_neg_integer()}.

-type terminated_reason() :: 
    deactivated | {probation, undefined|non_neg_integer()} | rejected |
    timeout | {giveup, undefined|non_neg_integer()} | noresource | invariant | 
    forced | {code, nksip:sip_code()}.

%% All dialog event states
-type status() :: 
    init | active | pending | {terminated, terminated_reason()} | binary().



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Get the subscripion a request, response or id
-spec get_id(nksip:subscription()|nksip:request()|nksip:response()|nksip:id()) ->
    nksip:id().

get_id({user_subs, #subscription{id=SubsId}, #dialog{app_id=AppId, id=DialogId, call_id=CallId}}) ->
    App = atom_to_binary(AppId, latin1), 
    <<$U, $_, SubsId/binary, $_, DialogId/binary, $_, App/binary, $_, CallId/binary>>;
get_id(#sipmsg{app_id=AppId, dialog_id=DialogId, call_id=CallId}=SipMsg) ->
    SubsId = make_id(SipMsg),
    App = atom_to_binary(AppId, latin1), 
    <<$U, $_, SubsId/binary, $_, DialogId/binary, $_, App/binary, $_, CallId/binary>>;
get_id(<<"U_", _/binary>>=Id) ->
    Id;
get_id(<<Class, $_, _/binary>>=Id) when Class==$R; Class==$S ->
    Fun = fun(#sipmsg{}=SipMsg) -> {ok, get_id(SipMsg)} end,
    case nksip_router:apply_sipmsg(Id, Fun) of
        {ok, Id1} -> Id1;
        {error, _} -> <<>>
    end.


%% @doc Gets thel App of a dialog
-spec app_id(nksip:subscription()|nksip:id()) ->
    nksip:app_id().

app_id({user_subs, _, #dialog{app_id=AppId}}) ->
    AppId;
app_id(Id) ->
    {AppId, _SubsId, _DialogId, _CallId} = parse_id(Id),
    AppId. 


%% @doc Gets app's name
-spec app_name(nksip:subscription()|nksip:id()) -> 
    term().

app_name(Req) -> 
    (app_id(Req)):name().


%% @doc Gets thel Call-ID of the subscription
-spec call_id(nksip:subscription()|nksip:id()) ->
    nksip:call_id().

call_id({user_subs, _, #dialog{call_id=CallId}}) ->
    CallId;
call_id(Id) ->
    {_AppId, _SubsId, _DialogId, CallId} = parse_id(Id),
    CallId. 


%% @doc
-spec meta(field()|[field()], nksip:subscription()|nksip:id()) -> 
    term() | [{field(), term()}] | error.

meta(Fields, {user_subs, _, _}=Subs) when is_list(Fields), not is_integer(hd(Fields)) ->
    [{Field, meta(Field, Subs)} || Field <- Fields];

meta(Fields, Id) when is_list(Fields), not is_integer(hd(Fields)), is_binary(Id) ->
    {_AppId, SubsId, _DialogId, _CallId} = parse_id(Id),
    Fun = fun(Dialog) -> 
        case find(SubsId, Dialog) of
            #subscription{} = U -> {ok, meta(Fields, {user_subs, U, Dialog})};
            not_found -> error
        end
    end,
    DialogId = nksip_dialog:get_id(Id),
    case nksip_router:apply_dialog(DialogId, Fun) of
        {ok, Values} -> Values;
        _ -> error
    end;

meta(Field, {user_subs, U, D}) ->
    case Field of
        id ->
            get_id({user_subs, U, D});
        internal_id -> 
            U#subscription.id;
        status -> 
            U#subscription.status;
        event -> 
            U#subscription.event;
        raw_event -> 
            nksip_unparse:token(U#subscription.event);
        class -> 
            U#subscription.class;
        answered -> 
            U#subscription.answered;
        expires when is_reference(U#subscription.timer_expire) ->
            round(erlang:read_timer(U#subscription.timer_expire)/1000);
        expires ->
            undefined;
       _ ->
            nksip_dialog:meta(Field, D)
    end;

meta(Field, <<"U_", _/binary>>=Id) -> 
    case meta([Field], Id) of
        [{_, Value}] -> Value;
        error -> error
    end.


%% @doc Gets the subscription object corresponding to a request or subscription and a call
-spec get_subscription(nksip:request()|nksip:response()|nksip:subscription(), nksip:call()) ->
    nksip:subscription()|error.

get_subscription({uses_subs, _Subs, _Dialog}=UserSubs, _) ->
    UserSubs;

get_subscription(#sipmsg{}=SipMsg, #call{}=Call) ->
    case nksip_dialog:get_dialog(SipMsg, Call) of
        {ok, Dialog} ->
            SubsId = make_id(SipMsg),
            case find(SubsId, Dialog) of
                #subscription{}=Subs ->
                    {user_subs, Subs, Dialog};
                not_found ->
                    error
            end;
        error ->
            error
    end.


%% @doc Gets all started subscription ids.
-spec get_all() ->
    [nksip:id()].

get_all() ->
    lists:flatten([
        nksip_dialog:meta(subscriptions, Id) 
        || Id <- nksip_router:get_all_dialogs()
    ]).


%% @doc Finds all existing subscriptions having a `Call-ID'.
-spec get_all(nksip:app_id(), nksip:call_id()) ->
    [nksip:id()].

get_all(AppId, CallId) ->
    lists:flatten([
        nksip_dialog:meta(subscriptions, Id)
        || Id <- nksip_router:get_all_dialogs(AppId, CallId)
    ]).


%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec get_subscription(nksip:id()) ->
    nksip:dialog() | error.

get_subscription(<<"U_", _/binary>>=Id) ->
    {_AppId, SubsId, _DialogId, _CallId} = parse_id(Id),
    DialogId = nksip_dialog:get_id(Id),
    Fun = fun(#dialog{}=Dialog) ->
        case find(SubsId, Dialog) of
            #subscription{} = Event -> {ok, Event};
            _ -> error
        end
    end,
    case nksip_router:apply_dialog(DialogId, Fun) of
        {ok, Event} -> Event;
        _ -> error
    end.



%% @private
-spec parse_id(nksip:id()) ->
    {nksip:app_id(), id(), nksip_dialog:id(), nksip:call_id()}.

parse_id(<<"U_", SubsId:6/binary, $_, DialogId:6/binary, $_, App:7/binary, 
         $_, CallId/binary>>) ->
    AppId = binary_to_existing_atom(App, latin1),
    {AppId, SubsId, DialogId, CallId}. 


%% @private
-spec make_id(nksip:request()) ->
    id().

make_id(#sipmsg{class={req, 'REFER'}, cseq={CSeqNum, 'REFER'}}) ->
    nksip_lib:hash({<<"refer">>, nksip_lib:to_binary(CSeqNum)});

make_id(#sipmsg{class={resp, _, _}, cseq={CSeqNum, 'REFER'}}) ->
    nksip_lib:hash({<<"refer">>, nksip_lib:to_binary(CSeqNum)});

make_id(#sipmsg{event={Event, Opts}}) ->
    Id = nksip_lib:get_value(<<"id">>, Opts),
    nksip_lib:hash({Event, Id}).


%% @private Finds a event.
-spec find(id()|nksip:request()|nksip:response(), nksip:dialog()) ->
    nksip:subscription() | not_found.

find(Id, #dialog{subscriptions=Subs}) when is_binary(Id) ->
    do_find(Id, Subs);

find(#sipmsg{}=Req, #dialog{subscriptions=Subs}) ->
    do_find(make_id(Req), Subs).

%% @private 
do_find(_, []) -> not_found;
do_find(Id, [#subscription{id=Id}=Subs|_]) -> Subs;
do_find(Id, [_|Rest]) -> do_find(Id, Rest).



%% @private Hack to find the UAS subscription from the UAC and the opposite way
remote_id(Id, App) ->
    {_AppId0, SubsId, _DialogId, CallId} = parse_id(Id),
    RemoteId = nksip_dialog:remote_id(nksip_dialog:get_id(Id), App),
    {AppId1, RemDialogId, CallId} = nksip_dialog:parse_id(RemoteId),
    App1 = atom_to_binary(AppId1, latin1),
    <<$U, $_, SubsId/binary, $_, RemDialogId/binary, $_, App1/binary, $_, CallId/binary>>.


%% @private
-spec subscription_state(nksip:request()) ->
    subscription_state() | invalid.

subscription_state(#sipmsg{}=SipMsg) ->
    try
        case nksip_sipmsg:header(<<"subscription-state">>, SipMsg, tokens) of
            [{Name, Opts}] -> ok;
            _ -> Name = Opts = throw(invalid)
        end,
        case Name of
            <<"active">> -> 
                case nksip_lib:get_integer(<<"expires">>, Opts, -1) of
                    -1 -> Expires = undefined;
                    Expires when is_integer(Expires), Expires>=0 -> ok;
                    _ -> Expires = throw(invalid)
                end,
                 {active, Expires};
            <<"pending">> -> 
                case nksip_lib:get_integer(<<"expires">>, Opts, -1) of
                    -1 -> Expires = undefined;
                    Expires when is_integer(Expires), Expires>=0 -> ok;
                    _ -> Expires = throw(invalid)
                end,
                {pending, Expires};
            <<"terminated">> ->
                case nksip_lib:get_integer(<<"retry-after">>, Opts, -1) of
                    -1 -> Retry = undefined;
                    Retry when is_integer(Retry), Retry>=0 -> ok;
                    _ -> Retry = throw(invalid)
                end,
                case nksip_lib:get_value(<<"reason">>, Opts) of
                    undefined -> 
                        {terminated, undefined, undefined};
                    Reason0 ->
                        case catch binary_to_existing_atom(Reason0, latin1) of
                            {'EXIT', _} -> {terminated, undefined, undefined};
                            probation -> {terminated, probation, Retry};
                            giveup -> {terminated, giveup, Retry};
                            Reason -> {terminated, Reason, undefined}
                        end
                end;
            _ ->
                throw(invalid)
        end
    catch
        throw:invalid -> invalid
    end.



