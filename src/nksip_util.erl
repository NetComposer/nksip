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

%% @doc Common library utility funcions
-module(nksip_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_syntax/1, parse_syntax/2]).
-export([get_cseq/0, initial_cseq/0]).
-export([get_local_ips/0, find_main_ip/0, find_main_ip/2]).
-export([put_log_cache/2]).

-include("nksip.hrl").




%% ===================================================================
%% Public
%% =================================================================


parse_syntax(Data) ->
    nkservice_util:parse_syntax(Data, syntax(), defaults()).


parse_syntax(Data, Defaults) ->
    nkservice_util:parse_syntax(Data, syntax(), Defaults).



syntax() ->
    #{
        log_level => log_level,

        % System options
        sip_timer_t1 => {integer, 10, 2500},
        sip_timer_t2 => {integer, 100, 16000},
        sip_timer_t4 => {integer, 100, 25000},
        sip_timer_c => {integer, 1, none},
        sip_udp_timeout => {integer, 5, none},
        sip_tcp_timeout => {integer, 5, none},
        sip_sctp_timeout => {integer, 5, none},
        sip_ws_timeout => {integer, 5, none},
        sip_trans_timeout => {integer, 5, none},
        sip_dialog_timeout => {integer, 5, none},
        sip_event_expires => {integer, 1, none},
        sip_event_expires_offset => {integer, 0, none},
        sip_nonce_timeout => {integer, 5, none},
        sip_max_calls => {integer, 1, 1000000},
        sip_max_connections => {integer, 1, 1000000},
        
        % Startup options
        sip_transports => fun parse_transports/3,
        sip_certfile => path,
        sip_keyfile => path,
        sip_supported => words,
        sip_allow => words,
        sip_accept => words,
        sip_events => words,
        
        % Default headers and options
        sip_from => uri,
        sip_route => uris,
        sip_local_host => [{enum, [auto]}, host],
        sip_local_host6 => [{enum, [auto]}, host6],
        sip_no_100 => {enum, [true]},

        sip_debug => boolean
    }.


defaults() ->
    [
        {log_level, notice},
        {sip_allow, [
            <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
            <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
            <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>]},
        {sip_supported, [<<"path">>]},
        {sip_timer_t1, 500},                    % (msecs) 0.5 secs
        {sip_timer_t2, 4000},                   % (msecs) 4 secs
        {sip_timer_t4, 5000},                   % (msecs) 5 secs
        {sip_timer_c,  180},                    % (secs) 3min
        {sip_udp_timeout, 30},                  % (secs) 30 secs
        {sip_tcp_timeout, 180},                 % (secs) 3 min
        {sip_sctp_timeout, 180},                % (secs) 3 min
        {sip_ws_timeout, 180},                  % (secs) 3 min
        {sip_trans_timeout, 900},               % (secs) 15 min
        {sip_dialog_timeout, 1800},             % (secs) 30 min
        {sip_event_expires, 60},                % (secs) 1 min
        {sip_event_expires_offset, 5},          % (secs) 5 secs
        {sip_nonce_timeout, 30},                % (secs) 30 secs
        {sip_from, undefined},
        {sip_accept, undefined},
        {sip_events, []},
        {sip_route, []},
        {sip_local_host, auto},
        {sip_local_host6, auto},
        {sip_no_100, true},
        {sip_max_calls, 100000},                % Each Call-ID counts as a call
        {sip_max_connections, 1024},            % Per transport and SipApp
        {sip_debug, false}                      % Used in nksip_debug plugin
    ].


%% @private
parse_transports(_, List, _) when is_list(List) ->
    try
        do_parse_transports(List, [])
    catch
        throw:Throw -> {error, Throw}
    end;

parse_transports(_, _List, _) ->
    error.


%% @private
do_parse_transports([], Acc) ->
    {ok, lists:reverse(Acc)};

do_parse_transports([Transport|Rest], Acc) ->
    case Transport of
        {Scheme, Ip, Port, TOpts} when is_list(TOpts); is_map(TOpts) -> ok;
        {Scheme, Ip, Port} -> TOpts = [];
        {Scheme, Ip} -> Port = any, TOpts = [];
        Scheme -> Ip = all, Port = any, TOpts = []
    end,
    case 
        (Scheme==udp orelse Scheme==tcp orelse 
         Scheme==tls orelse Scheme==sctp orelse
         Scheme==ws  orelse Scheme==wss)
    of
        true -> ok;
        false -> throw({invalid_transport, Transport})
    end,
    Ip1 = case Ip of
        all ->
            {0,0,0,0};
        all6 ->
            {0,0,0,0,0,0,0,0};
        _ when is_tuple(Ip) ->
            case catch inet_parse:ntoa(Ip) of
                {error, _} -> throw({invalid_transport, Transport});
                {'EXIT', _} -> throw({invalid_transport, Transport});
                _ -> Ip
            end;
        _ ->
            case catch nklib_util:to_ip(Ip) of
                {ok, PIp} -> PIp;
                _ -> throw({invalid_transport, Transport})
            end
    end,
    Port1 = case Port of
        any -> 0;
        _ when is_integer(Port), Port >= 0 -> Port;
        _ -> throw({invalid_transport, Transport})
    end,
    TOpts1 = nklib_util:to_list(TOpts),
    do_parse_transports(Rest, [{Scheme, Ip1, Port1, TOpts1}|Acc]).




%% @doc Gets a new `CSeq'.
%% After booting, CSeq's counter is set using {@link nksip_util:cseq/0}. Then each call 
%% to this function increments the counter by one.
-spec get_cseq() -> 
    nksip:cseq().

get_cseq() ->
    nklib_config:increment(nksip, current_cseq, 1).



%% @doc Generates an incrementing-each-second 31 bit integer.
%% It will not wrap around until until {{2080,1,19},{3,14,7}} GMT.
-spec initial_cseq() -> 
    non_neg_integer().

initial_cseq() ->
    case binary:encode_unsigned(nklib_util:timestamp()-1325376000) of  % Base is 1/1/2012
        <<_:1, CSeq:31>> -> ok;
        <<_:9, CSeq:31>> -> ok
    end,
    CSeq.   




%% @doc Get all local network ips.
-spec get_local_ips() -> 
    [inet:ip_address()].

get_local_ips() ->
    {ok, All} = inet:getifaddrs(),
    lists:flatten([proplists:get_all_values(addr, Data) || {_, Data} <- All]).


%% @doc Equivalent to `find_main_ip(auto, ipv4)'.
-spec find_main_ip() -> 
    inet:ip_address().

find_main_ip() ->
    find_main_ip(auto, ipv4).


%% @doc Finds the <i>best</i> local IP.
%% If a network interface is supplied (as "en0") it returns its ip.
%% If `auto' is used, probes `ethX' and `enX' interfaces. If none is available returns 
%% localhost
-spec find_main_ip(auto|string(), ipv4|ipv6) -> 
    inet:ip_address().

find_main_ip(NetInterface, Type) ->
    {ok, All} = inet:getifaddrs(),
    case NetInterface of
        auto ->
            IFaces = lists:filter(
                fun(Name) ->
                    case Name of
                        "eth" ++ _ -> true;
                        "en" ++ _ -> true;
                        _ -> false
                    end
                end,
                proplists:get_keys(All)),
            find_main_ip(lists:sort(IFaces), All, Type);
        _ ->
            find_main_ip([NetInterface], All, Type)   
    end.


%% @private
find_main_ip([], _, ipv4) ->
    {127,0,0,1};

find_main_ip([], _, ipv6) ->
    {0,0,0,0,0,0,0,1};

find_main_ip([IFace|R], All, Type) ->
    Data = nklib_util:get_value(IFace, All, []),
    Flags = nklib_util:get_value(flags, Data, []),
    case lists:member(up, Flags) andalso lists:member(running, Flags) of
        true ->
            Addrs = lists:zip(
                proplists:get_all_values(addr, Data),
                proplists:get_all_values(netmask, Data)),
            case find_real_ip(Addrs, Type) of
                error -> find_main_ip(R, All, Type);
                Ip -> Ip
            end;
        false ->
            find_main_ip(R, All, Type)
    end.

%% @private
find_real_ip([], _Type) ->
    error;

% Skip link-local addresses
find_real_ip([{{65152,_,_,_,_,_,_,_}, _Netmask}|R], Type) ->
    find_real_ip(R, Type);

find_real_ip([{{A,B,C,D}, Netmask}|_], ipv4) 
             when Netmask /= {255,255,255,255} ->
    {A,B,C,D};

find_real_ip([{{A,B,C,D,E,F,G,H}, Netmask}|_], ipv6) 
             when Netmask /= {65535,65535,65535,65535,65535,65535,65535,65535} ->
    {A,B,C,D,E,F,G,H};

find_real_ip([_|R], Type) ->
    find_real_ip(R, Type).


%% @private Save cache for speed log access
put_log_cache(SrvId, CallId) ->
    erlang:put(nksip_app_id, SrvId),
    erlang:put(nksip_call_id, CallId),
    erlang:put(nksip_app_name, SrvId:name()),
    erlang:put(nksip_log_level, SrvId:config_log_level()).
