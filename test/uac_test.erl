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
-include("../include/nksip.hrl").

-compile([export_all]).


uac_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uac/0},
            {timeout, 60, fun info/0},
            {timeout, 60, fun message/0},
            {timeout, 60, fun timeout/0}
        ]
    }.


start() ->
    tests_util:start_nksip(),
    ok = nksip:start(client1, ?MODULE, client1, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client1@nksip>"},
        {transports, [ {udp, all, 5070},{tls, all, 5071}]}
    ]),
            
    ok = nksip:start(client2, ?MODULE, client2, [
        {from, "\"NkSIP Basic SUITE Test Client\" <sip:client2@nksip>"}]),
    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).


stop() ->
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


uac() ->
    client2 = client2,
    SipC1 = "sip:127.0.0.1:5070",

    {error, invalid_uri} = nksip_uac:options(client2, "sip::a", []),
    {error, {invalid, <<"from">>}} = nksip_uac:options(client2, SipC1, [{from, "<>"}]),
    {error, {invalid, <<"to">>}} = nksip_uac:options(client2, SipC1, [{to, "<>"}]),
    {error, {invalid, <<"route">>}} = nksip_uac:options(client2, SipC1, [{route, "<>"}]),
    {error, {invalid, <<"contact">>}} = nksip_uac:options(client2, SipC1, [{contact, "<>"}]),
    {error, {invalid, cseq_num}} = nksip_uac:options(client2, SipC1, [{cseq_num, -1}]),
    nksip_trace:error("Next error about 'unknown_siapp' is expected"),
    {error, unknown_sipapp} = nksip_uac:options(none, SipC1, []),
    nksip_trace:error("Next error about 'too_many_calls' is expected"),
    nksip_counters:incr(nksip_calls, 1000000000),
    {error, too_many_calls} = nksip_uac:options(client2, SipC1, []),
    nksip_counters:incr(nksip_calls, -1000000000),

    Self = self(),
    Ref = make_ref(),
    Fun = fun(Reply) -> Self ! {Ref, Reply} end,
    CB = {callback, Fun},
    Hds = [{add, "x-nk-op", busy}, {add, "x-nk-prov", "true"}],

    nksip_trace:info("Next two infos about connection error to port 50600 are expected"),
    {error, service_unavailable} =
        nksip_uac:options(client2, "<sip:127.0.0.1:50600;transport=tcp>", []),
    
    % Async, error
    {async, _ReqId1} = nksip_uac:options(client2, "<sip:127.0.0.1:50600;transport=tcp>", 
                                        [async, CB, get_request]),
    receive 
        {Ref, {error, service_unavailable}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync
    {ok, 200, Values2} = nksip_uac:options(client2, SipC1, [{meta, [app_id, id, call_id]}]),
    [{app_id, client2}, {id, RespId2}, {call_id, CallId2}] = Values2,
    CallId2 = nksip_response:call_id(RespId2),
    error = nksip_dialog:field(client2, RespId2, status),
    {error, unknown_dialog} = nksip_uac:options(client2, RespId2, []),

    % Sync, get_response
    {resp, #sipmsg{class={resp, _, _}}} = nksip_uac:options(client2, SipC1, [get_response]),

    % Sync, callback for request
    {ok, 200, [{id, RespId3}]} = 
        nksip_uac:options(client2, SipC1, [CB, get_request, {meta, [id]}]),
    CallId3 = nksip_response:call_id(RespId3),
    receive 
        {Ref, {req, #sipmsg{class={req, _}, call_id=CallId3}}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync, callback for request and provisional response
    {ok, 486, [{call_id, CallId4}, {id, RespId4}]} = 
        nksip_uac:invite(client2, SipC1, [CB, get_request, {meta, [call_id, id]}|Hds]),
    CallId4 = nksip_response:call_id(RespId4),
    DlgId4 = nksip_dialog:id(client2, RespId4),
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
    {resp, #sipmsg{class={resp, 486, _}, call_id=CallId5}=Resp5} = 
        nksip_uac:invite(client2, SipC1, [CB, get_request, get_response|Hds]),
    DialogId5 = nksip_dialog:class_id(uac, Resp5),
    receive 
        {Ref, {req, #sipmsg{class={req, _}, call_id=CallId5}}} -> ok
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {resp, #sipmsg{class={resp, 180, _}, call_id=CallId5}=Resp5_180}} ->
            DialogId5 = nksip_dialog:class_id(uac, Resp5_180)
        after 500 -> 
            error(uac) 
    end,

    % Async
    {async, ReqId6} = nksip_uac:invite(client2, SipC1, [async, CB, get_request | Hds]),
    CallId6 = nksip_request:call_id(ReqId6),
    CallId6 = nksip_request:field(client2, ReqId6, call_id),
    receive 
        {Ref, {req, Req6}} -> 
            ReqId6 = nksip_sipmsg:field(Req6, id),
            CallId6 = nksip_sipmsg:field(Req6, call_id)
        after 500 -> 
            error(uac) 
    end,
    receive 
        {Ref, {ok, 180, [{dialog_id, _}]}} -> ok
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {ok, 486, []}} -> ok
        after 500 -> error(uac) 
    end,
    ok.



info() ->
    SipC1 = "sip:127.0.0.1:5070",
    Hd1 = {add, <<"x-nk-op">>, <<"ok">>},
    {ok, 200, [{dialog_id, DialogId2}]} = nksip_uac:invite(client2, SipC1, [Hd1]),
    ok = nksip_uac:ack(client2, DialogId2, []),
    Fs = {meta, [<<"x-nk-method">>, <<"x-nk-dialog">>]},
    DialogId1 = nksip_dialog:field(client2, DialogId2, remote_id),

    {ok, 200, Values1} = nksip_uac:info(client2, DialogId2, [Fs]),
    [{<<"x-nk-method">>, [<<"info">>]}, {<<"x-nk-dialog">>, [DialogId1]}] = Values1,

    % Now we forcefully stop dialog at client1. At client2 is still valid, and can send the INFO
    ok = nksip_dialog:stop(client1, DialogId1),
    {ok, 481, []} = nksip_uac:info(client2, DialogId2, []), 

    % The dialog at client2, at receiving a 481 (even for INFO) is destroyed before the BYE
    {error, unknown_dialog} = nksip_uac:bye(client2, DialogId2, []),
    ok.


timeout() ->
    SipC1 = "sip:127.0.0.1:5070",
    {ok, _Module, Opts, _Pid} = nksip_sipapp_srv:get_opts(client2),
    Opts1 = [{timer_t1, 10}, {timer_c, 1}|Opts],
    ok = nksip_sipapp_srv:put_opts(client2, Opts1),

    nksip_trace:notice("Next notices about several timeouts are expected"),

    {ok, 408, [{reason_phrase, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(client2, "sip:127.0.0.1:9999", [{meta,[reason_phrase]}]),

    {ok, 408, [{reason_phrase, <<"Timer B Timeout">>}]} = 
        nksip_uac:invite(client2, "sip:127.0.0.1:9999", [{meta,[reason_phrase]}]),

    % REGISTER sends a provisional response, but the timeout is the same
    Hd1 = {add, <<"x-nk-sleep">>, 2000},
    {ok, 408, [{reason_phrase, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(client2, SipC1, [Hd1, {meta, [reason_phrase]}]),

    % INVITE sends 
    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-prov", "true"}, {add, "x-nk-sleep", 20000}],
    {ok, 408, [{reason_phrase, Reason}]} = 
        nksip_uac:invite(client2, SipC1, [{meta, [reason_phrase]}|Hds2]),
    
    % TODO: Should fire timer C, sometimes it fires timer B 
    case Reason of
        <<"Timer C Timeout">> -> ok;
        <<"Timer B Timeout">> -> ok
    end,
    nksip_call_router:clear_all_calls(),
    ok.


message() ->
    {Ref, Hd} = tests_util:get_ref(),
    {ok, 200, []} = nksip_uac:message(client2, "sip:user@127.0.0.1:5070", [
                                      Hd, {expires, 10}, {content_type, "text/plain"},
                                      {body, <<"Message">>}]),

    receive 
        {Ref, {ok, 10, RawDate, <<"text/plain">>, <<"Message">>}} ->
            Date = httpd_util:convert_request_date(binary_to_list(RawDate)),
            true = nksip_lib:timestamp() - nksip_lib:gmt_to_timestamp(Date) < 2
        after 1000 -> error(message)
    end,
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(Id) ->
    {ok, Id}.


invite(ReqId, Meta, From, AppId=State) ->
    tests_util:save_ref(AppId, ReqId, Meta),
    Op = case nksip_request:header(AppId, ReqId, <<"x-nk-op">>) of
        [Op0] -> Op0;
        _ -> <<"decline">>
    end,
    Sleep = case nksip_request:header(AppId, ReqId, <<"x-nk-sleep">>) of
        [Sleep0] -> nksip_lib:to_integer(Sleep0);
        _ -> 0
    end,
    Prov = case nksip_request:header(AppId, ReqId, <<"x-nk-prov">>) of
        [<<"true">>] -> true;
        _ -> false
    end,
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(AppId, ReqId, ringing); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip:reply(From, {ok, []});
                <<"answer">> ->
                    SDP = nksip_sdp:new("client2", 
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip:reply(From, {ok, [{body, SDP}]});
                <<"busy">> ->
                    nksip:reply(From, busy);
                <<"increment">> ->
                    DialogId = nksip_lib:get_value(dialog_id, Meta),
                    SDP1 = nksip_dialog:field(AppId, DialogId, invite_local_sdp),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip:reply(From, {ok, [{body, SDP2}]});
                _ ->
                    nksip:reply(From, decline)
            end
        end),
    {noreply, State}.


options(ReqId, _Meta, _From, AppId=State) ->
    case nksip_request:header(AppId, ReqId, <<"x-nk-sleep">>) of
        [Sleep0] -> 
            nksip_request:reply(AppId, ReqId, 101), 
            timer:sleep(nksip_lib:to_integer(Sleep0));
        _ -> 
            ok
    end,
    {reply, {ok, [contact]}, State}.


info(ReqId, _Meta, _From, AppId=State) ->
    DialogId = nksip_request:dialog_id(AppId, ReqId),
    {reply, {ok, [{add, "x-nk-method", "info"}, {add, "x-nk-dialog", DialogId}]}, State}.


message(ReqId, _Meta, _From, AppId=State) ->
    case nksip_request:header(AppId, ReqId, <<"x-nk-reply">>) of
        [RepBin] ->
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            [
                {_, Expires},
                {_, [Date]},
                {_, ContentType},
                {_, Body}

            ] = nksip_request:fields(AppId, ReqId, 
                    [parsed_expires, <<"date">>, content_type, body]),
            Pid ! {Ref, {ok, Expires, Date, ContentType, Body}},
            {reply, ok, State};
        _ ->
            {reply, decline, State}
    end.

