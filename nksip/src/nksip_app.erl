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

%% @doc NkSIP OTP Application Module
-module(nksip_app).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(application).

-export([start/0, start/2, stop/1]).
-export([profile_output/0]).

-include("nksip.hrl").



%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts NkSIP stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case application:load(nksip) of
        ok -> ok;
        {error, {already_loaded, nksip}} -> ok
    end,
    {ok, DepApps} = application:get_key(nksip, applications),
    ensure_started(DepApps),
    application:start(nksip).


%% @private OTP standard start callback
start(_Type, _Args) ->
    % application:set_env(nksip, profile, true),
    case application:get_env(nksip, profile) of
        {ok, true} ->
            {ok, _Pid} = eprof:start(),
            eprof:start_profiling([self()]);
        _ ->
            ok
    end,
    {ok, Pid} = nksip_sup:start_link(),
    nksip_config:put(global_id, nksip_lib:luid()),
    nksip_config:put(local_ips, nksip_lib:get_local_ips()),
    MainIp = nksip_lib:find_main_ip(),
    nksip_config:put(main_ip, MainIp),
    {ok, Vsn} = application:get_key(nksip, vsn),
    lager:notice("NkSIP v~s has started. Main IP is ~s", 
                    [Vsn, nksip_lib:to_binary(MainIp)]),
    {ok, Pid}.


%% @private OTP standard stop callback
stop(_) ->
    ok.


%% @private
ensure_started([App|R]) ->
    case application:start(App) of
        ok -> ensure_started(R);
        {error, {already_started, App}} -> ensure_started(R)
    end;
ensure_started([]) ->
    ok.
   

%% @private
-spec profile_output() -> 
    ok.

profile_output() ->
    eprof:stop_profiling(),
    % eprof:log("nksip_procs.profile"),
    % eprof:analyze(procs),
    eprof:log("nksip.profile"),
    eprof:analyze(total).




