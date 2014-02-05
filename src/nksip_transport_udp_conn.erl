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

%% @private UDP Transport Connection Module.
-module(nksip_transport_udp_conn).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nksip.hrl").


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transp, Socket, Opts) -> 
    gen_server:start_link(?MODULE, [AppId, Transp, Socket, Opts, self()], []).


-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    master :: pid(),
    nat_ip :: inet:ip_address(),
    nat_port :: inet:port_number(),
    refresh_timer :: reference(),
    refresh_time :: integer(),
    timeout :: integer()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transp, Socket, Opts, Master]) ->
    #transport{remote_ip=Ip, remote_port=Port} = Transp,
    nksip_proc:put({nksip_connection, {AppId, udp, Ip, Port}}, Transp), 
    ?notice(AppId, "UDP created connection to ~p (~p)", [{Ip, Port}, self()]),
    Timeout = 1000*nksip_config:get_cached(udp_timeout, Opts),
    State = #state{
        app_id = AppId,
        transport = Transp,
        socket = Socket,
        master = Master,
        timeout = Timeout
    },
    {ok, State, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Packet}, _From, State) ->
    #state{socket=Socket, transport=Transp, timeout=Timeout} = State,
    #transport{remote_ip=Ip, remote_port=Port} = Transp,
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State, Timeout};

handle_call(Msg, _Form, State) -> 
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({udp, Packet}, State) ->
    #state{app_id=AppId, transport=Transp, timeout=Timeout} = State,
    nksip_transport_udp:parse(AppId, Transp, Packet),
    {noreply, State, Timeout};

handle_cast({start_refresh, Secs}, State) ->
    #state{refresh_timer=RefreshTimer, timeout=Timeout} = State,
    nksip_lib:cancel_timer(RefreshTimer),
    RefreshTime = 1000*Secs,
    State1 = State#state{
        refresh_timer = erlang:start_timer(RefreshTime, self(), refresh),
        refresh_time = RefreshTime
    },
    {noreply, State1, Timeout};

handle_cast({stun_response, {StunIp, StunPort}}, State) ->
    #state{
        app_id = AppId, 
        nat_ip = NatIp, 
        nat_port = NatPort, 
        refresh_time = RefreshTime,
        timeout = Timeout
    } = State,
    case 
        {NatIp, NatPort} == {undefined, undefined} orelse
        {NatIp, NatPort} == {StunIp, StunPort}
    of
        true ->
            State1 = State#state{
                nat_ip = StunIp,
                nat_port = StunPort,
                refresh_timer = erlang:start_timer(RefreshTime, self(), refresh)
            },
            {noreply, State1, Timeout};
        false ->
            ?notice(AppId, "UDP connection stop on STUN response", []),
            {stop, normal, State}
    end;

handle_cast({stun_response, error}, #state{app_id=AppId}=State) ->
    ?notice(AppId, "UDP connection stop on STUN response", []),
    {stop, normal, State};

handle_cast(stun_request, #state{timeout=Timeout}=State) ->
    {noreply, State, Timeout};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) -> 
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({timeout, _, refresh}, State) ->
    #state{master=Master, transport=Transport, timeout=Timeout} = State,
    #transport{remote_ip=Ip, remote_port=Port} = Transport,
    nksip_transport_udp:send_stun_async(Master, Ip, Port),
    {noreply, State#state{refresh_timer=undefined}, Timeout};

handle_info(timeout, #state{app_id=AppId}=State) ->
    ?notice(AppId, "UDP connection timeout", []),
    {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State, State#state.timeout}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, #state{app_id=AppId}) ->  
    ?notice(AppId, "UDP stopped connection", []).


