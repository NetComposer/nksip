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

%% @private SCTP Connection Module.
-module(nksip_transport_sctp_conn).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3,   
         handle_cast/2, handle_info/2]).

-include("nksip.hrl").


%% ===================================================================
%% gen_server
%% ===================================================================


%% @private
start_link(AppId, Transp, Socket, Timeout) -> 
    gen_server:start_link(?MODULE, [AppId, Transp, Socket, Timeout], []).


-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    timeout :: non_neg_integer(),
    refresher_timer :: reference(),
    refresher_time :: integer(),
    refreshed_timer :: reference()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transp, Socket, Timeout]) ->
    #transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId} = Transp,
    nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp), 
    ?notice(AppId, "SCTP new connection: ~p (~p, ~p)", [{Ip, Port}, AssocId, self()]),
    State = #state{
        app_id = AppId, 
        transport = Transp, 
        socket = Socket,
        timeout = Timeout
    },
    {ok, State, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({start_refresh, Secs}, _From, State) ->
    #state{
        refresher_timer = RefresherTimer, 
        refreshed_timer = RefreshedTimer,
        timeout = Timeout
    } = State,
    nksip_lib:cancel_timer(RefresherTimer),
    nksip_lib:cancel_timer(RefreshedTimer),
    Time = 1000*Secs,
    State1 = State#state{
        refresher_timer = erlang:start_timer(Time, self(), refresher),
        refresher_time = Time,
        refreshed_timer = undefined
    },
    {reply, ok, State1, Timeout};

handle_call({receive_refresh, Secs}, _From, State) ->
    State1 = State#state{timeout=1000*Secs},
    {reply, ok, State1, State1#state.timeout};

handle_call(get_socket, _From, #state{socket=Socket}=State) ->
    {reply, {ok, Socket}, State};

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({sctp, Data}, State) ->
    #state{
        app_id = AppId,
        socket = Socket,
        transport = Transp,
        refreshed_timer = RefreshedTimer, 
        refresher_time = Time, 
        timeout = Timeout
    } = State,
    nksip_transport_sctp:parse(AppId, Transp, Socket, Data),
    State1 = case is_reference(RefreshedTimer) of
        true ->
            nksip_lib:cancel_timer(RefreshedTimer),
            ?debug(AppId, "SCTP renew refresh: ~p", [Time]),
            State#state{
                refresher_timer = erlang:start_timer(Time, self(), refresher),
                refreshed_timer = undefined
            };
        false ->
            State
    end,
    {noreply, State1, Timeout};

handle_cast(stop, State) ->
    #state{app_id=AppId, transport=#transport{sctp_id=AssocId}} = State,
    ?debug(AppId, "SCTP association ordered to stop: ~p", [AssocId]),
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State, State#state.timeout}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({timeout, _, refresher}, State) ->
    #state{
        app_id = AppId, 
        socket = Socket,
        transport = #transport{sctp_id=AssocId},
        timeout = Timeout
    } = State,
    case gen_sctp:send(Socket, AssocId, 0, <<"\r\n\r\n">>) of
        ok -> 
            State1 = State#state{
                refresher_timer = undefined,
                refreshed_timer = erlang:start_timer(10000, self(), refreshed)
            },
            ?debug(AppId, "SCTP sending refresh", []),
            {noreply, State1, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send SCTP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_info({timeout, _, refreshed}, #state{app_id=AppId}=State) ->
    ?notice(AppId, "SCTP refresher timeout", []),
    {stop, normal, State};

handle_info(timeout, State) ->
    #state{app_id=AppId, transport=#transport{sctp_id=AssocId}} = State,
    ?debug(AppId, "SCTP connection timeout: ~p", [AssocId]),
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

terminate(_Reason, #state{app_id=AppId, socket=Socket, transport=Transp}) ->  
    #transport{sctp_id=AssocId} = Transp,
    gen_sctp:eof(Socket, #sctp_assoc_change{assoc_id=AssocId}),
    ?notice(AppId, "SCTP connection process stopped: ~p, (~p)", [AssocId, self()]).



%% ===================================================================
%% Internal
%% ===================================================================


