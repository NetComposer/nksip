%% -------------------------------------------------------------------
%%
%% path_test: Path (RFC3327) Tests
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

-module(t18_path).
-include_lib("nklib/include/nklib.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").
-include_lib("nksip/include/nksip_registrar.hrl").

-compile([export_all, nowarn_export_all]).

path_gen() ->
    {setup, spawn,
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0
        ]
    }.

% This configuration resembles the example in RFC3327
start() ->
    ?debugFmt("\n\nStarting ~p\n\n", [?MODULE]),
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(path_test_p1, #{
        sip_local_host => "localhost",
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }),

    {ok, _} = nksip:start_link(path_test_p2, #{
        sip_local_host => "localhost",
        sip_listen => "<sip:all:5070>, <sip:all:5071;transport=tls>"
    }),

    {ok, _} = nksip:start_link(path_test_p3, #{
        sip_local_host => "localhost",
        sip_listen => "<sip:all:5080>,<sip:all:5081;transport=tls>"
    }),

    {ok, _} = nksip:start_link(path_test_registrar, #{
        sip_local_host => "localhost",
        plugins => [nksip_registrar],
        sip_listen => "<sip:all:5090>, <sip:all:5091;transport=tls>"
    }),

    {ok, _} = nksip:start_link(path_test_ua1, #{
        sip_from => "sip:path_test_ua1@nksip",
        sip_route => "<sip:127.0.0.1;lr>",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all, <sip:all;transport=tls>"
    }),

    {ok, _} = nksip:start_link(path_test_ua2, #{
        sip_route => "<sip:127.0.0.1:5090;lr>",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all, <sip:all;transport=tls>"
    }),

    timer:sleep(1000),
    ok.


stop() ->
    ok = nksip:stop(path_test_p1),
    ok = nksip:stop(path_test_p2),
    ok = nksip:stop(path_test_p3),
    ok = nksip:stop(path_test_registrar),
    ok = nksip:stop(path_test_ua1),
    ok = nksip:stop(path_test_ua2),
    ?debugFmt("Stopping ~p", [?MODULE]),
    timer:sleep(500),
    ok.


basic() ->
    nksip_registrar:clear(path_test_registrar),
    
    % We didn't send the Supported header, so first proxy 
    % (P1, configured to include Path) sends a 421 (Extension Required)
    {ok, 421, [{<<"require">>, [<<"path">>]}]} = 
        nksip_uac:register(path_test_ua1, "sip:nksip", [{get_meta,[<<"require">>]}, {supported, ""}]),

    % If the request arrives at registrar, having a valid Path header and
    % no Supported: path, it returns a 420 (Bad Extension)
    {ok, 420, [{<<"unsupported">>, [<<"path">>]}]} = 
        nksip_uac:register(path_test_ua1, "<sip:nksip?Path=sip:mypath>",
                        [{route, "<sip:127.0.0.1:5090;lr>"}, 
                         {get_meta, [<<"unsupported">>]}, {supported, ""}]),


    {ok, 200, [{<<"path">>, Path}]} = 
        nksip_uac:register(path_test_ua1, "sip:nksip", [supported, contact, {get_meta, [<<"path">>]}]),
    [P1, P2] = nklib_parse:uris(Path),

    
    [#reg_contact{
        contact = #uri{scheme = sip,user = <<"path_test_ua1">>,domain = <<"127.0.0.1">>},
        path = [
            #uri{scheme = sip,domain = <<"localhost">>,port = 5080,
                    opts = [<<"lr">>]} = P1Uri,
            #uri{scheme = sip,domain = <<"localhost">>,port = 5061,
                    opts = [{<<"transport">>,<<"tls">>}, <<"lr">>]} = P2Uri
        ]
    }] = nksip_registrar_lib:get_info(path_test_registrar, sip, <<"path_test_ua1">>, <<"nksip">>),

    P1 = P1Uri,
    P2 = P2Uri,

    % Now, if send a request to UA1, the registrar inserts the stored path
    % as routes, and requests pases throw P3, P1 and to UA1
    {ok, 200, [{_, [<<"path_test_ua1,path_test_p1,path_test_p3">>]}]} =
        nksip_uac:options(path_test_ua2, "sip:path_test_ua1@nksip", [{get_meta,[<<"x-nk-id">>]}]),
    ok.

