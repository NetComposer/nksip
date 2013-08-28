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

	{ok, 200} = nksip_uac:options(client2, "sip:127.0.0.1:5070", []),
	{ok, 407} = nksip_uac:options(client1, "sip:127.0.0.1", []),
	
	{ok, 200} = nksip_uac:options(client1, "sip:127.0.0.1", 
									[{pass, "1234"}]),
	{ok, 200} = nksip_uac:options(client2, "<sip:127.0.0.1;transport=tls>",
									[{pass, "1234"}]),

	{ok, 200} = nksip_uac:register(client1, "sip:127.0.0.1",
									[{pass, "1234"}, make_contact]),
	{ok, 200} = nksip_uac:register(client2, "<sip:127.0.0.1;transport=tls>",
									[{pass, "1234"}, make_contact]),
	
	{reply, Resp1} = nksip_uac:register(client2, "<sip:127.0.0.1;transport=tls>",
									[{pass, "1234"}, full_response]),
	200 = nksip_response:code(Resp1),
	[<<"<sips:client2@", _/binary>>] = nksip_response:headers(<<"Contact">>, Resp1),

	{ok, 200} = nksip_uac:options(client1, "sip:127.0.0.1", []),
	{ok, 200} = nksip_uac:options(client2, "<sip:127.0.0.1;transport=tls>", []),
	
	{ok, 407} = nksip_uac:options(client1, "sips:client2@nksip", 
										[{route, "<sip:127.0.0.1;lr>"}]),
	{reply, Resp2} = nksip_uac:options(client1, "sips:client2@nksip", 
										[{route, "<sip:127.0.0.1;lr>"}, full_response,
										 {pass, "1234"}]),
	200 = nksip_response:code(Resp2),
	[<<"client2">>] = nksip_response:headers(<<"Nksip-Id">>, Resp2),
	
	{reply, Resp3} = nksip_uac:options(client2, "sip:client1@nksip", 
										[{route, "<sips:127.0.0.1;lr>"}, full_response]),
	200 = nksip_response:code(Resp3),
	[<<"client1">>] = nksip_response:headers(<<"Nksip-Id">>, Resp3),


	{ok, 488, _} = nksip_uac:invite(client2, "sip:client1@nksip", 
									 [{route, "<sips:127.0.0.1;lr>"}]),
	{ok, 200, Dialog1} = nksip_uac:invite(client2, "sip:client1@nksip", 
											[{route, "<sips:127.0.0.1;lr>"}, 
											 {body, nksip_sdp:new()}]),
	ok = nksip_uac:ack(Dialog1, []),
	{ok, 200} = nksip_uac:bye(Dialog1, []),

	{ok, _} = nksip:call(server, get_started),
	nksip:stop_all(),
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
