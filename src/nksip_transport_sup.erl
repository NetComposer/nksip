%% -------------------------------------------------------------------
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

%% @private NkSIP Transport Supervisor.
%% Start the SipApp core's transport supervisor and starts and connects 
%% all configured transports.

-module(nksip_transport_sup).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(supervisor).

-export([add_transport/2, start_link/2, init/1]).

-include("nksip.hrl").


%% @private Starts a new transport control process under this supervisor
-spec add_transport(nksip:app_id(), any()) ->
    {ok, pid()} | {error, term()}.

add_transport(AppId, Spec) ->
    SupPid = nksip_proc:whereis_name({nksip_transport_sup, AppId}),
    case supervisor:start_child(SupPid, Spec) of
        {ok, Pid} -> {ok, Pid};
        {error, {Error, _}} -> {error, Error};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec start_link(nksip:app_id(), nksip_lib:proplist()) -> 
    {ok, pid()} | {error, Error}
    when Error ::  could_not_start_udp | could_not_start_tcp |
                   could_not_start_tls | no_matching_tcp |
                   could_not_start_sctp.


start_link(AppId, Opts) ->
    Reg = {nksip_transport_sup, AppId},
    Spec = {{one_for_one, 10, 60}, []},
    {ok, SupPid} = supervisor:start_link(?MODULE, [Reg, Spec]),
    Transports = nksip_lib:get_value(transports, Opts, []), 
    case start_transports(AppId, Transports, Opts) of
        ok -> {ok, SupPid};
        {error, Error} -> {error, Error}
    end.


%% @private
init([Reg, ChildSpecs]) ->
    yes = nksip_proc:register_name(Reg, self()),
    {ok, ChildSpecs}.


%% @private Tries to start all the configured transports for a SipApp.
%% For every UDP transport it will start a TCP transport on the same port
-spec start_transports(nksip:app_id(), [term()], nksip_lib:proplist()) ->
    ok | {error, Error}
    when Error ::  {could_not_start_udp, term()} | {could_not_start_tcp, term()} |
                   {could_not_start_tls, term()} | {could_not_start_sctp, term()}.

start_transports(AppId, [{Proto, Ip, Port}|Rest], Opts) ->
    case nksip_transport:start_transport(AppId, Proto, Ip, Port, Opts) of
        {ok, _} -> start_transports(AppId, Rest, Opts);
        {error, Error} when Proto==udp -> {error, {could_not_start_udp, Error}};
        {error, Error} when Proto==tcp -> {error, {could_not_start_tcp, Error}};
        {error, Error} when Proto==tls -> {error, {could_not_start_tls, Error}};
        {error, Error} when Proto==sctp -> {error, {could_not_start_sctp, Error}}
    end;

start_transports(_AppId, [], __Opts) ->
    ok.


