%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([nks_sip_connection_sent/2, nks_sip_connection_recv/4, nks_sip_debug/3]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%


%% @doc Called when a new message has been sent
-spec nks_sip_connection_sent(nksip:request()|nksip:response(), binary()) ->
    continue.

nks_sip_connection_sent(SipMsg, Packet) ->
    #sipmsg{srv_id=_SrvId, class=Class, call_id=_CallId, nkport=NkPort} = SipMsg,
    {ok, {Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    case Class of
        {req, Method} ->
            nksip_debug:insert(SipMsg, {Transp, Ip, Port, Method, Packet});
        {resp, Code, _Reason} ->
            nksip_debug:insert(SipMsg, {Transp, Ip, Port, Code, Packet})
    end,
    continue.


%% @doc Called when a new message has been received and parsed
-spec nks_sip_connection_recv(nkservice:id(), nksip:call_id(), 
                           nkpacket:nkport(), binary()) ->
    continue.

nks_sip_connection_recv(SrvId, CallId, NkPort, Packet) ->
    {ok, {Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    nksip_debug:insert(SrvId, CallId, {Transp, Ip, Port, Packet}),
    continue.


%% doc Called at specific debug points
-spec nks_sip_debug(nkservice:id(), nksip:call_id(), term()) ->
    continue.

nks_sip_debug(SrvId, CallId, Info) ->
    nksip_debug:insert(SrvId, CallId, Info),
    continue.
