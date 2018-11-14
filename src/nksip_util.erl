%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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

-export([get_cseq/0, initial_cseq/0]).
-export([get_listenhost/4, make_route/6]).
-export([get_connected/2, get_connected/5, is_local/2, send/6]).
-export([print_all/0]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").




%% ===================================================================
%% Public
%% =================================================================


%%%% @private
%%adapt_transports(SrvId, Transports, Service) ->
%%    adapt_transports(SrvId, Transports, Service, []).
%%
%%
%%%% @private
%%adapt_transports(_SrvId, [], _Config, Acc) ->
%%    lists:reverse(Acc);
%%
%%adapt_transports(SrvId, [{RawConns, Opts}|Rest], Config, Acc) ->
%%    SipOpts = case RawConns of
%%        [{nksip_protocol, Transp, _Ip, _Port}|_] ->
%%            Base = #{class => {nksip, SrvId}},
%%            case Transp of
%%                udp ->
%%                    #config{times=#call_times{t1=T1}} = Config,
%%                    Base#{
%%                        udp_starts_tcp => true,
%%                        udp_stun_reply => true,
%%                        udp_stun_t1 => T1
%%                    };
%%                ws ->
%%                    Base#{ws_proto => sip};
%%                wss ->
%%                    Base#{ws_proto => sip};
%%                _ ->
%%                    Base
%%            end;
%%        _ ->
%%            Opts
%%    end,
%%    Opts1 = maps:merge(Opts, SipOpts),
%%    adapt_transports(SrvId, Rest, Config, [{RawConns, Opts1}|Acc]).



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
        <<_:1, CSeq0:31>> -> CSeq0;
        <<_:9, CSeq0:31>> -> CSeq0
    end.


%% @private 
-spec get_listenhost(nkservice:id(), nkservice:package_id(), inet:ip_address(), nksip:optslist()) ->
    binary().

get_listenhost(SrvId, PkgId, Ip, Opts) ->
    case size(Ip) of
        4 ->
            Host = case nklib_util:get_value(local_host, Opts) of
                undefined ->
                    Config = nksip_plugin:get_config(SrvId, PkgId),
                    Config#config.local_host;
                Host0 ->
                    Host0
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
                undefined ->
                    Config = nksip_plugin:get_config(SrvId, PkgId),
                    Config#config.local_host6;
                Host0 ->
                    Host0
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
-spec get_connected(nkservice:id(), nkpacket:nkport()) ->
    [pid()].

get_connected(SrvId, #nkport{transp=Transp, remote_ip=Ip, remote_port=Port, opts=Opts}) ->
    Path = maps:get(path, Opts, <<"/">>),
    get_connected(SrvId, Transp, Ip, Port, Path).


%% @private
-spec get_connected(nkservice:id(), nkpacket:transport(), inet:ip_address(),
                    inet:port_number(), binary()) ->
    [pid()].

get_connected(SrvId, Transp, Ip, Port, Path) ->
    Opts = #{class=>{nksip, SrvId}, path=>Path},
    Conn = #nkconn{protocol=nksip_protocol, transp=Transp, ip=Ip, port=Port, opts=Opts},
    nkpacket_transport:get_connected(Conn).


%% @doc Checks if an `nksip:uri()' or `nksip:via()' refers to a local started transport.
-spec is_local(nkservice:id(), Input::nksip:uri()|nksip:via()) ->
    boolean().

is_local(SrvId, #uri{}=Uri) ->
    nkpacket:is_local(Uri, #{class=>{nksip, SrvId}});

is_local(SrvId, #via{}=Via) ->
    {Transp, Host, Port} = nksip_parse:transport(Via),
    Transp = {<<"transport">>, nklib_util:to_binary(Transp)},
    Uri = #uri{scheme=sip, domain=Host, port=Port, opts=[Transp]},
    is_local(SrvId, Uri).


%% @private
-spec send(nkservice:id(), nkservice:package_id(), [nkpacket:send_spec()],
           nksip:request()|nksip:response(), nkpacket:pre_send_fun(),
           [nksip_uac:req_option()]) ->
    {ok, #sipmsg{}} | {error, term()}.

send(SrvId, PkgId, Spec, Msg, Fun, Opts) when is_list(Spec) ->
    Opts2 = lists:filter(fun send_opts/1, Opts),
    Opts3 = maps:from_list(Opts2),
    Config = nksip_plugin:get_config(SrvId, PkgId),
    Opts4 = Opts3#{
        class => {nksip, SrvId, PkgId},
        base_nkport => true,                % Find a listening transport
        udp_to_tcp => true,
        udp_max_size => Config#config.udp_max_size,
        ws_proto => sip,
        debug => erlang:get(nksip_debug)
    },
    Opts5 = case Fun of
        none ->
            Opts4;
        _ ->
            Opts4#{pre_send_fun => Fun}
    end,
    case nkpacket:send(Spec, Msg, Opts5) of
        {ok, _Pid, Msg1} ->
            {ok, Msg1};
        {error, Error} ->
            {error, Error}
    end.


%% @private
send_opts({connect_timeout, _}) -> true;
send_opts({no_dns_cache, _}) -> true;
send_opts({idle_timeout, _}) -> true;
send_opts({tls_opts, _}) -> true;
send_opts(_) -> false.



%%%% @private Save cache for speed log access
%%put_log_cache(SrvId, CallId) ->
%%    erlang:put(nksip_srv, SrvId),
%%    erlang:put(nksip_call_id, CallId),
%%    erlang:put(nksip_log_level, SrvId:log_level()).


%% @private
print_all() ->
    lists:foreach(
        fun(Pid) ->
            {ok, #nkport{class={nksip, SrvId}}=NkPort} = nkpacket:get_nkport(Pid),
            {ok, Conn} = nkpacket:get_local(NkPort),
            io:format("Srv ~p: ~p\n", [SrvId:name(), Conn])
        end,
        nkpacket:get_all()).




