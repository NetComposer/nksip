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

    ok = nksip:start(p1, ?MODULE, p1, [
        {local_host, "localhost"},
        no_100,
        {transports, [{udp, all, 5060}]},
        {min_session_expires, 2}
    ]),

    ok = nksip:start(p2, ?MODULE, p2, [
        {local_host, "localhost"},
        no_100,
        {transports, [{udp, all, 5070}]},
        {min_session_expires, 3}
    ]),

    ok = nksip:start(ua1, ?MODULE, ua1, [
        {from, "sip:ua1@nksip"},
        {local_host, "127.0.0.1"},
        no_100,
        {transports, [{udp, all, 5071}]},
        {min_session_expires, 1}
    ]),

    ok = nksip:start(ua2, ?MODULE, ua2, [
        {local_host, "127.0.0.1"},
        no_100,
        {transports, [{udp, all, 5072}]},
        {min_session_expires, 2}
    ]),
    
    ok = nksip:start(ua3, ?MODULE, ua3, [
        {local_host, "127.0.0.1"},
        no_100,
        {supported, ""},
        {transports, [{udp, all, 5073}]}
    ]),


    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->

    ok = nksip:stop(p1),
    ok = nksip:stop(p2),
    ok = nksip:stop(ua1),
    ok = nksip:stop(ua2),
    ok = nksip:stop(ua3).


basic() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},

    % ua2 has a min_session_expires of 2
    {error, {invalid, session_expires}} = 
        nksip_uac:invite(ua2, "sip:any", [{session_expires, 1}]),

    % ua1 sends a INVITE to ua2, with session_expires=1
    % ua2 rejects the request, with a 422 response, including Min-SE=2
    % ua1 updates its Min-SE to 2, and updates session_expires=2
    % ua2 receives again the INVITE. Now it is valid.

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog_id, Dialog1A}, {<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5072", 
            [{session_expires, 1}, {meta, [<<"session-expires">>]}, 
             CB, auto_2xx_ack, get_request, {body, SDP1}, RepHd]),
   
    % Start events also at ua1
    nksip:put(ua1, dialogs, [{Dialog1A, Ref, Self}]),

    CallId1 = nksip_dialog:call_id(Dialog1A),
    CSeq1 = receive 
        {Ref, #sipmsg{cseq={CSeq1_0, _}, headers=Headers1, call_id=CallId1}} ->
            1 = proplists:get_value(<<"session-expires">>, Headers1),
            undefined = proplists:get_value(<<"min-sE">>, Headers1),
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
    
    % SDP2 is the answer from ua2; ithas "nksip.auto" as domains, update with real data
    SDP2 = (nksip_sdp:increment(SDP1))#sdp{
                address={<<"IN">>,<<"IP4">>,<<"127.0.0.1">>},
                connect = {<<"IN">>,<<"IP4">>,<<"127.0.0.1">>}},

    % UA2 is refresher, so it will send refresh reminder in 1 sec
    ok = tests_util:wait(Ref, [
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua2, ack},
        {ua2, {refresh, SDP2}}      % The same SDP ua2 sent
    ]),

    Dialog1B = nksip_dialog:remote_id(ua1, Dialog1A),
    2 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    expired = nksip_dialog:field(ua2, Dialog1B, invite_refresh),

    % Now ua2 (current refresher) "refreshs" the dialog
    % We must include a min_se option because of ua2 has no received any 422 
    % in current dialog, so it will otherwhise send no Min-SE header, and
    % ua1 would use a 90-sec default, incrementing Session-Expires also.
    %
    % We use Min-SE=3, so ua1 will increment Session-Timer to 3

    {ok, 200, _} = nksip_uac:invite(ua2, Dialog1B, [auto_2xx_ack, {body, SDP2}, 
                                                   {min_se, 3}]),

    ok = tests_util:wait(Ref, [
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua1, ack},
        {ua2, {refresh, SDP2}}
    ]),

    3 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    expired = nksip_dialog:field(ua2, Dialog1B, invite_refresh),

    % Now we send another refresh from ua2 to ua1, this time using UPDATE
    % An automatic Min-SE header is not added by NkSIP because ua2 has not
    % received any 422 or refresh request with Min-SE header
    % The default Min-SE is 90 secs, so the refresh interval is updated to that

    {ok, 200, [{<<"session-expires">>, [<<"90;refresher=uac">>]}]} = 
        nksip_uac:update(ua2, Dialog1B, [{meta,[<<"session-expires">>]}]),

    90 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    90 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog1B, invite_refresh)),


    % Before waiting for expiration, ua1 sends a refresh to ua2.
    % We force session_expires to a value ua2 will not accept, so it will reply 
    % 422 and a new request will be sent

    {ok, 200, [{<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(ua1, Dialog1A, [{session_expires, 1}, {meta, [<<"session-expires">>]}]),

    2 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog1B, invite_refresh)),

    % Now both ua1 and ua2 has received a 422 response or a refresh request with MinSE,
    % so it will be used in new requests
    % NkSIP includes atomatically stored Session-Expires and Min-SE
    % It detects the remote party (ua2) is currently refreshing a proposes refresher=uas

    {ok, 200, [{<<"session-expires">>,[<<"2;refresher=uas">>]}]} = 
        nksip_uac:update(ua1, Dialog1A, [get_request, CB, {meta, [<<"session-expires">>]}]),

    receive 
        {Ref, #sipmsg{headers=Headers3}} ->
            {2, [{<<"refresher">>, uas}]} = proplists:get_value(<<"session-expires">>, Headers3),
            2 = proplists:get_value(<<"min-se">>, Headers3)
    after 1000 ->
        error(basic)
    end,

    2 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    2 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog1B, invite_refresh)),

    % Now ua1 refreshes, but change roles, becoming refresher. 
    % Using session_expires option overrides automatic behaviour, no Min-SE is sent

    {ok, 200, []} = nksip_uac:update(ua1, Dialog1A, [{session_expires, {2,uac}}]),

    90 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua1, Dialog1A, invite_refresh)),
    90 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    undefined = nksip_dialog:field(ua2, Dialog1B, invite_refresh),

    
    % Now ua1 send no Session-Expires, but ua2 insists, using default time
    % (and changing roles again)
    {ok, 200, []} = nksip_uac:update(ua1, Dialog1A, [{replace, session_expires, <<>>}]),
    1800 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    1800 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog1B, invite_refresh)),


    % Lower time to wait for timeout

    {ok, 200, []} = nksip_uac:update(ua1, Dialog1A, [{session_expires, {2,uac}}, {min_se, 2}]),
    SDP3 = nksip_sdp:increment(SDP2),
    ok = tests_util:wait(Ref, [
        {ua1, {refresh, SDP3}},
        {ua2, timeout},
        {ua1, bye},                         % ua1 receives BYE
        {ua1, {dialog_stop, callee_bye}},
        {ua2, {dialog_stop, callee_bye}}
    ]),

    ok.


proxy() ->
    Self = self(),
    {Ref, RepHd} = tests_util:get_ref(),
    CB = {callback, fun ({req, R}) -> Self ! {Ref, R}; (_) -> ok end},

    SDP1 = nksip_sdp:new(),
    {ok, 200, [{dialog_id, Dialog1A}, {<<"session-expires">>,[<<"3;refresher=uas">>]}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5072", 
            [{session_expires, 1}, {meta, [<<"session-expires">>]}, 
             CB, auto_2xx_ack, get_request, {body, SDP1}, RepHd,
             {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
   
    % Start events also at ua1
    nksip:put(ua1, dialogs, [{Dialog1A, Ref, Self}]),

    CallId1 = nksip_dialog:call_id(Dialog1A),
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
        {ua2, dialog_confirmed},
        {ua1, dialog_confirmed},
        {ua2, ack}
    ]),

    Dialog1B = nksip_dialog:remote_id(ua1, Dialog1A),
    3 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog1B, invite_refresh)),

    3 = nksip_dialog:field(p1, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(p1, Dialog1A, invite_refresh),
    3 = nksip_dialog:field(p2, Dialog1A, invite_session_expires),
    undefined = nksip_dialog:field(p2, Dialog1A, invite_refresh),

    {ok, 200, []} = nksip_uac:update(ua1, Dialog1A, [{session_expires, 1000}]),
    1000 = nksip_dialog:field(ua1, Dialog1A, invite_session_expires),
    1000 = nksip_dialog:field(ua2, Dialog1B, invite_session_expires),
    1000 = nksip_dialog:field(p1, Dialog1A, invite_session_expires),
    1000 = nksip_dialog:field(p2, Dialog1A, invite_session_expires),

    {ok, 200, []} = nksip_uac:bye(ua2, Dialog1B, []),


    % p1 received a Session-Timer of 1801. Since it has configured a 
    % time of 1800, and it is > MinSE, it chages the value
    {ok, 200, [{dialog_id, Dialog2}, {<<"session-expires">>,[<<"1800;refresher=uas">>]}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5072", 
            [{session_expires, 1801}, {meta, [<<"session-expires">>]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),
    {ok, 200, []} = nksip_uac:bye(ua1, Dialog2, []),

    
    % Now ua1 does not support the timer extension. p1 adds a Session-Expires
    % header. ua2 accepts the session proposal, but it doesn't add the
    % 'Require' header
    {ok, 200, [{dialog_id, Dialog3A}, {<<"session-expires">>,[<<"1800;refresher=uas">>]}, 
               {parsed_require, []}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5072", 
            [{replace, session_expires, <<>>}, {supported, "100rel,path"}, 
             {meta, [<<"session-expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog3B = nksip_dialog:remote_id(ua1, Dialog3A),
    1800 = nksip_dialog:field(ua1, Dialog3A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog3A, invite_refresh),
    1800 = nksip_dialog:field(ua2, Dialog3B, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua2, Dialog3B, invite_refresh)),
    1800 = nksip_dialog:field(p1, Dialog3A, invite_session_expires),
    1800 = nksip_dialog:field(p2, Dialog3A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(ua1, Dialog3A, []),

    % Now ua3 not support the timer extension. It does not return any
    % Session-Expires, but p2 remembers ua1 supports the extension
    % and adds a response and require
    {ok, 200, [{dialog_id, Dialog4A}, {<<"session-expires">>,[<<"1800;refresher=uac">>]}, 
               {parsed_require, [<<"timer">>]}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5073", 
            [{meta,[<<"session-expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog4B = nksip_dialog:remote_id(ua1, Dialog4A),
    1800 = nksip_dialog:field(ua1, Dialog4A, invite_session_expires),
    true = is_integer(nksip_dialog:field(ua1, Dialog4A, invite_refresh)),
    undefined = nksip_dialog:field(ua3, Dialog4B, invite_session_expires),
    undefined  = nksip_dialog:field(ua3, Dialog4B, invite_refresh),
    1800 = nksip_dialog:field(p1, Dialog4A, invite_session_expires),
    1800 = nksip_dialog:field(p2, Dialog4A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(ua1, Dialog4A, []),


    % None of UAC and UAS supports the extension
    % Router adds a Session-Expires header, but it is not honored
    {ok, 200, [{dialog_id, Dialog5A}, {<<"session-expires">>,[]}, 
               {parsed_require, []}]} = 
        nksip_uac:invite(ua1, "sip:127.0.0.1:5073", 
            [{replace, session_expires, <<>>}, {supported, "100rel,path"}, 
             {meta, [<<"session-expires">>, parsed_require]}, 
             auto_2xx_ack, {body, SDP1}, {route, "<sip:127.0.0.1:5060;lr>"}
            ]),

    timer:sleep(100),
    Dialog5B = nksip_dialog:remote_id(ua1, Dialog5A),
    undefined = nksip_dialog:field(ua1, Dialog5A, invite_session_expires),
    undefined = nksip_dialog:field(ua1, Dialog5A, invite_refresh),
    undefined = nksip_dialog:field(ua3, Dialog5B, invite_session_expires),
    undefined = nksip_dialog:field(ua3, Dialog5B, invite_refresh),
    undefined = nksip_dialog:field(p1, Dialog5A, invite_session_expires),
    undefined = nksip_dialog:field(p2, Dialog5A, invite_session_expires),
    {ok, 200, []} = nksip_uac:bye(ua1, Dialog5A, []),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.


route(_ReqId, _Scheme, _User, _Domain, _From, p1=State) ->
    Opts = [record_route, {route, "<sip:127.0.0.1:5070;lr>"}],
    {reply, {proxy, ruri, Opts}, State};

route(_ReqId, _Scheme, _User, _Domain, _From, p2=State) ->
    Opts = [record_route],
    {reply, {proxy, ruri, Opts}, State};

route(_ReqId, _Scheme, _User, _Domain, _From, State) ->
    {reply, process, State}.


invite(ReqId, Meta, _From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Body = nksip_lib:get_value(body, Meta),
    Body1 = nksip_sdp:increment(Body),
    {reply, {answer, Body1}, State}.

reinvite(ReqId, Meta, From, State) ->
    invite(ReqId, Meta, From, State).


ack(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, ack),
    {reply, ok, State}.


update(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.


bye(_ReqId, Meta, _From, AppId=State) ->
    tests_util:send_ref(AppId, Meta, bye),
    {reply, ok, State}.


dialog_update(DialogId, Update, AppId=State) ->
    tests_util:dialog_update(DialogId, Update, AppId),
    {noreply, State}.





