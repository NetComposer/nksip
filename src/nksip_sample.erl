%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Companion code for NkSIP Tutorial.


-module(nksip_sample).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0]).
-export([s1/0]).

-define(NAME, test).



%% @doc Launches the full tutorial.
start() ->
    Spec = #{
        callback => ?MODULE,
        sip_debug => [nkpacket, call, protocol]

    },
    nksip:start(?NAME, Spec).



stop() ->
    nksip:stop(?NAME).


s1() ->
    nksip_uac:options(?NAME, <<"sip1">>, "<sip:carlosj.sip.us1.twilio.com>;transport=tcp", []).