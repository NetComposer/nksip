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
    ok = nksip:start(client1, ?MODULE, client1, [
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {sctp, all, 5070}]}
    ]),

    ok = nksip:start(client2, ?MODULE, client2, [
        {from, "sip:client2@nksip"},
        {pass, "jj"},
        {pass, {"4321", "client1"}},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5071}, {sctp, all, 5071}]}
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

    Fun = fun(Term) -> Self ! {Ref, Term} end,
    Opts = [async, {callback, Fun}, get_request, get_response],
    {async, _} = nksip_uac:options(client1, SipC2, Opts),
    
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

    % client1 should have started a new transport to client2:5071
    [LocPid] = [Pid || {#transport{proto=sctp, local_port=LP, remote_port=5071,
                                   sctp_id=Id}, Pid} 
                        <- nksip_transport:get_all(client1), LP=:=LocalPort, Id=:=SctpId],

    % client2 should not have started a new transport also to client1:5070
    [RemPid] = [Pid || {#transport{proto=sctp, remote_port=5070}, Pid} 
                       <- nksip_transport:get_all(client2)],

    % client1 should have started a new connection. client2 too.
    [{_, LocPid}] = nksip_transport:get_connected(client1, sctp, {127,0,0,1}, 5071, <<>>),
    [{_, RemPid}] = nksip_transport:get_connected(client2, sctp, {127,0,0,1}, LocalPort, <<>>),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.

