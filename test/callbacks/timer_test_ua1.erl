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

-module(timer_test_ua1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_invite/2, sip_ack/2, sip_update/2, sip_bye/2, sip_dialog_update/3]).


sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {ok, Body} = nksip_request:body(Req),
    Body1 = nksip_sdp:increment(Body),
    {reply, {answer, Body1}}.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_update(_Req, _Call) ->
    {reply, ok}.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.


sip_dialog_update(Status, Dialog, _Call) ->
    tests_util:dialog_update(Status, Dialog),
    ok.





