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
-module(nksip_uac_auto_outbound).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_register/5, stop_register/2, get_registers/1]).

-include("nksip_uac_auto_outbound.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new registration serie.
-spec start_register(nkservice:id(), nkservice:package_id(), term(), nksip:user_uri(),
                     nksip:optslist()) -> 
    {ok, boolean()} | {error, term()}.

start_register(SrvId, PkgId, RegId, Uri, Opts) when is_list(Opts) ->
    Opts1 = [{user, [nksip_uac_auto_outbound]}|Opts],
    nksip_uac_auto_register:start_register(SrvId, PkgId, RegId, Uri, Opts1).


%% @doc Stops a previously started registration serie.
-spec stop_register(nkservice:name()|nkservice:id(), term()) ->
    ok | not_found.

stop_register(Srv, RegId) ->
    nksip_uac_auto_register:stop_register(Srv, RegId).
    

%% @doc Get current registration status.
-spec get_registers(nkservice:name()|nkservice:id()) ->
    [{RegId::term(), OK::boolean(), Time::non_neg_integer()}].
 
get_registers(Srv) ->
    nkservice:call(Srv, nksip_uac_auto_outbound_get_regs).

    
