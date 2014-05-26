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

%% @doc SipApp callbacks for plugin nksip_uac_auto
-module(nksip_uac_auto_sipapp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([nksip_uac_auto_register_update/3, nksip_uac_auto_ping_update/3]).


%% ===================================================================
%% Callbacks
%% ===================================================================


%% @doc Called when the status of an automatic registration status changes.
-spec nksip_uac_auto_register_update(AppId::nksip:app_id(), RegId::term(), OK::boolean()) ->
    ok.

nksip_uac_auto_register_update( _AppId, _RegId, _OK) ->
    ok.


%% @doc Called when the status of an automatic ping status changes.
-spec nksip_uac_auto_ping_update(AppId::nksip:app_id(), PingId::term(), OK::boolean()) ->
    ok.

nksip_uac_auto_ping_update(_AppId, _PingId, _OK) ->
    ok.






