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

% timer_test_() ->
%     {setup, spawn, 
%         fun() -> start() end,
%         fun(_) -> stop() end,
%         [
%             fun basic/0
%         ]
%     }.

start() ->
    tests_util:start_nksip(),

    % ok = timer_server:start({timer, p1}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5060}},
    %     {transport, {tls, {0,0,0,0}, 5061}}]),

    % ok = timer_server:start({timer, p2}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5070}},
    %     {transport, {tls, {0,0,0,0}, 5071}}]),

    % ok = timer_server:start({timer, p3}, [
    %     {local_host, "localhost"},
    %     {transport, {udp, {0,0,0,0}, 5080}},
    %     {transport, {tls, {0,0,0,0}, 5081}}]),

    ok = sipapp_endpoint:start({timer, ua1}, [
        {from, "sip:ua1@nksip"},
        % {route, "<sip:127.0.0.1;lr>"},
        {local_host, "127.0.0.1"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5071}},
        {min_session_expires, 1}
    ]),

    ok = sipapp_endpoint:start({timer, ua2}, [
        % {route, "<sip:127.0.0.1:5090;lr>"},
        {local_host, "127.0.0.1"},
        no_100,
        {transport, {udp, {0,0,0,0}, 5072}},
        {min_session_expires, 2}
    ]),
    
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->

    % ok = sipapp_server:stop({timer, p1}),
    % ok = sipapp_server:stop({timer, p2}),
    % ok = sipapp_server:stop({timer, p3}),
    ok = sipapp_endpoint:stop({timer, ua1}),
    ok = sipapp_endpoint:stop({timer, ua2}).


basic() ->
    C1 = {timer, ua1},
    C2 = {timer, ua2},
    Ref = make_ref(),
    Self = self(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},
    RepHd = {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))},

    % % C2 has a min_session_expires of 2
    % {error, invalid_session_expires} = 
    %     nksip_uac:invite(C2, "sip:any", [{session_expires, 1}]),


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
        {ua1, bye},
        {ua1, {dialog_stop, callee_bye}},
        {ua2, {dialog_stop, callee_bye}}
    ]),





    ok.

    % {ok, 200, _} = nksip_uac:invite(C1, "sip:127.0.0.1:5090", 
    %     [auto_2xx_ack, {session_expires, 10}]),    

        



