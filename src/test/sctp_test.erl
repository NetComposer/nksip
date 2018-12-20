%% -------------------------------------------------------------------
%%
%% sctp_test: SCTP Tests
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

-module(sctp_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).
-define(RECV(T), receive T -> T after 1000 -> error(recv) end).

sctp_test_() ->
    case gen_sctp:open() of
        {ok, S} ->
            gen_sctp:close(S),
            {setup, spawn, 
                fun() -> start() end,
                fun(_) -> stop() end,
                [
                    fun basic/0
                ]
            };
        {error, eprotonosupport} ->
            ?debugMsg("Skipping SCTP test (no Erlang support)"),
            [];
        {error, esocktnosupport} ->
            ?debugMsg("Skipping SCTP test (no OS support)"),
            []
    end.


start() ->
    tests_util:start_nksip(),
    ok = tests_util:start(client1, ?MODULE, [
        {sip_from, "sip:client1@nksip"},
        {sip_local_host, "127.0.0.1"},
        {sip_listen, "sip:all:5070, <sip:all:5070;transport=sctp>"}
    ]),

    ok = tests_util:start(client2, ?MODULE, [
        {sip_from, "sip:client2@nksip"},
        {sip_pass, ["jj", {"4321", "client1"}]},
        {sip_local_host, "127.0.0.1"},
        {sip_listen, "sip:all:5071, <sip:all:5071;transport=sctp>"}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


basic() ->
    SipC2 = "<sip:127.0.0.1:5071;transport=sctp>",
    Self = self(),
    Ref = make_ref(),

    Fun = fun
        ({req, #sipmsg{vias=[#via{transp=sctp}], nkport=ReqNkPort}, _Call}) ->
            #nkport{
                transp = sctp,
                local_port = FLocalPort,
                remote_ip = {127,0,0,1},
                remote_port = 5071,
                listen_port = 5070,
                socket = {_, FSctpId}
            } = ReqNkPort,
            Self ! {Ref, {cb1, FLocalPort, FSctpId}};
        ({resp, 200, #sipmsg{vias=[#via{transp=sctp}]}, _Call}) ->
            Self ! {Ref, cb2}
    end,
    {async, _} = nksip_uac:options(client1, SipC2, [async, {callback, Fun}, get_request]),
    {_, {_, LocalPort, SctpId}} = ?RECV({Ref, {cb1, LocalPort0, FSctpId0}}),
    _ = ?RECV({Ref, cb2}),

    % client1 should have started a new transport to client2:5071
    {ok, C1} = nkservice_srv:get_srv_id(client1),
    % b3f
    [LocPid] = nkpacket_connection:get_all({nksip, C1}),
    {ok, #nkport{transp=sctp, local_port=LocalPort, remote_port=5071, socket={_, SctpId}}} = nkpacket:get_nkport(LocPid),

    % client2 should not have started a new transport also to client1:5070
    {ok, C2} = nkservice_srv:get_srv_id(client2),
    [RemPid] = nkpacket_connection:get_all({nksip, C2}),
    {ok, #nkport{transp=sctp, remote_port=5070}} = nkpacket:get_nkport(RemPid),

    % client1 should have started a new connection. client2 too.
    [LocPid] = nksip_util:get_connected(C1, sctp, {127,0,0,1}, 5071, <<>>),
    [RemPid] = nksip_util:get_connected(C2, sctp, {127,0,0,1}, LocalPort, <<>>),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%
%%% not necessary, ok with defaults

