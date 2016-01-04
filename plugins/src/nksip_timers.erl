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

%% @doc NkSIP Reliable Provisional Responses Plugin
-module(nksip_timers).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-export([get_session_expires/1, get_session_refresh/1]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Gets the current session expires value for a dialog
-spec get_session_expires(nksip:dialog()|nksip:handle()) ->
    {ok, non_neg_integer() | undefined} | {error, term()}.

get_session_expires(#dialog{invite=Invite, meta=Meta}) ->
    case is_record(Invite, invite) of
        true ->
            {ok, nklib_util:get_value(sip_timers_se, Meta)};
        false ->
            {ok, undefined}
    end;

get_session_expires(Handle) ->
    Fun = fun(#dialog{}=Dialog) -> get_session_expires(Dialog) end,
    case nksip_dialog:meta({function, Fun}, Handle) of
        {ok, Value} -> Value;
        {error, Error} -> {error, Error}
    end.


%% @doc Gets the reamining time to refresh the session
-spec get_session_refresh(nksip:dialog()|nksip:handle()) ->
    {ok, non_neg_integer() | expired | undefined} | {error, term()}.

get_session_refresh(#dialog{invite=Invite, meta=Meta}) ->
    case is_record(Invite, invite) of
        true ->
            RefreshTimer = nklib_util:get_value(sip_timers_refresh, Meta),
            case is_reference(RefreshTimer) of
                true -> 
                    case erlang:read_timer(RefreshTimer) of
                        false -> {ok, expired};
                        IR -> {ok, IR}
                    end;
                false ->
                    {ok, undefined}
            end;
        false -> 
            {ok, undefined}
    end;

get_session_refresh(Handle) ->
    Fun = fun(#dialog{}=Dialog) -> get_session_refresh(Dialog) end,
    case nksip_dialog:meta({function, Fun}, Handle) of
        {ok, Value} -> Value;
        {error, Error} -> {error, Error}
    end.


