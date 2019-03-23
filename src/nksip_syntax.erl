%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([app_syntax/0]).
-export([default_allow/0, default_supported/0]).
-export([make_config/1]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-define(UDP_MAX_SIZE, 1300).

%% ===================================================================
%% Internal
%% ===================================================================


%% @private
%% Transport options must be included in url
app_syntax() ->
    Syntax = #{
        sip_listen => binary,
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
        sip_from => [{atom, [undefined]}, uri],
        sip_accept => [{atom, [undefined]}, words],
        sip_events => words,
        sip_route => uris,
        sip_no_100 => boolean,
        sip_max_calls => {integer, 1, 1000000},
        sip_local_host => [{atom, [auto]}, host],
        sip_local_host6 => [{atom, [auto]}, host6],
        sip_debug => {list, atom},                      % nkpacket, call, protocol
        sip_udp_max_size => nat_integer                 % Used for all sent packets
    },
    nkpacket_syntax:tls_syntax(Syntax).


default_allow() ->
    [
        <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
        <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
        <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>
    ].


default_supported() ->
    [<<"path">>].


make_config(Config) ->
    Times = #call_times{
        t1 = maps:get(sip_timer_t1, Config, 500),
        t2 = maps:get(sip_timer_t2, Config, 4000),
        t4 = maps:get(sip_timer_t4, Config, 5000),
        tc = maps:get(sip_timer_c, Config, 180),
        trans = maps:get(sip_trans_timeout, Config, 900),
        dialog = maps:get(sip_dialog_timeout, Config, 1800)
    },
    #config{
        debug = maps:get(sip_debug, Config, []),
        allow = maps:get(sip_allow, Config, default_allow()),
        supported = maps:get(sip_supported, Config, default_supported()),
        event_expires = maps:get(sip_event_expires, Config, 60),
        event_expires_offset = maps:get(sip_event_expires_offset, Config, 5),
        nonce_timeout = maps:get(sip_nonce_timeout, Config, 30),
        from = maps:get(sip_from, Config, undefined),
        accept = maps:get(sip_accept, Config, undefined),
        events = maps:get(sip_events, Config, []),
        route = maps:get(sip_route, Config, []),
        no_100 = maps:get(sip_no_100, Config, false),
        max_calls = maps:get(sip_max_calls, Config, 100000),
        local_host = maps:get(sip_local_host, Config, auto),
        local_host6 = maps:get(sip_local_host6, Config, auto),
        times = Times,
        udp_max_size = maps:get(sip_udp_max_size, Config, ?UDP_MAX_SIZE)
    }.

