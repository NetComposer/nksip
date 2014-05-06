
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

%% @doc User Dialog Management Module.
%% This module implements several utility functions related to dialogs.

-module(nksip_dialog).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([field/2, fields/2, call_id/1, app_id/1]).
-export([stop/1, bye_all/0, stop_all/0]).
-export([get_dialog/1, get_all/0, get_all/2, get_all_data/0]).
-export([make_id/2, get_id/1, parse_id/1, remote_id/2, change_app/2]).
-export_type([id/0, dlg/0, invite_status/0, field/0, stop_reason/0]).

-include("nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% SIP Dialog unique ID
-type id() :: binary().


%% User Dialog
-type dlg() :: {user_dlg, nksip:dialog(), nksip_call:call()}.


%% SIP Dialog stop reason
-type stop_reason() :: 
    nksip:response_code() | caller_bye | callee_bye | forced |
    busy | cancelled | service_unavailable | declined | timeout |
    ack_timeout | no_events.

%% All the ways to specify a dialog
% -type spec() :: id() | nksip:id().

-type field() :: 
    id | app_id | app_name | created | updated | local_seq | remote_seq | 
    local_uri | raw_local_uri | remote_uri | raw_remote_uri | 
    local_target | raw_local_target | remote_target | raw_remote_target | 
    early | secure | route_set | raw_route_set | 
    invite_status | invite_answered | invite_local_sdp | invite_remote_sdp |
    invite_timeout | invite_session_expires | invite_refresh |
    subscriptions | call_id | from_tag | to_tag.


%% All dialog INVITE states
-type invite_status() :: 
    init | proceeding_uac | proceeding_uas |accepted_uac | accepted_uas |
    confirmed | bye.



%% ===================================================================
%% Public
%% ===================================================================


-spec meta(field(), nksip:id()|dlg()|nksip:dialog()) -> 
    term() | error.

meta(Field, Id) when is_binary(Id) -> 
    case metas([Field], Id) of
        [{_, Value}] -> Value;
        error -> error
    end;

meta(Field, {user_dlg, Dialog, _Call}) ->
    meta(Field, Dialog);

meta(Field, #dialog{invite=I0}=D) ->
    I = case I0 of undefined -> #invite{}; _ -> I end,
    case Field of
        id -> get_id(D);
        internal_id -> D#dialog.id;
        app_id -> D#dialog.app_id;
        app_name -> apply(D#dialog.app_id, name, []);
        call_id -> D#dialog.call_id;
        created -> D#dialog.created;
        updated -> D#dialog.updated;
        local_seq -> D#dialog.local_seq; 
        remote_seq  -> D#dialog.remote_seq; 
        local_uri -> D#dialog.local_uri;
        raw_local_uri -> nksip_unparse:uri(D#dialog.local_uri);
        remote_uri -> D#dialog.remote_uri;
        raw_remote_uri -> nksip_unparse:uri(D#dialog.remote_uri);
        local_target -> D#dialog.local_target;
        raw_local_target -> nksip_unparse:uri(D#dialog.local_target);
        remote_target -> D#dialog.remote_target;
        raw_remote_target -> nksip_unparse:uri(D#dialog.remote_target);
        early -> D#dialog.early;
        secure -> D#dialog.secure;
        route_set -> D#dialog.route_set;
        raw_route_set -> [nksip_lib:to_binary(Route) || Route <- D#dialog.route_set];
        invite_status when is_record(I, invite) -> I#invite.status;
        invite_status -> undefined;
        invite_answered when is_record(I, invite) -> I#invite.answered;
        invite_answered -> undefined;
        invite_local_sdp when is_record(I, invite) -> I#invite.local_sdp;
        invite_local_sdp -> undefined;
        invite_remote_sdp when is_record(I, invite) -> I#invite.remote_sdp;
        invite_remote_sdp -> undefined;
        invite_timeout when is_record(I, invite) -> read_timer(I#invite.timeout_timer);
        invite_timeout -> undefined;
        invite_session_expires when is_record(I, invite) -> I#invite.session_expires;
        invite_session_expires -> undefined;
        invite_refresh when is_record(I, invite) -> 
            case is_reference(I#invite.refresh_timer) of
                true -> 
                    case erlang:read_timer(I#invite.refresh_timer) of
                        false -> expired;
                        IR -> IR
                    end;
                false ->
                 undefined
            end;
        invite_refresh -> undefined;
        subscriptions -> 
            [nksip_subscription:get_id(S, D) || S <- D#dialog.subscriptions];
        call_id -> D#dialog.call_id;
        from_tag -> nksip_lib:get_binary(<<"tag">>, (D#dialog.local_uri)#uri.ext_opts);
        to_tag -> nksip_lib:get_binary(<<"tag">>, (D#dialog.remote_uri)#uri.ext_opts);
        _ -> invalid_field 
    end.


%% @doc Gets a number of fields from the `Request' as described in {@link field/2}.
-spec fields(nksip:id(), [field()]) -> 
    [{atom(), term()}] | error.
    
fields(Id, Fields) when is_list(Fields) ->
    Fun = fun(Dialog) -> 
        {ok, [{Field, field(Dialog, Field)} || Field <- Fields]}
    end,
    case get_id(Id) of
        <<>> ->
            error;
        DialogId ->
            case nksip_call_router:apply_dialog(DialogId, Fun) of
                {ok, Values} -> Values;
                _ -> error
            end
    end.

%% @doc Gets thel Call-ID of a dialog
-spec call_id(nksip:id()|#dialog{}) ->
    nksip:call_id().

call_id(#dialog{call_id=CallId}) ->
    CallId;

call_id(Id) ->
    {_AppId, _DialogId, CallId} = parse_id(Id),
    CallId. 


%% @doc Gets thel App of a dialog
-spec app_id(nksip:id()|#dialog{}) ->
    nksip:app_id().

app_id(#dialog{app_id=AppId}) ->
    AppId;

app_id(Id) ->
    {AppId, _DialogId, _CallId} = parse_id(Id),
    AppId. 



%% @doc Calculates a <i>dialog's id</i> from a {@link nksip:id()}.
-spec get_id(nksip:id()|nksip:dialog()|nksip:request()|nksip:response()) ->
    nksip:id().

get_id(<<"D_", _/binary>>=DialogId) ->
    DialogId;

get_id(<<"U_", _/binary>>=SubscriptionId) ->
    nksip_subscription:dialog_id(SubscriptionId);

get_id(<<Class, $_, _/binary>>=MsgId) when Class==$R; Class==$S ->
    case nksip_call:find_dialog(MsgId) of
        {ok, DialogId} -> DialogId;
        {error, _} -> <<>>
    end;

get_id(#dialog{id=Id, app_id=AppId, call_id=CallId}) ->
    App = atom_to_binary(AppId, latin1),
    <<$D, $_, Id/binary, $_, App/binary, $_, CallId/binary>>;

get_id(#sipmsg{dialog_id=DialogId, app_id=AppId, call_id=CallId}) ->
    App = atom_to_binary(AppId, latin1),
    <<$D, $_, DialogId/binary, $_, App/binary, $_, CallId/binary>>.


%% @private
-spec parse_id(nksip:id()) -> 
    {nksip:app_id(), binary(), nksip:call_id()} | error.

parse_id(<<$D, $_, _/binary>>=Bin) ->
    <<$D, $_, Id:6/binary, $_, App:7/binary, $_, CallId/binary>> = Bin,
    {binary_to_existing_atom(App, latin1), Id, CallId};

parse_id(Other) ->
    case get_id(Other) of
        <<>> -> error;
        DialogId -> parse_id(DialogId)
    end.


%% @doc Gets a full dialog record.
-spec get_dialog(nksip:id()) ->
    nksip:dialog() | error.

get_dialog(Id) ->
    Fun = fun(Dialog) -> {ok, Dialog} end,
    case get_id(Id) of
        <<>> ->
            error;
        DialogId ->
            case nksip_call_router:apply_dialog(DialogId, Fun) of
                {ok, Dialog} -> Dialog;
                _ -> error
            end
    end.


%% @doc Gets all started dialog ids.
-spec get_all() ->
    [nksip:id()].

get_all() ->
    nksip_call_router:get_all_dialogs().


%% @doc Finds all existing dialogs having a `Call-ID'.
-spec get_all(nksip:app_id(), nksip:call_id()) ->
    [nksip:id()].

get_all(App, CallId) ->
    case nksip:find_app(App) of
        {ok, AppId} -> nksip_call_router:get_all_dialogs(AppId, CallId);
        _ ->[]
    end.


%% @doc Sends an in-dialog BYE to all existing dialogs.
-spec bye_all() ->
    ok.

bye_all() ->
    Fun = fun(DialogId) -> nksip_uac:bye(DialogId, [async]) end,
    lists:foreach(Fun, get_all()).


%% @doc Stops an existing dialog (remove it from memory).
-spec stop(nksip:id()) ->
    ok.

stop(Id) ->
    nksip_call:stop_dialog(Id).


%% @doc Stops (deletes) all current dialogs.
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun(DialogId) -> stop(DialogId) end, get_all()).


%% @doc Calculates a <i>dialog's id</i> from a {@link nksip:request()} or
%% {@link nksip:response()} and a endpoint class.
%% Dialog ids are calculated as a hash over <i>Call-ID</i>, <i>From</i> tag 
%% and <i>To</i> Tag. Dialog ids with same From and To are different
%% for different endpoint classes.
-spec make_id(uac|uas, nksip:request()|nksip:response()) ->
    id().

make_id(Class, #sipmsg{from={_, FromTag}, to={_, ToTag}})
        when FromTag /= <<>>, ToTag /= <<>> ->
    make_id(Class, FromTag, ToTag);

make_id(Class, #sipmsg{from={_, FromTag}, to={_, <<>>}, class={req, Method}}=SipMsg)
    when FromTag /= <<>> andalso
         (Method=='INVITE' orelse Method=='REFER' orelse
          Method=='SUBSCRIBE' orelse Method=='NOTIFY') ->
    #sipmsg{to_tag_candidate=ToTag} = SipMsg,
    case ToTag of
        <<>> -> <<>>;
        _ -> make_id(Class, FromTag, ToTag)
    end;

make_id(_, #sipmsg{}) ->
    <<>>.



%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec make_id(uac|uas, nksip:tag(), nksip:tag()) ->
    id().

make_id(Class, FromTag, ToTag) ->
    case Class of
        uac -> nksip_lib:hash({ToTag, FromTag});
        uas -> nksip_lib:hash({FromTag, ToTag})
    end.

%% @private Hack to find the UAS dialog from the UAC and the opposite way
remote_id(<<$D, _/binary>>=DialogId, App) ->
    {ok, AppId} = nksip:find_app(App),
    [{internal_id, BaseId}, {parsed_local_uri, LUri}, 
      {parsed_remote_uri, RUri}, {call_id, CallId}] =  
        fields(DialogId, [internal_id, parsed_local_uri, parsed_remote_uri, call_id]),
    FromTag = nksip_lib:get_binary(<<"tag">>, LUri#uri.ext_opts),
    ToTag = nksip_lib:get_binary(<<"tag">>, RUri#uri.ext_opts),
    Id = case make_id(uac, FromTag, ToTag) of
        BaseId -> make_id(uas, FromTag,ToTag);
        RemoteId -> RemoteId
    end,
    BinApp = atom_to_binary(AppId, latin1),
    <<$D, $_, Id/binary, $_, BinApp/binary, $_, CallId/binary>>.


%% @private Hack to find de dialog at another app in the same machine
change_app(Id, App) ->
    {_, DialogId, CallId} = parse_id(Id),
    {ok, AppId1} = nksip:find_app(App),
    App1 = atom_to_binary(AppId1, latin1),
    <<$D, $_, DialogId/binary, $_, App1/binary, $_, CallId/binary>>.



%% @private Dumps all dialog information
%% Do not use it with many active dialogs!!
-spec get_all_data() ->
    [{nksip:id(), nksip_lib:optslist()}].

get_all_data() ->
    Now = nksip_lib:timestamp(),
    Fun = fun(DialogId, Acc) ->
        case get_dialog(DialogId) of
            #dialog{}=Dialog ->
                Data = {DialogId, [
                    {id, Dialog#dialog.id},
                    {app_id, Dialog#dialog.app_id},
                    {call_id, Dialog#dialog.call_id},
                    {local_uri, nksip_unparse:uri(Dialog#dialog.local_uri)},
                    {remote_uri, nksip_unparse:uri(Dialog#dialog.remote_uri)},
                    {created, Dialog#dialog.created},
                    {elapsed, Now - Dialog#dialog.created},
                    {updated, Dialog#dialog.updated},
                    {local_seq, Dialog#dialog.local_seq},
                    {remote_seq, Dialog#dialog.remote_seq},
                    {local_target, nksip_unparse:uri(Dialog#dialog.local_target)},
                    {remote_target, nksip_unparse:uri(Dialog#dialog.remote_target)},
                    {route_set, 
                        [nksip_unparse:uri(Route) || Route <- Dialog#dialog.route_set]},
                    {early, Dialog#dialog.early},
                    {invite, 
                        case Dialog#dialog.invite of
                            #invite{
                                status = InvStatus, 
                                local_sdp = LSDP, 
                                remote_sdp = RSDP,
                                timeout_timer  = Timeout
                            } -> 
                                Time = erlang:read_timer(Timeout)/1000,
                                {InvStatus, Time, LSDP, RSDP};
                            undefined ->
                                undefined
                        end},
                   {subscriptions,
                        [Id || #subscription{id=Id} <- Dialog#dialog.subscriptions]}
                ]},
                [Data|Acc];
            _ ->
                Acc
        end
    end,
    lists:foldl(Fun, [], get_all()).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
read_timer(Ref) when is_reference(Ref) -> (erlang:read_timer(Ref))/1000;
read_timer(_) -> undefined.






