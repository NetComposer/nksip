
%% -------------------------------------------------------------------
%%
%% basic_test: Basic Test Suite
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

-module(all_test).

-include_lib("eunit/include/eunit.hrl").


all_test_() ->
    {inorder, [
        t01_basic:basic_gen(),
        t02_core:core_gen(),
        t03_uac:uac_gen(),
        t04_uas:uas_gen(),
        t05_torture1:torture1_gen(),
        t06_torture2:torture2_gen(),
        t07_torture3:torture3_gen(),
        t08_register:register_gen(),
        t09_invite:invite_gen(),
        t10_proxy:stateful_gen(),
        t10_proxy:stateful_gen(),
        t11_fork:fork_gen(),
        t12_update:update_gen(),
        t13_auth:auth_gen(),
        t13_auth:auth2_gen(),
        t14_event:event_gen(),
        t15_gruu:gruu_gen(),
        t16_publish:publish_gen(),
        t17_prack:prack_gen(),
        t18_path:path_gen(),
        t19_refer:refer_gen(),
        t20_timers:timer_gen(),
        t21_outbound:outbound_gen(),
        t22_ipv6:ipv6_gen(),
        t23_websocket:ws_gen(),
        t24_sctp:sctp_gen()
    ]}.


