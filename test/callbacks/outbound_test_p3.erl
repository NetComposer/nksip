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

-module(outbound_test_p3).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_route/5]).

sip_route(_Scheme, _User, Domain, _Req, _Call) ->
    % P3 is the SBC.
    % For 'nksip', it sends everything to the registrar, inserting Path header
    % For other proxies the request
    Base = [{insert, "x-nk-id", "outbound_test_p3"}],
    case Domain of
        <<"nksip">> ->
            Opts = [{route, "<sip:127.0.0.1:5090;lr>"}, path, record_route|Base],
            {proxy, ruri, Opts};
        _ ->
            {proxy, ruri, [record_route|Base]}
    end.
