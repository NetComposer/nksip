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
%%
%% For listening, we try to start a new webserver (ranch using cowboy_protocol), 
%% that can be shared with other instances. We use this module as callback.
%% We a new connection arrives, init/3 will be called, and we start a new
%% nksip_connection process in websocket_init/3.
%%
%% For outbound connections, we start a normal tcp/ssl connection and let it be
%% managed by a fresh nksip_connection process

-module(nksip_transport_ws).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

% -behaviour(cowboy_websocket_handler).

-export([get_listener/3, connect/3]).
-export([start_link/4, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).
-export([init/3, websocket_init/3, websocket_handle/3, websocket_info/3, 
         websocket_terminate/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("wsock/include/wsock.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @private Starts a new listening server
-spec get_listener(nkservice:id(), nksip:transport(), nksip:optslist()) ->
    term().

get_listener(SrvId, Transp, Opts) ->
    case lists:keytake(dispatch, 1, Opts) of
        false -> 
            Dispatch = "/",
            Opts1 = Opts;
        {value, {_, Dispatch}, Opts1} -> 
            ok
    end,
    Timeout = 1000*nklib_util:get_value(sip_ws_timeout, Opts),
    Dispatch1 = dispatch(Dispatch, [SrvId, Transp, [{timeout, Timeout}]]),
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp,
    {
        {ws, {Proto, Ip, Port}},
        {?MODULE, start_link, [SrvId, Transp, Dispatch1, Opts1]},
        permanent,
        5000,
        worker,
        [?MODULE]
    }.


%% @private Starts a new connection to a remote server
-spec connect(nkservice:id(), nksip:transport(), nksip:optslist()) ->
    {ok, term()} | {error, term()}.
         
connect(SrvId, Transp, Opts) ->
    try
        case nksip_connection:is_max(SrvId) of
            false -> ok;
            true -> throw(max_connections)
        end,
        #transport{proto=Proto, remote_ip=Ip, remote_port=Port, resource=Res} = Transp,
        {InetMod, TranspMod} = case Proto of
            ws -> {inet, gen_tcp};
            wss -> {ssl, ssl}
        end,
        Res1 = case Res of <<>> -> <<"/">>; _ -> Res end,
        SocketOpts = outbound_opts(Proto, SrvId),
        Socket = case TranspMod:connect(Ip, Port, SocketOpts) of
            {ok, Socket0} -> Socket0;
            {error, Error1} -> throw(Error1) 
        end,
        {Data1, HandshakeReq} = handshake_req(Ip, Port, Res1, Opts),
        case TranspMod:send(Socket, Data1) of
            ok -> ok;
            {error, Error2} -> throw(Error2)
        end,
        case recv(TranspMod, Socket, <<>>) of
            {ok, Data2} ->
                ?debug(SrvId, <<>>, "received ws reply: ~s", [print_headers(Data2)]),
                case handshake_resp(SrvId, Data2, HandshakeReq) of
                    ok -> ok;
                    {error, Error3} -> throw(Error3)
                end;
            {error, Error4} ->
                throw(Error4)
        end,
        {ok, {LocalIp, LocalPort}} = InetMod:sockname(Socket),
        Transp1 = Transp#transport{
            local_ip = LocalIp,
            local_port = LocalPort,
            remote_ip = Ip,
            remote_port = Port,
            resource = Res1
        },
        Timeout = 1000 * SrvId:cache_sip_ws_timeout(),
        Spec = {
            {SrvId, Proto, Ip, Port, make_ref()},
            {nksip_connection, start_link, 
                [SrvId, Transp1, Socket, Timeout]},
            temporary,
            5000,
            worker,
            [?MODULE]
        },
        {ok, Pid} = nkservice_transport_sup:add_transport(SrvId, Spec),
        TranspMod:controlling_process(Socket, Pid),
        InetMod:setopts(Socket, [{active, once}]),
        ?debug(SrvId, <<>>, "~p connected to ~p", [Proto, {Ip, Port}]),
        {ok, Pid, Transp1}
    catch
        throw:TError -> {error, TError}
    end.


%% @private
recv(Mod, Socket, Buff) ->
    case Mod:recv(Socket, 0, 5000) of
        {ok, Data} ->
            Data1 = <<Buff/binary, Data/binary>>,
            case binary:match(Data, <<"\r\n\r\n">>) of
                nomatch -> 
                    recv(Mod, Socket, Data1);
                _ ->
                    {ok, Data1}
            end;
        {error, Error} ->
            {error, Error}
    end.




%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    srv_id :: nkservice:id(),
    transport :: nksip:transport(),
    webserver :: reference(),
    timeout :: pos_integer()
}).


%% @private
start_link(SrvId, Transp, Dispatch, Opts) ->
    gen_server:start_link(?MODULE, [SrvId, Transp, Dispatch, Opts], []).
    

%% @private 
init([SrvId, Transp, Dispatch, Opts]) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp,
    case 
        nksip_webserver:start_server(SrvId, Proto, Ip, Port, Dispatch, Opts) 
    of
        {ok, WebPid} ->
            Port1 = nksip_webserver:get_port(Proto, Ip, Port),
            Transp1 = Transp#transport{listen_port=Port1},   
            nklib_proc:put(nksip_transports, {SrvId, Transp1}),
            nklib_proc:put({nksip_listen, SrvId}, Transp1),
            State = #state{
                srv_id = SrvId, 
                transport = Transp,
                webserver = erlang:monitor(process, WebPid),
                timeout = 1000*nklib_util:get_value(sip_ws_timeout, Opts)
            },
            {ok, State};
        {error, Error} ->
            {error, Error}
    end.


%% @private
handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
handle_info({'DOWN', MRef, process, _Pid, _Reason}, #state{webserver=MRef}=State) ->
    {noreply, State};
    
handle_info(Msg, State) -> 
    lager:warning("Module ~p received unexpected info ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
terminate(_Reason, _State) ->  
    ok.


% %% ===================================================================
% %% Cowboy's callbacks
% %% ===================================================================

-record(ws_state, {
    conn_pid :: pid()
}).


%% @private
init({Transp, http}, _Req, _Opts) when Transp==tcp; Transp==ssl ->
    {upgrade, protocol, cowboy_websocket}.

%% @private
websocket_init(_TransportName, Req, [SrvId, Transp, Opts]) ->
    WsProtos = case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        {ok, ProtList, Req2} when is_list(ProtList) -> ProtList;
        {ok, _, Req2} -> []
    end,
    case lists:member(<<"sip">>, WsProtos) of
        true ->
            Req3 = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, 
                                              <<"sip">>, Req2),
            Timeout = nklib_util:get_value(timeout, Opts),
            {{RemoteIp, RemotePort}, _} = cowboy_req:peer(Req3),
            {Path, _} = cowboy_req:path(Req3),
            Transp1 = Transp#transport{
                remote_ip = RemoteIp, 
                remote_port = RemotePort,
                resource = Path
            },
            {ok, Pid} = nksip_connection:start_link(SrvId, Transp1, self(), Timeout),
            {ok, Req3, #ws_state{conn_pid=Pid}};
        false -> 
            {shutdown, Req2}
    end.


%% @private
websocket_handle({text, Msg}, Req, #ws_state{conn_pid=Pid}=State) ->
    nksip_connection:incoming(Pid, Msg),
    {ok, Req, State};

websocket_handle({binary, Msg}, Req, #ws_state{conn_pid=Pid}=State) ->
    nksip_connection:incoming(Pid, Msg),
    {ok, Req, State};

websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.


%% @private
websocket_info({send, Frames}, Req, State) ->
    {reply, Frames, Req, State};

websocket_info(Info, Req, #ws_state{conn_pid=Pid}=State) ->
    Pid ! Info,
    {ok, Req, State}.


%% @private
websocket_terminate(Reason, _Req, #ws_state{conn_pid=Pid}) ->
    nksip_connection:stop(Pid, Reason),
    ok.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
dispatch([H|_]=String, Args) when is_integer(H) ->
    dispatch([String], Args);

dispatch(List, Args) ->
    lists:map(
        fun(Spec) ->
            case Spec of
                {Host, Constraints, PathsList} 
                    when is_list(Constraints), is_list(PathsList) -> 
                    ok;
                {Host, PathsList} when is_list(PathsList) -> 
                    Constraints = [];
                SinglePath when is_list(SinglePath), is_integer(hd(SinglePath)) ->
                    Host = '_', Constraints = [], PathsList = [SinglePath];
                PathsList when is_list(PathsList) ->
                    Host = '_', Constraints = []
            end,
            Paths = lists:map(
                fun(PatchSpec) ->
                    case PatchSpec of
                        {Path, PathConstraints} 
                            when is_list(Path), is_list(PathConstraints) ->
                            {Path, PathConstraints, ?MODULE, Args};
                        Path when is_list(Path) ->
                            {Path, [], ?MODULE, Args}
                    end
                end,
                PathsList),
            {Host, Constraints, Paths}
        end,
        List).


%% @private Gets socket options for outbound connections
-spec outbound_opts(nksip:protocol(), nkservice:id()) ->
    nksip:optslist().

outbound_opts(ws, _SrvId) ->
    [binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw}];

outbound_opts(wss, SrvId) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "cert.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = case erlang:function_exported(SrvId, cache_sip_certfile, 0) of
        true -> SrvId:cache_sip_certfile();
        false -> DefCert
    end,
    Key = case erlang:function_exported(SrvId, cache_sip_keyfile, 0) of
        true -> SrvId:cache_sip_keyfile();
        false -> DefKey
    end,
    lists:flatten([
        binary, {active, false}, {nodelay, true}, {keepalive, true}, {packet, raw},
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end
    ]).


%% @private
-spec handshake_req(inet:ip_address(), inet:port_number(), binary(), 
                    nksip:optslist()) ->
    {binary(), #handshake{}}.

handshake_req(Ip, Port, Res, Opts) ->
    Host = case nklib_util:get_value(transport_uri, Opts) of
        #uri{domain=Domain} -> 
            binary_to_list(Domain);
        undefined -> 
            binary_to_list(nklib_util:to_host(Ip))
    end,
    Res1 = nklib_util:to_list(Res),
    {ok, #handshake{message=Msg1}=HS1} = wsock_handshake:open(Res1, Host, Port),
    #http_message{headers=Headers1} = Msg1,
    Headers2 = [{"Sec-Websocket-Protocol", "sip"}|Headers1],
    Msg2 = Msg1#http_message{headers=Headers2},
    HS2 = HS1#handshake{message=Msg2},
    {wsock_http:encode(Msg2), HS2}.


%% @private
-spec handshake_resp(nkservice:id(), binary(), #handshake{}) ->
    ok | {error, term()}.

handshake_resp(SrvId, Data, Req) ->
    case wsock_http:decode(Data, response) of
        {ok, Resp} ->
            case wsock_handshake:handle_response(Resp, Req) of
                {ok, #handshake{message=#http_message{headers=Headers}}} -> 
                    case nklib_util:get_value("Sec-Websocket-Protocol", Headers) of
                        "sip" -> 
                            ok;
                        _ ->
                            %% R15 sends it in lowercase (?)
                            case nklib_util:get_value("sec-websocket-protocol", Headers) of
                                "sip" -> 
                                    ok;
                                _ ->
                                    ?warning(SrvId, <<>>, 
                                        "websocket server did not send protocol: ~p", 
                                        [Headers])
                            end
                    end;
                {error, Error1} -> 
                    {error, Error1}
            end;
        {error, Error2} ->
            {error, Error2};
        Other3 ->
            {error, Other3}
    end.



%% private 
print_headers(Binary) ->
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    list_to_binary(io_lib:format("\r\n\r\n~s\r\n", [list_to_binary(Lines)])).



