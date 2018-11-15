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
    AppSyntax = nksip_syntax:app_syntax(),
    ServiceSyntax = nksip_syntax:syntax(),
    Syntax = maps:merge(AppSyntax, ServiceSyntax),
    % Defaults = maps:merge(nksip_syntax:app_defaults(), nksip_syntax:defaults()),
    Defaults = nksip_syntax:app_defaults(),
    case nklib_config:load_env(?APP, Syntax, Defaults) of
        {ok, Parsed} ->
            put(global_id, nklib_util:luid()),
            {ok, ReCallId} = re:compile(?RE_CALL_ID, [caseless]),
            put(re_call_id, ReCallId),
            {ok, ReCL} = re:compile(?RE_CONTENT_LENGTH, [caseless]),
            put(re_content_length, ReCL),
            ServiceKeys = maps:keys(ServiceSyntax),
            ServiceDefaults = nklib_util:extract(Parsed, ServiceKeys),
            put(sip_defaults, ServiceDefaults),
            CacheKeys = [
                global_id, re_call_id, re_content_length, sip_defaults 
                | maps:keys(nksip_syntax:app_syntax())],
            DataPath = nkservice_app:get(log_path),
            nklib_config:make_cache(CacheKeys, ?APP, none, 
                                    nksip_config_cache, DataPath),
            ok = nkpacket:register_protocol(sip, nksip_protocol),
            ok = nkpacket:register_protocol(sips, nksip_protocol),
            {ok, Pid} = nksip_sup:start_link(),
            put(current_cseq, nksip_util:initial_cseq()-?MINUS_CSEQ),
            {ok, Vsn} = application:get_key(nksip, vsn),
            lager:info("NkSIP v~s has started", [Vsn]),
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

