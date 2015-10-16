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
-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.2".


%% @doc Dependant plugins
-spec deps() ->
    [atom()].
    
deps() ->
    [nksip].


plugin_start(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p starting (~p)", [?MODULE, SrvId]),
    case nkservice_util:parse_syntax(SrvSpec, syntax(), defaults()) of
        {ok, SrvSpec1} ->
            UpdFun = fun(Supp) -> nklib_util:store_value(<<"timer">>, Supp) end,
            SrvSpec2 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec1),
            #{
                sip_timers_se := SE, 
                sip_timers_min_se := MinSE, 
                cache := OldCache
            } = SrvSpec2,
            Cache = #{sip_timers_times=>{SE, MinSE}},
            {ok, SrvSpec2#{cache:=maps:merge(OldCache, Cache)}};
        {error, Error} ->
            {stop, Error}
    end.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    lager:info("Plugin ~p stopping (~p)", [?MODULE, SrvId]),
    UpdFun = fun(Supp) -> Supp -- [<<"timer">>] end,
    SrvSpec1 = nksip_util:plugin_update_value(sip_supported, UpdFun, SrvSpec),
    SrvSpec2 = maps:without(maps:keys(syntax()), SrvSpec1),
    {ok, SrvSpec2}.


syntax() ->
    #{
        sip_timers_se =>  {integer, 5, none},
        sip_timers_min_se => {integer, 1, none}
    }.

defaults() ->
    #{
        sip_timers_se =>  1800,     % (secs) 30 min
        sip_timers_min_se => 90     % (secs) 90 secs (min 90, recomended 1800)
    }.



% %% @doc Parses this plugin specific configuration
% -spec parse_config(nksip:optslist()) ->
%     {ok, nksip:optslist()} | {error, term()}.

% parse_config(Opts) ->
%     Defaults = [
%         {sip_timers_se, 1800},        % (secs) 30 min
%         {sip_timers_min_se, 90}       % (secs) 90 secs (min 90, recomended 1800)
%     ],
%     Opts1 = nklib_util:defaults(Opts, Defaults),
%     Supported = nklib_util:get_value(sip_supported, Opts),
%     Opts2 = case lists:member(<<"timer">>, Supported) of
%         true -> Opts1;
%         false -> nklib_util:store_value(sip_supported, Supported++[<<"timer">>], Opts1)
%     end,
%     try
%         case nklib_util:get_value(sip_timers_se, Opts2) of
%             SE when is_integer(SE), SE>=5 -> 
%                 ok;
%             _ -> 
%                 throw(sip_timers_se)
%         end,
%         case nklib_util:get_value(sip_timers_min_se, Opts2) of
%             MinSE when is_integer(MinSE), MinSE>=1 -> 
%                 ok;
%             _ -> 
%                 throw(sip_timers_min_se)
%         end,
%         Times = {
%             nklib_util:get_value(sip_timers_se, Opts2),
%             nklib_util:get_value(sip_timers_min_se, Opts2)
%         },
%         Cached1 = nklib_util:get_value(cached_configs, Opts2, []),
%         Cached2 = nklib_util:store_value(config_nksip_timers, Times, Cached1),
%         Opts3 = nklib_util:store_value(cached_configs, Cached2, Opts2),
%         {ok, Opts3}
%     catch
%         throw:OptName -> {error, {invalid_config, OptName}}
%     end.


%% ===================================================================
%% Public specific
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


