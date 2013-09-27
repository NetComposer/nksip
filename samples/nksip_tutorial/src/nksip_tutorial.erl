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

%% @doc Companion code for NkSIP Tutorial.


-module(nksip_tutorial).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([launch/0, trace/1, loglevel/1]).

%% @doc Launches the full tutorial.
launch() ->
	nksip:start(server, nksip_tutorial_sipapp_server, [server], 
		[
			registrar, 
		 	{transport, {udp, {0,0,0,0}, 5060}}, 
		 	{transport, {tls, {0,0,0,0}, 5061}}
		 ]),

	nksip:start(client1, nksip_tutorial_sipapp_client, [client1], 
		[
			{from, "sip:client1@nksip"},
		 	{transport, {udp, {127,0,0,1}, 5070}}, 
		 	{transport, {tls, {127,0,0,1}, 5071}}
		]),
	nksip:start(client2, nksip_tutorial_sipapp_client, [client2], 
		[{from, "sips:client2@nksip"}]),

	trace(false),

	{ok, 200, _} = nksip_uac:options(client2, "sip:127.0.0.1:5070", []),
	{ok, 407, _} = nksip_uac:options(client1, "sip:127.0.0.1", []),
	
	{ok, 200, _} = nksip_uac:options(client1, "sip:127.0.0.1", 
									[{pass, "1234"}]),
	{ok, 200, _} = nksip_uac:options(client2, "sip:127.0.0.1;transport=tls", 
									[{pass, "1234"}]),

	{ok, 200, _} = nksip_uac:register(client1, "sip:127.0.0.1", 
									[{pass, "1234"}, make_contact]),
	{ok, 200, _} = nksip_uac:register(client2, "sip:127.0.0.1;transport=tls", 
									[{pass, "1234"}, make_contact]),
	
	{ok, 200, Resp1} = nksip_uac:register(client2, "sip:127.0.0.1;transport=tls", 
									[{pass, "1234"}]),
	[<<"<sips:client2@", _/binary>>] = nksip_response:header(Resp1, <<"Contact">>),

	{ok, 200, _} = nksip_uac:options(client1, "sip:127.0.0.1", []),
	{ok, 200, _} = nksip_uac:options(client2, "sip:127.0.0.1;transport=tls", []),
	
	{ok, 407, _} = nksip_uac:options(client1, "sips:client2@nksip", 
										[{route, "sip:127.0.0.1;lr"}]),
	{ok, 200, Resp2} = nksip_uac:options(client1, "sips:client2@nksip", 
										[{route, "sip:127.0.0.1;lr"}, {pass, "1234"}]),
	[<<"client2">>] = nksip_response:header(Resp2, <<"Nksip-Id">>),
	
	{ok, 200, Resp3} = nksip_uac:options(client2, "sip:client1@nksip", 
										[{route, "sips:127.0.0.1;lr"}]),
	[<<"client1">>] = nksip_response:header(Resp3, <<"Nksip-Id">>),

	{ok, 488, _} = nksip_uac:invite(client2, "sip:client1@nksip", 
									 [{route, "sips:127.0.0.1;lr"}]),
	{ok, 200, Resp4} = nksip_uac:invite(client2, "sip:client1@nksip", 
											[{route, "sips:127.0.0.1;lr"}, 
											 {body, nksip_sdp:new()}]),
	{req, _} = nksip_uac:ack(Resp4, []),
	{ok, 200, _} = nksip_uac:bye(Resp4, []),

	{ok, _} = nksip:call(server, get_started),
	ok = nksip:stop(client1),
	ok = nksip:stop(client2),
	ok = nksip:stop(server),
	ok.


%% ===================================================================
%% Utilities
%% ===================================================================

%% @doc Enables SIP trace messages to console.
-spec trace(Start::boolean()) -> ok.

trace(true) ->  nksip_trace:start();
trace(false) -> nksip_trace:stop().


%% @doc Changes console log level.
%% Availanle options are `debug' (maximum), `info' (medium) and `notice' (minimum).
-spec loglevel(debug|info|notice) -> ok.

loglevel(Level) -> lager:set_loglevel(lager_console_backend, Level).
