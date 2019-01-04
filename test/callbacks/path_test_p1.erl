%% -------------------------------------------------------------------
%%
%% path_test: Path (RFC3327) Tests
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

-module(path_test_p1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_route/5]).


sip_route(_Scheme, _User, Domain, _Req, _Call) ->
    % P1 is the outbound proxy.
    % It domain is 'nksip', it sends the request to P2,
    % inserting Path and x-nk-id headers
    % If not, simply proxies the request adding a x-nk-id header
    Base = [{insert, "x-nk-id", "path_test_p1"}],
    case Domain of
        <<"nksip">> ->
            Opts = [{route, "<sip:127.0.0.1:5071;lr;transport=tls>"},
                     path, record_route|Base],
            {proxy, ruri, Opts};
        _ ->
            {proxy, ruri, Base}
    end.
