%% -------------------------------------------------------------------
%%
%% update_test: UPDATE method test
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

-module(update_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).

update_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun basic/0,
            fun pending/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    ok = nksip:start({update, client1}, update_endpoint, [client1], [
        {from, "sip:client1@nksip"},
        {local_host, "localhost"},
        {transport, {udp, {0,0,0,0}, 5060}},
        {transport, {tls, {0,0,0,0}, 5061}},
        no_100
    ]),
    
    ok = nksip:start({update, client2}, update_endpoint, [client2], [
        {from, "sip:client2@nksip"},
        {local_host, "127.0.0.1"},
        {transport, {udp, {0,0,0,0}, 5070}},
        {transport, {tls, {0,0,0,0}, 5071}},
        no_100
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop({update, client1}),
    ok = nksip:stop({update, client2}).



% Starts a INVITE transaction, after the first reliable provisional response,
% C1 sends a UPDATE to C2, updating media and remote target,
% then C2 sends a UPDATE to C1, updating both again,
% after a time, the final 200 of the INVITE is sent.
basic() ->
    C1 = {update, client1},
    C2 = {update, client2},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    SDP0 = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Vsn0 = SDP0#sdp.vsn,
    
    CB = {callback, fun(Reply) ->
        case Reply of
            {ok, 180, [{dialog_id, FunD1}]} ->
                % Both sessions have been stablished
                spawn(fun() ->
                    FunD2 = nksip_dialog:field(C1, FunD1, remote_id),
                    SDP1 = SDP0#sdp{vsn=Vsn0+1}, 
                    {SDP1,SDP0} = update_endpoint:get_sessions(C2, FunD2),
                    SDP2 = SDP0#sdp{vsn=Vsn0+2},
                    {ok, 200, []} = nksip_uac:update(C1, FunD1, 
                        [{body, SDP2}, {contact, "sip:a@127.0.0.1"}]),
                    SDP4 = SDP0#sdp{vsn=Vsn0+4},
                    % Updated Remote Target
                    {ok, 200, []} = 
                        nksip_uac:update(C2, FunD2,
                            [{body, SDP4}, {contact, "sip:b@127.0.0.1:5070"}])
                end)
        end
    end},
    Body = {body, SDP0},
    Hds1 = {headers, [
        {"Nk-Op", "basic"},
        {"Nk-Reply", base64:encode(erlang:term_to_binary({Ref, Self}))}
    ]},
    {ok, 200, Values1} = nksip_uac:invite(C1, SipC2, [CB, Hds1, Body]),
    [{dialog_id, DialogId}] = Values1,
    ok = nksip_uac:ack(C1, DialogId, []),
    ok = tests_util:wait(Ref, [
                                {client2, sdp_start}, 
                                {client2, update},
                                {client2, sdp_update}, % First UPDATE
                                {client2, sdp_update}, % Second UPDATE
                                {client2, target_update},
                                {client2, dialog_confirmed}, 
                                {client2, ack}
                            ]),
    SDP4 = SDP0#sdp{vsn=Vsn0+4},
    SDP5 = SDP0#sdp{vsn=Vsn0+5},
    DialogId2 = nksip_dialog:field(C1, DialogId, remote_id),
    {SDP4,SDP5} = update_endpoint:get_sessions(C2, DialogId2),

    [
        {local_target, <<"<sip:a@127.0.0.1>">>},
        {remote_target, <<"<sip:b@127.0.0.1:5070>">>},
        {invite_local_sdp, SDP5},
        {invite_remote_sdp, SDP4} 
    ] = nksip_dialog:fields(C1, DialogId, 
                    [local_target, remote_target, invite_local_sdp, invite_remote_sdp]),
    [
        {local_target, <<"<sip:b@127.0.0.1:5070>">>},
        {remote_target, <<"<sip:a@127.0.0.1>">>},        
        {invite_local_sdp, SDP4},
        {invite_remote_sdp, SDP5} 
    ] = 
        nksip_dialog:fields(C2, DialogId2, 
            [local_target, remote_target, invite_local_sdp, invite_remote_sdp]),

    {ok, 200, []} = nksip_uac:bye(C1, DialogId, []),
    ok.


pending() ->
    C1 = {update, client1},
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    SDP0 = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Vsn0 = SDP0#sdp.vsn,

    CB = {callback, fun(Reply) ->
        case Reply of
            {ok, 180, [{dialog_id, FunD1}]} ->
                % We have an offer, but no answer
                spawn(fun() ->
                    SDP1 = SDP0#sdp{vsn=Vsn0+1}, 
                    {error, request_pending} = nksip_uac:update(C1, FunD1, [{body, SDP1}]),
                    Self ! {Ref, fun_ok_1}
                end)
        end
    end},    Body = {body, SDP0},
    Hds1 = {headers, [
        {"Nk-Op", "pending1"}
    ]},
    {ok, 200, [{dialog_id, DialogId}]} = nksip_uac:invite(C1, SipC2, [Hds1, Body, CB]),
    ok = nksip_uac:ack(C1, DialogId, []),

    ok = tests_util:wait(Ref, [fun_ok_1]),
    {ok, 200, []} = nksip_uac:bye(C1, DialogId, []).


