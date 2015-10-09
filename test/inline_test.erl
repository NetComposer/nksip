%% -------------------------------------------------------------------
%%
%% uas_test: Inline Test Suite
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

-module(inline_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").

-compile([export_all]).


inline_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun basic/0},
            {timeout, 60, fun cancel/0}, 
            {timeout, 60, fun auth/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(server1, ?MODULE, [], [
        {from, "\"NkSIP Basic SUITE Test Server\" <sip:server@nksip>"},
        {plugins, [nksip_registrar]},
        {local_host, "127.0.0.1"},
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ]),

    {ok, _} = nksip:start(client1, ?MODULE, [], [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {plugins, [nksip_uac_auto_auth]},
        {local_host, "127.0.0.1"},
        {route, "<sip:127.0.0.1;lr>"},
        {transports, [{udp, all, 5070}, {tls, all, 5071}]}
    ]),

    {ok, _} = nksip:start(client2, ?MODULE, [], [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"},
        {local_host, "127.0.0.1"},
        {route, "<sip:127.0.0.1;lr>"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


basic() ->
    Ref = make_ref(),
    Pid = self(),
    ok = nkservice_server:put(server1, inline_test, {Ref, Pid}),
    ok = nkservice_server:put(client1, inline_test, {Ref, Pid}),
    ok = nkservice_server:put(client2, inline_test, {Ref, Pid}),
    nksip_registrar:clear(server1),
    
    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", [contact]),
    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", [contact]),
    ok = tests_util:wait(Ref, [{server1, route}, {server1, route}]),

    Fs1 = {meta, [<<"x-nk-id">>]},
    {ok, 200, Values1} = nksip_uac:options(client1, "sip:client2@nksip", [Fs1]),
    [{<<"x-nk-id">>, [<<"client2,server1">>]}] = Values1,
    ok = tests_util:wait(Ref, [{server1, route}, {client2, options}]),

    {ok, 480, []} = nksip_uac:options(client2, "sip:client3@nksip", []),
    ok = tests_util:wait(Ref, [{server1, route}]),

    {ok, 200, [{dialog, Dlg2}]} = nksip_uac:invite(client2, "sip:client1@nksip", []),
    ok = nksip_uac:ack(Dlg2, []),
    ok = tests_util:wait(Ref, [
            {server1, route}, {server1, dialog_start}, {server1, route}, 
            {client1, invite}, {client1, ack}, {client1, dialog_start},
            {client2, dialog_start}]),

    {ok, 200, []} = nksip_uac:info(Dlg2, []),
    ok = tests_util:wait(Ref, [{server1, route}, {client1, info}]),

    SDP = nksip_sdp:new("client1", [{"test", 1234, [{rtpmap, 0, "codec1"}]}]),
    Dlg1 = nksip_dialog_lib:remote_id(Dlg2, client1),
    {ok, 200, _} = nksip_uac:invite(Dlg1, [{body, SDP}]),
    ok = nksip_uac:ack(Dlg1, []),

    ok = tests_util:wait(Ref, [
            {server1, route}, {server1, route}, {server1, session_start},
            {client1, session_start},
            {client2, reinvite}, {client2, ack}, {client2, session_start}]),

    {ok, 200, []} = nksip_uac:bye(Dlg1, []),
    ok = tests_util:wait(Ref, [
            {server1, route}, {server1, session_stop}, {server1, dialog_stop},
            {client1, session_stop}, {client1, dialog_stop}, 
            {client2, bye}, {client2, session_stop}, {client2, dialog_stop}]),
    nkservice_server:del(server1, inline_test),
    nkservice_server:del(client1, inline_test),
    nkservice_server:del(client2, inline_test),
    ok.


cancel() ->
    Ref = make_ref(),
    Pid = self(),
    ok = nkservice_server:put(server1, inline_test, {Ref, Pid}),
    ok = nkservice_server:put(client1, inline_test, {Ref, Pid}),
    ok = nkservice_server:put(client2, inline_test, {Ref, Pid}),

    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", [contact]),
    ok = tests_util:wait(Ref, [{server1, route}]),

    Hds = {add, "x-nk-op", "wait"},
    CB = {callback, fun({resp, Code, _Req, _Call}) -> Pid ! {Ref, {ok, Code}} end},
    {async, ReqId} = nksip_uac:invite(client1, "sip:client2@nksip", [async, Hds, CB]),
    ok = nksip_uac:cancel(ReqId, []),
    receive {Ref, {ok, 180}} -> ok after 500 -> error(inline) end,
    receive {Ref, {ok, 487}} -> ok after 500 -> error(inline) end,

    ok = tests_util:wait(Ref, [
            {server1, route},  {server1, dialog_start}, {server1, cancel},
            {server1, dialog_stop},
            {client1, dialog_start}, {client1, dialog_stop},
            {client2, invite}, {client2, cancel},
            {client2, dialog_start}, {client2, dialog_stop}]),
    nkservice_server:del(server1, inline_test),
    nkservice_server:del(client1, inline_test),
    nkservice_server:del(client2, inline_test),
    ok.


auth() ->
    SipS1 = "sip:127.0.0.1",
    nksip_registrar:clear(server1),

    Hd = {add, "x-nk-auth", true},
    {ok, 407, []} = nksip_uac:options(client1, SipS1, [Hd]),
    {ok, 200, []} = nksip_uac:options(client1, SipS1, [Hd, {pass, "1234"}]),

    {ok, 407, []} = nksip_uac:register(client1, SipS1, [Hd]),
    {ok, 200, []} = nksip_uac:register(client1, SipS1, [Hd, {pass, "1234"}, contact]),

    {ok, 200, []} = nksip_uac:options(client1, SipS1, [Hd]),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%

init([]) ->
    {ok, []}.


sip_get_user_pass(User, Realm, Req, _Call) ->
    case nksip_request:app_name(Req) of
        {ok, server1} ->
            case {User, Realm} of
                {<<"client1">>, <<"nksip">>} -> <<"1234">>;
                {<<"client2">>, <<"nksip">>} -> <<"4321">>;
                _ -> false
            end;
        {ok, _} ->
            true
    end.


sip_authorize(Auth, Req, _Call) ->
    case nksip_request:app_name(Req) of
        {ok, server1} ->
            case nksip_sipmsg:header(<<"x-nk-auth">>, Req) of
                [<<"true">>] ->
                    case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
                        true ->
                            ok;
                        false ->
                            case nklib_util:get_value({digest, <<"nksip">>}, Auth) of
                                true -> ok;
                                false -> forbidden;
                                undefined -> {proxy_authenticate, <<"nksip">>}
                            end
                    end;
                _ ->
                    ok
            end;
        {ok, _} ->
            ok
    end.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:app_name(Req) of
        {ok, server1} ->
            send_reply(Req, route),
            Opts = [
                record_route,
                {add, "x-nk-id", "server1"}
            ],
            case lists:member(Domain, [<<"127.0.0.1">>, <<"nksip">>]) of
                true when User =:= <<>> ->
                    process;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> 
                            lager:notice("E: ~p, ~p, ~p", [Scheme, User, Domain]),
                            {reply, temporarily_unavailable};
                        UriList ->
                         {proxy, UriList, Opts}
                    end;
                true ->
                    % It is for 127.0.0.1 domain, route
                    {proxy, ruri, Opts};
                false ->
                    {proxy, ruri, Opts}
            end;
        _ ->
            process
    end.


sip_invite(Req, _Call) ->
    send_reply(Req, invite),
    case nksip_sipmsg:header(<<"x-nk-op">>, Req) of
        [<<"wait">>] ->
            {ok, ReqId} = nksip_request:get_handle(Req),
            lager:error("Next error about a looped_process is expected"),
            {error, looped_process} = nksip_request:reply(ringing, ReqId),
            spawn(
                fun() ->
                    nksip_request:reply(ringing, ReqId),
                    timer:sleep(1000),
                    nksip_request:reply(ok, ReqId)
                end),
            noreply;
        _ ->
            {reply, {answer, nksip_sipmsg:meta(body, Req)}}
    end.


sip_reinvite(Req, _Call) ->
    send_reply(Req, reinvite),
    {reply, {answer, nksip_sipmsg:meta(body, Req)}}.


sip_cancel(InvReq, Req, _Call) ->
    {ok, 'INVITE'} = nksip_request:method(InvReq),
    send_reply(Req, cancel),
    ok.


sip_bye(Req, _Call) ->
    send_reply(Req, bye),
    {reply, ok}.


sip_info(Req, _Call) ->
    send_reply(Req, info),
    {reply, ok}.


sip_ack(Req, _Call) ->
    send_reply(Req, ack),
    ok.


sip_options(Req, _Call) ->
    send_reply(Req, options),
    App = nksip_sipmsg:meta(app_name, Req),
    Ids = nksip_sipmsg:header(<<"x-nk-id">>, Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    Reply = {ok, [{add, "x-nk-id", [nklib_util:to_binary(App)|Ids]}]},
    spawn(fun() -> nksip_request:reply(Reply, ReqId) end),
    noreply.


sip_dialog_update(State, Dialog, _Call) ->
    case State of
        start -> send_reply(Dialog, dialog_start);
        stop -> send_reply(Dialog, dialog_stop);
        _ -> ok
    end.


sip_session_update(State, Dialog, _Call) ->
    case State of
        {start, _, _} -> send_reply(Dialog, session_start);
        stop -> send_reply(Dialog, session_stop);
        _ -> ok
    end.



%%%%%%%%%%% Util %%%%%%%%%%%%%%%%%%%%


send_reply(Elem, Msg) ->
    App = case Elem of
        #sipmsg{} -> nksip_sipmsg:meta(app_name, Elem);
        #dialog{} -> nksip_dialog_lib:meta(app_name, Elem)
    end,
    case nkservice_server:get(App, inline_test) of
        {Ref, Pid} -> Pid ! {Ref, {App, Msg}};
        _ -> ok
    end.





