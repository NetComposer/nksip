%% -------------------------------------------------------------------
%%
%% outbound_test: Path (RFC5626) Tests
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

-module(outbound_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

% path_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             fun basic/0
%         ]
%     }.

start() ->
    tests_util:start_nksip(),

    % ok = path_server:start({outbound, p1}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5060}},
    %     {transport, {tls, {0,0,0,0}, 5061}}]),

    % ok = path_server:start({outbound, p2}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5070}},
    %     {transport, {tls, {0,0,0,0}, 5071}}]),

    % ok = path_server:start({outbound, p3}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5080}},
    %     {transport, {tls, {0,0,0,0}, 5081}}]),

    ok = path_server:start({outbound, registrar}, [
        registrar,
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}}
        % {transport, {sctp, {0,0,0,0}, 5060}}
    ]),

    ok = sipapp_endpoint:start({outbound, ua1}, [
        {from, "sip:ua1@nksip"},
        % {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}
        % {transport, {sctp, {0,0,0,0}, 0}}
    ]),

    ok = sipapp_endpoint:start({outbound, ua2}, [
        % {route, "<sip:127.0.0.1:5090;lr>"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5080}},
        {transport, {tls, {0,0,0,0}, 5081}}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    % ok = sipapp_server:stop({outbound, p1}),
    % ok = sipapp_server:stop({outbound, p2}),
    % ok = sipapp_server:stop({outbound, p3}),
    ok = sipapp_server:stop({outbound, registrar}),
    ok = sipapp_endpoint:stop({outbound, ua1}),
    ok = sipapp_endpoint:stop({outbound, ua2}).


basic() ->
    C1 = {outbound, ua1},
    C2 = {outbound, ua2},
    R1 = {outbound, registrar},
    nksip_registrar:clear(R1),
    
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},
    % RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    % {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", 
    %                                     [make_contact, CB, get_request]),
    % receive 
    %     {Ref, #sipmsg{contacts=[#uri{opts=Opts1}]}} ->
    %         true = lists:member(<<"ob">>, Opts1)
    % after 1000 ->
    %     error(basic)
    % end,
  
    % {ok, 200, []} = nksip_uac:options(C1, "sip:127.0.0.1", 
    %                                     [make_contact, CB, get_request, 
    %                                      {supported, "path"}]),
    % receive 
    %     {Ref, #sipmsg{contacts=[#uri{opts=Opts2}]}} ->
    %         false = lists:member(<<"ob">>, Opts2)
    % after 1000 ->
    %     error(basic)
    % end,

    



    ok.

%     % We didn't send the Supported header, so first proxy 
%     % (P1, configured to include Path) sends a 421 (Extension Required)
%     {ok, 421, [{<<"Require">>, [<<"path">>]}]} = 
%         nksip_uac:register(C1, "sip:nksip", [{fields, [<<"Require">>]}]),

%     % If the request arrives at registrar, having a valid Path header and
%     % no Supported: path, it returns a 420 (Bad Extension)
%     {ok, 420, [{<<"Unsupported">>, [<<"path">>]}]} = 
%         nksip_uac:register(C1, "<sip:nksip?Path=sip:mypath>", 
%                         [{route, "<sip:127.0.0.1:5090;lr>"}, 
%                          {fields, [<<"Unsupported">>]}]),


%     {ok, 200, [{<<"Path">>, [P1, P2]}]} = 
%         nksip_uac:register(C1, "sip:nksip", 
%                         [make_supported, make_contact, {fields, [<<"Path">>]}]),

%     [#reg_contact{
%         contact = #uri{scheme = sip,user = <<"ua1">>,domain = <<"127.0.0.1">>},
%         path = [
%             #uri{scheme = sip,domain = <<"localhost">>,port = 5080,
%                     opts = [<<"lr">>]} = P1Uri,
%             #uri{scheme = sip,domain = <<"localhost">>,port = 5061,
%                     opts = [<<"lr">>,{<<"transport">>,<<"tls">>}]} = P2Uri
%         ]
%     }] = nksip_registrar:get_info({outbound, registrar}, sip, <<"ua1">>, <<"nksip">>),

%     P1 = nksip_unparse:uri(P1Uri),
%     P2 = nksip_unparse:uri(P2Uri),


%     % Now, if send a request to UA1, the registrar inserts the stored path
%     % as routes, and requests pases throw P3, P1 and to UA1
%     {ok, 200, [{_, [<<"ua1,p1,p3">>]}]} = 
%         nksip_uac:options(C2, "sip:ua1@nksip", [{fields, [<<"Nk-Id">>]}]),
%     ok.



