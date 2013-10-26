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

%% @doc NkSIP Transport control module

-module(nksip_transport).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_all/0, get_all/1, get_protocol/1]).
-export([is_local/2, is_local_ip/1, main_ip/0, local_ips/0, get_listening/2]).
-export([start_transport/5, start_connection/5, get_connected/4]).
-export([send/4]).

-export_type([transport/0]).

-include("nksip.hrl").

-compile({no_auto_import,[get/1]}).


%% ===================================================================
%% Types
%% ===================================================================

-type transport() :: #transport{}.

-type proto_ip_port() :: {nksip:protocol(), inet:ip_address(), inet:port_number()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all registered transports in all SipApps.
-spec get_all() -> 
    [{nksip:app_id(), transport()}].

get_all() ->
    All = [{AppId, Transport} 
            || {{AppId, Transport}, _Pid} <- nksip_proc:values(nksip_transports)],
    lists:sort(All).


%% @doc Gets all registered transports for a SipApp.
-spec get_all(nksip:app_id()) -> 
    [transport()].

get_all(AppId) ->
    [Transport || {A, Transport} <- get_all(), AppId=:=A].


%% @doc Gets all registered transports in all SipApps for this {@link nksip:protocol()}.
-spec get_protocol(nksip:protocol()) -> 
    [{nksip:app_id(), transport()}].

get_protocol(Proto) ->
    [{AppId, Transport} 
        || {AppId, #transport{proto=P}=Transport} <- get_all(), P=:=Proto].


%% @private Finds a listening transport of Proto.
-spec get_listening(nksip:app_id(), nksip:protocol()) -> 
    [{transport(), pid()}].

get_listening(AppId, Proto) ->
    Fun = fun({#transport{proto=TP}, _}) -> TP=:=Proto end,
    lists:filter(Fun, nksip_proc:values({nksip_listen, AppId})).


%% @doc Checks if an `nksip:uri()' or `nksip:via()' refers to a local started transport.
-spec is_local(nksip:app_id(), Input::nksip:uri()|nksip:via()) -> 
    boolean().

is_local(AppId, #uri{}=Uri) ->
    Listen = [
        {Proto, Ip, Port} ||
        {#transport{proto=Proto, listen_ip=Ip, listen_port=Port}, _Pid} 
        <- nksip_proc:values({nksip_listen, AppId})
    ],
    is_local(Listen, nksip_dns:resolve(Uri), local_ips());

is_local(AppId, #via{}=Via) ->
    {Proto, Host, Port} = nksip_parse:transport(Via),
    Uri = #uri{domain=Host, port=Port, opts=[{transport, Proto}]},
    is_local(AppId, Uri).

is_local(Listen, [{Proto, Ip, Port}|Rest], LocalIps) -> 
    case lists:member(Ip, LocalIps) of
        true ->
            case lists:member({Proto, Ip, Port}, Listen) of
                true ->
                    true;
                false ->
                    case lists:member({Proto, {0,0,0,0}, Port}, Listen) of
                        true -> true;
                        false -> is_local(Listen, Rest, LocalIps)
                    end
            end;
        false ->
            is_local(Listen, Rest, LocalIps)
    end;

is_local(_, [], _) ->
    false.


%% @doc Checks if an IP is local to this node.
-spec is_local_ip(inet:ip4_address()) -> 
    boolean().

is_local_ip({0,0,0,0}) ->
    true;
is_local_ip(Ip) ->
    lists:member(Ip, local_ips()).


%% @doc Gets a cached version of node's main IP address.
-spec main_ip() -> 
    inet:ip4_address().

main_ip() ->
    nksip_config:get(main_ip). 


%% @doc Gets a cached version of all detected local node IPs.
-spec local_ips() -> 
    [inet:ip4_address()].

local_ips() ->
    nksip_config:get(local_ips).


%% @doc Start a new listening transport.
-spec start_transport(nksip:app_id(), nksip:protocol(), inet:ip_address(), 
                      inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_transport(AppId, Proto, Ip, Port, Opts) ->
    Listening = [
        {{LIp, LPort}, Pid} || 
            {#transport{listen_ip=LIp, listen_port=LPort}, Pid} 
            <- get_listening(AppId, Proto)
    ],
    case nksip_lib:get_value({Ip, Port}, Listening) of
        undefined -> 
            nksip_transport_lib:start_transport(AppId, Proto, Ip, Port, Opts);
        Pid when is_pid(Pid) -> 
            {ok, Pid}
    end.


%% @private Starts a new outbound connection.
-spec start_connection(nksip:app_id(), nksip:protocol(),
                       inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | error.

start_connection(AppId, Proto, Ip, Port, Opts) ->
    Max = nksip_config:get(max_connections),
    case nksip_counters:value(nksip_transport_tcp) of
        Current when Current > Max ->
            error;
        _ ->
            nksip_transport_srv:start_connection(AppId, Proto, Ip, Port, Opts)
    end.
                


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send(nksip:app_id(), [TSpec], function(), nksip_lib:proplist()) ->
    {ok, nksip:request()|nksip:response()} | error
    when TSpec :: #uri{} | proto_ip_port() | {current, proto_ip_port()}.

send(AppId, [#uri{}=Uri|Rest]=All, MakeMsg, Opts) ->
    Resolv = nksip_dns:resolve(Uri),
    ?debug(AppId, "Transport send to ~p (~p)", [All, Resolv]),
    send(AppId, Resolv++Rest, MakeMsg, Opts);

send(AppId, [{udp, Ip, 0}|Rest], MakeMsg, Opts) ->
    %% If no port was explicitly specified, use default.
    send(AppId, [{udp, Ip, 5060}|Rest], MakeMsg, Opts);

send(AppId, [{udp, Ip, Port}|Rest]=All, MakeMsg, Opts) -> 
    ?debug(AppId, "Transport send to ~p", [All]),
    case get_listening(AppId, udp) of
        [{Transport1, Pid}|_] -> 
            Transport2 = Transport1#transport{remote_ip=Ip, remote_port=Port},
            SipMsg = MakeMsg(Transport2),
            case nksip_transport_udp:send(Pid, SipMsg) of
                ok -> 
                    {ok, SipMsg};
                error -> 
                    send(AppId, [{tcp, Ip, Port}|Rest], MakeMsg, Opts)
            end;
        [] ->
            send(AppId, [{tcp, Ip, Port}|Rest], MakeMsg, Opts)
    end;

send(AppId, [{current, {udp, Ip, Port}}|Rest], MakeMsg, Opts) ->
    send(AppId, [{udp, Ip,Port}|Rest], MakeMsg, Opts);

send(AppId, [{current, {Proto, Ip, Port}}|Rest]=All, MakeMsg, Opts) 
        when Proto=:=tcp; Proto=:=tls ->
    ?debug(AppId, "Transport send to ~p", [All]),
    case get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case nksip_transport_tcp:send(Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg, Opts)
            end;
        [] ->
            send(AppId, Rest, MakeMsg, Opts)
    end;

send(AppId, [{Proto, Ip, Port}|Rest]=All, MakeMsg, Opts) 
     when Proto=:=tcp; Proto=:=tls ->
    ?debug(AppId, "Transport send to ~p", [All]),
    case get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case nksip_transport_tcp:send(Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg, Opts)
            end;
        [] ->
            case start_connection(AppId, Proto, Ip, Port, Opts) of
                {ok, Pid, Transport} ->
                    SipMsg = MakeMsg(Transport),
                    case nksip_transport_tcp:send(Pid, SipMsg) of
                        ok -> {ok, SipMsg};
                        error -> send(AppId, Rest, MakeMsg, Opts)
                    end;
                error ->
                    send(AppId, Rest, MakeMsg, Opts)
            end
    end;

send(AppId, [Other|Rest], MakeMsg, Opts) ->
    ?warning(AppId, "invalid send specification: ~p", [Other]),
    send(AppId, Rest, MakeMsg, Opts);

send(_, [], _MakeMsg, _Opts) ->
    error.
        


%% ===================================================================
%% Private
%% ===================================================================

%% @private Finds a listening transport of Proto
-spec get_connected(nksip:app_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number()) ->
    [{nksip_transport:transport(), pid()}].

get_connected(AppId, Proto, Ip, Port) ->
    nksip_proc:values({nksip_connection, {AppId, Proto, Ip, Port}}).


