%% -------------------------------------------------------------------
%%
%% outbound_test: Path (RFC5626) Tests
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

-module(outbound_test_ua3).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_invite/2, sip_options/2]).


sip_invite(Req, _Call) ->
    case nksip_request:header(<<"x-nk-op">>, Req) of
        {ok, [<<"ok">>]} -> {reply, ok};
        {ok, _} -> {reply, 603}
    end.


sip_options(Req, _Call) ->
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([?MODULE|Ids])}],
    {reply, {ok, [contact|Hds]}}.





