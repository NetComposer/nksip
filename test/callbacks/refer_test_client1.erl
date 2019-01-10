%% -------------------------------------------------------------------
%%
%% refer_test: REFER Test
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

-module(refer_test_client1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_refer/3, sip_refer_update/3, sip_invite/2]).


sip_refer(_ReferTo, _Req, _Call) ->
    true.

sip_refer_update(SubsHandle, Status, Call) ->
    {ok, DialogId} = nksip_dialog:get_handle(SubsHandle),
    PkgId = nksip_call:srv_id(Call),
    Dialogs = nkserver:get(PkgId, dialogs, []),
    case lists:keyfind(DialogId, 1, Dialogs) of
        {DialogId, Ref, Pid}=_D -> 
            Pid ! {Ref, {PkgId, SubsHandle, Status}};
        false ->
            ok
    end.


sip_invite(Req, _Call) ->
    {ok, ReqId} = nksip_request:get_handle(Req),
    spawn(
        fun() ->
            nksip_request:reply(180, ReqId),
            timer:sleep(1000),
            nksip_request:reply(ok, ReqId)
        end),
    noreply.

