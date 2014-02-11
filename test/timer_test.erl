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

-module(timer_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

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

    ok = sipapp_endpoint:start({timer, ua1}, [
        {from, "sip:ua1@nksip"},
        {local_host, "127.0.0.1"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5071}},
        {min_session_expires, 1}
    ]),

    ok = sipapp_endpoint:start({timer, ua2}, [
        {local_host, "127.0.0.1"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5072}},
        {min_session_expires, 2}
    ]),
    
    ok = sipapp_endpoint:start({timer, ua3}, [
        {local_host, "127.0.0.1"},
        no_100,
        {supported, ""},
        {transport, {udp, {0,0,0,0}, 5073}}
    ]),


    ok = sipapp_server:start({timer, p1}, [
        {local_host, "localhost"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5060}},
        {min_session_expires, 2}
    ]),

    ok = sipapp_server:start({timer, p2}, [
        {local_host, "localhost"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5070}},
        {min_session_expires, 3}
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->

    ok = sipapp_server:stop({timer, p1}),
    ok = sipapp_server:stop({timer, p2}),
    ok = sipapp_endpoint:stop({timer, ua1}),
    ok = sipapp_endpoint:stop({timer, ua2}),
    ok = sipapp_endpoint:stop({timer, ua3}).


basic() ->
    C1 = {timer, ua1},
    C2 = {timer, ua2},
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    % C2 has a min_session_expires of 2
    {error, invalid_session_expires} = 
        nksip_uac:invite(C2, "sip:any", [{session_expires, 1}]),

    % C1 sends a INVITE to C2, with session_expires=1
    % C2 rejects the request, with a 422 response, including Min-SE=2
    % C1 updates its Min-SE to 2, and updates session_expires=2
    % C2 receives again the INVITE. Now it is valid.

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog_id, Dialog1A}, {<<"Session-Expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5072", 
            [{session_expires, 1}, {fields, [<<"Session-Expires">>]}, 
             CB, auto_2xx_ack, get_request, {body, SDP1}, {headers, [RepHd]}]),
   
    % Start events also at C1
    sipapp_endpoint:start_events(C1, Ref, Self, Dialog1A),

    CallId1 = nksip_dialog:call_id(Dialog1A),
    CSeq1 = receive 
        {Ref, #sipmsg{cseq=CSeq1_0, headers=Headers1, call_id=CallId1}} ->
            <<"1">> = proplists:get_value(<<"Session-Expires">>, Headers1),
            undefined = proplists:get_value(<<"Min-SE">>, Headers1),
            CSeq1_0
    after 1000 ->
        error(basic)
    end,

    receive 
        {Ref, #sipmsg{cseq=CSeq2, headers=Headers2, call_id=CallId1}} ->
            <<"2">> = proplists:get_value(<<"Session-Expires">>, Headers2),
            <<"2">> = proplists:get_value(<<"Min-SE">>, Headers2),
            CSeq2 = CSeq1+1
    after 1000 ->
        error(basic)
    end,
    
    % SDP2 is the answer from C2; ithas "nksip.auto" as domains, update with real data
    SDP2 = (nksip_sdp:increment(SDP1))#sdp{
                address={<<"IN">>,<<"IP4">>,<<"127.0.0.1">>},
                connect = {<<"IN">>,<<"IP4">>,<<"127.0.0.1">>}},

    % UA2 is refresher, so it will send refresh reminder in 1 sec
    ok = tests_util:wait(Ref, [
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua2, ack},
        {ua2, {refresh, SDP2}}      % The same SDP C2 sent
    ]),

    Dialog1B = nksip_dialog:remote_id(C1, Dialog1A),
    2 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    expired = nksip_dialog:field(C2, Dialog1B, invite_refresh),

    % Now C2 (current refresher) "refreshs" the dialog
    % We must include a min_se option because of C2 has no received any 422 
    % in current dialog, so it will otherwhise send no Min-SE header, and
    % C1 would use a 90-sec default, incrementing Session-Expires also.
    %
    % We use Min-SE=3, so C1 will increment Session-Timer to 3

    {ok, 200, _} = nksip_uac:invite(C2, Dialog1B, [auto_2xx_ack, {body, SDP2}, 
                                                   {min_se, 3}]),

    ok = tests_util:wait(Ref, [
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua1, ack},
        {ua2, {refresh, SDP2}}
    ]),

    3 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    expired = nksip_dialog:field(C2, Dialog1B, invite_refresh),

    % Now we send another refresh from C2 to C1, this time using UPDATE
    % An automatic Min-SE header is not added by NkSIP because C2 has not
    % received any 422 or refresh request with Min-SE header
    % The default Min-SE is 90 secs, so the refresh interval is updated to that

    {ok, 200, [{<<"Session-Expires">>, [<<"90;refresher=uac">>]}]} = 
        nksip_uac:update(C2, Dialog1B, [{fields, [<<"Session-Expires">>]}]),

    90 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    90 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog1B, invite_refresh)),


    % Before waiting for expiration, C1 sends a refresh to C2.
    % We force session_expires to a value C2 will not accept, so it will reply 
    % 422 and a new request will be sent

    {ok, 200, [{<<"Session-Expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(C1, Dialog1A, [{session_expires, 1}, {fields, [<<"Session-Expires">>]}]),

    2 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog1B, invite_refresh)),

    % Now both C1 and C2 has received a 422 response or a refresh request with MinSE,
    % so it will be used in new requests
    % NkSIP includes atomatically stored Session-Expires and Min-SE
    % It detects the remote party (C2) is currently refreshing a proposes refresher=uas

    {ok, 200, [{<<"Session-Expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(C1, Dialog1A, [get_request, CB, {fields, [<<"Session-Expires">>]}]),

    receive 
        {Ref, #sipmsg{headers=Headers3}} ->
            <<"2;refresher=uas">> = proplists:get_value(<<"Session-Expires">>, Headers3),
            <<"2">> = proplists:get_value(<<"Min-SE">>, Headers3)
    after 1000 ->
        error(basic)
    end,

    2 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog1B, invite_refresh)),

    % Now C1 refreshes, but change roles, becoming refresher. 
    % Using session_expires option overrides automatic behaviour, no Min-SE is sent

    {ok, 200, []} = nksip_uac:update(C1, Dialog1A, [{session_expires, {2,uac}}]),

    90 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    true = is_integer(nksip_dialog:field(C1, Dialog1A, invite_refresh)),
    90 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    undefined = nksip_dialog:field(C2, Dialog1B, invite_refresh),

    
    % Now C1 send no Session-Expires, but C2 insists, using default time
    % (and changing roles again)
    {ok, 200, []} = nksip_uac:update(C1, Dialog1A, [{session_expires, 0}]),
    1800 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    1800 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog1B, invite_refresh)),


    % Lower time to wait for timeout

    {ok, 200, []} = nksip_uac:update(C1, Dialog1A, [{session_expires, {2,uac}}, {min_se, 2}]),
    SDP3 = nksip_sdp:increment(SDP2),
    ok = tests_util:wait(Ref, [
        {ua1, {refresh, SDP3}},
        {ua2, timeout},
        {ua1, bye},                         % C1 receives BYE
        {ua1, {dialog_stop, callee_bye}},
        {ua2, {dialog_stop, callee_bye}}
    ]),

    ok.


proxy() ->
    C1 = {timer, ua1},
    C2 = {timer, ua2},
    C3 = {timer, ua3},
    P1 = {timer, p1},
    P2 = {timer, p2},
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog_id, Dialog1A}, {<<"Session-Expires">>,[<<"3;refresher=uas">>]}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5072", 
            [{session_expires, 1}, {fields, [<<"Session-Expires">>]}, 
             CB, auto_2xx_ack, get_request, {body, SDP1}, {headers, [RepHd]},
             {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
   
    % Start events also at C1
    sipapp_endpoint:start_events(C1, Ref, Self, Dialog1A),

    CallId1 = nksip_dialog:call_id(Dialog1A),
    receive 
        {Ref, #sipmsg{headers=Headers1, call_id=CallId1}} ->
            <<"1">> = proplists:get_value(<<"Session-Expires">>, Headers1),
            undefined = proplists:get_value(<<"Min-SE">>, Headers1)
    after 1000 ->
        error(basic)
    end,

    receive 
        {Ref, #sipmsg{headers=Headers2, call_id=CallId1}} ->
            <<"2">> = proplists:get_value(<<"Session-Expires">>, Headers2),
            <<"2">> = proplists:get_value(<<"Min-SE">>, Headers2)
    after 1000 ->
        error(basic)
    end,
    
    receive 
        {Ref, #sipmsg{headers=Headers3, call_id=CallId1}} ->
            <<"3">> = proplists:get_value(<<"Session-Expires">>, Headers3),
            <<"3">> = proplists:get_value(<<"Min-SE">>, Headers3)
    after 1000 ->
        error(basic)
    end,

    
    ok = tests_util:wait(Ref, [
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua2, ack}
    ]),

    Dialog1B = nksip_dialog:remote_id(C1, Dialog1A),
    3 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog1B, invite_refresh)),

    3 = nksip_dialog:field(P1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(P1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(P2, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(P2, Dialog1A, invite_refresh),

    {ok, 200, []} = nksip_uac:update(C1, Dialog1A, [{session_expires, 1000}]),
    1000 = nksip_dialog:field(C1, Dialog1A, invite_session_expires),
    1000 = nksip_dialog:field(C2, Dialog1B, invite_session_expires),
    1000 = nksip_dialog:field(P1, Dialog1A, invite_session_expires),
    1000 = nksip_dialog:field(P2, Dialog1A, invite_session_expires),

    {ok, 200, []} = nksip_uac:bye(C2, Dialog1B, []),


    % P1 received a Session-Timer of 1801. Since it has configured a 
    % time of 1800, and it is > MinSE, it chages the value
    {ok, 200, [{dialog_id, Dialog2}, {<<"Session-Expires">>,[<<"1800;refresher=uas">>]}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5072", 
            [{session_expires, 1801}, {fields, [<<"Session-Expires">>]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
    {ok, 200, []} = nksip_uac:bye(C1, Dialog2, []),

    
    % Now C1 does not support the timer extension. P1 adds a Session-Expires
    % header. C2 accepts the session proposal, but it doesn't add the
    % 'Require' header
    {ok, 200, [{dialog_id, Dialog3A}, {<<"Session-Expires">>,[<<"1800;refresher=uas">>]}, 
               {parsed_require, []}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5072", 
            [{session_expires, 0}, {supported, "100rel,path"}, 
             {fields, [<<"Session-Expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog3B = nksip_dialog:remote_id(C1, Dialog3A),
    1800 = nksip_dialog:field(C1, Dialog3A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog3A, invite_refresh),
    1800 = nksip_dialog:field(C2, Dialog3B, invite_session_expires),
    true = is_integer(nksip_dialog:field(C2, Dialog3B, invite_refresh)),
    1800 = nksip_dialog:field(P1, Dialog3A, invite_session_expires),
    1800 = nksip_dialog:field(P2, Dialog3A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(C1, Dialog3A, []),

    % Now C3 not support the timer extension. It does not return any
    % Session-Expires, but P2 remembers C1 supports the extension
    % and adds a response and require
    {ok, 200, [{dialog_id, Dialog4A}, {<<"Session-Expires">>,[<<"1800;refresher=uac">>]}, 
               {parsed_require, [<<"timer">>]}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5073", 
            [{fields, [<<"Session-Expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog4B = nksip_dialog:remote_id(C1, Dialog4A),
    1800 = nksip_dialog:field(C1, Dialog4A, invite_session_expires),
    true = is_integer(nksip_dialog:field(C1, Dialog4A, invite_refresh)),
    undefined = nksip_dialog:field(C3, Dialog4B, invite_session_expires),
    undefined  = nksip_dialog:field(C3, Dialog4B, invite_refresh),
    1800 = nksip_dialog:field(P1, Dialog4A, invite_session_expires),
    1800 = nksip_dialog:field(P2, Dialog4A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(C1, Dialog4A, []),


    % None of UAC and UAS supports the extension
    % Router adds a Session-Expires header, but it is not honored
    {ok, 200, [{dialog_id, Dialog5A}, {<<"Session-Expires">>,[]}, 
               {parsed_require, []}]} = 
        nksip_uac:invite(C1, "sip:127.0.0.1:5073", 
            [{session_expires, 0}, {supported, "100rel,path"}, 
             {fields, [<<"Session-Expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog5B = nksip_dialog:remote_id(C1, Dialog5A),
    undefined = nksip_dialog:field(C1, Dialog5A, invite_session_expires),
    undefined = nksip_dialog:field(C1, Dialog5A, invite_refresh),
    undefined = nksip_dialog:field(C3, Dialog5B, invite_session_expires),
    undefined = nksip_dialog:field(C3, Dialog5B, invite_refresh),
    undefined = nksip_dialog:field(P1, Dialog5A, invite_session_expires),
    undefined = nksip_dialog:field(P2, Dialog5A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(C1, Dialog5A, []),

    ok.





