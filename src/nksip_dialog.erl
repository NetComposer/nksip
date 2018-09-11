
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([srv_id/1, get_handle/1, call_id/1, get_meta/2, get_metas/2]).
-export([get_dialog/2, get_all/0, get_all/2, stop/1, bye_all/0, stop_all/0]).
-export([get_authorized_list/1, clear_authorized_list/1]).
-export([get_all_data/0]).
-export_type([invite_status/0, field/0, stop_reason/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% SIP Dialog stop reason
-type stop_reason() :: 
    nksip:sip_code() | caller_bye | callee_bye | forced |
    busy | cancelled | service_unavailable | declined | timeout |
    ack_timeout | no_events.

%% All the ways to specify a dialog
% -type spec() :: id() | nksip:handle().

-type field() :: 
    get_handle | srv_id | created | updated | local_seq | remote_seq |
    local_uri | raw_local_uri | remote_uri | raw_remote_uri | 
    local_target | raw_local_target | remote_target | raw_remote_target | 
    early | secure | route_set | raw_route_set | 
    invite_status | invite_answered | invite_local_sdp | invite_remote_sdp |
    invite_timeout | subscriptions | call_id | from_tag | to_tag.


%% All dialog INVITE states
-type invite_status() :: 
    init | proceeding_uac | proceeding_uas |accepted_uac | accepted_uas |
    confirmed | bye.



%% ===================================================================
%% Public
%% ===================================================================



%% @doc Calculates a dialog's id.
-spec get_handle(nksip:dialog()|nksip:request()|nksip:response()|nksip:handle()) ->
    {ok, nksip:handle()} | {error, term()}.

get_handle(<<Class, $_, _/binary>>=Handle) when Class==$R; Class==$S ->
    case nksip_sipmsg:remote_meta(dialog_handle, Handle) of
        {ok, DialogHandle} ->
            {ok, DialogHandle};
        {error, _} ->
            {error, invalid_dialog}
    end;
get_handle(Term) ->
    {ok, nksip_dialog_lib:get_handle(Term)}.


%% @doc Gets the App of a dialog
-spec srv_id(nksip:dialog()|nksip:handle()) ->
    {ok, nkserver:id()}.

srv_id(#dialog{srv_id=SrvId}) ->
    {ok, SrvId};
srv_id(Handle) ->
    {SrvId, _DialogId, _CallId} = nksip_dialog_lib:parse_handle(Handle),
    {ok, SrvId}.


%% @doc Gets the Call-ID of a dialog
-spec call_id(nksip:dialog()|nksip:handle()) ->
    {ok, nksip:call_id()}.

call_id(#dialog{call_id=CallId}) ->
    {ok, CallId};
call_id(Handle) ->
    {_PkgId, _DialogId, CallId} = nksip_dialog_lib:parse_handle(Handle),
    {ok, CallId}.


%% @doc Get a specific metadata
-spec get_meta(field() | {function, function()}, nksip:dialog()|nksip:handle()) ->
    {ok, term()} | {error, term()}.

get_meta(Field, #dialog{}=Dialog) ->
    {ok, nksip_dialog_lib:get_meta(Field, Dialog)};
get_meta(Field, <<Class, $_, _/binary>>=MsgHandle) when Class==$R; Class==$S ->
    case get_handle(MsgHandle) of
        {ok, DlgHandle} ->
            get_meta(Field, DlgHandle);
        {error, Error} ->
            {error, Error}
    end;
get_meta(Field, Handle) ->
    nksip_dialog_lib:remote_meta(Field, Handle).


%% @doc Get a group of specific metadata
-spec get_metas([field()], nksip:dialog()|nksip:handle()) ->
    {ok, [{field(), term()}]} | {error, term()}.

get_metas(Fields, #dialog{}=Dialog) when is_list(Fields) ->
    {ok, nksip_dialog_lib:get_metas(Fields, Dialog)};
get_metas(Fields, <<Class, $_, _/binary>>=MsgHandle) when Class==$R; Class==$S ->
    case get_handle(MsgHandle) of
        {ok, DlgHandle} ->
            get_metas(Fields, DlgHandle);
        {error, Error} ->
            {error, Error}
    end;
get_metas(Fields, Handle) when is_list(Fields) ->
    nksip_dialog_lib:remote_metas(Fields, Handle).



%% @doc Gets the dialog object corresponding to a request or subscription and a call
-spec get_dialog(nksip:request()|nksip:response()|nksip:subscription(), nksip:call()) ->
    {ok, nksip:dialog()} | {error, term()}.

get_dialog(#sipmsg{dialog_id=DialogId}, #call{}=Call) ->
    case nksip_call_dialog:find(DialogId, Call) of
        not_found ->
            {error, invalid_dialog};
        Dialog ->
            {ok, Dialog}
    end;

get_dialog({uses_subs, _Subs, Dialog}, _) ->
    {ok, Dialog}.


%% @doc Gets all started dialogs handles
-spec get_all() ->
    [nksip:handle()].

get_all() ->
    nksip_call:get_all_dialogs().


%% @doc Finds all started dialogs handles having `Call-ID'.
-spec get_all(nkserver:id(), nksip:call_id()) ->
    [nksip:handle()].

get_all(SrvId, CallId) ->
    case nksip_call:get_all_dialogs(SrvId, CallId) of
        {ok, Handles} ->
            Handles;
        {error, _} ->
            []
    end.


%% @doc Sends an in-dialog BYE to all existing dialogs.
-spec bye_all() ->
    ok.

bye_all() ->
    Fun = fun(DialogId) -> nksip_uac:bye(DialogId, [async]) end,
    lists:foreach(Fun, get_all()).


%% @doc Stops an existing dialog (remove it from memory).
-spec stop(nksip:handle()) ->
    ok | {error, term()}.

stop(Handle) ->
    {SrvId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Handle),
    nksip_call:stop_dialog(SrvId, CallId, DialogId).


%% @doc Stops (deletes) all current dialogs.
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun(DialogId) -> stop(DialogId) end, get_all()).


%% @doc Gets the authorized list of transport, ip and ports for a dialog.
-spec get_authorized_list(nksip:handle()) ->
    [{nkpacket:transport(), inet:ip_address(), inet:port_number()}].

get_authorized_list(Handle) ->
    {SrvId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Handle),
    case nksip_call:get_authorized_list(SrvId, CallId, DialogId)of
        {ok, List} ->
            List;
        _ ->
            []
    end.


%% @doc Clears the authorized list of transport, ip and ports for a dialog.
-spec clear_authorized_list(nksip:handle()) ->
    ok | {error, term()}.

clear_authorized_list(Handle) ->
    {SrvId, DialogId, CallId} = nksip_dialog_lib:parse_handle(Handle),
    nksip_call:clear_authorized_list(SrvId, CallId, DialogId).



%% ===================================================================
%% Private
%% ===================================================================


%% @private Dumps all dialog information
%% Do not use it with many active dialogs!!
-spec get_all_data() ->
    [{nksip:handle(), nksip:optslist()}].

get_all_data() ->
    Now = nklib_util:timestamp(),
    Fun = fun(DialogId, Acc) ->
        case get_meta(full_dialog, DialogId) of
            {ok, #dialog{}=Dialog} ->
                Data = {DialogId, [
                    {id, Dialog#dialog.id},
                    {srv_id, Dialog#dialog.srv_id},
                    {call_id, Dialog#dialog.call_id},
                    {local_uri, nklib_unparse:uri(Dialog#dialog.local_uri)},
                    {remote_uri, nklib_unparse:uri(Dialog#dialog.remote_uri)},
                    {created, Dialog#dialog.created},
                    {elapsed, Now - Dialog#dialog.created},
                    {updated, Dialog#dialog.updated},
                    {local_seq, Dialog#dialog.local_seq},
                    {remote_seq, Dialog#dialog.remote_seq},
                    {local_target, nklib_unparse:uri(Dialog#dialog.local_target)},
                    {remote_target, nklib_unparse:uri(Dialog#dialog.remote_target)},
                    {route_set, 
                        [nklib_unparse:uri(Route) || Route <- Dialog#dialog.route_set]},
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


