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

-export([field/3, field/2, fields/3, id/1, id/2, call_id/1]).
-export([stop/2, bye_all/0, stop_all/0]).
-export([get_dialog/2, get_all/0, get_all/2, get_all_data/0]).

-export_type([id/0, dialog/0, stop_reason/0, spec/0, status/0, field/0]).

-include("nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% SIP Dialog unique ID
-type id() :: binary().

%% SIP Dialog stop reason
-type stop_reason() :: nksip:response_code() | caller_bye | callee_bye | forced |
                       busy | cancelled | service_unavailable | declined | timeout |
                       ack_timeout. 

%% SIP Dialog State
-type dialog() :: #dialog{}.

%% All the ways to specify a dialog
-type spec() :: id() | nksip_request:id() | nksip_response:id().

%% All dialog states
-type status() :: init | proceeding_uac | proceeding_uas |accepted_uac | accepted_uas |
                  confirmed | bye | {stop, stop_reason()}.

-type field() :: dialog_id | app_id | call_id | created | updated | answered | 
                 state | expires |  local_seq | remote_seq | 
                 local_uri | parsed_local_uri | remote_uri |  parsed_remote_uri | 
                 local_target | parsed_local_target | remote_target | 
                 parsed_remote_target | route_set | parsed_route_set |
                 local_sdp | remote_sdp | stop_reason |
                 from_tag | to_tag.



%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets specific information from the dialog indicated by `DialogSpec'. 
%% The available fields are:
%%  
%% <table border="1">
%%      <tr><th>Field</th><th>Type</th><th>Description</th></tr>
%%      <tr>
%%          <td>`app_id'</td>
%%          <td>{@link nksip:app_id()}</td>
%%          <td>SipApp that created the dialog</td>
%%      </tr>
%%      <tr>
%%          <td>`call_id'</td>
%%          <td>{@link nksip:call_id()}</td>
%%          <td>Call-ID</td>
%%      </tr>
%%      <tr>
%%          <td>`created'</td>
%%          <td>{@link nksip_lib:timestamp()}</td>
%%          <td>Creation timestamp</td>
%%      </tr>
%%      <tr>
%%          <td>`updated'</td>
%%          <td>{@link nksip_lib:timestamp()}</td>
%%          <td>Last update timestamp</td>
%%      </tr>
%%      <tr>
%%          <td>`answered'</td>
%%          <td>{@link nksip_lib:timestamp()}`|undefined'</td>
%%          <td>Answer (first 2xx response) timestamp</td>
%%      </tr>
%%      <tr>
%%          <td>`status'</td>
%%          <td>{@link status()}</td>
%%          <td>Current dialog state</td>
%%      </tr>
%%      <tr>
%%          <td>`expires'</td>
%%          <td>`integer()'</td>
%%          <td>Seconds to expire current state</td>
%%      </tr>
%%      <tr>
%%          <td>`local_seq'</td>
%%          <td>{@link nksip:cseq()}</td>
%%          <td>Local CSeq number</td>
%%      </tr>
%%      <tr>
%%          <td>`remote_seq'</td>
%%          <td>{@link nksip:cseq()}</td>
%%          <td>Remote CSeq number</td>
%%      </tr>
%%      <tr>
%%          <td>`local_uri'</td>
%%          <td>`binary()'</td>
%%          <td>Local URI</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_local_uri'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>Local URI</td>
%%      </tr>
%%      <tr>
%%          <td>`remote_uri'</td>
%%          <td>`binary()'</td>
%%          <td>Remote URI</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_remote_uri'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>Remote URI</td>
%%      </tr>
%%      <tr>
%%          <td>`local_target'</td>
%%          <td>`binary()'</td>
%%          <td>Local Target URI</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_local_target'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>Local Target URI</td>
%%      </tr>
%%      <tr>
%%          <td>`remote_target'</td>
%%          <td>`binary()'</td>
%%          <td>Remote Target URI</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_remote_target'</td>
%%          <td>{@link nksip:uri()}</td>
%%          <td>Remote Target URI</td>
%%      </tr>
%%      <tr>
%%          <td>`early'</td>
%%          <td>`boolean()'</td>
%%          <td>Early dialog (no final response yet)</td>
%%      </tr>
%%      <tr>
%%          <td>`secure'</td>
%%          <td>`boolean()'</td>
%%          <td>Secure (sips) dialog</td>
%%      </tr>
%%      <tr>
%%          <td>`route_set'</td>
%%          <td>`[binary()]'</td>
%%          <td>Route Set</td>
%%      </tr>
%%      <tr>
%%          <td>`parsed_route_set'</td>
%%          <td>`['{@link nksip:uri()}`]'</td>
%%          <td>Route Set</td>
%%      </tr>
%%      <tr>
%%          <td>`local_sdp'</td>
%%          <td>{@link nksip:sdp()}`|undefined'</td>
%%          <td>Current local SDP</td>
%%      </tr>
%%      <tr>
%%          <td>`remote_sdp'</td>
%%          <td>{@link nksip:sdp()}`|undefined'</td>
%%          <td>Current remote SDP</td>
%%      </tr>
%%      <tr>
%%          <td>`stop_reason'</td>
%%          <td>{@link stop_reason()}</td>
%%          <td>Dialog stop reason</td>
%%      </tr>
%% </table>
-spec field(nksip:app_id(), spec(), field()) -> 
    term() | error.

field(AppId, DialogSpec, Field) -> 
    case fields(AppId, DialogSpec, [Field]) of
        [{_, Value}] -> Value;
        error -> error
    end.


%% @doc Extracts a specific field from a #dialog structure
-spec field(dialog(), field()) -> 
    any().

field(D, Field) ->
    case Field of
        id -> D#dialog.id;
        app_id -> D#dialog.app_id;
        call_id -> D#dialog.call_id;
        created -> D#dialog.created;
        updated -> D#dialog.updated;
        answered -> D#dialog.answered;
        status -> D#dialog.status;
        local_seq -> D#dialog.local_seq; 
        remote_seq  -> D#dialog.remote_seq; 
        local_uri -> nksip_unparse:uri(D#dialog.local_uri);
        parsed_local_uri -> D#dialog.local_uri;
        remote_uri -> nksip_unparse:uri(D#dialog.remote_uri);
        parsed_remote_uri -> D#dialog.remote_uri;
        local_target -> nksip_unparse:uri(D#dialog.local_target);
        parsed_local_target -> D#dialog.local_target;
        remote_target -> nksip_unparse:uri(D#dialog.remote_target);
        parsed_remote_target -> D#dialog.remote_target;
        route_set -> [nksip_lib:to_binary(Route) || Route <- D#dialog.route_set];
        parsed_route_set -> D#dialog.route_set;
        early -> D#dialog.early;
        secure -> D#dialog.secure;
        local_sdp -> D#dialog.local_sdp;
        remote_sdp -> D#dialog.remote_sdp;
        stop_reason -> D#dialog.stop_reason;
        from_tag -> nksip_lib:get_binary(<<"tag">>, (D#dialog.local_uri)#uri.ext_opts);
        to_tag -> nksip_lib:get_binary(<<"tag">>, (D#dialog.remote_uri)#uri.ext_opts);
        timeout -> round(erlang:read_timer(D#dialog.timeout_timer)/1000);
        _ -> invalid_field 
    end.


%% @doc Gets a number of fields from the `Request' as described in {@link field/2}.
-spec fields(nksip:app_id(), spec(), [field()]) -> 
    [{atom(), term()}] | error.
    
fields(AppId, DialogSpec, Fields) when is_list(Fields) ->
    Fun = fun(Dialog) -> 
        {ok, [{Field, field(Dialog, Field)} || Field <- Fields]}
    end,
    case id(AppId, DialogSpec) of
        <<>> ->
            error;
        DialogId ->
            case nksip_call_router:apply_dialog(AppId, DialogId, Fun) of
                {ok, Values} -> Values;
                _ -> error
            end
    end.


%% @doc Calculates a <i>dialog's id</i> from a {@link nksip:request()} or
%% {@link nksip:response()}.
%% Dialog ids are calculated as a hash over <i>Call-ID</i>, <i>From</i> tag 
%% and <i>To</i> Tag. If From tag and To tag are swapped the resulting id is the same.
-spec id(nksip:request()|nksip:response()) ->
    id().

id(#sipmsg{from_tag=FromTag, to_tag=ToTag, call_id=CallId})
    when FromTag =/= <<>>, ToTag =/= <<>> ->
    dialog_id(CallId, FromTag, ToTag);

id(#sipmsg{from_tag=FromTag, to_tag=(<<>>), class={req, 'INVITE'}}=SipMsg)
    when FromTag =/= <<>> ->
    #sipmsg{call_id=CallId, to_tag_candidate=ToTag} = SipMsg,
    case ToTag of
        <<>> -> <<>>;
        _ -> dialog_id(CallId, FromTag, ToTag)
    end;

id(#sipmsg{}) ->
    <<>>.


%% @doc Calculates a <i>dialog's id</i> from a {@link nksip_request:id()}, 
%% {@link nksip_response:id()}.
-spec id(nksip:app_id(), id()|nksip_request:id()|nksip_response:id()) ->
    id().


id(_, <<"D_", _/binary>>=DialogId) ->
    DialogId;

id(AppId, <<Class, $_, _/binary>>=MsgId) when Class=:=$R; Class=:=$S ->
    case nksip_call:dialog_id(AppId, MsgId) of
        {ok, DialogId} -> DialogId;
        {error, _} -> <<>>
    end.

    

%% @doc Gets the calls's id of a dialog
-spec call_id(spec()) ->
    nksip:call_id().

call_id(<<"D_", Rest/binary>>) ->
    nksip_lib:bin_last($_, Rest).


%% @doc Gets a full dialog record.
-spec get_dialog(nksip:app_id(), spec()) ->
    dialog() | error.

get_dialog(AppId, DialogSpec) ->
    Fun = fun(Dialog) -> {ok, Dialog} end,
    case id(AppId, DialogSpec) of
        <<>> ->
            error;
        DialogId ->
            case nksip_call_router:apply_dialog(AppId, DialogId, Fun) of
                {ok, Dialog} -> Dialog;
                _ -> error
            end
    end.


%% @doc Gets all started dialog ids.
-spec get_all() ->
    [{nksip:app_id(), id()}].

get_all() ->
    nksip_call_router:get_all_dialogs().


%% @doc Finds all existing dialogs having a `Call-ID'.
-spec get_all(nksip:app_id(), nksip:call_id()) ->
    [id()].

get_all(AppId, CallId) ->
    [DlgId || {_, DlgId} <- nksip_call_router:get_all_dialogs(AppId, CallId)].


%% @doc Sends an in-dialog BYE to all existing dialogs.
-spec bye_all() ->
    ok.

bye_all() ->
    Fun = fun({AppId, DialogId}) -> nksip_uac:bye(AppId, DialogId, [async]) end,
    lists:foreach(Fun, get_all()).


%% @doc Stops an existing dialog (remove it from memory).
-spec stop(nksip:app_id(), spec()) ->
    ok.

stop(AppId, DialogSpec) ->
    nksip_call:stop_dialog(AppId, DialogSpec).


%% @doc Stops (deletes) all current dialogs.
-spec stop_all() ->
    ok.

stop_all() ->
    lists:foreach(fun({AppId, DialogId}) -> stop(AppId, DialogId) end, get_all()).



%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec dialog_id(nksip:call_id(), nksip:tag(), nksip:tag()) ->
    id().

dialog_id(CallId, FromTag, ToTag) ->
    {A, B} = case FromTag < ToTag of
        true -> {FromTag, ToTag};
        false -> {ToTag, FromTag}
    end,
    <<"D_", (nksip_lib:hash({A, B}))/binary, $_, CallId/binary>>.


%% @private Dumps all dialog information
%% Do not use it with many active dialogs!!
-spec get_all_data() ->
    [{nksip_dialog:id(), nksip_lib:proplist()}].

get_all_data() ->
    Now = nksip_lib:timestamp(),
    Fun = fun({AppId, DialogId}, Acc) ->
        case get_dialog(AppId, DialogId) of
            #dialog{}=Dialog ->
                Data = {DialogId, [
                    {id, Dialog#dialog.id},
                    {app_id, Dialog#dialog.app_id},
                    {call_id, Dialog#dialog.call_id},
                    {status, Dialog#dialog.status},
                    {local_uri, nksip_unparse:uri(Dialog#dialog.local_uri)},
                    {remote_uri, nksip_unparse:uri(Dialog#dialog.remote_uri)},
                    {created, Dialog#dialog.created},
                    {elapsed, Now - Dialog#dialog.created},
                    {updated, Dialog#dialog.updated},
                    {answered, Dialog#dialog.answered},
                    {local_seq, Dialog#dialog.local_seq},
                    {remote_seq, Dialog#dialog.remote_seq},
                    {local_target, nksip_unparse:uri(Dialog#dialog.local_target)},
                    {remote_target, nksip_unparse:uri(Dialog#dialog.remote_target)},
                    {route_set, 
                        [nksip_unparse:uri(Route) || Route <- Dialog#dialog.route_set]},
                    {early, Dialog#dialog.early},
                    % {local_sdp, nksip_sdp:unparse(Dialog#dialog.local_sdp)},
                    % {remote_sdp, nksip_sdp:unparse(Dialog#dialog.remote_sdp)}
                    {local_sdp, Dialog#dialog.local_sdp},
                    {remote_sdp, Dialog#dialog.remote_sdp}
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








