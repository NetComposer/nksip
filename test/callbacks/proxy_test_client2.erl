%% -------------------------------------------------------------------
%%
%% proxy_test: Stateless and Stateful Proxy Tests
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

-module(proxy_test_client2).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_invite/2, sip_ack/2, sip_bye/2, sip_options/2]).


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {ok, Values} = nksip_request:header(<<"x-nk">>, Req),
    {ok, Routes} = nksip_request:header(<<"route">>, Req),
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, ?MODULE} = nksip_request:pkg_id(Req),
    Hds = [
        case Values of [] -> ignore; _ -> {add, "x-nk", nklib_util:bjoin(Values)} end,
        case Routes of [] -> ignore; _ -> {add, "x-nk-r", nklib_util:bjoin(Routes)} end,
        {add, "x-nk-id", nklib_util:bjoin([?MODULE|Ids])}
    ],
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"decline">>
    end,
    Sleep = case nksip_request:header(<<"x-nk-sleep">>, Req) of
        {ok, [Sleep0]} -> nklib_util:to_integer(Sleep0);
        {ok, _} -> 0
    end,
    Prov = case nksip_request:header(<<"x-nk-prov">>, Req) of
        {ok, [<<"true">>]} -> true;
        {ok, _} -> false
    end,
    {ok, ReqId} = nksip_request:get_handle(Req),
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    proc_lib:spawn(
        fun() ->
            if 
                Prov -> nksip_request:reply(ringing, ReqId); 
                true -> ok 
            end,
            case Sleep of
                0 -> ok;
                _ -> timer:sleep(Sleep)
            end,
            case Op of
                <<"ok">> ->
                    nksip_request:reply({ok, Hds}, ReqId);
                <<"answer">> ->
                    SDP = nksip_sdp:new("proxy_test_client2",
                                            [{"test", 4321, [{rtpmap, 0, "codec1"}]}]),
                    nksip_request:reply({ok, [{body, SDP}|Hds]}, ReqId);
                <<"busy">> ->
                    nksip_request:reply(busy, ReqId);
                <<"increment">> ->
                    {ok, SDP1} = nksip_dialog:get_meta(invite_local_sdp, DialogId),
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({ok, [{body, SDP2}|Hds]}, ReqId);
                _ ->
                    nksip_request:reply(decline, ReqId)
            end
        end),
    noreply.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.


sip_options(Req, _Call) ->
    {ok, Values} = nksip_request:header(<<"x-nk">>, Req),
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    {ok, Routes} = nksip_request:header(<<"route">>, Req),
    {ok, ?MODULE} = nksip_request:pkg_id(Req),
    Hds = [
        case Values of [] -> ignore; _ -> {add, "x-nk", nklib_util:bjoin(Values)} end,
        case Routes of [] -> ignore; _ -> {add, "x-nk-r", nklib_util:bjoin(Routes)} end,
        {add, "x-nk-id", nklib_util:bjoin([?MODULE|Ids])}
    ],
    {reply, {ok, [contact|Hds]}}.

