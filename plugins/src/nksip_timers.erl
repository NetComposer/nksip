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
-export([version/0, deps/0, parse_config/1]).


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.1".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(nksip:optslist()) ->
    {ok, nksip:optslist()} | {error, term()}.

parse_config(Opts) ->
    Defaults = [
        {nksip_timers_se, 1800},        % (secs) 30 min
        {nksip_timers_min_se, 90}       % (secs) 90 secs (min 90, recomended 1800)
    ],
    Opts1 = nksip_lib:defaults(Opts, Defaults),
    Supported = nksip_lib:get_value(supported, Opts),
    Opts2 = case lists:member(<<"timer">>, Supported) of
        true -> Opts1;
        false -> nksip_lib:store_value(supported, Supported++[<<"timer">>], Opts1)
    end,
    try
        case nksip_lib:get_value(nksip_timers_se, Opts2) of
            SE when is_integer(SE), SE>=5 -> 
                ok;
            _ -> 
                throw(nksip_timers_se)
        end,
        case nksip_lib:get_value(nksip_timers_min_se, Opts2) of
            MinSE when is_integer(MinSE), MinSE>=1 -> 
                ok;
            _ -> 
                throw(nksip_timers_min_se)
        end,
        Times = {
            nksip_lib:get_value(nksip_timers_se, Opts2),
            nksip_lib:get_value(nksip_timers_min_se, Opts2)
        },
        Cached1 = nksip_lib:get_value(cached_configs, Opts2, []),
        Cached2 = nksip_lib:store_value(config_nksip_timers, Times, Cached1),
        Opts3 = nksip_lib:store_value(cached_configs, Cached2, Opts2),
        {ok, Opts3}
    catch
        throw:OptName -> {error, {invalid_config, OptName}}
    end.


%% ===================================================================
%% Public specific
%% ===================================================================


%% @doc Gets the current session expires value for a dialog
-spec get_session_expires(nksip:dialog()|nksip:id()) ->
    non_neg_integer() | undefined.

get_session_expires(Id) when is_binary(Id) ->
    Fun = fun(Dialog) -> {ok, get_session_expires(Dialog)} end,
    nksip_dialog:apply_meta(Fun, Id);

get_session_expires(#dialog{invite=Invite, meta=Meta}) ->
    case is_record(Invite, invite) of
        true ->
            nksip_lib:get_value(nksip_timers_se, Meta);
        false ->
            undefined
    end.


%% @doc Gets the reamining time to refresh the session
-spec get_session_refresh(nksip:dialog()|nksip:id()) ->
    non_neg_integer() | undefined.

get_session_refresh(Id) when is_binary(Id) ->
    Fun = fun(Dialog) -> {ok, get_session_refresh(Dialog)} end,
    nksip_dialog:apply_meta(Fun, Id);

get_session_refresh(#dialog{invite=Invite, meta=Meta}) ->
    case is_record(Invite, invite) of
        true ->
            RefreshTimer = nksip_lib:get_value(nksip_timers_refresh, Meta),
            case is_reference(RefreshTimer) of
                true -> 
                    case erlang:read_timer(RefreshTimer) of
                        false -> expired;
                        IR -> IR
                    end;
                false ->
                    undefined
            end;
        false -> 
            undefined
    end.

