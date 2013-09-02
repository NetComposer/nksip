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
-export([send/3]).
-export([is_local/2, is_local_ip/1, main_ip/0, local_ips/0, get_listening/2, resolve/1]).
-export([get_naptr/2, get_srvs/2]).

-export_type([transport/0]).

-include("nksip.hrl").

-compile({no_auto_import,[get/1]}).

-define(QUEUE_TIMEOUT, 30000).



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
    is_local(Listen, resolve(Uri), local_ips());

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



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send(nksip:app_id(), [TSpec], function()) ->
    {ok, nksip:request()|nksip:response()} | error
    when TSpec :: #uri{} | proto_ip_port() | {current, proto_ip_port()}.

send(AppId, [#uri{}=Uri|Rest]=All, MakeMsg) ->
    ?debug(AppId, "send to ~p", [All]),
    send(AppId, resolve(Uri)++Rest, MakeMsg);

send(AppId, [{udp, Ip, Port}|Rest]=All, MakeMsg) -> 
    ?debug(AppId, "send to ~p", [All]),
    case get_listening(AppId, udp) of
        [{Transport1, Pid}|_] -> 
            Transport2 = Transport1#transport{remote_ip=Ip, remote_port=Port},
            SipMsg = MakeMsg(Transport2),
            case nksip_transport_udp:send(Pid, SipMsg) of
                ok -> 
                    {ok, SipMsg};
                error -> 
                    send(AppId, [{tcp, Ip, Port}|Rest], MakeMsg)
            end;
        [] ->
            send(AppId, [{tcp, Ip, Port}|Rest], MakeMsg)
    end;

send(AppId, [{current, {udp, Ip, Port}}|Rest]
    , MakeMsg) ->
    send(AppId, [{udp, Ip,Port}|Rest], MakeMsg);

send(AppId, [{current, {Proto, Ip, Port}}|Rest]=All, MakeMsg) 
        when Proto=:=tcp; Proto=:=tls ->
    ?debug(AppId, "send to ~p", [All]),
    case nksip_transport_conn:get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case nksip_transport_tcp:send(Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg)
            end;
        [] ->
            send(AppId, Rest, MakeMsg)
    end;

send(AppId, [{Proto, Ip, Port}|Rest]=All, MakeMsg) when Proto=:=tcp; Proto=:=tls ->
    ?debug(AppId, "send to ~p", [All]),
    case nksip_transport_conn:get_connected(AppId, Proto, Ip, Port) of
        [{Transport, Pid}|_] -> 
            SipMsg = MakeMsg(Transport),
            case nksip_transport_tcp:send(Pid, SipMsg) of
                ok -> {ok, SipMsg};
                error -> send(AppId, Rest, MakeMsg)
            end;
        [] ->
            case nksip_transport_conn:start_connection(AppId, Proto, Ip, Port, []) of
                {ok, Pid, Transport} ->
                    SipMsg = MakeMsg(Transport),
                    case nksip_transport_tcp:send(Pid, SipMsg) of
                        ok -> {ok, SipMsg};
                        error -> send(AppId, Rest, MakeMsg)
                    end;
                error ->
                    send(AppId, Rest, MakeMsg)
            end
    end;

send(AppId, [Other|Rest], MakeMsg) ->
    ?warning(AppId, "invalid send specification: ~p", [Other]),
    send(AppId, Rest, MakeMsg);

send(_, [], _MakeMsg) ->
    error.
        



%% ===================================================================
%% Private
%% ===================================================================

%% @doc Finds the transports, servers and ports available for the indicated 
%% `nksip:uri()' or `nksip:via()' following RFC3263 (SRV weights not honored).
-spec resolve(nksip:uri()|nksip:via()) -> 
    [proto_ip_port()].

resolve(#uri{scheme=Scheme, domain=Host, opts=Opts, port=Port}) 
        when Scheme=:=sip; Scheme=:=sips -> 
    Target = nksip_lib:get_list(maddr, Opts, Host),
    case nksip_lib:to_ip(Target) of 
        {ok, TargetIp} -> IsNumeric = true;
        _ -> TargetIp = IsNumeric = false
    end,
    Proto = case nksip_lib:get_value(transport, Opts) of
        _ when Scheme=:=sips ->
            tls;
        udp -> 
            udp;
        tcp -> 
            tcp;
        tls -> 
            tls;
        undefined ->
            undefined;
        OtherProto ->
            case string:to_lower(nksip_lib:to_list(OtherProto)) of
                "udp" -> udp;
                "tcp" -> tcp;
                "tls" -> tls;
                _ -> undefined
            end
    end,
    if
        IsNumeric; Port=/=0 ->
            case IsNumeric of
                true -> 
                    Addrs = [TargetIp];
                false ->
                    case inet:getaddrs(Target, inet) of
                        {ok, Addrs} -> ok;
                        _ -> Addrs = []
                    end
            end,
            Proto1 = case Proto of 
                undefined -> udp; 
                _ -> Proto 
            end,
            Port1 = case Port of
                0 when Proto=:=tls -> 5061;
                0 -> 5060;
                _ -> Port
            end,
            [{Proto1, Addr, Port1} || Addr <- Addrs];
        true ->
            case get_srvs(Scheme, Target) of
                [] ->
                   case inet:getaddrs(Target, inet) of
                        {ok, Addrs} -> 
                            Proto1 = case Proto of undefined -> udp; _ -> Proto end,
                            Port1 = case Proto of tls -> 5061; _ -> 5060 end,
                            [{Proto1, Addr, Port1} || Addr <- Addrs];
                        _ ->
                            []
                    end;
                Transports when Proto=:=undefined ->
                    Transports;
                Transports ->
                    [{TProto, TAddr, TPort} || 
                     {TProto, TAddr, TPort} <- Transports, TProto=:=Proto]
            end
    end.


%% @private
-spec get_srvs(nksip:scheme(), string()) ->
    [proto_ip_port()].

get_srvs(Scheme, Domain) ->
    Naptr = get_naptr(Scheme, Domain),
    get_srvs_iter(Naptr, []).


-spec get_srvs_iter([{nksip:protocol(), string()}], [proto_ip_port()]) ->
    [proto_ip_port()].

get_srvs_iter([], Acc) ->
    Acc;

get_srvs_iter([{Proto, SrvDomain}|Rest], Acc) ->
    Fun = fun({_Order, _Weight, Port, Host}, FAcc) ->
        case inet:getaddrs(Host, inet) of
            {ok, Addrs} -> 
                FAcc ++ [{Proto, Addr, Port} || Addr <- Addrs];
            _ -> 
                FAcc
        end
    end,
    Srvs = lists:sort(inet_res:lookup(SrvDomain, in, srv)),
    Res = lists:foldl(Fun, [], Srvs),
    get_srvs_iter(Rest, Acc++Res).


%% @private
-spec get_naptr(nksip:scheme(), string()) -> 
    [{nksip:protocol(), string()}].

get_naptr(Scheme, Domain) ->
    Fun = fun({_Order, _Prio, _Flag, Service, _Re, SrvDomain}, Acc) ->
        case Service of
            "sips+d2t" -> [{tls, SrvDomain}|Acc];
            "sip+d2t" when Scheme=:=sip -> [{tcp, SrvDomain}|Acc];
            "sip+d2u" when Scheme=:=sip -> [{udp, SrvDomain}|Acc];
            % "sip+d2s" when Scheme=:=sip -> [{sctp, SrvDomain}|Acc];
            _ -> Acc
        end
    end,
    Naptr = lists:sort(inet_res:lookup(Domain, in, naptr)),
    case lists:foldl(Fun, [], Naptr) of
        [] ->
            [
                {tls, "_sips._tcp."++Domain},
                {tcp, "_sip._tcp."++Domain},
                {udp, "_sip._udp."++Domain}
            ];
        Srvs ->
            lists:reverse(Srvs)
    end.












