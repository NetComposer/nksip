%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([adapt_opts/1, adapt_transports/3]).
-export([plugin_update_value/3, cached/0, syntax/0, defaults/0]).
-export([get_cseq/0, initial_cseq/0]).
-export([get_listenhost/3, make_route/6]).
-export([put_log_cache/2]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").




%% ===================================================================
%% Public
%% =================================================================




syntax() ->
    #{
        sip_allow => words,
        sip_supported => words,
        sip_timer_t1 => {integer, 10, 2500},
        sip_timer_t2 => {integer, 100, 16000},
        sip_timer_t4 => {integer, 100, 25000},
        sip_timer_c => {integer, 1, none},
        sip_trans_timeout => {integer, 5, none},
        sip_dialog_timeout => {integer, 5, none},
        sip_event_expires => {integer, 1, none},
        sip_event_expires_offset => {integer, 0, none},
        sip_nonce_timeout => {integer, 5, none},
        sip_from => [{enum, [undefined]}, uri],
        sip_accept => [{enum, [undefined]}, words],
        sip_events => words,
        sip_route => uris,
        sip_no_100 => boolean,
        sip_max_calls => {integer, 1, 1000000},
        sip_debug => boolean
    }.


defaults() ->
    #{
        sip_allow => [
            <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
            <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
            <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>],
        sip_supported => [<<"path">>],
        sip_timer_t1 => 500,                    % (msecs) 0.5 secs
        sip_timer_t2 => 4000,                   % (msecs) 4 secs
        sip_timer_t4 => 5000,                   % (msecs) 5 secs
        sip_timer_c =>  180,                    % (secs) 3min
        sip_trans_timeout => 900,               % (secs) 15 min
        sip_dialog_timeout => 1800,             % (secs) 30 min
        sip_event_expires => 60,                % (secs) 1 min
        sip_event_expires_offset => 5,          % (secs) 5 secs
        sip_nonce_timeout => 30,                % (secs) 30 secs
        sip_from => undefined,
        sip_accept => undefined,
        sip_events => [],
        sip_route => [],
        sip_no_100 => false,
        sip_max_calls => 100000,                % Each Call-ID counts as a call
        sip_debug => false                      % Used in nksip_debug plugin
    }.


%% @private
plugin_update_value(Key, Fun, SrvSpec) ->
    Value1 = maps:get(Key, SrvSpec, undefined),
    Value2 = Fun(Value1),
    SrvSpec2 = maps:put(Key, Value2, SrvSpec),
    OldCache = maps:get(cache, SrvSpec, #{}),
    Cache = case lists:member(Key, cached()) of
        true -> maps:put(Key, Value2, #{});
        false -> #{}
    end,
    SrvSpec2#{cache=>maps:merge(OldCache, Cache)}.


cached() ->
    [
        sip_accept, sip_allow, sip_debug, sip_dialog_timeout, 
        sip_event_expires, sip_event_expires_offset, sip_events, 
        sip_from, sip_max_calls, sip_no_100, sip_nonce_timeout, 
        sip_route, sip_supported, sip_trans_timeout
    ].


adapt() ->
    #{
        allow => sip_allow,
        supported => sip_supported,
        timer_t1 => sip_timer_t1,
        timer_t2 => sip_timer_t2,
        timer_t4 => sip_timer_t4,
        timer_c => sip_timer_c,
        trans_timeout => sip_trans_timeout,
        dialog_timeout => sip_dialog_timeout,
        event_expires => sip_event_expires,
        event_expires_offset => sip_event_expires_offset,
        nonce_timeout => sip_nonce_timeout,
        from => sip_from,
        accept => sip_accept,
        events => sip_events,
        route => sip_route,
        no_100 => sip_no_100,
        max_calls => sip_max_calls,
        debug => sip_debug
    }.


%% @private
adapt_opts(Opts) ->
    adapt_opts(nklib_util:to_list(Opts), []).

adapt_opts([], Acc) ->
    maps:from_list(Acc);

adapt_opts([{Key, Val}|Rest], Acc) ->
    Key1 = case maps:find(Key, adapt()) of
        {ok, NewKey} -> NewKey;
        error -> Key
    end,
    adapt_opts(Rest, [{Key1, Val}|Acc]);

adapt_opts([Key|Rest], Acc) ->
    adapt_opts([{Key, true}|Rest], Acc).



%% @private
adapt_transports(SrvId, Transports, Config) ->
    adapt_transports(SrvId, Transports, Config, []).


%% @private
adapt_transports(_SrvId, [], _Config, Acc) ->
    lists:reverse(Acc);

adapt_transports(SrvId, [{RawConns, Opts}|Rest], Config, Acc) ->
    SipOpts = case RawConns of
        [{nksip_protocol, Transp, _Ip, _Port}|_] ->
            Base = #{group => {nksip, SrvId}},
            case Transp of
                udp ->
                    Base#{
                        udp_starts_tcp => true,
                        udp_stun_reply => true,
                        udp_stun_t1 => maps:get(sip_timer_t1, Config)
                    };
                ws ->
                    Base#{ws_proto => sip};
                wss -> 
                    Base#{ws_proto => sip};
                _ ->
                    Base
            end;
        _ ->
            Opts
    end,
    Opts1 = maps:merge(Opts, SipOpts),
    adapt_transports(SrvId, Rest, Config, [{RawConns, Opts1}|Acc]).


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


%% @private 
-spec get_listenhost(nkservice:id(), inet:ip_address(), nksip:optslist()) ->
    binary().

get_listenhost(SrvId, Ip, Opts) ->
    case size(Ip) of
        4 ->
            Host = case nklib_util:get_value(local_host, Opts) of
                undefined -> SrvId:cache_packet_local_host();
                Host0 -> Host0
            end,
            case Host of
                auto when Ip == {0,0,0,0} -> 
                    nklib_util:to_host(nkpacket_config_cache:main_ip()); 
                auto ->
                    nklib_util:to_host(Ip);
                _ -> 
                    Host
            end;
        8 ->
            Host = case nklib_util:get_value(local_host6, Opts) of
                undefined -> SrvId:cache_packet_local_host6();
                Host0 -> Host0
            end,
            case Host of
                auto when Ip == {0,0,0,0,0,0,0,0} -> 
                    nklib_util:to_host(nkpacket_config_cache:main_ip6(), true);
                auto -> 
                    nklib_util:to_host(Ip, true);
                _ -> 
                    Host
            end
    end.

    
%% @private Makes a route record
-spec make_route(nksip:scheme(), nksip:protocol(), binary(), inet:port_number(),
                 binary(), nksip:optslist()) ->
    #uri{}.

make_route(Scheme, Proto, ListenHost, Port, User, Opts) ->
    UriOpts = case Proto of
        tls when Scheme==sips -> Opts;
        udp when Scheme==sip -> Opts;
        _ -> [{<<"transport">>, nklib_util:to_binary(Proto)}|Opts] 
    end,
    #uri{
        scheme = Scheme,
        user = User,
        domain = ListenHost,
        port = Port,
        opts = UriOpts
    }.


%% @private Save cache for speed log access
put_log_cache(SrvId, CallId) ->
    erlang:put(nksip_srv_id, SrvId),
    erlang:put(nksip_call_id, CallId),
    erlang:put(nksip_srv_name, SrvId:name()),
    erlang:put(nksip_log_level, SrvId:cache_log_level()).
