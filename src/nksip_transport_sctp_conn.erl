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

% -define(IN_STREAMS, 10).
% -define(OUT_STREAMS, 10).



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
    % nksip_proc:put(nksip_transports, {AppId, Transp}),
    nksip_proc:put({nksip_connection, {AppId, sctp, Ip, Port}}, Transp), 
    ?notice(AppId, "SCTP new connection from ~p:~p (~p)", [Ip, Port, AssocId]),
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

% handle_call({send, Packet}, _From, State) ->
%     #state{socket=Socket, transport=Transp, timeout=Timeout} = State,
%     #transport{sctp_id=AssocId} = Transp,
%     {reply, gen_sctp:send(Socket, AssocId, 0, Packet), State, Timeout};

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State#state.timeout}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast({sctp, Packet}, State) ->
    #state{app_id=AppId, transport=Transp, socket=Socket, timeout=Timeout} = State,
    nksip_transport_sctp:parse(AppId, Transp, Socket, Packet),
    {noreply, State, Timeout};

handle_cast({start_refresh, Secs}, State) ->
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
    {noreply, State1, Timeout};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State#state.timeout}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({sctp, Socket, Ip, Port, {Anc, SAC}}, State) ->
    #state{app_id=AppId, socket=Socket, transport=Transp} = State,
    case SAC of
        #sctp_assoc_change{state=comm_up, assoc_id=AssocId} ->
            ?warning(AppId, "SCTP: comm_up: ~p", [AssocId]);
        #sctp_assoc_change{state=shutdown_comp, assoc_id=AssocId} ->
            ?warning(AppId, "SCTP: shutdown_comp: ~p", [AssocId]);
        #sctp_paddr_change{addr=Addr, state=addr_confirmed, assoc_id=AssocId} ->
            ?warning(AppId, "SCTP: addr_confirmed: ~p, ~p", [Addr, AssocId]);
        #sctp_shutdown_event{assoc_id=AssocId} ->
            ?warning(AppId, "SCTP: #sctp_shutdown_event: ~p", [AssocId]);
        Data when is_binary(Data) ->
            [#sctp_sndrcvinfo{assoc_id=AssocId}] = Anc,
            Transp1 = Transp#transport{remote_ip=Ip, remote_port=Port, sctp_id=AssocId},
            nksip_transport_sctp:parse(AppId, Transp1, Socket, Data);
        Other ->
            ?warning(AppId, "SCTP unknown data from ~p, ~p: ~p", [Ip, Port, Other])
    end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};


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
            {noreply, State1, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send SCTP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_info({timeout, _, refreshed}, #state{app_id=AppId}=State) ->
    ?notice(AppId, "SCTP refresher timeout", []),
    {stop, normal, State};

handle_info(timeout, #state{app_id=AppId}=State) ->
    ?debug(AppId, "SCTP connection timeout", []),
    {stop, normal, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received nexpected info: ~p", [?MODULE, Info]),
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
    ?debug(AppId, "SCTP connection process stopped", []).



%% ===================================================================
%% Internal
%% ===================================================================


