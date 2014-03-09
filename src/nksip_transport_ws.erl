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
-export([start_link/3, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).
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
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp1,
    {
        {ws, {Proto, Ip, Port}},
        {?MODULE, start_link, [AppId, Transp1, Opts1]},
        permanent,
        5000,
        worker,
        [?MODULE]
    }.





%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    webserver :: reference()
}).


%% @private
start_link(AppId, Transp, Opts) ->
    gen_server:start_link(?MODULE, [AppId, Transp, Opts], []).
    

%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transp, Opts]) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port, dispatch=Disp} = Transp,
    case nksip_webserver:start_server(AppId, Proto, Ip, Port, Disp, Opts) of
        {ok, WebPid} ->
            Port1 = nksip_webserver:get_port(Proto, Ip, Port),
            Transp1 = Transp#transport{listen_port=Port1},   
            nksip_proc:put(nksip_transports, {AppId, Transp1}),
            nksip_proc:put({nksip_listen, AppId}, Transp1),
            Ref = erlang:monitor(process, WebPid),
            {ok, #state{webserver=Ref}};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{webserver=MRef}=State) ->
    {noreply, State}.
    

%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.


%% ===================================================================
%% Private
%% ===================================================================





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



