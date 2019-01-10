%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Plugin implementing automatic registrations and pings support for Services.
-module(nksip_uac_auto_register).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_ping/4, stop_ping/2, get_pings/1]).
-export([start_register/4, stop_register/2, get_registers/1]).

-include("nksip_uac_auto_register.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nkserver:id(), term(), nksip:user_uri(),
                     nksip:optslist()) ->
    {ok, boolean()} | {error, term()}.

start_register(SrvId, RegId, Uri, Opts) when is_list(Opts) ->
    try
        case lists:keymember(get_meta, 1, Opts) of
            true ->
                throw(meta_not_allowed);
            false ->
                ok
        end,
        CallId = nklib_util:luid(),
        case nksip_call_uac_make:make(SrvId, 'REGISTER', Uri, CallId, Opts) of
            {ok, _, _} ->
                ok;
            {error, MakeError} ->
                throw(MakeError)
        end,
        Msg = {nksip_uac_auto_register_start_reg, RegId, Uri, Opts},
        nkserver_srv:call(SrvId, Msg)
    catch
        throw:Error ->
            {error, Error}
    end.


%% @doc Stops a previously started registration serie.
-spec stop_register(nkserver:id(), term()) ->
    ok | not_found.

stop_register(SrvId, RegId) ->
     nkserver_srv:call(SrvId, {nksip_uac_auto_register_stop_reg, RegId}).
    

%% @doc Get current registration status.
-spec get_registers(nkserver:id()) ->
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(SrvId) ->
     nkserver_srv:call(SrvId, nksip_uac_auto_register_get_regs).



%% @doc Starts a new automatic ping serie.
-spec start_ping(nkserver:id(), term(), nksip:user_uri(),
                 nksip:optslist()) ->
    {ok, boolean()} | {error, invalid_uri}.


start_ping(SrvId, PingId, Uri, Opts) when is_list(Opts) ->
    try
        case lists:keymember(meta, 1, Opts) of
            true ->
                throw(meta_not_allowed);
            false ->
                ok
        end,
        CallId = nklib_util:luid(),
        case nksip_call_uac_make:make(SrvId, 'OPTIONS', Uri, CallId, Opts) of
            {ok, _, _} ->
                ok;
            {error, MakeError} ->
                throw(MakeError)
        end,
        Msg = {nksip_uac_auto_register_start_ping, PingId, Uri, Opts},
         nkserver_srv:call(SrvId, Msg)
    catch
        throw:Error ->
            {error, Error}
    end.


%% @doc Stops a previously started ping serie.
-spec stop_ping(nkserver:id(), term()) ->
    ok | not_found.

stop_ping(Srv, PingId) ->
     nkserver_srv:call(Srv, {nksip_uac_auto_register_stop_ping, PingId}).
    

%% @doc Get current ping status.
-spec get_pings(nkserver:id()) ->
    [{PingId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_pings(SrvId) ->
     nkserver_srv:call(SrvId, nksip_uac_auto_register_get_pings).

