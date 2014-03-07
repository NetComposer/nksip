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

%% @private Websocket (WS/WSS) Transport.

-module(nksip_transport_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(cowboy_websocket_handler).

-export([get_listener/3]).
-export([init/3, websocket_init/3, websocket_handle/3, websocket_info/3, 
         websocket_terminate/3]).
-include("nksip.hrl").



%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nksip:app_id(), nksip:transport(), nksip_lib:proplist()) ->
    term().

get_listener(AppId, Transp, Opts) ->
    case lists:keytake(dispatch, 1, Opts) of
        false -> 
            Dispatch = [{'_', [{"/", ?MODULE, []}]}],
            Opts1 = Opts;
        {value, {_, Dispatch}, Opts1} -> 
            ok
    end,
    Transp1 = Transp#transport{dispatch=Dispatch},
    % Next function will insert transport's metadata in registry
    case nksip_webserver:start_server(AppId, Transp1, Opts1) of
        {ok, WebPid} ->
            Pid = nksip_transport_sup:get_pid(AppId),   
            Port = nksip_webserver:get_port(Transp1),
            Transp2 = Transp1#transport{listen_port=Port},                         
            nksip_proc:put(nksip_transports, {AppId, Transp2}, Pid),
            nksip_proc:put({nksip_listen, AppId}, Transp2, Pid),
            {ok, WebPid};
        {error, Error} ->
            {error, Error}
    end.






%% ===================================================================
%% Cowboy's callbacks
%% ===================================================================

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init(_TransportName, Req, _Opts) ->
    erlang:start_timer(1000, self(), <<"Hello!">>),
    {ok, Req, undefined_state}.

websocket_handle({text, Msg}, Req, State) ->
    {reply, {text, << "That's what she said! ", Msg/binary >>}, Req, State};
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.

websocket_info({timeout, _Ref, Msg}, Req, State) ->
    erlang:start_timer(1000, self(), <<"How' you doin'?">>),
    {reply, {text, Msg}, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
    ok.



