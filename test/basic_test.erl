
%% -------------------------------------------------------------------
%%
%% basic_test: Basic Test Suite
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

-module(basic_test).

-include_lib("nklib/include/nklib.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-compile([export_all]).


basic_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun running/0}, 
            {timeout, 60, fun transport/0}, 
            {timeout, 60, fun cast_info/0}, 
            {timeout, 60, fun stun/0}
        ]
    }.


s1() ->
    ok = tests_util:start(server1, ?MODULE, #{
        arg => server1,
        sip_from => "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>",
        plugins => [nksip_registrar],
        tls_versions => [tlsv1],
        transports => "sip://all;tcp_listeners=10, sips:all:5061;tls_password=1234" 
    }).


start() ->
    catch stop(),

    tests_util:start_nksip(),
    nklib_store:update_timer(200),

    ok = tests_util:start(server1, ?MODULE, #{
        arg => server1,
        sip_from => "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>",
        plugins => [nksip_registrar],
        transports => "sip://all;tcp_listeners=10, sips:all:5061"
    }),

    ok = tests_util:start(client1, ?MODULE, #{
        arg => client1,
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>",
        transports => ["sip://all:5070", "sips:all:5071"]
    }),

    ok = tests_util:start(client2, ?MODULE, #{
        callback => ?MODULE,
        arg => client2,
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop_all(),
    {error, service_not_found} = nksip:stop(server1),
    {error, service_not_found} = nksip:stop(client1),
    {error, service_not_found} = nksip:stop(client2),
    ok.


running() ->
    {error, already_started} = nksip:start(server1, []),
    {error, already_started} = nksip:start(client1, []),
    {error, already_started} = nksip:start(client2, []),
    [{_, server1, _}, {_, client2, _}, {_, client1, _}] =
        lists:sort(nkservice_server:get_all(nksip)),

    % lager:error("Next error about error1 is expected"),
    {error, error1} = nksip:start(error1, [
        {transports, "sip:all:5090"}, {callback, ?MODULE}]),
    timer:sleep(100),
    {ok, P1} = gen_udp:open(5090, [{reuseaddr, true}, {ip, {0,0,0,0}}]),
    ok = gen_udp:close(P1),
    
    {error, {syntax_error, <<"transports">>}} = 
        nksip:start(name, [{transports, "<sip:all;transport=other>"}]),
    {error,{could_not_start_plugin,{nksip_registrar,
            {syntax_error,<<"sip_registrar_min_time">>}}}} = 
        nksip:start(name, [{plugins, [nksip_registrar]}, {sip_registrar_min_time, -1}]),

    {error, {invalid_plugin, invalid}} = 
        nksip:start(name, [{plugins, [nksip_registrar, invalid]}]),

    ok.
    

transport() ->
    Body = base64:encode(crypto:rand_bytes(100)),
    Opts1 = [
        {add, "x-nksip", "test1"}, 
        {add, "x-nk-op", "reply-request"}, 
        {contact, "sip:aaa:123, sips:bbb:321"},
        {add, user_agent, "My SIP"},
        {body, Body},
        {meta, [body]}
    ],
    {ok, 200, [{body, RespBody}]} = nksip_uac:options(client1, "sip:127.0.0.1", Opts1),

    % Req1 is the request as received at the remote party
    Req1 = binary_to_term(base64:decode(RespBody)),
    [<<"My SIP">>] = nksip_sipmsg:header(<<"user-agent">>, Req1),
    [<<"<sip:aaa:123>">>,<<"<sips:bbb:321>">>] = nksip_sipmsg:header(<<"contact">>, Req1),
    Body = nksip_sipmsg:meta(body, Req1),

    % Remote has generated a valid Contact (OPTIONS generates a Contact by default)
    Fields2 = {meta, [contacts, remote]},
    {ok, 200, Values2} = nksip_uac:options(client1, "<sip:127.0.0.1;transport=tcp>", [Fields2]),

    [
        {_, [#uri{scheme=sip, port=5060, opts=[{<<"transport">>, <<"tcp">>}]}]},
        {_, {tcp, {127,0,0,1}, 5060, <<>>}}
    ] = Values2,

    % Remote has generated a SIPS Contact   
    {ok, 200, Values3} = nksip_uac:options(client1, "sips:127.0.0.1", [Fields2]),
    [
        {_, [#uri{scheme=sips, port=5061}]},
        {_, {tls, {127,0,0,1}, 5061, <<>>}}
    ] = Values3,

    % Send a big body, switching to TCP
    BigBody = list_to_binary([[integer_to_list(L), 32] || L <- lists:seq(1, 5000)]),
    BigBodyHash = erlang:phash2(BigBody),
    Opts4 = [
        {add, "x-nk-op", "reply-request"},
        {content_type, "nksip/binary"},
        {body, BigBody},
        {meta, [body, remote]}
    ],
    {ok, 200, Values4} = nksip_uac:options(client2, "sip:127.0.0.1", Opts4),
    [{body, RespBody4}, {remote, {tcp, _, _, _}}] = Values4,
    Req4 = binary_to_term(base64:decode(RespBody4)),
    BigBodyHash = erlang:phash2(nksip_sipmsg:meta(body, Req4)),

    % Check local_host is used to generare local Contact, Route headers are received
    Opts5 = [
        {add, "x-nk-op", "reply-request"},
        contact,
        {local_host, "mihost"},
        {route, [<<"<sip:127.0.0.1;lr>">>, "<sip:aaa;lr>, <sips:bbb:123;lr>"]},
        {meta, [body]}
    ],
    {ok, 200, Values5} = nksip_uac:options(client1, "sip:127.0.0.1", Opts5),
    [{body, RespBody5}] = Values5,
    Req5 = binary_to_term(base64:decode(RespBody5)),
    [#uri{user=(<<"client1">>), domain=(<<"mihost">>), port=5070}] = 
        nksip_sipmsg:meta(contacts, Req5),
    [
        #uri{domain=(<<"127.0.0.1">>), port=0, opts=[<<"lr">>]},
        #uri{domain=(<<"aaa">>), port=0, opts=[<<"lr">>]},
        #uri{domain=(<<"bbb">>), port=123, opts=[<<"lr">>]}
    ] = 
       nksip_sipmsg:meta(routes, Req5),

    {ok, 200, []} = nksip_uac:options(client1, "sip:127.0.0.1", 
                                [{add, "x-nk-op", "reply-stateless"}]),
    {ok, 200, []} = nksip_uac:options(client1, "sip:127.0.0.1", 
                                [{add, "x-nk-op", "reply-stateful"}]),

    % Cover ip resolution
    case nksip_uac:options(client1, "<sip:sip2sip.info>", []) of
        {ok, 200, []} -> ok;
        {ok, Code, []} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Code]);
        {error, Error} -> ?debugFmt("Could not contact sip:sip2sip.info: ~p", [Error])
    end,
    ok.


cast_info() ->
    % Direct calls to service's core processing app
    {ok, S1} = nkservice_server:get_srv_id(server1),
    Pid = whereis(S1),
    not_running = nkservice_server:get_pid(other),

    {ok, server1, Domains} = gen_server:call(S1, get_domains),
    {ok, server1} = gen_server:call(S1, {set_domains, [<<"test">>]}),
    {ok, server1, [<<"test">>]} = gen_server:call(S1, get_domains),
    {ok, server1} = gen_server:call(S1, {set_domains, Domains}),
    {ok, server1, Domains} = gen_server:call(S1, get_domains),
    Ref = make_ref(),
    Self = self(),
    gen_server:cast(S1, {cast_test, Ref, Self}),
    Pid ! {info_test, Ref, Self},
    ok = tests_util:wait(Ref, [{cast_test, server1}, {info_test, server1}]).


stun() ->
    {ok, {{0,0,0,0}, 5070}, {{127,0,0,1}, 5070}} = 
        nksip_uac:stun(client1, "sip:127.0.0.1", []),
    {ok, {{0,0,0,0}, 5060}, {{127,0,0,1}, 5060}} = 
        nksip_uac:stun(server1, "sip:127.0.0.1:5070", []),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(#{name:=error1}, _State) ->
    {stop, error1};

init(#{name:=Name, arg:=Name}, State) ->
    ok = nkservice_server:put(Name, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State#{my_name=>Name}}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        {ok, server1} ->
            Domains = nkservice_server:get(server1, domains),
            Opts = [
                record_route,
                {insert, "x-nk-server", server1}
            ],
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    case nksip_request:header(<<"x-nk-op">>, Req) of
                        {ok, [<<"reply-request">>]} ->
                            Body = base64:encode(term_to_binary(Req)),
                            {reply, {ok, [{body, Body}, contact]}};
                        {ok, [<<"reply-stateless">>]} ->
                            {reply_stateless, ok};
                        {ok, [<<"reply-stateful">>]} ->
                            {reply, ok};
                        {ok, [<<"reply-invalid">>]} ->
                            {reply, 'INVALID'};
                        {ok, [<<"force-error">>]} ->
                            error(test_error);
                        {ok, _} ->
                            process
                    end;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy, UriList, Opts}
                    end;
                _ ->
                    {proxy, ruri, Opts}
            end;
        {ok, _} ->
            process
    end.


handle_call(get_domains, _From, #{my_name:=Name}=State) ->
    Domains = nkservice_server:get(Name, domains),
    {reply, {ok, Name, Domains}, State};

handle_call({set_domains, Domains}, _From, #{my_name:=Name}=State) ->
    ok = nkservice_server:put(Name, domains, Domains),
    {reply, {ok, Name}, State}.

handle_cast({cast_test, Ref, Pid}, #{my_name:=Name}=State) ->
    Pid ! {Ref, {cast_test, Name}},
    {noreply, State}.

handle_info({info_test, Ref, Pid}, #{my_name:=Name}=State) ->
    Pid ! {Ref, {info_test, Name}},
    {noreply, State}.
















