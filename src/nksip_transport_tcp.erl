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
-behaviour(gen_server).

-export([start_listener/5, connect/5, send/2, stop/1]).
-export([start_link/3, init/1, terminate/2, code_change/3, handle_call/3,   
            handle_cast/2, handle_info/2]).
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
        [AppId, Transp]),
    % Little hack to use our start_link instead of ranch's one
    {ranch_listener_sup, start_link, StartOpts} = element(2, Spec),
    Spec1 = setelement(2, Spec, {?MODULE, ranch_start_link, StartOpts}),
    nksip_transport_sup:add_transport(AppId, Spec1).

    
%% @private Starts a new connection to a remote server
-spec connect(nksip:app_id(), tcp|tls,
                    inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | error.
         
connect(AppId, Proto, Ip, Port, Opts) when Proto==tcp; Proto==tls ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case nksip_transport:get_listening(AppId, Proto, Class) of
        [{ListenTransp, _Pid}|_] -> 
            SocketOpts = outbound_opts(Proto, Opts),
            Timeout = 64 * nksip_config:get(timer_t1),
            case socket_connect(Proto, Ip, Port, SocketOpts, Timeout) of
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
                    Spec = {
                        {AppId, Proto, Ip, Port, make_ref()},
                        {?MODULE, start_link, [AppId, Transp, Socket]},
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



%% ===================================================================
%% gen_server
%% ===================================================================

%% @private
start_link(AppId, Transport, Socket) -> 
    gen_server:start_link(?MODULE, [AppId, Transport, Socket], []).

-record(state, {
    app_id :: nksip:app_id(),
    transport :: nksip_transport:transport(),
    socket :: port() | #sslsocket{},
    timeout :: non_neg_integer(),
    buffer = <<>> :: binary()
}).


%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([AppId, Transport, Socket]) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    process_flag(priority, high),
    nksip_proc:put({nksip_connection, {AppId, Proto, Ip, Port}}, Transport), 
    nksip_proc:put(nksip_transports, {AppId, Transport}),
    nksip_counters:async([?MODULE]),
    Timeout = nksip_config:get(tcp_timeout),
    {ok, 
        #state{
            app_id = AppId,
            transport = Transport, 
            socket = Socket, 
            timeout = Timeout,
            buffer = <<>>}, Timeout}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({send, Packet}, _From, State) ->
    #state{
        app_id = AppId, 
        socket = Socket,
        transport = #transport{proto=Proto},
        timeout = Timeout
    } = State,
    case socket_send(Proto, Socket, Packet) of
        ok -> 
            {reply, ok, State, Timeout};
        {error, Error} ->
            ?notice(AppId, "could not send TCP message: ~p", [Error]),
            {stop, normal, State}
    end;

handle_call(Msg, _From, State) ->
    lager:warning("Module ~p received unexpected call: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(Msg, State) ->
    lager:warning("Module ~p received unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({tcp, Socket, Packet}, #state{buffer=Buff}=State)
            when byte_size(<<Buff/binary, Packet/binary>>) > ?MAX_BUFFER ->
    #state{
        app_id = AppId, 
        transport = #transport{proto=Proto},
        timeout = Timeout
    } = State,
    ?warning(AppId, "dropping TCP/TLS closing because of max_buffer", []),
    socket_close(Proto, Socket),
    {noreply, State, Timeout};

%% @private
handle_info({tcp, Socket, Packet}, State) ->
    #state{
        transport = #transport{proto=Proto},
        buffer = Buff, 
        socket = Socket,
        timeout = Timeout
    } = State,
    setopts(Proto, Socket, [{active, once}]),
    Rest = parse(<<Buff/binary, Packet/binary>>, State),
    {noreply, State#state{buffer=Rest}, Timeout};

handle_info({ssl, Socket, Packet}, State) ->
    handle_info({tcp, Socket, Packet}, State);

handle_info({tcp_closed, Socket}, State) ->
    #state{
        app_id = AppId,
        transport = #transport{remote_ip=Ip, remote_port=Port},
        socket = Socket
    } = State,
    ?debug(AppId, "closed TCP connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info({ssl_closed, Socket}, State) ->
    #state{
        app_id = AppId,
        socket = Socket, 
        transport = #transport{remote_ip=Ip, remote_port=Port}
    } = State,
    ?debug(AppId, "closed TLS connection from ~p:~p", [Ip, Port]),
    {stop, normal, State};

handle_info(timeout, State) ->
    #state{
        app_id = AppId,
        socket = Socket,
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}
    } = State,
    ?debug(AppId, "TCP/TLS connection from ~p:~p timeout", [Ip, Port]),
    socket_close(Proto, Socket),
    {stop, normal, State};

% Received from Ranch when the listener is ready
handle_info({shoot, _ListenerPid}, State) ->
    #state{socket=Socket, transport=#transport{proto=Proto}} = State,
    setopts(Proto, Socket, [{active, once}]),
    {noreply, State, State#state.timeout};

handle_info(Info, State) -> 
    lager:warning("Module ~p received nexpected info: ~p", [?MODULE, Info]),
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
parse(Packet, #state{app_id=AppId, socket=Socket, transport=Transport}=State) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port}=Transport,
    case nksip_parse:packet(AppId, Transport, Packet) of
        {ok, #raw_sipmsg{call_id=CallId, class=_Class}=RawMsg, More} -> 
            nksip_trace:sipmsg(AppId, CallId, <<"FROM">>, Transport, Packet),
            nksip_trace:insert(AppId, CallId, {tcp_in, Proto, Ip, Port, Packet}),
            case nksip_call_router:incoming_sync(RawMsg) of
                ok ->
                    case More of
                        <<>> -> <<>>;
                        _ -> parse(More, State)
                    end;
                {error, _} ->
                    socket_close(Proto, Socket),
                    <<>>
            end;
        {rnrn, More} ->
            socket_send(Proto, Socket, <<"\r\n">>),
            parse(More, State);
        {more, More} -> 
            More;
        {error, Error} ->
            ?notice(AppId, "error ~p processing TCP/TLS request", [Error]),
            socket_close(Proto, Socket),
            <<>>           
    end.



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
                    [AppId, Transp]) ->
    case 
        ranch_listener_sup:start_link(Ref, NbAcceptors, RanchTransp, TransOpts, 
                                      Protocol, [AppId, Transp])
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

start_link(_ListenerPid, Socket, Module, [AppId, #transport{proto=Proto}=Transp]) ->
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
    start_link(AppId, Transp1, Socket).


%% @private
socket_connect(tcp, Ip, Port, Opts, Timeout) -> 
    gen_tcp:connect(Ip, Port, Opts, Timeout);
socket_connect(tls, Ip, Port, Opts, Timeout) -> 
    ssl:connect(Ip, Port, Opts, Timeout).

%% @private
socket_send(tcp, Socket, Packet) -> gen_tcp:send(Socket, Packet);
socket_send(tls, Socket, Packet) -> ssl:send(Socket, Packet).


%% @private
setopts(tcp, Socket, Opts) -> inet:setopts(Socket, Opts);
setopts(tls, Socket, Opts) -> ssl:setopts(Socket, Opts).


%% @private
socket_close(tcp, Socket) -> gen_tcp:close(Socket);
socket_close(tls, Socket) -> ssl:close(Socket).


%% @private
controlling_process(tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
controlling_process(tls, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

