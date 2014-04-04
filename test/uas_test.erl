
%% -------------------------------------------------------------------
%%
%% uas_test: Basic Test Suite
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

-module(uas_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


uas_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uas/0}, 
            {timeout, 60, fun auto/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(server1, ?MODULE, server1, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        {supported, "a;a_param, 100rel"},
        registrar,
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {sipapp_timer, 1}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        {sipapp_timer, 1}
    ]),
            
    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


uas() ->
    % Test loop detection
    {ok, 200, Values1} = nksip_uac:options(client1, "sip:127.0.0.1", [
                                {add, <<"x-nk-op">>, <<"reply-stateful">>},
                                {meta, [call_id, from, cseq_num]}]),
    [{call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}] = Values1,

    {ok, 482, [{reason_phrase, <<"Loop Detected">>}]} = 
        nksip_uac:options(client1, "sip:127.0.0.1", [
                            {add, <<"x-nk-op">>, <<"reply-stateful">>},
                            {call_id, CallId1}, {from, From1}, {cseq_num, CSeq1}, 
                            {meta, [reason_phrase]}]),

    % Stateless proxies do not detect loops
    {ok, 200, Values3} = nksip_uac:options(client1, "sip:127.0.0.1", [
                            {add, "x-nk-op", "reply-stateless"},
                            {meta, [call_id, from, cseq_num]}]),

    [{_, CallId3}, {_, From3}, {_, CSeq3}] = Values3,
    {ok, 200, []} = nksip_uac:options(client1, "sip:127.0.0.1", [
                        {add, "x-nk-op", "reply-stateless"},
                        {call_id, CallId3}, {from, From3}, {cseq_num, CSeq3}]),

    % Test bad extension endpoint and proxy
    {ok, 420, [{all_headers, Hds5}]} = nksip_uac:options(client1, "sip:127.0.0.1", [
                                           {add, "require", "a,b;c,d"}, 
                                           {meta, [all_headers]}]),
    % 'a' is supported because of app config
    [<<"b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds5),
    
    {ok, 420, [{all_headers, Hds6}]} = nksip_uac:options(client1, "sip:a@external.com", [
                                            {add, "proxy-require", "a,b;c,d"}, 
                                            {route, "<sip:127.0.0.1;lr>"},
                                            {meta, [all_headers]}]),
    [<<"a,b,d">>] = proplists:get_all_values(<<"unsupported">>, Hds6),

    % Force invalid response
    lager:warning("Next warning about a invalid sipreply is expected"),
    {ok, 500,  [{reason_phrase, <<"Invalid SipApp Response">>}]} = 
        nksip_uac:options(client1, "sip:127.0.0.1", [
            {add, "x-nk-op", "reply-invalid"}, {meta, [reason_phrase]}]),
    ok.


auto() ->
    % Start a new server to test ping and register options
    nksip:stop(server2),
    {ok, _} = nksip:start(server2, ?MODULE, server2, [
        registrar, 
        {transports, [{udp, all, 5080}]},
        {registrar_min_time, 1},
        {sipapp_timer, 1}
    ]),
    timer:sleep(200),
    {error, invalid_uri} = nksip_sipapp_auto:start_ping(n, ping1, "sip::a", 1, []),
    Ref = make_ref(),
    
    ok = nksip:put(client1, callback, {Ref, self()}),
    
    {ok, true} = nksip_sipapp_auto:start_ping(client1, ping1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 5, []),

    {error, invalid_uri} = nksip_sipapp_auto:start_register(name, reg1, "sip::a", 1, []),
    {ok, true} = nksip_sipapp_auto:start_register(client1, reg1, 
                                "<sip:127.0.0.1:5080;transport=tcp>", 1, []),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(client1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(client1),

    ok = tests_util:wait(Ref, [{ping, ping1, true}, {reg, reg1, true}]),

    lager:info("Next infos about connection error to port 9999 are expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(client1, ping2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    {ok, false} = nksip_sipapp_auto:start_register(client1, reg2, 
                                            "<sip:127.0.0.1:9999;transport=tcp>", 1, []),
    ok = tests_util:wait(Ref, [{ping, ping2, false}, {reg, reg2, false}]),

    [{ping1, true,_}, {ping2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_pings(client1)),
    [{reg1, true,_}, {reg2, false,_}] = 
        lists:sort(nksip_sipapp_auto:get_registers(client1)),
    
    ok = nksip_sipapp_auto:stop_ping(client1, ping2),
    ok = nksip_sipapp_auto:stop_register(client1, reg2),

    [{ping1, true, _}] = nksip_sipapp_auto:get_pings(client1),
    [{reg1, true, _}] = nksip_sipapp_auto:get_registers(client1),

    ok = nksip:stop(server2),
    lager:info("Next info about connection error to port 5080 is expected"),
    {ok, false} = nksip_sipapp_auto:start_ping(client1, ping3, 
                                            "<sip:127.0.0.1:5080;transport=tcp>", 1, []),
    ok = nksip_sipapp_auto:stop_ping(client1, ping1),
    ok = nksip_sipapp_auto:stop_ping(client1, ping3),
    ok = nksip_sipapp_auto:stop_register(client1, reg1),
    [] = nksip_sipapp_auto:get_pings(client1),
    [] = nksip_sipapp_auto:get_registers(client1),
    ok.

timeout() ->
    SipC1 = "<sip:127.0.0.1:5070;transport=tcp>",

    {ok, _} = nksip:update(client1, [{sipapp_timeout, 0.02}]),

    % Client1 callback module has a 50msecs delay in route()
    {ok, 500, [{reason_phrase, <<"No SipApp Response">>}]} = 
        nksip_uac:options(client2, SipC1, [{meta,[reason_phrase]}]),

    {ok, _} = nksip:update(client1, [{timer_t1, 10}, {timer_c, 1}, {sipapp_timeout, 10}]),

    Hd1 = {add, "x-nk-sleep", 2000},
    {ok, 408, [{reason_phrase, <<"No-INVITE Timeout">>}]} = 
        nksip_uac:options(client2, SipC1, [Hd1, {meta, [reason_phrase]}]),

    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-sleep", 2000}],
    {ok, 408, [{reason_phrase, <<"Timer C Timeout">>}]} = 
        nksip_uac:invite(client2, SipC1, [{meta,[reason_phrase]}|Hds2]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    nksip:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, Id}.

route(ReqId, Scheme, User, Domain, _From, AppId=State) when AppId==server1 ->
    Opts = [
        record_route,
        {insert, "x-nk-server", AppId}
    ],
    {ok, Domains} = nksip:get(server1, domains),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            case nksip_request:header(ReqId, <<"x-nk-op">>) of
                [<<"reply-request">>] ->
                    Request = nksip_request:get_request(ReqId),
                    Body = base64:encode(term_to_binary(Request)),
                    {reply, {ok, [{body, Body}, contact]}, State};
                [<<"reply-stateless">>] ->
                    {reply, {response, ok, [stateless]}, State};
                [<<"reply-stateful">>] ->
                    {reply, {response, ok}, State};
                [<<"reply-invalid">>] ->
                    {reply, {response, 'INVALID'}, State};
                [<<"force-error">>] ->
                    error(test_error);
                _ ->
                    {reply, {process, Opts}, State}
            end;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        _ ->
            {reply, {proxy, ruri, Opts}, State}
    end;

route(_ReqId, _Scheme, _User, _Domain, _From, client1=State) ->
    timer:sleep(50),
    {reply, process, State};

route(_ReqId, _Scheme, _User, _Domain, _From, State) ->
    timer:sleep(50),
    {reply, process, State}.


invite(ReqId, Meta, From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Op = case nksip_request:header(ReqId, <<"x-nk-op">>) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    Sleep = case nksip_request:header(ReqId, <<"x-nk-sleep">>) of
        [Sleep0] -> nksip_lib:to_integer(Sleep0);
        _ -> 0
    end,
    proc_lib:spawn(
        fun() ->
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip:reply(From, {ok, []});
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip:reply(From, {ok, [{body, SDP}]});
                <<"busy">> ->
                    nksip:reply(From, busy);
                <<"increment">> ->
                    DialogId = nksip_lib:get_value(dialog_id, Meta),
                    SDP1 = nksip_dialog:field(AppId, DialogId, invite_local_sdp),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {ok, [{body, SDP2}]});
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State}.


options(ReqId, _Meta, _From, AppId=State) ->
    case nksip_request:header(ReqId, <<"x-nk-sleep">>) of
        [Sleep0] -> 
            nksip_request:reply(ReqId, 101), 
            timer:sleep(nksip_lib:to_integer(Sleep0));
        _ -> 
            ok
    end,
    {reply, {ok, [contact]}, State}.


ping_update(PingId, OK, AppId=State) ->
    {ok, {Ref, Pid}} = nksip:get(AppId, callback, []),
    Pid ! {Ref, {ping, PingId, OK}},
    {noreply, State}.


register_update(RegId, OK, AppId=State) ->
    {ok, {Ref, Pid}} = nksip:get(AppId, callback, []),
    Pid ! {Ref, {reg, RegId, OK}},
    {noreply, State}.






