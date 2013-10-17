%% -------------------------------------------------------------------
%%
%% uac_test: Basic Test Suite
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

-module(uac_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all]).


uac_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uac/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),
    ok = sipapp_endpoint:start({uac, client1}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}}]),
    ok = sipapp_endpoint:start({uac, client2}, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = sipapp_endpoint:stop({uac, client1}),
    ok = sipapp_endpoint:stop({uac, client2}).


uac() ->
    C2 = {uac, client2},
    SipC1 = "sip:127.0.0.1:5070",

    {error, invalid_uri} = nksip_uac:options(C2, "sip::a", []),
    {error, invalid_from} = nksip_uac:options(C2, SipC1, [{from, "<>"}]),
    {error, invalid_to} = nksip_uac:options(C2, SipC1, [{to, "<>"}]),
    {error, invalid_route} = nksip_uac:options(C2, SipC1, [{route, "<>"}]),
    {error, invalid_contact} = nksip_uac:options(C2, SipC1, [{contact, "<>"}]),
    {error, invalid_cseq} = nksip_uac:options(C2, SipC1, [{cseq, -1}]),
    nksip_trace:error("Next error about 'unknown_siapp' is expected"),
    {error, unknown_sipapp} = nksip_uac:options(none, SipC1, []),
    nksip_trace:error("Next error about 'too_many_calls' is expected"),
    nksip_counters:incr(nksip_calls, 1000000000),
    {error, too_many_calls} = nksip_uac:options(C2, SipC1, []),
    nksip_counters:incr(nksip_calls, -1000000000),

    Self = self(),
    Ref = make_ref(),
    Fun = fun(Reply) -> Self ! {Ref, Reply} end,
    CB = {callback, Fun},
    Hds = {headers, [{"Nk-Op", busy}, {"Nk-Prov", "true"}]},

    nksip_trace:info("Next two infos about connection error to port 50600 are expected"),
    {error, network_error} =
        nksip_uac:options(C2, "<sip:127.0.0.1:50600;transport=tcp>", []),
    
    % Async, error
    {async, _ReqId1} = nksip_uac:options(C2, "<sip:127.0.0.1:50600;transport=tcp>", 
                                        [async, CB, get_request]),
    receive 
        {Ref, {error, network_error}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync
    {ok, 200, Values2} = nksip_uac:options(C2, SipC1, [{fields, [app_id, id, call_id]}]),
    [{app_id, C2}, {id, RespId2}, {call_id, CallId2}] = Values2,
    CallId2 = nksip_response:call_id(RespId2),
    error = nksip_dialog:field(C2, RespId2, status),
    {error, unknown_dialog} = nksip_uac:options(C2, RespId2, []),

    % Sync, get_response
    {resp, #sipmsg{class=resp}} = nksip_uac:options(C2, SipC1, [get_response]),

    % Sync, callback for request
    {ok, 200, [{id, RespId3}]} = 
        nksip_uac:options(C2, SipC1, [CB, get_request, {fields, [id]}]),
    CallId3 = nksip_response:call_id(RespId3),
    receive 
        {Ref, {req, #sipmsg{class=req, call_id=CallId3}}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync, callback for request and provisional response
    {ok, 486, [{dialog_id, DlgId4}, {call_id, CallId4}, {id, RespId4}]} = 
        nksip_uac:invite(C2, SipC1, [Hds, CB, get_request, {fields, [call_id, id]}]),
    CallId4 = nksip_dialog:call_id(DlgId4),
    CallId4 = nksip_response:call_id(RespId4),
    DlgId4 = nksip_dialog:id(C2, RespId4),
    receive 
        {Ref, {req, Req4}} -> 
            CallId4 = nksip_sipmsg:field(Req4, call_id)
        after 500 -> 
            error(uac) 
    end,
    receive 
        {Ref, {ok, 180, Values4}} ->
            [{dialog_id, DlgId4}, {call_id, CallId4}, {id, RespId4_180}] = Values4,
            CallId4 = nksip_response:call_id(RespId4_180)
        after 500 -> 
            error(uac) 
    end,

    % Sync, callback for request and provisional response, get_request, get_response
    {resp, #sipmsg{class=resp, response=486, call_id=CallId5}=Resp5} = 
        nksip_uac:invite(C2, SipC1, [Hds, CB, get_request, get_response]),
    DialogId5 = nksip_dialog:id(Resp5),
    receive 
        {Ref, {req, #sipmsg{class=req, call_id=CallId5}}} -> ok
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {resp, #sipmsg{class=resp, response=180, call_id=CallId5}=Resp5_180}} ->
            DialogId5 = nksip_dialog:id(Resp5_180)
        after 500 -> 
            error(uac) 
    end,

    % Async
    {async, ReqId6} = nksip_uac:invite(C2, SipC1, 
                                        [async, CB, get_request, Hds]),
    CallId6 = nksip_request:call_id(ReqId6),
    CallId6 = nksip_request:field(C2, ReqId6, call_id),
    receive 
        {Ref, {req, Req6}} -> 
            ReqId6 = nksip_sipmsg:field(Req6, id),
            CallId6 = nksip_sipmsg:field(Req6, call_id)
        after 500 -> 
            error(uac) 
    end,
    Dialog6 = receive 
        {Ref, {ok, 180, [{dialog_id, Dlg6A}]}} -> Dlg6A
        after 500 -> error(uac) 
    end,
    Dialog6 = receive 
        {Ref, {ok, 486, [{dialog_id, Dlg6B}]}} -> Dlg6B
        after 500 -> error(uac) 
    end,
    ok.


timeout() ->
    C2 = {uac, client2},
    SipC1 = "sip:127.0.0.1:5070",
    {ok, _Module, Opts, _Pid} = nksip_sipapp_srv:get_opts(C2),
    Opts1 = [{timer_t1, 10}, {timer_c, 1}|Opts],
    ok = nksip_sipapp_srv:put_opts(C2, Opts1),

    nksip_trace:notice("Next notices about several timeouts are expected"),

    {ok, 408, [{reason, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(C2, "sip:127.0.0.1:9999", [{fields, [reason]}]),

    {ok, 408, [{dialog_id, _}, {reason, <<"Timer B Timeout">>}]} = 
        nksip_uac:invite(C2, "sip:127.0.0.1:9999", [{fields, [reason]}]),

    % REGISTER sends a provisional response, but the timeout is the same
    Hds1 = {headers, [{<<"Nk-Sleep">>, 2000}]},
    {ok, 408, [{reason, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(C2, SipC1, [Hds1, {fields, [reason]}]),

    % INVITE sends 
    Hds2 = {headers, [{"Nk-Op", busy}, {"Nk-Prov", "true"}, {"Nk-Sleep", 20000}]},
    {ok, 408, [{dialog_id, _}, {reason, Reason}]} = 
        nksip_uac:invite(C2, SipC1, [Hds2, {fields, [reason]}]),
    
    % TODO: Should fire timer C, sometimes it fires timer B 
    case Reason of
        <<"Timer C Timeout">> -> ok;
        <<"Timer B Timeout">> -> ok
    end,
    nksip_call_router:clear_all_calls(),
    ok.









