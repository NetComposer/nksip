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

-module(nksip_pbx).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/0, stop/0]).
-export([check_speed/1, get_speed/0, trace/1, loglevel/1]).

%% ===================================================================
%% Start & Stop
%% ===================================================================


%% @doc Starts a new Service, listening on port 5060 for udp and tcp and 5061 for tls,
%% and acting as a registrar.
start() ->
    {ok, _} = nksip:start(pbx, #{
        callback => ?MODULE,
        plugins => [nksip_registrar, nksip_100rel, nksip_gruu,
                    nksip_outbound, nksip_timers],
        sip_listen => "<sip:all:5060>, <sip:all:5061;transport=tls>"
    }),
    ok.


%% @doc Stops the Service.
stop() ->
    nksip:stop(pbx).



%% ===================================================================
%% Utilities
%% ===================================================================

%% @doc Stops or restart automatic response time detection.
check_speed(Bool) ->
    nkservice:cast(pbx, {check_speed, Bool}).


%% @doc Get all registered endpoints with their last respnse time.
get_speed() ->
    nkservice:call(pbx, get_speed).


%% @doc Enables SIP trace messages to console.
-spec trace(Start::boolean()) -> ok.

trace(true) ->  
	nksip_trace:start();
trace(false) -> 
	nksip_trace:stop().


%% @doc Changes console log level.
%% Availanle options are `debug' (maximum), `info' (medium) and `notice' (minimum).
-spec loglevel(debug|info|notice) -> ok.

loglevel(Level) -> 
	nklib_log:console_loglevel(Level),
	ok = nksip:update(pbx, [{log_level, Level}]).



