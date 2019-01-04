%% -------------------------------------------------------------------
%%
%% event_test: Event Suite Test
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
%% --------------------------º-----------------------------------------

-module(event_test_client1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_invite/2, sip_ack/2, sip_bye/2, sip_subscribe/2, sip_resubscribe/2, sip_notify/2, sip_dialog_update/3]).


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {reply, ok}.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.


sip_subscribe(Req, _Call) ->
    tests_util:save_ref(Req),
    Op = case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [Op0]} -> Op0;
        {ok, _} -> <<"ok">>
    end,
    case Op of
        <<"ok">> ->
            {reply, ok};
        <<"expires-2">> ->
            {reply, {ok, [{expires, 2}]}};
        <<"wait">> ->
            tests_util:send_ref({wait, Req}, Req),
            {ok, ReqId} = nksip_request:get_handle(Req),
            spawn(
                fun() ->
                    timer:sleep(1000),
                    nksip_request:reply(ok, ReqId)
                end),
            noreply
    end.


sip_resubscribe(_Req, _Call) ->
    {reply, ok}.


sip_notify(Req, _Call) ->
    {ok, Body} = nksip_request:body(Req),
    tests_util:send_ref({notify, Body}, Req),
    {reply, ok}.


sip_dialog_update(Update, Dialog, _Call) ->
    tests_util:dialog_update(Update, Dialog),
    ok.
