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

-module(auth_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

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


start() ->
    tests_util:start_nksip(),
    {ok, _} = nksip:start(server1, ?MODULE, [], [
        {from, "sip:server1@nksip"},
        {plugins, [nksip_registrar]},
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}]}
    ]),

    {ok, _} = nksip:start(server2, ?MODULE, [], [
        {from, "sip:server2@nksip"},
        {local_host, "localhost"},
        {transports, [{udp, all, 5061}]}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, [], [
        {from, "sip:client1@nksip"},
        {plugins, [nksip_uac_auto_auth]},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}]}
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, [], [
        {from, "sip:client2@nksip"},
        {plugins, [nksip_uac_auto_auth]},
        {passes, ["jj", {"client1", "4321"}]},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5071}]}
    ]),

    {ok, _} = nksip:start(client3, ?MODULE, [], [
        {from, "sip:client3@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5072}]}
    ]),
    
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(server2),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2),
    ok = nksip:stop(client3).


digest() ->
    Sipclient1 = "sip:127.0.0.1:5070",
    SipC2 = "sip:127.0.0.1:5071",

    {ok, 401, []} = nksip_uac:options(client1, SipC2, []),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, "1234"}]),
    {ok, 403, []} = nksip_uac:options(client1, SipC2, [{pass, "12345"}]),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, {"client2", "1234"}}]),
    {ok, 403, []} = nksip_uac:options(client1, SipC2, [{pass, {"other", "1234"}}]),

    HA1 = nksip_auth:make_ha1("client1", "1234", "client2"),
    {ok, 200, []} = nksip_uac:options(client1, SipC2, [{pass, HA1}]),
    
    % Pass is invalid, but there is a valid one in SipApp's options
    {ok, 200, []} = nksip_uac:options(client2, Sipclient1, []),
    {ok, 200, []} = nksip_uac:options(client2, Sipclient1, [{pass, "kk"}]),
    {ok, 403, []} = nksip_uac:options(client2, Sipclient1, [{pass, {"client1", "kk"}}]),

    Self = self(),
    Ref = make_ref(),
    Fun = fun({resp, 200, _, _}) -> Self ! {Ref, digest_ok} end,
    {async, _} = nksip_uac:options(client1, SipC2, [async, {callback, Fun}, {pass, HA1}]),
    ok = tests_util:wait(Ref, [digest_ok]),
    ok.



invite() ->
    SipC3 = "sip:127.0.0.1:5072",
    {Ref, RepHd} = tests_util:get_ref(),
    Self = self(),

    % client3 does not support dialog's authentication, only digest is used
    {ok, 401, [{cseq_num, CSeq}]} = 
        nksip_uac:invite(client1, SipC3, [{meta, [cseq_num]}]),
    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(client1, SipC3, 
                                             [{pass, "abcd"}, RepHd]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{client3, ack}]),
    {ok, 401, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId1, [{pass, "abcd"}]),

    {ok, 401, _} = nksip_uac:invite(DialogId1, []),

    {ok, 200, _} = nksip_uac:invite(DialogId1, [{pass, "abcd"}]),
    
    FunAck = fun({req, ACK3, _Call}) ->
        {ok, AckCSeq} = nksip_request:meta(cseq_num, ACK3),
        Self ! {Ref, {ack_cseq, AckCSeq-8}}
    end,
    ok = nksip_uac:ack(DialogId1, [get_request, {callback, FunAck}]),
    ok = tests_util:wait(Ref, [{ack_cseq, CSeq}, {client3, ack}]),

    % client1 does support dialog's authentication
    DialogId3 = nksip_dialog_lib:remote_id(DialogId1, client3),
    {ok, 200, [{cseq_num, CSeq2}]} = 
        nksip_uac:options(DialogId3, [{meta, [cseq_num]}]),
    {ok, 200, [{dialog, DialogId3}]} = 
        nksip_uac:invite(DialogId3, [RepHd]),
    ok = nksip_uac:ack(DialogId3, [RepHd]),
    ok = tests_util:wait(Ref, [{client1, ack}]),
    {ok, 200, [{_, CSeq3}]} = nksip_uac:bye(DialogId3, [{meta, [cseq_num]}]),
    ok = tests_util:wait(Ref, [{client1, bye}]),
    CSeq3 = CSeq2 + 2,
    ok.


dialog() ->
    SipC2 = "sip:127.0.0.1:5071",
    {Ref, RepHd} = tests_util:get_ref(),

    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(client1, SipC2, 
                                            [{pass, "1234"}, RepHd]),
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    [{udp, {127,0,0,1}, 5071}] = nksip_dialog:get_authorized_list(DialogId1),
    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, client2),
    [{udp, {127,0,0,1}, 5070}] = nksip_dialog:get_authorized_list(DialogId2),

    {ok, 200, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),

    ok = nksip_dialog:clear_authorized_list(DialogId2),
    {ok, 401, []} = nksip_uac:options(DialogId1, []),
    {ok, 200, []} = nksip_uac:options(DialogId1, [{pass, "1234"}]),
    {ok, 200, []} = nksip_uac:options(DialogId1, []),

    ok = nksip_dialog:clear_authorized_list(DialogId1),
    [] = nksip_dialog:get_authorized_list(DialogId1),

    % Force an invalid password, because the SipApp config has a valid one
    {ok, 403, []} = nksip_uac:options(DialogId2, [{pass, {"client1", "invalid"}}]),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, []} = nksip_uac:options(DialogId2, [{pass, {"client1", "invalid"}}]),

    {ok, 200, []} = nksip_uac:bye(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, bye}]),
    ok.


proxy() ->
    S1 = "sip:127.0.0.1",
    {Ref, RepHd} = tests_util:get_ref(),

    {ok, 407, []} = nksip_uac:register(client1, S1, []),
    {ok, 200, []} = nksip_uac:register(client1, S1, [{pass, "1234"}, unregister_all]),
    
    {ok, 200, []} = nksip_uac:register(client2, S1, [{pass, "4321"}, unregister_all]),
    
    % Users are not registered and no digest
    {ok, 407, []} = nksip_uac:options(client1, S1, []),
    % client2's SipApp has a password, but it is invalid
    {ok, 403, []} = nksip_uac:options(client2, S1, []),

    % We don't want the registrar to store outbound info, so that no 
    % Route header will be added to lookups (we are doing a special routing)
    {ok, 200, []} = nksip_uac:register(client1, S1, 
                                       [{pass, "1234"}, contact, {supported, ""}]),
    {ok, 200, []} = nksip_uac:register(client2, S1, 
                                       [{pass, "4321"}, contact, {supported, ""}]),

    % Authorized because of previous registration
    {ok, 200, []} = nksip_uac:options(client1, S1, []),
    {ok, 200, []} = nksip_uac:options(client2, S1, []),
    
    % The request is authorized at server1 (registered) but not server server2
    % (server1 will proxy to server2)
    Route = {route, "<sip:127.0.0.1;lr>"},
    {ok, 407, [{realms, [<<"server2">>]}]} = 
        nksip_uac:invite(client1, "sip:client2@nksip", [Route, {meta, [realms]}]),

    % Now the request reaches client2, and it is not authorized there. 
    % client2 replies with 401, but we generate a new request with the SipApp's invalid
    % password
    {ok, 403, _} = nksip_uac:invite(client1, "sip:client2@nksip", 
                                      [Route, {pass, {"server2", "1234"}}, 
                                       RepHd]),

    % Server1 accepts because of previous registration
    % Server2 replies with 407, and we generate a new request
    % Server2 now accepts and sends to client2
    % client2 replies with 401, and we generate a new request
    % Server2 and client2 accepts their digests
    {ok, 200, [{dialog, DialogId1}]} = nksip_uac:invite(client1, "sip:client2@nksip", 
                                            [Route, 
                                            {passes, [{"server2", "1234"}, 
                                                      {"client2", "1234"}]},
                                            % {supported, ""},    % No outbound
                                            RepHd]),
    % Server2 inserts a Record-Route, so every in-dialog request is sent to Server2
    % ACK uses the same authentication headers from last invite
    ok = nksip_uac:ack(DialogId1, []),
    ok = tests_util:wait(Ref, [{client2, ack}]),

    % Server2 and client2 accepts the request because of dialog authentication
    {ok, 200, []} = nksip_uac:options(DialogId1, []),
    % The same for client1
    DialogId2 = nksip_dialog_lib:remote_id(DialogId1, client2),
    {ok, 200, []} = nksip_uac:options(DialogId2, []),
    {ok, 200, []} = nksip_uac:bye(DialogId2, []),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


sip_get_user_pass(User, Realm, Req, _Call) ->
    {ok, App} = nksip_request:app_name(Req),
    if
        App==server1; App==server2 ->
            % Password for user "client1", any realm, is "1234"
            % For user "client2", any realm, is "4321"
            case User of
                <<"client1">> -> "1234";
                <<"client2">> -> "4321";
                _ -> false
            end;
        true ->
            % Password for any user in realm "client1" is "4321",
            % for any user in realm "client2" is "1234", and for "client3" is "abcd"
            case Realm of 
                <<"client1">> ->
                    % A hash can be used instead of the plain password
                    nksip_auth:make_ha1(User, "4321", "client1");
                <<"client2">> ->
                    "1234";
                <<"client3">> ->
                    "abcd";
                _ ->
                    false
            end
    end.


% Authorization is only used for "auth" suite
sip_authorize(Auth, Req, _Call) ->
    {ok, App} = nksip_request:app_name(Req),
    IsDialog = lists:member(dialog, Auth),
    IsRegister = lists:member(register, Auth),
    if
        App==server1; App==server2 ->
            % lager:warning("AUTH AT ~p: ~p", [App, Auth]),
            case IsDialog orelse IsRegister of
                true ->
                    ok;
                false ->
                    BinId = nksip_lib:to_binary(App) ,
                    case nksip_lib:get_value({digest, BinId}, Auth) of
                        true -> ok;
                        false -> forbidden;
                        undefined -> {proxy_authenticate, BinId}
                    end
            end;
        App/=client3, IsDialog ->
            % client3 doesn't support dialog authorization
            ok;
        true ->
            BinId = nksip_lib:to_binary(App) ,
            case nksip_lib:get_value({digest, BinId}, Auth) of
                true -> ok;                         % At least one user is authenticated
                false -> forbidden;                 % Failed authentication
                undefined -> {authenticate, BinId}  % No auth header
            end
    end.




% Route for server1 in auth tests
% Finds the user and proxies to server2
sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:app_name(Req) of
        {ok, server1} ->
            Opts = [{route, "<sip:127.0.0.1:5061;lr>"}],
            case User of
                <<>> -> 
                    process;
                _ when Domain =:= <<"127.0.0.1">> ->
                    proxy;
                _ ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> 
                            {reply, temporarily_unavailable};
                        UriList -> 
                            {proxy, UriList, Opts}
                    end
            end;
        {ok, server2} ->
            {proxy, ruri, [record_route]};
        {ok, _} ->
            process
    end.


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {reply, ok}.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.





