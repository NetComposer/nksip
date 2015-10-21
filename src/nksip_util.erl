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
-export([get_cseq/0, initial_cseq/0]).
-export([get_listenhost/3, make_route/6]).
-export([get_connected/2, get_connected/5, is_local/2, send/5]).
-export([put_log_cache/2]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nksip.hrl").




%% ===================================================================
%% Public
%% =================================================================



%% @private Adapt old style parameters to new style
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
        local_host => sip_local_host,
        local_host6 => sip_local_host6,        
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
                undefined -> SrvId:cache_sip_local_host();
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
                undefined -> SrvId:cache_sip_local_host6();
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
-spec make_route(nksip:scheme(), nkpacket:transport(), binary(), inet:port_number(),
                 binary(), nksip:optslist()) ->
    #uri{}.

make_route(Scheme, Transp, ListenHost, Port, User, Opts) ->
    UriOpts = case Transp of
        tls when Scheme==sips -> Opts;
        udp when Scheme==sip -> Opts;
        _ -> [{<<"transport">>, nklib_util:to_binary(Transp)}|Opts] 
    end,
    #uri{
        scheme = Scheme,
        user = User,
        domain = ListenHost,
        port = Port,
        opts = UriOpts
    }.


%% @private
-spec get_connected(nksip:srv_id(), nkpacket:nkport()) ->
    [pid()].

get_connected(SrvId, #nkport{transp=Transp, remote_ip=Ip, remote_port=Port, meta=Meta}) ->
    Path = maps:get(path, Meta, <<"/">>),
    get_connected(SrvId, Transp, Ip, Port, Path).


%% @private
-spec get_connected(nksip:srv_id(), nkpacket:transport(), inet:ip_address(), 
                    inet:port_number(), binary()) ->
    [pid()].

get_connected(SrvId, Transp, Ip, Port, Path) ->
    Raw = {nksip_protocol, Transp, Ip, Port},
    nkpacket_transport:get_connected(Raw, #{group=>{nksip, SrvId}, path=>Path}).


%% @doc Checks if an `nksip:uri()' or `nksip:via()' refers to a local started transport.
-spec is_local(nkservice:id(), Input::nksip:uri()|nksip:via()) -> 
    boolean().

is_local(SrvId, #uri{}=Uri) ->
    nkpacket:is_local(Uri, #{group=>{nksip, SrvId}});

is_local(SrvId, #via{}=Via) ->
    {Transp, Host, Port} = nksip_parse:transport(Via),
    Transp = {<<"transport">>, nklib_util:to_binary(Transp)},
    Uri = #uri{scheme=sip, domain=Host, port=Port, opts=[Transp]},
    is_local(SrvId, Uri).


%% @private
-spec send(nksip:srv_id(), nkpacket:send_spec()|[nkpacket:send_spec()], 
           nksip:request()|nksip:response(), nkpacket:pre_send_fun(), 
           nkpacket:send_opts()) ->
    {ok, #sipmsg{}} | {error, term()}.

send(SrvId, Spec, Msg, Fun, Opts) when is_list(Spec) ->
    Opts1 = lists:filter(fun send_opts/1, Opts),
    case nkpacket_util:parse_opts(Opts1) of
        {ok, Opts2} ->
            Opts3 = Opts2#{
                group => {nksip, SrvId}, 
                listen_port => true, 
                udp_to_tcp=>true
            },
            Opts4 = case Fun of
                none ->
                    Opts3;   
                _ ->
                    Opts3#{pre_send_fun => Fun}
            end,
            case nkpacket_transport:send(Spec, Msg, Opts4) of
                {ok, {_Pid, Msg1}} -> {ok, Msg1};
                {error, Error} -> {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.


send_opts({group, _}) -> true;
send_opts({connect_timeout, _}) -> true;
send_opts({no_dns_cache, _}) -> true;
send_opts({idle_timeout, _}) -> true;
send_opts({tls_opts, _}) -> true;
send_opts(_) -> false.



%% @private Save cache for speed log access
put_log_cache(SrvId, CallId) ->
    erlang:put(nksip_srv_id, SrvId),
    erlang:put(nksip_call_id, CallId),
    erlang:put(nksip_srv_name, SrvId:name()),
    erlang:put(nksip_log_level, SrvId:cache_log_level()).
