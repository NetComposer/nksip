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

-export([version/0, deps/0, parse_config/2]).


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
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Defaults = [
        {nksip_timers_se, 1800},        % (secs) 30 min
        {nksip_timers_min_se, 90}       % (secs) 90 secs (min 90, recomended 1800)
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),
    Supported = nksip_lib:get_value(supported, Config),
    Config1 = case lists:member(<<"timer">>, Supported) of
        true -> Config;
        false -> nksip_lib:store_value(supported, Supported++[<<"timer">>], Config)
    end,
    case nksip_timers_lib:parse_config(PluginOpts1, [], Config1) of
        {ok, Unknown, Config2} ->
            Times = {
                nksip_lib:get_value(nksip_timers_se, Config2),
                nksip_lib:get_value(nksip_timers_min_se, Config2)
            },
            Cached1 = nksip_lib:get_value(cached_configs, Config2, []),
            Cached2 = nksip_lib:store_value(config_nksip_timers, Times, Cached1),
            Config3 = nksip_lib:store_value(cached_configs, Cached2, Config2),
            {ok, Unknown, Config3};
        {error, Error} ->
            {error, Error}
    end.