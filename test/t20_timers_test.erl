%% -------------------------------------------------------------------
%%
%% timer_test: Timer (RFC4028) Tests
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

-module(t20_timers_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).

timer_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun proxy/0}
        ]
    }.

start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start_link(timer_test_p1, #{
        sip_local_host => "localhost",
        sip_no_100 => true,
        sip_timers_min_se => 2,
        sip_listen => "sip:all:5060",
        plugins => [nksip_timers]
    }),

    {ok, _} = nksip:start_link(timer_test_p2, #{
        sip_local_host => "localhost",
        sip_no_100 => true,
        sip_timers_min_se => 3,
        sip_listen => "sip:all:5070",
        plugins => [nksip_timers]
    }),

    {ok, _} = nksip:start_link(timer_test_ua1, #{
        sip_from => "sip:timer_test_ua1@nksip",
        sip_local_host => "127.0.0.1",
        sip_no_100 => true,
        sip_timers_min_se => 1,
        sip_listen => "sip:all:5071",
        plugins => [nksip_timers]
    }),

    {ok, _} = nksip:start_link(timer_test_ua2, #{
        sip_local_host => "127.0.0.1",
        sip_no_100 => true,
        sip_timers_min_se => 2,
        sip_listen => "sip:all:5072",
        plugins => [nksip_timers]
    }),
    
    {ok, _} = nksip:start_link(timer_test_ua3, #{
        sip_local_host => "127.0.0.1",
        sip_no_100 => true,
        sip_listen => "sip:all:5073"
    }),


    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->

    ok = nksip:stop(timer_test_p1),
    ok = nksip:stop(timer_test_p2),
    ok = nksip:stop(timer_test_ua1),
    ok = nksip:stop(timer_test_ua2),
    ok = nksip:stop(timer_test_ua3).


all() ->
    start(),
    lager:warning("Starting TEST ~p normal", [?MODULE]),
    timer:sleep(1000),
    basic(),
    proxy(),
    stop().



basic() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    CB = {callback, fun ({req, R, _Call}) -> Self ! {Ref, R}; (_) -> ok end},

    % timer_test_ua2 has a min_session_expires of 2
    {error, {invalid_config, sip_timers_se}} = 
        nksip_uac:invite(timer_test_ua2, "sip:localhost", [{sip_timers_se, 1}]),

    % timer_test_ua1 sends a INVITE to timer_test_ua2, with sip_timers_se=1
    % ua2 rejects the request, with a 422 response, including Min-SE=2
    % timer_test_ua1 updates its Min-SE to 2, and updates sip_timers_se=2
    % ua2 receives again the INVITE. Now it is valid.

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog, Dialog1A}, {<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5072",
            [{sip_timers_se, 1}, {get_meta, [<<"session-expires">>]},
             CB, auto_2xx_ack, get_request, {body, SDP1}, RepHd]),
   
    % Start events also at timer_test_ua1
    ok =  nkserver:put(timer_test_ua1, dialogs, [{Dialog1A, Ref, Self}]),

    {ok, CallId1} = nksip_dialog:call_id(Dialog1A),
    CSeq1 = receive 
        {Ref, #sipmsg{cseq={CSeq1_0, _}, headers=Headers1, call_id=CallId1}} ->
            1 = proplists:get_value(<<"session-expires">>, Headers1),
            undefined = proplists:get_value(<<"min-se">>, Headers1),
            CSeq1_0
    after 1000 ->
        error(basic)
    end,

    receive 
        {Ref, #sipmsg{cseq={CSeq2, _}, headers=Headers2, call_id=CallId1}} ->
            <<"2">> = proplists:get_value(<<"session-expires">>, Headers2),
            <<"2">> = proplists:get_value(<<"min-se">>, Headers2),
            CSeq2 = CSeq1+1
    after 1000 ->
        error(basic)
    end,
    
    % SDP2 is the answer from timer_test_ua2; it has "nksip.auto" as domains, update with real data
    SDP2 = (nksip_sdp:increment(SDP1))#sdp{
                address={<<"IN">>,<<"IP4">>,<<"127.0.0.1">>},
                connect = {<<"IN">>,<<"IP4">>,<<"127.0.0.1">>}},

    % UA2 is refresher, so it will send refresh reminder in 1 sec
    ok = tests_util:wait(Ref, [
        {timer_test_ua2, dialog_confirmed},
        {timer_test_ua1, dialog_confirmed},
        {timer_test_ua2, ack},
        {timer_test_ua2, {refresh, SDP2}}      % The same SDP timer_test_ua2 sent
    ]),

    Dialog1B = nksip_dialog_lib:remote_id(Dialog1A, timer_test_ua2),
    {ok, 2} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 2 } = nksip_timers:get_session_expires(Dialog1B),
    {ok, expired} = nksip_timers:get_session_refresh( Dialog1B),

    % Now timer_test_ua2 (current refresher) "refreshs" the dialog
    % We must include a min_se option because of timer_test_ua2 has no received any 422
    % in current dialog, so it will otherwhise send no Min-SE header, and
    % timer_test_ua1 would use a 90-sec default, incrementing Session-Expires also.
    %
    % We use Min-SE=3, so timer_test_ua1 will increment Session-Timer to 3

    {ok, 200, _} = nksip_uac:invite(Dialog1B, [auto_2xx_ack, {body, SDP2}, 
                                               {sip_timers_min_se, 3}]),

    ok = tests_util:wait(Ref, [
        {timer_test_ua2, dialog_confirmed},
        {timer_test_ua1, dialog_confirmed},
        {timer_test_ua1, ack},
        {timer_test_ua2, {refresh, SDP2}}
    ]),

    {ok, 3} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 3} = nksip_timers:get_session_expires(Dialog1A),
    {ok, expired} = nksip_timers:get_session_refresh( Dialog1B),

    % Now we send another refresh from timer_test_ua2 to timer_test_ua1, this time using UPDATE
    % An automatic Min-SE header is not added by NkSIP because timer_test_ua2 has not
    % received any 422 or refresh request with Min-SE header
    % The default Min-SE is 90 secs, so the refresh interval is updated to that

    {ok, 200, [{<<"session-expires">>, [<<"90;refresher=uac">>]}]} = 
        nksip_uac:update(Dialog1B, [{get_meta,[<<"session-expires">>]}]),

    {ok, 90} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 90} = nksip_timers:get_session_expires(Dialog1B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1B))),


    % Before waiting for expiration, timer_test_ua1 sends a refresh to timer_test_ua2.
    % We force session_expires to a value timer_test_ua2 will not accept, so it will reply
    % 422 and a new request will be sent

    {ok, 200, [{<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(Dialog1A, [{sip_timers_se, 1}, {get_meta, [<<"session-expires">>]}]),

    {ok, 2} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 2} = nksip_timers:get_session_expires(Dialog1B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1B))),

    % Now both timer_test_ua1 and timer_test_ua2 has received a 422 response or a refresh request with MinSE,
    % so it will be used in new requests
    % NkSIP includes atomatically stored Session-Expires and Min-SE
    % It detects the remote party (timer_test_ua2) is currently refreshing a proposes refresher=uas

    {ok, 200, [{<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(Dialog1A, [get_request, CB, {get_meta, [<<"session-expires">>]}]),

    receive 
        {Ref, #sipmsg{headers=Headers3}} ->
            {2, [{<<"refresher">>, uas}]} = proplists:get_value(<<"session-expires">>, Headers3),
            2 = proplists:get_value(<<"min-se">>, Headers3)
    after 1000 ->
        error(basic)
    end,

    {ok, 2} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 2} = nksip_timers:get_session_expires(Dialog1B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1B))),

    % Now timer_test_ua1 refreshes, but change roles, becoming refresher.
    % Using session_expires option overrides automatic behaviour, no Min-SE is sent

    {ok, 200, []} = nksip_uac:update(Dialog1A, [{sip_timers_se, {2,uac}}]),

    {ok, 90} = nksip_timers:get_session_expires(Dialog1A),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1A))),
    {ok, 90} = nksip_timers:get_session_expires(Dialog1B),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1B),

    
    % Now timer_test_ua1 send no Session-Expires, but timer_test_ua2 insists, using default time
    % (and changing roles again)
    {ok, 200, []} = nksip_uac:update(Dialog1A, [{replace, session_expires, <<>>}]),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog1B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1B))),


    % Lower time to wait for timeout

    {ok, 200, []} = nksip_uac:update(Dialog1A, [{sip_timers_se, {2,uac}}, {sip_timers_min_se, 2}]),
    SDP3 = nksip_sdp:increment(SDP2),
    ok = tests_util:wait(Ref, [
        {timer_test_ua1, {refresh, SDP3}},
        {timer_test_ua2, timeout},
        {timer_test_ua1, bye},                         % timer_test_ua1 receives BYE
        {timer_test_ua1, {dialog_stop, callee_bye}},
        {timer_test_ua2, {dialog_stop, callee_bye}}
    ]),

    ok.


proxy() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    CB = {callback, fun ({req, R, _Call}) -> Self ! {Ref, R}; (_) -> ok end},

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog, Dialog1A}, {<<"session-expires">>,[<<"3;refresher=uas">>]}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5072",
            [{sip_timers_se, 1}, {get_meta, [<<"session-expires">>]},
             CB, auto_2xx_ack, get_request, {body, SDP1}, RepHd,
             {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
   
    % Start events also at timer_test_ua1
    ok =  nkserver:put(timer_test_ua1, dialogs, [{Dialog1A, Ref, Self}]),

    {ok, CallId1} = nksip_dialog:call_id(Dialog1A),
    receive 
        {Ref, #sipmsg{headers=Headers1, call_id=CallId1}} ->
            1 = proplists:get_value(<<"session-expires">>, Headers1),
            undefined = proplists:get_value(<<"min-se">>, Headers1)
    after 1000 ->
        error(basic)
    end,

    receive 
        {Ref, #sipmsg{headers=Headers2, call_id=CallId1}} ->
            <<"2">> = proplists:get_value(<<"session-expires">>, Headers2),
            <<"2">> = proplists:get_value(<<"min-se">>, Headers2)
    after 1000 ->
        error(basic)
    end,
    
    receive 
        {Ref, #sipmsg{headers=Headers3, call_id=CallId1}} ->
            <<"3">> = proplists:get_value(<<"session-expires">>, Headers3),
            <<"3">> = proplists:get_value(<<"min-se">>, Headers3)
    after 1000 ->
        error(basic)
    end,

    
    ok = tests_util:wait(Ref, [
        {timer_test_ua2, dialog_confirmed},
        {timer_test_ua1, dialog_confirmed},
        {timer_test_ua2, ack}
    ]),

    Dialog1B = nksip_dialog_lib:remote_id(Dialog1A, timer_test_ua2),
    {ok, 3} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 3} = nksip_timers:get_session_expires(Dialog1B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog1B))),

    {ok, 3} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),
    {ok, 3} = nksip_timers:get_session_expires(Dialog1A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog1A),

    {ok, 200, []} = nksip_uac:update(Dialog1A, [{sip_timers_se, 1000}]),
    {ok, 1000} = nksip_timers:get_session_expires(Dialog1A),
    {ok, 1000} = nksip_timers:get_session_expires(Dialog1B),
    {ok, 1000} = nksip_timers:get_session_expires(Dialog1A),
    {ok, 1000} = nksip_timers:get_session_expires(Dialog1A),

    {ok, 200, []} = nksip_uac:bye(Dialog1B, []),


    % timer_test_p1 received a Session-Timer of 1801. Since it has configured a
    % time of 1800, and it is > MinSE, it chages the value
    {ok, 200, [{dialog, Dialog2}, {<<"session-expires">>,[<<"1800;refresher=uas">>]}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5072",
            [{sip_timers_se, 1801}, {get_meta, [<<"session-expires">>]},
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
    {ok, 200, []} = nksip_uac:bye(Dialog2, []),

    
    % Now timer_test_ua1 does not support the timer extension. timer_test_p1 adds a Session-Expires
    % header. timer_test_ua2 accepts the session proposal, but it doesn't add the
    % 'Require' header
    {ok, 200, [{dialog, Dialog3A}, {<<"session-expires">>,[<<"1800;refresher=uas">>]}, 
               {require, []}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5072",
            [{replace, sip_timers_se, <<>>}, {supported, "100rel,path"}, 
             {get_meta, [<<"session-expires">>, require]},
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog3B = nksip_dialog_lib:remote_id(Dialog3A, timer_test_ua2),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog3A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog3A),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog3B),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog3B))),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog3A),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog3A),
    {ok, 200, []} = nksip_uac:bye(Dialog3A, []),

    % timer_test_ua3 doesn't support the timer extension. It does not return any
    % Session-Expires, but timer_test_p2 remembers timer_test_ua1 supports the extension
    % and adds a response and require
    {ok, 200, [{dialog, Dialog4A}, {<<"session-expires">>,[<<"1800;refresher=uac">>]}, 
               {require, [<<"timer">>]}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5073",
            [{get_meta,[<<"session-expires">>, require]},
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog4B = nksip_dialog_lib:remote_id(Dialog4A, timer_test_ua3),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog4A),
    true = erlang:is_integer(element(2, nksip_timers:get_session_refresh( Dialog4A))),
    {ok, undefined} = nksip_timers:get_session_expires(Dialog4B),
    {ok, undefined}  = nksip_timers:get_session_refresh( Dialog4B),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog4A),
    {ok, 1800} = nksip_timers:get_session_expires(Dialog4A),
    {ok, 200, []} = nksip_uac:bye(Dialog4A, []),


    % None of UAC and UAS supports the extension
    % Router adds a Session-Expires header, but it is not honored
    {ok, 200, [{dialog, Dialog5A}, {<<"session-expires">>,[]}, 
               {require, []}]} = 
        nksip_uac:invite(timer_test_ua1, "sip:127.0.0.1:5073",
            [{replace, sip_timers_se, <<>>}, {supported, "100rel,path"}, 
             {get_meta, [<<"session-expires">>, require]},
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog5B = nksip_dialog_lib:remote_id(Dialog5A, timer_test_ua3),
    {ok, undefined} = nksip_timers:get_session_expires(Dialog5A),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog5A),
    {ok, undefined} = nksip_timers:get_session_expires(Dialog5B),
    {ok, undefined} = nksip_timers:get_session_refresh( Dialog5B),
    {ok, undefined} = nksip_timers:get_session_expires(Dialog5A),
    {ok, undefined} = nksip_timers:get_session_expires(Dialog5A),
    {ok, 200, []} = nksip_uac:bye(Dialog5A, []),
    ok.

