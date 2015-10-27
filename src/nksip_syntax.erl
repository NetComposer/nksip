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

%% @doc Syntax definitions
-module(nksip_syntax).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([app_syntax/0, app_defaults/0, syntax/0, defaults/0, cached/0]).


%% ===================================================================
%% Internal
%% ===================================================================

app_syntax() ->
    #{
        sync_call_time => nat_integer,
        max_calls => {integer, 1, 1000000},
        msg_routers => {integer, 1, 127}
    }.


app_defaults() ->
    #{
        sync_call_time => 30000,            % MSecs
        max_calls => 100000,                % Each Call-ID counts as a call
        msg_routers => 16                   % Number of parallel msg routers 
    }.
    

%% @private
%% Transport options must be included in url
syntax() ->
    #{
        sip_allow => words,
        sip_supported => words,
        sip_timer_t1 => {integer, 10, 2500},
        sip_timer_t2 => {integer, 100, 16000},
        sip_timer_t4 => {integer, 100, 25000},
        sip_timer_c => {integer, 1, none},
        sip_trans_timeout => {integer, 5, none},
        sip_dialog_timeout => {integer, 5, none},
        sip_event_expires => {integer, 1, none},
        sip_event_expires_offset => {integer, 0, none},
        sip_nonce_timeout => {integer, 5, none},
        sip_from => [{enum, [undefined]}, uri],
        sip_accept => [{enum, [undefined]}, words],
        sip_events => words,
        sip_route => uris,
        sip_no_100 => boolean,
        sip_max_calls => {integer, 1, 1000000},
        sip_local_host => [{enum, [auto]}, host],
        sip_local_host6 => [{enum, [auto]}, host6]
    }.



%% @private
defaults() ->
    #{
        sip_allow => [
            <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
            <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
            <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>],
        sip_supported => [<<"path">>],
        sip_timer_t1 => 500,                    % (msecs) 0.5 secs
        sip_timer_t2 => 4000,                   % (msecs) 4 secs
        sip_timer_t4 => 5000,                   % (msecs) 5 secs
        sip_timer_c =>  180,                    % (secs) 3min
        sip_trans_timeout => 900,               % (secs) 15 min
        sip_dialog_timeout => 1800,             % (secs) 30 min
        sip_event_expires => 60,                % (secs) 1 min
        sip_event_expires_offset => 5,          % (secs) 5 secs
        sip_nonce_timeout => 30,                % (secs) 30 secs
        sip_from => undefined,
        sip_accept => undefined,
        sip_events => [],
        sip_route => [],
        sip_no_100 => false,
        sip_max_calls => 100000,                % Each Call-ID counts as a call
        sip_local_host => auto,
        sip_local_host6 => auto
    }.


%% @private
cached() ->
    [
        sip_accept, sip_allow, sip_debug, sip_dialog_timeout, 
        sip_event_expires, sip_event_expires_offset, sip_events, 
        sip_from, sip_max_calls, sip_no_100, sip_nonce_timeout, 
        sip_route, sip_supported, sip_trans_timeout,
        sip_local_host, sip_local_host6
    ].
