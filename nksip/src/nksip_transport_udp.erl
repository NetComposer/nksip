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

%% @private UDP Transport Module.

-module(nksip_transport_udp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([send/2, send/4, send_stun/3, get_port/1]).
-export([start_link/2, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
             handle_info/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_UDP, 1500).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Sends a new UDP request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, #sipmsg{
            app_id=AppId, call_id=CallId,
            transport=#transport{remote_ip=Ip, remote_port=Port}=Transport,
            method=Method, response=Code}=SipMsg) ->
    Packet = nksip_unparse:packet(SipMsg),
    case send(Pid, Ip, Port, Packet) of
        ok when is_integer(Code) -> 
            nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Code, Packet}),
            nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transport, Packet),
            ok;
        ok ->
            nksip_trace:insert(SipMsg, {udp_out, Ip, Port, Method, Packet}),
            nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transport, Packet),
            ok;
        {error, closed} ->
            error;
        {error, too_large} ->
            error;
        {error, Error} ->
            ?notice(AppId, CallId, "could not send UDP msg to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            error
    end.


%% @private Sends a new packet
-spec send(pid(), inet:ip4_address(), inet:port_number(), binary()) ->
    ok | {error, term()}.

send(Pid, Ip, Port, Packet) when byte_size(Packet) =< ?MAX_UDP ->
    case catch gen_server:call(Pid, {send, Ip, Port, Packet}, 60000) of
        ok -> ok;
        {error, Error} -> {error, Error};
        {'EXIT', {noproc, _}} -> {error, closed};
        {'EXIT', Error} -> {error, Error}
    end;

send(_Pid, _Ip, _Port, Packet) ->
    lager:debug("Coult not send UDP packet (too large: ~p)", [byte_size(Packet)]),
    {error, too_large}.


%% @private Sends a STUN binding request
send_stun(Pid, Ip, Port) ->
    case catch gen_server:call(Pid, {send_stun, Ip, Port}, 30000) of
        {ok, List} -> 
            case nksip_lib:get_value(xor_mapped_address, List) of
                {StunIp, StunPort} -> 
                    {ok, StunIp, StunPort};
                _ ->
                    case nksip_lib:get_value(mapped_address, List) of
                        {StunIp, StunPort} -> {ok, StunIp, StunPort};
                        _ -> error
                    end
            end;
        _ ->
            error
    end.


%% @private Get transport current port
-spec get_port(pid()) ->
    {ok, inet:port_number()}.

get_port(Pid) ->
    gen_server:call(Pid, get_port).


%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transport) -> 
    gen_server:start_link(?MODULE, [AppId, Transport], []).


-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port(),
    stuns :: [{Id::binary(), Time::nksip_lib:timestamp(), term()}]
}).



% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, #transport{listen_ip=Ip, listen_port=Port}=Transport]) ->
    Opts = [binary, {reuseaddr, true}, {ip, Ip}, {active, once}],
    case gen_udp:open(Port, Opts) of
        {ok, Socket}  ->
            process_flag(priority, high),
            {ok, Port1} = inet:port(Socket),
            case gen_tcp:listen(Port1, [{ip, Ip}, {reuseaddr, true}]) of
                {ok, TCPSocket} ->
                    Self = self(),
                    spawn(fun() -> start_tcp(AppId, Ip, Port1, TCPSocket, Self) end),
                    Transport1 = Transport#transport{local_port=Port1, listen_port=Port1},
                    nksip_proc:put(nksip_transports, {AppId, Transport1}),
                    nksip_proc:put({nksip_listen, AppId}, Transport1),
                    {ok, 
                        #state{
                            app_id = AppId, 
                            transport = Transport1, 
                            socket = Socket,
                            stuns = []
                    }};
                Error ->
                    ?error(AppId, "could not start matching TCP transport on ~p:~p: ~p", 
                           [Ip, Port1, Error]),
                    {stop, no_matching_tcp}
            end;
        {error, Error} ->
            ?error(AppId, "could not start UDP transport on ~p:~p (~p)", 
                   [Ip, Port, Error]),
            {stop, Error}
    end.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Ip, Port, Packet}, _From, #state{socket=Socket}=State) ->
    {reply, gen_udp:send(Socket, Ip, Port, Packet), State};

handle_call({send_stun, Ip, Port}, From, #state{
                                                app_id=AppId, 
                                                socket=Socket, 
                                                stuns=Stuns}=State) ->
    {Id, Packet} = nksip_stun:binding_request(),
    case gen_udp:send(Socket, Ip, Port, Packet) of
        ok -> 
            Now = nksip_lib:timestamp(),
            Stuns1 = [{I, T, F} || {I, T, F} <- Stuns, Now-T < 5],
            Stuns2 = [{Id, nksip_lib:timestamp(), From}|Stuns1],
            {noreply, State#state{stuns=Stuns2}};
        {error, Error} ->
            ?notice(AppId, "could not send UDP STUN request to ~p:~p: ~p", 
                  [Ip, Port, Error]),
            {reply, error, State}
    end;

handle_call(get_port, _From, #state{transport=#transport{listen_port=Port}}=State) ->
    {reply, {ok, Port}, State};

handle_call(Msg, _Form, State) -> 
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.



%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(no_matching_tcp, State) ->
    {stop, no_matching_tcp, State};

handle_cast(Msg, State) -> 
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.



%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({udp, Socket, _Ip, _Port, <<_, _>>}, #state{socket=Socket}=State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({udp, Socket, Ip, Port, <<0:2, _Header:158, _Msg/binary>>=Packet}, 
            #state{
                app_id = AppId,
                socket = Socket,
                stuns = Stuns
            } = State) ->
    ok = inet:setopts(Socket, [{active, once}]),
    case nksip_stun:decode(Packet) of
        {request, binding, TransId, _} ->
            Response = nksip_stun:binding_response(TransId, Ip, Port),
            gen_udp:send(Socket, Ip, Port, Response),
            ?debug(AppId, "sent STUN Bind to ~p:~p", [Ip, Port]),
            {noreply, State};
        {response, binding, TransId, Attrs} ->
            case lists:keytake(TransId, 1, Stuns) of
                false ->
                    ?debug(AppId, "received unexpected STUN response", []),
                    {noreply, State};
                {value, {TransId, _, From}, Stuns1} ->
                    gen_server:reply(From, {ok, Attrs}),
                    {noreply, State#state{stuns=Stuns1}}
            end;
        error ->
            ?notice(AppId, "received unrecognized UDP Packet: ~p", [Packet]),
            {noreply, State}
    end;

handle_info({udp, Socket, Ip, Port, Packet}, #state{socket=Socket}=State) ->
    parse(Packet, Ip, Port, State),
    read_packets(100, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
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
%% Internal
%% ===================================================================


%% @private
start_tcp(AppId, Ip, Port, Socket, Pid) ->
    gen_tcp:close(Socket),
    case nksip_transport_conn:start_transport(AppId, tcp, Ip, Port, []) of
        {ok, _} -> ok;
        {error, _} -> gen_server:cast(Pid, no_matching_tcp)
    end.


%% @private 
read_packets(0, _State) ->
    ok;
read_packets(N, #state{socket=Socket}=State) ->
    case gen_udp:recv(Socket, 0, 0) of
        {error, _} -> 
            ok;
        {ok, {Ip, Port, Packet}} -> 
            parse(Packet, Ip, Port, State),
            read_packets(N-1, State)
    end.


%% @private
parse(Packet, Ip, Port, #state{app_id=AppId, transport=Transport}=State) ->   
    Transport1 = Transport#transport{remote_ip=Ip, remote_port=Port},
    case nksip_parse:packet(AppId, Transport1, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport1, Packet),
            nksip_trace:insert(AppId, CallId, {in_udp, Class}),
            nksip_call_router:incoming_async(RawMsg),
            case More of
                <<>> -> ok;
                _ -> ?notice(AppId, "ignoring data after UDP msg: ~p", [More])
            end;
        {rnrn, More} ->
            parse(More, Ip, Port, State);
        {more, More} -> 
            ?notice(AppId, "ignoring incomplete UDP msg: ~p", [More])
    end.






