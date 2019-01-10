%% -------------------------------------------------------------------
%%
%% auth_test: Authentication Tests
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

-module(t13_auth_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).

auth_test_() ->
  {setup, spawn, 
      fun() -> start() end,
      fun(_) -> stop() end,
      [
          fun digest/0, 
          fun invite/0, 
          fun dialog/0, 
          fun proxy/0
      ]
  }.


auth2_test_() ->
    {setup, spawn,
        fun() -> start(), force_tcp() end,
        fun(_) -> stop() end,
        [
            fun digest/0,
            fun invite/0,
            fun dialog/0,
            fun proxy/0
        ]
    }.


all() ->
    start(),
    lager:warning("Starting TEST ~p normal", [?MODULE]),
    timer:sleep(1000),
    digest(),
    invite(),
    dialog(),
    proxy(),
    stop(),

    timer:sleep(1000),
    start(),
    force_tcp(),
    lager:warning("Starting TEST ~p forced tcp", [?MODULE]),
    timer:sleep(1000),
    digest(),
    invite(),
    dialog(),
    proxy(),
    stop().



start() ->
    % It must work also with all sip_udp_max_size to 200

    tests_util:start_nksip(),
    {ok, _} = nksip:start_link(auth_test_server1, #{
        sip_from => "sip:auth_test_server1@nksip",
        sip_local_host => "localhost",
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060"
    }),

    {ok, _} = nksip:start_link(auth_test_server2, #{
        sip_from => "sip:auth_test_server2@nksip",
        sip_local_host => "localhost",
        sip_listen => "sip:all:5061"
    }),

    {ok, _} = nksip:start_link(auth_test_client1, #{
        sip_from => "sip:auth_test_client1@nksip",
        sip_local_host => "127.0.0.1",
        plugins => [nksip_uac_auto_auth],
        sip_listen => "sip:all:5070"
    }),
    
    {ok, _} = nksip:start_link(auth_test_client2, #{
        sip_from => "sip:auth_test_client2@nksip",
        sip_pass => ["jj", {"auth_test_client1", "4321"}],
        sip_local_host => "127.0.0.1",
        plugins => [nksip_uac_auto_auth],
        sip_listen => "sip:all:5071"
    }),

    {ok, _} = nksip:start_link(auth_test_client3, #{
        sip_from => "sip:auth_test_client3@nksip",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all:5072"
    }),
    
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


% For UDP-to-TCP for all requests
force_tcp() ->
    ok = nkserver:update(auth_test_server1, #{sip_udp_max_size => 200}),
    ok = nkserver:update(auth_test_server2, #{sip_udp_max_size => 200}),
    ok = nkserver:update(auth_test_client1, #{sip_udp_max_size => 200}),
    ok = nkserver:update(auth_test_client2, #{sip_udp_max_size => 200}).



stop() ->
    ok = nksip:stop(auth_test_server1),
    ok = nksip:stop(auth_test_server2),
    ok = nksip:stop(auth_test_client1),
    ok = nksip:stop(auth_test_client2),
    ok = nksip:stop(auth_test_client3).


digest() ->
    SipC1 = "sip:127.0.0.1:5070",
    SipC2 = "sip:127.0.0.1:5071",

    {ok, 401, []} = nksip_uac:options(auth_test_client1, SipC2, []),
    {ok, 200, []} = nksip_uac:options(auth_test_client1, SipC2, [{sip_pass, "1234"}]),
    {ok, 403, []} = nksip_uac:options(auth_test_client1, SipC2, [{sip_pass, "12345"}]),
    {ok, 200, []} = nksip_uac:options(auth_test_client1, SipC2, [{sip_pass, {"auth_test_client2", "1234"}}]),
    {ok, 403, []} = nksip_uac:options(auth_test_client1, SipC2, [{sip_pass, {"other", "1234"}}]),

    HA1 = nksip_auth:make_ha1("auth_test_client1", "1234", "auth_test_client2"),
    {ok, 200, []} = nksip_uac:options(auth_test_client1, SipC2, [{sip_pass, HA1}]),
    
    % Pass is invalid, but there is a valid one in Service's options
    {ok, 200, []} = nksip_uac:options(auth_test_client2, SipC1, []),
    {ok, 200, []} = nksip_uac:options(auth_test_client2, SipC1, [{sip_pass, "kk"}]),
    {ok, 403, []} = nksip_uac:options(auth_test_client2, SipC1, [{sip_pass, {"auth_test_client1", "kk"}}]),

    Self = self(),
    Ref = make_ref(),
    Fun = fun({resp, 200, _, _}) -> Self ! {Ref, digest_ok} end,
    {async, _} = nksip_uac:options(auth_test_client1, SipC2, [async, {callback, Fun}, {sip_pass, HA1}]),
    ok = tests_util:wait(Ref, [digest_ok]),
    ok.



invite() ->
    SipC3 = "sip:127.0.0.1:5072",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),

    % auth_test_client3 does not support dialog's authentication, only digest is used
    % (dialog would be ok if activated in client3 callback module as in client1)
    {ok, 401, [{cseq_num, CSeq}]} =
        nksip_uac:invite(auth_test_client1, SipC3, [{get_meta, [cseq_num]}]),
    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(auth_test_client1, SipC3,
                                             [{sip_pass, "abcd"}, RepHd]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{auth_test_client3, ack}]),
    {ok, 401, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId1, [{sip_pass, "abcd"}]),

    {ok, 401, _} = nksip_uac:invite(DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(DialogId1, [{sip_pass, "abcd"}]),

    FunAck = fun({req, ACK3, _Call}) ->
        {ok, AckCSeq} = nksip_request:get_meta(cseq_num, ACK3),
        Self ! {Ref, {ack_cseq, AckCSeq-8}}
    end,
    ok = nksip_uac:ack(DialogId1, [get_request, {callback, FunAck}]),
    ok = tests_util:wait(Ref, [{ack_cseq, CSeq}, {auth_test_client3, ack}]),

    % auth_test_client1 does support dialog's authentication
    DialogId3 = nksip_dialog_lib:remote_id(DialogId1, auth_test_client3),
    {ok, 200, [{cseq_num, CSeq2}]} =
        nksip_uac:options(DialogId3, [{get_meta, [cseq_num]}]),
    {ok, 200, [{dialog, DialogId3}]} =
        nksip_uac:invite(DialogId3, [RepHd]),
    ok = nksip_uac:ack(DialogId3, [RepHd]),
    ok = tests_util:wait(Ref, [{auth_test_client1, ack}]),
    {ok, 200, [{_, CSeq3}]} = nksip_uac:bye(DialogId3, [{get_meta, [cseq_num]}]),
    ok = tests_util:wait(Ref, [{auth_test_client1, bye}]),
    CSeq3 = CSeq2 + 2,
    ok.


dialog() ->
    SipC2 = "sip:127.0.0.1:5071",
    {Ref, RepHd} = tests_util:get_ref(),

    % Since udp_max_size is 200, it will retry all operations with tcp
    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(auth_test_client1, SipC2,
                                            [{sip_pass, "1234"}, RepHd]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{auth_test_client2, ack}]),

    [{_, {127,0,0,1}, 5071}] = nksip_dialog:get_authorized_list(DialogId1),

    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, auth_test_client2),
    [{_, {127,0,0,1}, _}] = nksip_dialog:get_authorized_list(DialogId2),

    {ok, 200, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),

    ok = nksip_dialog:clear_authorized_list(DialogId2),
    {ok, 401, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId1, [{sip_pass, "1234"}]),
    {ok, 200, []} = nksip_uac:options(DialogId1, []),

    ok = nksip_dialog:clear_authorized_list(DialogId1),
    [] = nksip_dialog:get_authorized_list(DialogId1),

    % Force an invalid password, because the Service config has a valid one
    {ok, 403, []} = nksip_uac:options(DialogId2, [{sip_pass, {"auth_test_client1", "invalid"}}]),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, []} = nksip_uac:options(DialogId2, [{sip_pass, {"auth_test_client1", "invalid"}}]),

    {ok, 200, []} = nksip_uac:bye(DialogId1, []),
    ok = tests_util:wait(Ref, [{auth_test_client2, bye}]),
    ok.


p() ->
    S1 = "sip:127.0.0.1",
    {Ref, RepHd} = tests_util:get_ref(),
    Route = {route, "<sip:127.0.0.1;lr>"},

    {ok, 407, []} = nksip_uac:register(auth_test_client1, S1, []),
    {ok, 200, []} = nksip_uac:register(auth_test_client1, S1, [{sip_pass, "1234"}, unregister_all]),

    {ok, 200, []} = nksip_uac:register(auth_test_client2, S1, [{sip_pass, "4321"}, unregister_all]),

    % Users are not registered and no digest
    {ok, 407, []} = nksip_uac:options(auth_test_client1, S1, []),
    % auth_test_client2's Service has a password, but it is invalid
    {ok, 403, []} = nksip_uac:options(auth_test_client2, S1, []),

    % We don't want the registrar to store outbound info, so that no
    % Route header will be added to lookups (we are doing a special routing)
    {ok, 200, []} = nksip_uac:register(auth_test_client1, S1,
        [{sip_pass, "1234"}, contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(auth_test_client2, S1,
        [{sip_pass, "4321"}, contact, {supported, ""}]),

    % Authorized because of previous registration
    {ok, 200, []} = nksip_uac:options(auth_test_client1, S1, []),
    {ok, 200, []} = nksip_uac:options(auth_test_client2, S1, []),

    % The request is authorized at auth_test_server1 (registered) but not server auth_test_server2
    % (auth_test_server1 will proxy to auth_test_server2)
    {ok, 407, [{realms, [<<"auth_test_server2">>]}]} =
        nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip", [Route, {get_meta, [realms]}]),

    % Now the request reaches auth_test_client2, and it is not authorized there.
    % auth_test_client2 replies with 401, but we generate a new request with the Service's invalid
    % password
    {ok, 403, _} = nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip",
        [Route, {sip_pass, {"auth_test_server2", "1234"}},
            RepHd]),

    % Server1 accepts because of previous registration
    % Server2 replies with 407, and we generate a new request
    % Server2 now accepts and sends to auth_test_client2
    % auth_test_client2 replies with 401, and we generate a new request
    % Server2 and auth_test_client2 accepts their digests
    {ok, 200, [{dialog, DialogId1}]} =
        nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip",
            [Route,
                {sip_pass, [
                    {"auth_test_server2", "1234"},
                    {"auth_test_client2", "1234"}
                ]},
                % {supported, ""},    % No outbound
                RepHd]),

    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{auth_test_client2, ack}]),

    % Server2 and auth_test_client2 accepts the request because of dialog authentication
    {ok, 200, []} = nksip_uac:options(DialogId1, []),
    % The same for auth_test_client1
    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, auth_test_client2),
    DialogId2.

%%    {ok, 200, []} = nksip_uac:options(DialogId2, []),
%%    {ok, 200, []} = nksip_uac:bye(DialogId2, []),
%%    ok.


p2(D) ->
    nksip_uac:options(D, []).



proxy() ->
    S1 = "sip:127.0.0.1",
    {Ref, RepHd} = tests_util:get_ref(),
    Route = {route, "<sip:127.0.0.1;lr>"},

    {ok, 407, []} = nksip_uac:register(auth_test_client1, S1, []),
    {ok, 200, []} = nksip_uac:register(auth_test_client1, S1, [{sip_pass, "1234"}, unregister_all]),

    {ok, 200, []} = nksip_uac:register(auth_test_client2, S1, [{sip_pass, "4321"}, unregister_all]),

    % Users are not registered and no digest
    {ok, 407, []} = nksip_uac:options(auth_test_client1, S1, []),
    % auth_test_client2's Service has a password, but it is invalid
    {ok, 403, []} = nksip_uac:options(auth_test_client2, S1, []),

    % We don't want the registrar to store outbound info, so that no
    % Route header will be added to lookups (we are doing a special routing)
    {ok, 200, []} = nksip_uac:register(auth_test_client1, S1,
        [{sip_pass, "1234"}, contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(auth_test_client2, S1,
        [{sip_pass, "4321"}, contact, {supported, ""}]),

    % Authorized because of previous registration
    {ok, 200, []} = nksip_uac:options(auth_test_client1, S1, []),
    {ok, 200, []} = nksip_uac:options(auth_test_client2, S1, []),

    % The request is authorized at auth_test_server1 (registered) but not server auth_test_server2
    % (auth_test_server1 will proxy to auth_test_server2)
    {ok, 407, [{realms, [<<"auth_test_server2">>]}]} =
        nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip", [Route, {get_meta, [realms]}]),

    % Now the request reaches auth_test_client2, and it is not authorized there.
    % auth_test_client2 replies with 401, but we generate a new request with the Service's invalid
    % password
    {ok, 403, _} = nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip",
        [Route, {sip_pass, {"auth_test_server2", "1234"}},
            RepHd]),

    % Server1 accepts because of previous registration
    % Server2 replies with 407, and we generate a new request
    % Server2 now accepts and sends to auth_test_client2
    % auth_test_client2 replies with 401, and we generate a new request
    % Server2 and auth_test_client2 accepts their digests
    {ok, 200, [{dialog, DialogId1}]} =
        nksip_uac:invite(auth_test_client1, "sip:auth_test_client2@nksip",
                            [Route,
                            {sip_pass, [
                                {"auth_test_server2", "1234"},
                                {"auth_test_client2", "1234"}
                            ]},
                            % {supported, ""},    % No outbound
                            RepHd]),

    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{auth_test_client2, ack}]),

    % Server2 and auth_test_client2 accepts the request because of dialog authentication
    {ok, 200, []} = nksip_uac:options(DialogId1, []),
    % The same for auth_test_client1
    % For each incoming UAS request, field 'dests' in call is updated with via info,
    % and it is used if now it is used as a UAC, reusing the tcp connection
    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, auth_test_client2),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(DialogId2, []),
    ok.


