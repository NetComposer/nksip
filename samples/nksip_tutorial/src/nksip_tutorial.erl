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
    ok = nksip:start(server, nksip_tutorial_sipapp_server, [server], 
        [
            registrar, 
            {transport, {udp, any, 5060}}, 
            {transport, {tls, any, 5061}}
         ]),
    ok = nksip:start(client1, nksip_tutorial_sipapp_client, [client1], 
        [
            {from, "sip:client1@nksip"},
            {transport, {udp, {127,0,0,1}, 5070}}, 
            {transport, {tls, {127,0,0,1}, 5071}}
        ]),
    ok = nksip:start(client2, nksip_tutorial_sipapp_client, [client2], 
        [   {from, "sips:client2@nksip"},
            {transport, {udp, {127,0,0,1}, 5080}}, 
            {transport, {tls, {127,0,0,1}, 5081}}
        ]),

    {ok,200,[]} = nksip_uac:options(client2, "sip:127.0.0.1:5070", []),
    {ok,407,[{reason_phrase,<<"Proxy Authentication Required">>}]} =
        nksip_uac:options(client1, "sip:127.0.0.1", [{fields, [reason_phrase]}]),

    {ok,200,[]} = nksip_uac:options(client1, "sip:127.0.0.1", [{pass, "1234"}]),
    {ok,200,[]} = nksip_uac:options(client2, "<sip:127.0.0.1;transport=tls>", [{pass, "1234"}]),

    {ok,200,[{<<"Contact">>, [<<"<sip:client1@127.0.0.1:5070>;expires=3600">>]}]} = 
        nksip_uac:register(client1, "sip:127.0.0.1", 
                           [{pass, "1234"}, make_contact, {fields, [<<"Contact">>]}]),

    {ok,200,[]} = nksip_uac:register(client2, "sips:127.0.0.1", [{pass, "1234"}, make_contact]),

    {ok,200,[{all_headers, _}]} = 
        nksip_uac:register(client2, "sips:127.0.0.1", [{pass, "1234"}, {fields, [all_headers]}]),

    {ok,200,[]} = nksip_uac:options(client1, "sip:127.0.0.1", []),
    {ok,200,[]} = nksip_uac:options(client2, "sips:127.0.0.1", []),

    {ok,407,[]} = nksip_uac:options(client1, "sips:client2@nksip", [{route, "<sip:127.0.0.1;lr>"}]),
    {ok,200,[{<<"Nksip-Id">>, [<<"client2">>]}]} = 
        nksip_uac:options(client1, "sips:client2@nksip", 
                          [{route, "<sip:127.0.0.1;lr>"}, {pass, "1234"},
                           {fields, [<<"Nksip-Id">>]}]),

    {ok,488,[{dialog_id, _}]} = 
        nksip_uac:invite(client2, "sip:client1@nksip", [{route, "<sips:127.0.0.1;lr>"}]),

    {ok,200,[{dialog_id, DlgId}]}= 
        nksip_uac:invite(client2, "sip:client1@nksip", 
                        [{route, "<sips:127.0.0.1;lr>"}, {body, nksip_sdp:new()}]),
    ok = nksip_uac:ack(client2, DlgId, []),

    confirmed = nksip_dialog:field(client2, DlgId, status),
    [_, _, _] = nksip_dialog:get_all_data(),

    {ok,200,[]} = nksip_uac:bye(client2, DlgId, []),
    ok = nksip:stop_all().



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
