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

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").

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
    Opts1 = case lists:member(<<"timer">>, Supported) of
        true -> Opts;
        false -> nksip_lib:store_value(supported, Supported++[<<"timer">>], Opts)
    end,
    try
        case nksip_lib:get_value(nksip_timers_se, Opts) of
            SE when is_integer(SE), SE>=5 -> ok;
            _ -> throw(nksip_timers_se)
        end,
        case nksip_lib:get_value(nksip_timers_min_se, Opts) of
            MinSE when is_integer(MinSE), MinSE>=1 -> ok;
            _ -> throw(nksip_timers_min_se)
        end,
        Times = {
            nksip_lib:get_value(nksip_timers_se, Opts1),
            nksip_lib:get_value(nksip_timers_min_se, Opts1)
        },
        Cached1 = nksip_lib:get_value(cached_configs, Opts1, []),
        Cached2 = nksip_lib:store_value(config_nksip_timers, Times, Cached1),
        Opts2 = nksip_lib:store_value(cached_configs, Cached2, Opts1),
        {ok, Opts2}
    catch
        throw:OptName -> {error, {invalid_config, OptName}}
    end.