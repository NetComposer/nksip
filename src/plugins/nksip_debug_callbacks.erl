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

%% @doc NkSIP Debug Plugin Callbacks
-module(nksip_debug_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([nksip_connection_sent/2, nksip_connection_recv/2, nksip_debug/3]).


%% ===================================================================
%% SIP Core
%% ===================================================================


%% @doc Called when a new message has been sent
-spec nksip_connection_sent(nksip:request()|nksip:response(), binary()) ->
    continue.

nksip_connection_sent(SipMsg, Packet) ->
    #sipmsg{class=Class, call_id=_CallId, nkport=NkPort} = SipMsg,
    {ok, {_Proto, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    case Class of
        {req, Method} ->
            nksip_debug:insert(SipMsg, {Transp, Ip, Port, Method, Packet});
        {resp, Code, _Reason} ->
            nksip_debug:insert(SipMsg, {Transp, Ip, Port, Code, Packet})
    end,
    continue.


%% @doc Called when a new message has been received and parsed
-spec nksip_connection_recv(nksip:sipmsg(), binary()) ->
    continue.

nksip_connection_recv(NkPort, Packet) ->
    #sipmsg{nkport=NkPort, call_id=CallId, pkg_id=PkgId} = NkPort,
    {ok, {_Proto, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    nksip_debug:insert(PkgId, CallId, {Transp, Ip, Port, Packet}),
    continue.


%% doc Called at specific debug points
-spec nksip_debug(nkserver:id(), nksip:call_id(), term()) ->
    continue.

nksip_debug(PkgId, CallId, Info) ->
    nksip_debug:insert(PkgId, CallId, Info),
    continue.
