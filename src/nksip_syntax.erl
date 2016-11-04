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

-export([app_syntax/0, app_defaults/0, syntax/0]).
-export([default_allow/0, default_supported/0]).
-export([make_config/1]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-define(UDP_MAX_SIZE, 1300).

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
        sip_listen => fun nkservice_syntax:parse_fun_listen/3,
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
        sip_local_host6 => [{enum, [auto]}, host6],
        sip_debug => boolean,                           % Needs to be always defined
        sip_udp_max_size => nat_integer                 % Used for all sent packets
    }.


default_allow() ->
    [
        <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
        <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
        <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>
    ].


default_supported() ->
    [<<"path">>].


make_config(Data) ->
    Times = #call_times{
        t1 = maps:get(sip_timer_t1, Data, 500),
        t2 = maps:get(sip_timer_t2, Data, 4000),
        t4 = maps:get(sip_timer_t4, Data, 5000),
        tc = maps:get(sip_timer_c, Data, 180),
        trans = maps:get(sip_trans_timeout, Data, 900),
        dialog = maps:get(sip_dialog_timeout, Data, 1800)
    },
    #config{
        debug = maps:get(sip_debug, Data, false),
        allow = maps:get(sip_allow, Data, default_allow()),
        supported = maps:get(sip_supported, Data, default_supported()),
        event_expires = maps:get(sip_event_expires, Data, 60),
        event_expires_offset = maps:get(sip_event_expires_offset, Data, 5),
        nonce_timeout = maps:get(sip_nonce_timeout, Data, 30),
        from = maps:get(sip_from, Data, undefined),
        accept = maps:get(sip_accept, Data, undefined),
        events = maps:get(sip_events, Data, []),
        route = maps:get(sip_route, Data, []),
        no_100 = maps:get(sip_no_100, Data, false),
        max_calls = maps:get(sip_max_calls, Data, 100000),
        local_host = maps:get(sip_local_host, Data, auto),
        local_host6 = maps:get(sip_local_host6, Data, auto),
        times = Times,
        udp_max_size = maps:get(sip_udp_max_size, Data, ?UDP_MAX_SIZE)
    }.

