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

-export([get_listener/3, connect/2]).
-export([ranch_start_link/6, start_link/4]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Private
%% ===================================================================

%% @private Starts a new listening server
-spec get_listener(nksip:app_id(), nksip:transport(), nksip:optslist()) ->
    term().

get_listener(SrvId, Transp, Opts) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp,
    Listeners = nklib_util:get_value(listeners, Opts, 100),
    Module = case Proto of
        tcp -> ranch_tcp;
        tls -> ranch_ssl
    end,
    Timeout = 1000 * nksip_sipapp_srv:config(SrvId, tcp_timeout),
    Spec = ranch:child_spec(
        {SrvId, Proto, Ip, Port}, 
        Listeners, 
        Module,
        listen_opts(Proto, Ip, Port, Opts), 
        ?MODULE,
        [SrvId, Transp, Timeout]),
    % Little hack to use our start_link instead of ranch's one
    {ranch_listener_sup, start_link, StartOpts} = element(2, Spec),
    setelement(2, Spec, {?MODULE, ranch_start_link, StartOpts}).

    
%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), nksip:transport()) ->
    {ok, term()} | {error, term()}.
         
connect(SrvId, Transp) ->
    case nksip_connection:is_max(SrvId) of
        false ->
            #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transp,
            SocketOpts = outbound_opts(Proto, SrvId),
            {InetMod, TranspMod} = case Proto of
                tcp -> {inet, gen_tcp};
                tls -> {ssl, ssl}
            end,
            case TranspMod:connect(Ip, Port, SocketOpts) of
                {ok, Socket} -> 
                    {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
                    Transp1 = Transp#transport{
                        local_ip = LocalIp,
                        local_port = LocalPort,
                        remote_ip = Ip,
                        remote_port = Port
                    },
                    Timeout = 1000 * nksip_sipapp_srv:config(SrvId, tcp_timeout),
                    Spec = {
                        {SrvId, Proto, Ip, Port, make_ref()},
                        {nksip_connection, start_link, 
                            [SrvId, Transp1, Socket, Timeout]},
                        temporary,
                        5000,
                        worker,
                        [?MODULE]
                    },
                    {ok, Pid} = nksip_transport_sup:add_transport(SrvId, Spec),
                    TranspMod:controlling_process(Socket, Pid),
                    InetMod:setopts(Socket, [{active, once}]),
                    ?debug(SrvId, <<>>, "~p connected to ~p", [Proto, {Ip, Port}]),
                    {ok, Pid, Transp1};
                {error, Error} ->
                    {error, Error}
            end;
        true ->
            {error, max_connections}
    end.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private Gets socket options for outbound connections
-spec outbound_opts(nksip:protocol(), nksip:app_id()) ->
    nksip:optslist().

outbound_opts(tcp, _SrvId) ->
    [binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw}];

outbound_opts(tls, SrvId) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Config = nksip_sipapp_srv:config(SrvId),
    Cert = nklib_util:get_value(certfile, Config, DefCert),
    Key = nklib_util:get_value(keyfile, Config, DefKey),
    lists:flatten([
        binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).


%% @private Gets socket options for listening connections
-spec listen_opts(nksip:protocol(), inet:ip_address(), inet:port_number(), 
                    nksip:optslist()) ->
    nksip:optslist().

listen_opts(tcp, Ip, Port, Opts) ->
    Max = nklib_util:get_value(max_connections, Opts, 100),
    [
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        {max_connections, Max}
    ];

listen_opts(tls, Ip, Port, Opts) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = nklib_util:get_value(certfile, Opts, DefCert),
    Key = nklib_util:get_value(keyfile, Opts, DefKey),
    Max = nklib_util:get_value(max_connections, Opts, 100),
    lists:flatten([
        {ip, Ip}, {port, Port}, {active, false}, 
        {nodelay, true}, {keepalive, true}, {packet, raw},
        {max_connections, Max},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).


%% @private Our version of ranch_listener_sup:start_link/5
-spec ranch_start_link(any(), non_neg_integer(), module(), term(), module(), term())-> 
    {ok, pid()}.

ranch_start_link(Ref, NbAcceptors, RanchTransp, TransOpts, Protocol, 
                    [SrvId, Transp, Timeout]) ->
    case 
        ranch_listener_sup:start_link(Ref, NbAcceptors, RanchTransp, TransOpts, 
                                      Protocol, [SrvId, Transp, Timeout])
    of
        {ok, Pid} ->
            Port = ranch:get_port(Ref),
            Transp1 = Transp#transport{local_port=Port, listen_port=Port},
            nklib_proc:put(nksip_transports, {SrvId, Transp1}, Pid),
            nklib_proc:put({nksip_listen, SrvId}, Transp1, Pid),
            {ok, Pid};
        Other ->
            Other
    end.
   

%% @private Ranch's callback, called for every new inbound connection
-spec start_link(pid(), port(), atom(), term()) ->
    {ok, pid()}.

start_link(_ListenerPid, Socket, Module, [SrvId, Transp, Timeout]) ->
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
    nksip_connection:start_link(SrvId, Transp1, Socket, Timeout).


