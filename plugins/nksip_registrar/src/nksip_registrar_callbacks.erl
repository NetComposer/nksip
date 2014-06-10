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

%% @doc NkSIP Registrar Plugin Callbacks
-module(nksip_registrar_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-export([nkcb_sip_method/2]).


%% @doc This plugin callback is called when a call to one of the method specific
%% application-level SipApp callbacks is needed.
-spec nkcb_sip_method(nksip_call:trans(), nksip_call:call()) ->
    {reply, nksip:sip_reply()} | noreply.


nkcb_sip_method(#trans{method='REGISTER', request=Req}, #call{app_id=AppId}) ->
    Module = AppId:module(),
    case erlang:function_exported(Module, sip_register, 2) of
        true ->
            continue;
        false ->
            {reply, nksip_registrar:request(Req)}
    end.

