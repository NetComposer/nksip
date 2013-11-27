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

-export([get_all/0, get_all/1, get_listening/3, get_connected/4]).
-export([is_local/2, is_local_ip/1, main_ip/0, main_ip6/0]).
-export([start_transport/5, start_connection/5, default_port/1]).
-export([send/4, raw_send/2]).

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
    [{nksip:app_id(), transport(), pid()}].

get_all() ->
    All = [{AppId, Transport, Pid} 
            || {{AppId, Transport}, Pid} <- nksip_proc:values(nksip_transports)],
    lists:sort(All).


%% @doc Gets all registered transports for a SipApp.
-spec get_all(nksip:app_id()) -> 
    [{transport(), pid()}].

get_all(AppId) ->
    [{Transport, Pid} || {A, Transport, Pid} <- get_all(), AppId==A].


%% @private Finds a listening transport of Proto.
-spec get_listening(nksip:app_id(), nksip:protocol(), ipv4|ipv6) -> 
    [{transport(), pid()}].

get_listening(AppId, Proto, Class) ->
    Fun = fun({#transport{proto=TProto, listen_ip=TListen}, _}) -> 
        case TProto==Proto of
            true ->
                case Class of
                    ipv4 when size(TListen)==4 -> true;
                    ipv6 when size(TListen)==8 -> true;
                    _ -> false
                end;
            false ->
                false
        end
    end,
    lists:filter(Fun, nksip_proc:values({nksip_listen, AppId})).


%% @private Finds a listening transport of Proto
-spec get_connected(nksip:app_id(), nksip:protocol(), 
                    inet:ip_address(), inet:port_number()) ->
    [{nksip_transport:transport(), pid()}].

get_connected(AppId, Proto, Ip, Port) ->
    nksip_proc:values({nksip_connection, {AppId, Proto, Ip, Port}}).


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
    Transp = {<<"transport">>, nksip_lib:to_binary(Proto)},
    Uri = #uri{domain=Host, port=Port, opts=[Transp]},
    is_local(AppId, Uri).


%% @private
is_local(Listen, [{Proto, Ip, Port}|Rest], LocalIps) -> 
    case lists:member(Ip, LocalIps) of
        true ->
            case lists:member({Proto, Ip, Port}, Listen) of
                true ->
                    true;
                false ->
                    case 
                        is_tuple(Ip) andalso size(Ip)==4 andalso
                        lists:member({Proto, {0,0,0,0}, Port}, Listen) 
                    of
                        true -> 
                            true;
                        false -> 
                            case 
                                is_tuple(Ip) andalso size(Ip)==8 andalso
                                lists:member({Proto, {0,0,0,0,0,0,0,0}, Port}, Listen) 
                            of
                                true -> true;
                                false -> is_local(Listen, Rest, LocalIps)
                            end
                    end
            end;
        false ->
            is_local(Listen, Rest, LocalIps)
    end;

is_local(_, [], _) ->
    false.


%% @doc Checks if an IP is local to this node.
-spec is_local_ip(inet:ip_address()) -> 
    boolean().

is_local_ip({0,0,0,0}) ->
    true;
is_local_ip({0,0,0,0,0,0,0,0}) ->
    true;
is_local_ip(Ip) ->
    lists:member(Ip, local_ips()).


%% @doc Gets a cached version of node's main IPv4 address.
-spec main_ip() -> 
    inet:ip4_address().

main_ip() ->
    nksip_config:get(main_ip). 


%% @doc Gets a cached version of node's main IPv6 address.
-spec main_ip6() -> 
    inet:ip6_address().

main_ip6() ->
    nksip_config:get(main_ip6). 


%% @doc Gets a cached version of all detected local node IPs.
-spec local_ips() -> 
    [inet:ip_address()].

local_ips() ->
    nksip_config:get(local_ips).


%% @doc Start a new listening transport.
-spec start_transport(nksip:app_id(), nksip:protocol(), inet:ip_address(), 
                      inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_transport(AppId, Proto, Ip, Port, Opts) ->
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    Listening = [
        {{LIp, LPort}, Pid} || 
            {#transport{listen_ip=LIp, listen_port=LPort}, Pid} 
            <- get_listening(AppId, Proto, Class)
    ],
    case nksip_lib:get_value({Ip, Port}, Listening) of
        undefined when Proto== udp ->
            nksip_transport_udp:start_listener(AppId, Ip, Port, Opts);
        undefined when Proto==tcp; Proto==tls ->
            nksip_transport_tcp:start_listener(AppId, Proto, Ip, Port, Opts);
        undefined when Proto==sctp ->
            nksip_transport_sctp:start_listener(AppId, Ip, Port, Opts);
        undefined ->
            {error, invalid_transport};
        Pid when is_pid(Pid) -> 
            {ok, Pid}
    end.


%% @private Starts a new outbound connection.
-spec start_connection(nksip:app_id(), nksip:protocol(),
                       inet:ip_address(), inet:port_number(), nksip_lib:proplist()) ->
    {ok, pid(), nksip_transport:transport()} | {error, term()}.

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
    ?debug(AppId, "Transport send to ~p (udp)", [All]),
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case get_listening(AppId, udp, Class) of
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
        when Proto==tcp; Proto==tls; Proto==sctp ->
    ?debug(AppId, "Transport send to ~p (current, ~p)", [All, Proto]),
    case get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case do_send(Proto, Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg, Opts)
            end;
        [] ->
            send(AppId, Rest, MakeMsg, Opts)
    end;

send(AppId, [{Proto, Ip, Port}|Rest]=All, MakeMsg, Opts) 
     when Proto==tcp; Proto==tls; Proto==sctp ->
    ?debug(AppId, "Transport send to ~p (~p)", [All, Proto]),
    case get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case do_send(Proto, Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg, Opts)
            end;
        [] ->
            case start_connection(AppId, Proto, Ip, Port, Opts) of
                {ok, Pid, Transport} ->
                    SipMsg = MakeMsg(Transport),
                    case do_send(Proto, Pid, SipMsg) of
                        ok -> {ok, SipMsg};
                        error -> send(AppId, Rest, MakeMsg, Opts)
                    end;
                {error, Error} ->
                    ?notice(AppId, "error connecting to ~p:~p (~p): ~p",
                            [Ip, Port, Proto, Error]),
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


raw_send(#raw_sipmsg{app_id=AppId, transport=#transport{proto=udp}=Transp}, Reply) ->
    #transport{remote_ip=Ip, remote_port=Port} = Transp,
    Class = case size(Ip) of 4 -> ipv4; 8 -> ipv6 end,
    case get_listening(AppId, udp, Class) of
        [{_, Pid}|_] -> nksip_transport_udp:send(Pid, Ip, Port, Reply);
        [] -> ok
    end;

raw_send(#raw_sipmsg{app_id=AppId, transport=Transp}, Reply) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port, sctp_id=AssocId} = Transp,
    case get_connected(AppId, Proto, Ip, Port) of
        [{_, Pid}|_] ->
            case Proto of
                tcp -> nksip_transport_tcp:send(Pid, Reply);
                tls -> nksip_transport_tcp:send(Pid, Reply);
                sctp -> nksip_transport_sctp:send(Pid, AssocId, Reply)
            end;
        [] -> 
            ok
    end.
               


%% @private
do_send(tcp, Pid, SipMsg) -> nksip_transport_tcp:send(Pid, SipMsg);
do_send(tls, Pid, SipMsg) -> nksip_transport_tcp:send(Pid, SipMsg);
do_send(sctp, Pid, SipMsg) -> nksip_transport_sctp:send(Pid, SipMsg).


%% @private
default_port(udp) -> 5060;
default_port(tcp) -> 5060;
default_port(tls) -> 5061;
default_port(sctp) -> 5060;
default_port(ws) -> 80;
default_port(wss) -> 443;
default_port(_) -> 0.



