%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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
-export([get/1, get/2, put/2, del/1]).
-export([profile_output/0]).

-include("nksip.hrl").

-compile({no_auto_import, [get/1, put/2]}).

-define(APP, nksip).
-define(RE_CALL_ID, "\r\n\s*(i|call\-id)\s*:\s*(.*?)\s*\r\n").
-define(RE_CONTENT_LENGTH, "\r\n\s*(l|content-length)\s*:\s*(.*?)\s*\r\n").
-define(MINUS_CSEQ, 46111468).  % Generate lower values to debug


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts NkSIP stand alone.
-spec start() -> 
    ok | {error, Reason::term()}.

start() ->
    case nklib_util:ensure_all_started(?APP, permanent) of
        {ok, _Started} ->
            ok;
        Error ->
            Error
    end.

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
    Syntax1 = #{
        sync_call_time => {integer, 1, none},
        dns_cache_ttl => {integer, 5, none},
        local_data_path => binary,
        global_max_calls => {integer, 1, 1000000},
        global_max_connections => {integer, 1, 1000000},
        msg_routers => {integer, 1, 127}
    },
    Syntax2 = maps:merge(Syntax1, nksip_util:syntax()),
    Defaults1 = #{
        sync_call_time => 30,               % Secs
        dns_cache_ttl => 3600,              % (secs) 1 hour
        local_data_path => "log",           % To store UUID
        global_max_calls => 100000,          % Each Call-ID counts as a call
        global_max_connections => 1024,     % 
        msg_routers => 16                   % Number of parallel msg routers 
    },
    Defaults2 = maps:merge(Defaults1, nksip_util:defaults()),
    case nklib_config:load_env(?APP, ?APP, Syntax2, Defaults2) of
        {ok, Parsed} ->
            file:make_dir(get(local_data_path)),
            put(global_id, nklib_util:luid()),
            put(sync_call_time, 1000*get(sync_call_time)),
            put(re_call_id, element(2, re:compile(?RE_CALL_ID, [caseless]))),
            put(re_content_length, 
                    element(2, re:compile(?RE_CONTENT_LENGTH, [caseless]))),
            SipKeys = maps:keys(nksip_util:syntax()),
            SipDef = nklib_util:extract(Parsed, SipKeys),
            put(sip_defaults, SipDef),
            CacheKeys = [
                global_id, re_call_id, re_content_length, sip_defaults 
                | maps:keys(Syntax1)],
            nklib_config:make_cache(CacheKeys, ?APP, none, 
                                    nksip_config_cache, get(local_data_path)),
            ok = nkpacket_config:register_protocol(sip, nksip_protocol),
            ok = nkpacket_config:register_protocol(sips, nksip_protocol),
            {ok, Pid} = nksip_sup:start_link(),
            put(current_cseq, nksip_util:initial_cseq()-?MINUS_CSEQ),
            MainIp = nkpacket_config_cache:main_ip(),
            MainIp6 = nkpacket_config_cache:main_ip6(),
            {ok, Vsn} = application:get_key(nksip, vsn),
            lager:notice("NkSIP v~s has started. Main IP is ~s (~s)", 
                         [Vsn, nklib_util:to_host(MainIp), nklib_util:to_host(MainIp6)]),
            {ok, Pid};
        {error, Error} ->
            lager:error("Error parsing config: ~p", [Error]),
            error(Error)
    end.



%% @private OTP standard stop callback
stop(_) ->
    ok.


%% @doc gets a configuration value
get(Key) ->
    get(Key, undefined).


%% @doc gets a configuration value
get(Key, Default) ->
    nklib_config:get(?APP, Key, Default).


%% @doc updates a configuration value
put(Key, Value) ->
    nklib_config:put(?APP, Key, Value).


%% @doc updates a configuration value
del(Key) ->
    nklib_config:del(?APP, Key).

%% @private
-spec profile_output() -> 
    ok.

profile_output() ->
    eprof:stop_profiling(),
    % eprof:log("nksip_procs.profile"),
    % eprof:analyze(procs),
    eprof:log("nksip.profile"),
    eprof:analyze(total).

