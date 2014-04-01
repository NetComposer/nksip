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

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


% basic_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             {timeout, 60, fun running/0}, 
%             {timeout, 60, fun transport/0}, 
%             {timeout, 60, fun cast_info/0}, 
%             {timeout, 60, fun stun/0}
%         ]
%     }.


start() ->
    tests_util:start_nksip(),
    nksip_config:put(nksip_store_timer, 200),
    nksip_config:put(nksip_sipapp_timer, 10000),

    {ok, _} = nksip:start(server1, ?MODULE, server1, [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server1@nksip>"},
        registrar,
        {supported, []},
        {transports, [
            {udp, all, 5060, [{listeners, 10}]},
            {tls, all, 5061}
        ]}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, client1, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {supported, []},
        {transports, [
            {udp, all, 5070},
            {tls, all, 5071}
        ]}
    ]),

    {ok, _} = nksip:start(client2, ?MODULE, client2, [
        % {supported, []},
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),

    tests_util:log(debug),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop_all(),
    error = nksip:stop(server1),
    error = nksip:stop(client1),
    error = nksip:stop(client2),
    ok.


running() ->
    {error, already_started} = nksip:start(server1, ?MODULE, server1, []),
    {error, already_started} = nksip:start(client1, ?MODULE, client1, []),
    {error, already_started} = nksip:start(client2, ?MODULE, client2, []),
    [{client1, _}, {client2, _}, {server1, _}] = lists:sort(nksip:get_all()),

    {error, error1} = nksip:start(error1, ?MODULE, error1, [{transports, [{udp, all, 5090}]}]),
    timer:sleep(100),
    {ok, P1} = gen_udp:open(5090, [{reuseaddr, true}, {ip, {0,0,0,0}}]),
    ok = gen_udp:close(P1),
    
    {error, invalid_transport} = 
                    nksip:start(name, ?MODULE, none, [{transports, [{other, all, any}]}]),
    {error, invalid_transport} = 
                    nksip:start(name, ?MODULE, none, [{transports, [{udp, {1,2,3}, any}]}]),
    {error, invalid_register} = nksip:start(name, ?MODULE, none, [{register, "sip::a"}]),

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
    [<<"My SIP">>] = nksip_sipmsg:header(Req1, <<"user-agent">>),
    [<<"<sip:aaa:123>">>,<<"<sips:bbb:321>">>] = 
        nksip_sipmsg:header(Req1, <<"contact">>),
    Body = nksip_sipmsg:field(Req1, body),

    % Remote has generated a valid Contact (OPTIONS generates a Contact by default)
    Fields2 = {meta, [parsed_contacts, remote]},
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
    BigBodyHash = erlang:phash2(nksip_sipmsg:field(Req4, body)),

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
    [
        [#uri{user=(<<"client1">>), domain=(<<"mihost">>), port=5070}],
        [
            #uri{domain=(<<"127.0.0.1">>), port=0, opts=[<<"lr">>]},
            #uri{domain=(<<"aaa">>), port=0, opts=[<<"lr">>]},
            #uri{domain=(<<"bbb">>), port=123, opts=[<<"lr">>]}
        ]
    ] = nksip_sipmsg:fields(Req5, [parsed_contacts, parsed_routes]),

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
    % Direct calls to SipApp's core processsipappº
    Pid = nksip:get_pid(server1),
    true = is_pid(Pid),
    not_found = nksip:get_pid(other),

    {ok, server1, Domains} = nksip:call(server1, get_domains),
    {ok, server1} = nksip:call(server1, {set_domains, [<<"test">>]}),
    {ok, server1, [<<"test">>]} = nksip:call(server1, get_domains),
    {ok, server1} = nksip:call(server1, {set_domains, Domains}),
    {ok, server1, Domains} = nksip:call(server1, get_domains),
    Ref = make_ref(),
    Self = self(),
    nksip:cast(server1, {cast_test, Ref, Self}),
    Pid ! {info_test, Ref, Self},
    ok = tests_util:wait(Ref, [{cast_test, server1}, {info_test, server1}]).


stun() ->
    {ok, {{0,0,0,0}, 5070}, {{127,0,0,1}, 5070}} = 
        nksip_uac:stun(client1, "sip:127.0.0.1", []),
    {ok, {{0,0,0,0}, 5060}, {{127,0,0,1}, 5060}} = 
        nksip_uac:stun(server1, "sip:127.0.0.1:5070", []),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(error1) ->
    {stop, error1};

init(AppName) ->
    ok = nksip:put(AppName, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, AppName}.

% Route for "basic" test suite. Allways add Record-Route and x-nk-server headers
% If no user, use Nksip-Op to select an operation
% If user and domain is nksip, proxy to registered contacts
% Any other case simply route
route(ReqId, Scheme, User, Domain, _From, AppId=State) when AppId==server1 ->
    {ok, Domains} = nksip:get(AppId, domains),
    Opts = [
        record_route,
        {insert, "x-nk-server", AppId}
    ],
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            case nksip_request:header(AppId, ReqId, <<"x-nk-op">>) of
                [<<"reply-request">>] ->
                    Request = nksip_request:get_request(AppId, ReqId),
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

route(_, _, _, _, _, State) ->
    {reply, process, State}.


dialog_update(_DialogId, _Update, State) ->
    {noreply, State}.


handle_call(get_domains, _From, AppId=State) ->
    {ok, Domains} = nksip:get(AppId, domains),
    {reply, {ok, AppId, Domains}, State};

handle_call({set_domains, Domains}, _From, AppId=State) ->
    ok = nksip:put(AppId, domains, Domains),
    {reply, {ok, AppId}, State}.

handle_cast({cast_test, Ref, Pid}, AppId=State) ->
    Pid ! {Ref, {cast_test, AppId}},
    {noreply, State}.

handle_info({info_test, Ref, Pid}, AppId=State) ->
    Pid ! {Ref, {info_test, AppId}},
    {noreply, State}.















