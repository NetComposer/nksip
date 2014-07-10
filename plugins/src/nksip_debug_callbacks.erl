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

%% @doc NkSIP Debug Plugin Callbacks
-module(nksip_debug_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").

-export([nkcb_connection_send/2, nkcb_connection_recv/2, nkcb_debug/2]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%


%% @doc Called when a new message has been sent
-spec nkcb_connection_send(nksip:request()|nksip:response(), binary()) ->
    continue.

nkcb_connection_send(SipMsg, Packet) ->
    #sipmsg{app_id=_AppId, class=Class, call_id=_CallId, transport=Transp} = SipMsg,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
    case Class of
        {req, Method} ->
            nksip_debug:insert(SipMsg, {Proto, Ip, Port, Method, Packet});
        {resp, Code, _Reason} ->
            nksip_debug:insert(SipMsg, {Proto, Ip, Port, Code, Packet})
    end,
    continue.


%% @doc Called when a new message has been received and parsed
-spec nkcb_connection_recv(nksip:request()|nksip:response(), binary()) ->
    continue.

nkcb_connection_recv(SipMsg, Packet) ->
    #sipmsg{app_id=AppId, call_id=CallId, transport=Transp} = SipMsg,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
    nksip_debug:insert(AppId, CallId, {Proto, Ip, Port, Packet}),
    continue.


%% doc Called at specific debug points
-spec nkcb_debug(nksip:request()|nksip:response(), term()) ->
    continue.

nkcb_debug(SipMsg, Info) ->
    nksip_debug:insert(SipMsg, Info),
    continue.

