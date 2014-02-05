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

%% @private TCP/TLS Transport.
%% This module is used for both inbound and outbound TCP and TLS connections.

-module(nksip_transport_tcp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_listener/5, connect/5, send/2, stop/1, start_refresh/1, start_refresh/2]).
-export([ranch_start_link/6, start_link/4]).

-include("nksip.hrl").

-define(MAX_BUFFER, 64*1024*1024).


%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a new listening server
-spec start_listener(nksip:app_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_listener(AppId, Proto, Ip, Port, Opts) when Proto==tcp; Proto==tls ->
    Listeners = nksip_lib:get_value(listeners, Opts, 1),
    Module = case Proto of
        tcp -> ranch_tcp;
        tls -> ranch_ssl
    end,
    Transp = #transport{
        proto = Proto,
        local_ip = Ip, 
        local_port = Port,
        listen_ip = Ip,
        listen_port = Port,
        remote_ip = {0,0,0,0},
        remote_port = 0
    },
    Spec = ranch:child_spec(
        {AppId, Proto, Ip, Port}, 
        Listeners, 
        Module,
        listen_opts(Proto, Ip, Port, Opts), 
        ?MODULE,
        [AppId, Transp, Opts]),
    % Little hack to use our start_link instead of ranch's one
    {ranch_listener_sup, start_link, StartOpts} = element(2, Spec),
    Spec1 = setelement(2, Spec, {?MODULE, ranch_start_link, StartOpts}),
    nksip_transport_sup:add_transport(AppId, Spec1).

    
%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), tcp|tls,
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.
         
connect(AppId, Proto, Ip, Port, Opts) when Proto==tcp; Proto==tls ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, Proto, Class) of
        [{ListenTransp, _Pid}|_] -> 
            SocketOpts = outbound_opts(Proto, Opts),
            case socket_connect(Proto, Ip, Port, SocketOpts) of
                {ok, Socket} -> 
                    {ok, {LocalIp, LocalPort}} = case Proto of
                        tcp -> inet:sockname(Socket);
                        tls -> ssl:sockname(Socket)
                    end,
                    Transp = ListenTransp#transport{
                        local_ip = LocalIp,
                        local_port = LocalPort,
                        remote_ip = Ip,
                        remote_port = Port
                    },
                    Timeout = 1000*nksip_config:get_cached(tcp_timeout, Opts),
                    Spec = {
                        {AppId, Proto, Ip, Port, make_ref()},
                        {nksip_transport_tcp_conn, start_link, 
                            [AppId, Transp, Socket, Timeout]},
                        temporary,
                        5000,
                        worker,
                        [?MODULE]
                    },
                    {ok, Pid} = nksip_transport_sup:add_transport(AppId, Spec),
                    controlling_process(Proto, Socket, Pid),
                    setopts(Proto, Socket, [{active, once}]),
                    ?debug(AppId, "connected to ~s:~p (~p)", 
                        [nksip_lib:to_host(Ip), Port, Proto]),
                    {ok, Pid, Transp};
                {error, Error} ->
                    {error, Error}
            end;
        [] ->
            {error, no_listening_transport}
    end.


%% @private Sends a new TCP or TLS request or response
-spec send(pid(), #sipmsg{}) ->
    ok | error.

send(Pid, #sipmsg{app_id=AppId, call_id=CallId, transport=Transport}=SipMsg) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    Packet = nksip_unparse:packet(SipMsg),
    case catch gen_server:call(Pid, {send, Packet}) of
        ok ->
            nksip_trace:insert(SipMsg, {tcp_out, Proto, Ip, Port, Packet}),
            nksip_trace:sipmsg(AppId, CallId, <<"TO">>, Transport, Packet),
            ok;
        {'EXIT', Error} ->
            ?notice(AppId, CallId, "could not send TCP message: ~p", [Error]),
            error
    end;

send(Pid, Packet) when is_binary(Packet) ->
    case catch gen_server:call(Pid, {send, Packet}) of
        ok -> ok;
        {'EXIT', _} -> error
    end.


%% @private
stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Start a time-alive series (default time)
-spec start_refresh(pid()) ->
    ok.

start_refresh(Pid) ->
    start_refresh(Pid, ?DEFAULT_TCP_KEEPALIVE).


%% @doc Start a time-alive series
-spec start_refresh(pid(), pos_integer()) ->
    ok.

start_refresh(Pid, Secs) ->
    Rand = crypto:rand_uniform(80, 101),
    Time = (Rand*Secs) div 100,
    gen_server:cast(Pid, {start_refresh, Time}).


%% ===================================================================
%% Internal
%% ===================================================================


%% @private Gets socket options for outbound connections
-spec outbound_opts(nksip:protocol(), nksip_lib:proplist()) ->
    nksip_lib:proplist().

outbound_opts(Proto, Opts) when Proto==tcp; Proto==tls ->
    Opts1 = listen_opts(Proto, {0,0,0,0}, 0, Opts),
    [binary|nksip_lib:delete(Opts1, [ip, port, max_connections])].


%% @private Gets socket options for listening connections
-spec listen_opts(nksip:protocol(), inet:ip_address(), inet:port_number(), 
                    nksip_lib:proplist()) ->
    nksip_lib:proplist().

listen_opts(tcp, Ip, Port, _Opts) ->
    lists:flatten([
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]);

listen_opts(tls, Ip, Port, Opts) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "certificate.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = nksip_lib:get_value(certfile, Opts, DefCert),
    Key = nksip_lib:get_value(keyfile, Opts, DefKey),
    lists:flatten([
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end,
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]).


%% @private Our version of ranch_listener_sup:start_link/5
-spec ranch_start_link(any(), non_neg_integer(), module(), term(), module(), term())-> 
    {ok, pid()}.

ranch_start_link(Ref, NbAcceptors, RanchTransp, TransOpts, Protocol, 
                    [AppId, Transp, Opts]) ->
    case 
        ranch_listener_sup:start_link(Ref, NbAcceptors, RanchTransp, TransOpts, 
                                      Protocol, [AppId, Transp, Opts])
    of
        {ok, Pid} ->
            Port = ranch:get_port(Ref),
            Transp1 = Transp#transport{local_port=Port, listen_port=Port},
            nksip_proc:put(nksip_transports, {AppId, Transp1}, Pid),
            nksip_proc:put({nksip_listen, AppId}, Transp1, Pid),
            {ok, Pid};
        Other ->
            Other
    end.
   

%% @private Ranch's callback, called for every new inbound connection
-spec start_link(pid(), port(), atom(), term()) ->
    {ok, pid()}.

start_link(_ListenerPid, Socket, Module, [AppId, Transp, Opts]) ->
    #transport{proto=Proto} = Transp,
    {ok, {LocalIp, LocalPort}} = Module:sockname(Socket),
    {ok, {RemoteIp, RemotePort}} = Module:peername(Socket),
    Transp1 = Transp#transport{
        local_ip = LocalIp,
        local_port = LocalPort,
        remote_ip = RemoteIp,
        remote_port = RemotePort,
        listen_ip = LocalIp,
        listen_port = LocalPort
    },
    Module:setopts(Socket, [{nodelay, true}, {keepalive, true}]),
    ?debug(AppId, "new connection from ~p:~p (~p)", [RemoteIp, RemotePort, Proto]),
    Timeout = 1000*nksip_config:get_cached(tcp_timeout, Opts),
    nksip_transport_tcp_conn:start_link(AppId, Transp1, Socket, Timeout).


%% @private
socket_connect(tcp, Ip, Port, Opts) -> gen_tcp:connect(Ip, Port, Opts);
socket_connect(tls, Ip, Port, Opts) -> ssl:connect(Ip, Port, Opts).


%% @private
setopts(tcp, Socket, Opts) -> inet:setopts(Socket, Opts);
setopts(tls, Socket, Opts) -> ssl:setopts(Socket, Opts).


%% @private
controlling_process(tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
controlling_process(tls, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

