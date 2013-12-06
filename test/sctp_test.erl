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
-include("../include/nksip.hrl").

-compile([export_all]).

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
    ok = sipapp_endpoint:start({sctp, client1}, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {sctp, {0,0,0,0}, 5070}}
    ]),

    ok = sipapp_endpoint:start({sctp, client2}, [
        {from, "sip:client2@nksip"},
        {pass, "jj"},
        {pass, {"4321", "client1"}},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5071}},
        {transport, {sctp, {0,0,0,0}, 5071}}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({sctp, client1}),
    ok = sipapp_endpoint:stop({sctp, client2}).


basic() ->
    C1 = {sctp, client1},
    C2 = {sctp, client2},
    SipC2 = "<sip:127.0.0.1:5071;transport=sctp>",
    Self = self(),
    Ref = make_ref(),

    Fun = fun(Term) -> Self ! {Ref, Term} end,
    Opts = [async, {callback, Fun}, get_request, get_response],
    {async, _} = nksip_uac:options(C1, SipC2, Opts),
    
    {LocalPort, SctpId} = receive
        {Ref, {req, #sipmsg{vias=[#via{proto=sctp}], transport=ReqTransp}}} ->
            #transport{
                proto = sctp,
                local_port = LocalPort0,
                remote_ip = {127,0,0,1},
                remote_port = 5071,
                listen_port = 5070,
                sctp_id = SctpId0
            } = ReqTransp,
            {LocalPort0, SctpId0}
    after 2000 ->
        error(sctp)
    end,

    receive
        {Ref, {resp, #sipmsg{vias=[#via{proto=sctp}]}}} -> ok
    after 2000 ->
        error(sctp)
    end,

    % C1 should have started a new transport to C2:5071
    [LocPid] = [Pid || {#transport{proto=sctp, local_port=LP, remote_port=5071,
                                   sctp_id=Id}, Pid} 
                        <- nksip_transport:get_all(C1), LP=:=LocalPort, Id=:=SctpId],

    % C2 should not have started a new transport
    [RemPid] = [Pid || {#transport{proto=sctp, remote_port=0}, Pid} 
                       <- nksip_transport:get_all(C2)],

    % C1 should have started a new connection. C2 too.
    [{_, LocPid}] = nksip_transport:get_connected(C1, sctp, {127,0,0,1}, 5071),
    [{_, RemPid}] = nksip_transport:get_connected(C2, sctp, {127,0,0,1}, LocalPort),
    ok.