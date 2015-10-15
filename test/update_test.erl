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

    {ok, _} = nksip:start(client1, ?MODULE, [
        {from, "sip:client1@nksip"},
        {local_host, "localhost"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]},
        {plugins, [nksip_100rel]},
        no_100
    ]),
    
    {ok, _} = nksip:start(client2, ?MODULE, [
        {from, "sip:client2@nksip"},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]},
        {plugins, [nksip_100rel]},
        no_100
    ]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).



% Starts a INVITE transaction, after the first reliable provisional response,
% C1 sends a UPDATE to C2, updating media and remote target,
% then C2 sends a UPDATE to C1, updating both again,
% after a time, the final 200 of the INVITE is sent.
basic() ->
    C1 = client1,
    C2 = client2,
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    SDP0 = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Vsn0 = SDP0#sdp.vsn,
    
    CB = {callback, fun(Reply) ->
        case Reply of
            {resp, 180, Resp1, _Call} ->
                % Both sessions have been stablished
                {ok, FunD1} = nksip_dialog:get_handle(Resp1),
                spawn(fun() ->
                    FunD2 = nksip_dialog_lib:remote_id(FunD1, client2),
                    SDP1 = SDP0#sdp{vsn=Vsn0+1}, 
                    {SDP1,SDP0} = get_sessions(C2, FunD2),
                    SDP2 = SDP0#sdp{vsn=Vsn0+2},
                    {ok, 200, []} = nksip_uac:update(FunD1, 
                        [{body, SDP2}, {contact, "sip:a@127.0.0.1"}]),
                    SDP4 = SDP0#sdp{vsn=Vsn0+4},
                    % Updated Remote Target
                    {ok, 200, []} = 
                        nksip_uac:update(FunD2,
                            [{body, SDP4}, {contact, "sip:b@127.0.0.1:5070"}])
                end)
        end
    end},
    Body = {body, SDP0},
    Hds1 = [
        {add, "x-nk-op", "basic"},
        {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, Self}))}
    ],
    {ok, 200, Values1} = nksip_uac:invite(C1, SipC2, [CB, Body | Hds1]),
    [{dialog, DialogId}] = Values1,
    ok = nksip_uac:ack(DialogId, []),
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
    DialogId2 = nksip_dialog_lib:remote_id(DialogId, client2),
    {SDP4,SDP5} = get_sessions(C2, DialogId2),

    {ok, [
        {raw_local_target, <<"<sip:a@127.0.0.1>">>},
        {raw_remote_target, <<"<sip:b@127.0.0.1:5070>">>},
        {invite_local_sdp, SDP5},
        {invite_remote_sdp, SDP4} 
    ]} = nksip_dialog:metas([raw_local_target, raw_remote_target, 
                            invite_local_sdp, invite_remote_sdp], DialogId),
    {ok, [
        {raw_local_target, <<"<sip:b@127.0.0.1:5070>">>},
        {raw_remote_target, <<"<sip:a@127.0.0.1>">>},        
        {invite_local_sdp, SDP4},
        {invite_remote_sdp, SDP5} 
    ]} = 
        nksip_dialog:metas([raw_local_target, raw_remote_target, 
                            invite_local_sdp, invite_remote_sdp], DialogId2),

    {ok, 200, []} = nksip_uac:bye(DialogId, []),
    ok.


pending() ->
    C1 = client1,
    SipC2 = "sip:127.0.0.1:5070",
    Ref = make_ref(),
    Self = self(),
    SDP0 = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Vsn0 = SDP0#sdp.vsn,

    CB = {callback, fun(Reply) ->
        case Reply of
            {resp, 180, Resp1, _Call} ->
                {ok, FunD1} = nksip_dialog:get_handle(Resp1),
                % We have an offer, but no answer
                spawn(fun() ->
                    SDP1 = SDP0#sdp{vsn=Vsn0+1}, 
                    {error, request_pending} = nksip_uac:update(FunD1, [{body, SDP1}]),
                    Self ! {Ref, fun_ok_1}
                end)
        end
    end},    Body = {body, SDP0},
    Hd1 = {add, "x-nk-op", "pending1"},
    {ok, 200, [{dialog, DialogId}]} = nksip_uac:invite(C1, SipC2, [Hd1, Body, CB]),
    ok = nksip_uac:ack(DialogId, []),

    ok = tests_util:wait(Ref, [fun_ok_1]),
    {ok, 200, []} = nksip_uac:bye(DialogId, []),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%

sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    {ok, Body} = nksip_request:body(Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            case Op of
                <<"basic">> ->
                    SDP1 = nksip_sdp:increment(Body),
                    ok = nksip_request:reply({rel_ringing, SDP1}, ReqId),
                    timer:sleep(500),
                    nksip_request:reply(ok, ReqId);
                <<"pending1">> ->
                    ok = nksip_request:reply(ringing, ReqId), 
                    timer:sleep(100),
                    nksip_request:reply(ok, ReqId);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_update(Req, _Call) ->
    tests_util:send_ref(update, Req),
    Body = case nksip_request:body(Req) of
        {ok, #sdp{} = SDP} -> nksip_sdp:increment(SDP);
        {ok, _} -> <<>>
    end,        
    {reply, {answer, Body}}.


sip_dialog_update(Update, Dialog, _Call) ->
    tests_util:dialog_update(Update, Dialog),
    ok.


sip_session_update(Update, Dialog, _Call) ->
    tests_util:session_update(Update, Dialog),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  Util %%%%%%%%%%%%%%%%%%%%%

get_sessions(SrvId, DialogId) ->
    Sessions = nkservice_server:get(SrvId, sessions, []),
    case lists:keyfind(DialogId, 1, Sessions) of
        {_DialogId, Local, Remote} -> {Local, Remote};
        _ -> not_found
    end.

