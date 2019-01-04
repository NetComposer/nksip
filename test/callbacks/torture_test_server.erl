%% -------------------------------------------------------------------
%%
%% torture_test: RFC4475 "Invalid" tests (3.1.2.1 to 3.1.2.19)
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

-module(torture_test_server).
-export([sip_route/5]).

-include_lib("nkserver/include/nkserver_module.hrl").


sip_route(Scheme, _User, _Domain, _Req, _Call) when Scheme=/=sip, Scheme=/=sips ->
    {reply, unsupported_uri_scheme};

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


