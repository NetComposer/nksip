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

%%----------------------------------------------------------------
%% @doc Service plugin callbacks default implementation
%% @end
%%----------------------------------------------------------------

-module(nksip_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("nkserver/include/nkserver.hrl").

-export([plugin_deps/0, plugin_config/3, plugin_cache/3,  plugin_start/3,
	     plugin_stop/3, plugin_update/4]).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


-spec plugin_deps() ->
    [module()].

plugin_deps() ->
    [].


%% @doc
plugin_config(SrvId, Config, #{class:=?PACKAGE_CLASS_SIP}) ->
	Syntax1 = nksip_syntax:app_syntax(),
	Syntax2 = Syntax1#{'__defaults' => #{sip_listen => <<"sip:all">>}},
    case nklib_syntax:parse_all(Config, Syntax2) of
		{ok, Config2} ->
			case get_listen(SrvId, Config2) of
				{ok, _Conns} ->
					{ok, Config2};
				{error, Error} ->
					{error, Error}
			end;
		{error, Error} ->
			{error, Error}
	end.


plugin_cache(_PkgId, Config, _Service) ->
	{ok, #{all_config=>nksip_syntax:make_config(Config)}}.


%% @doc
plugin_start(SrvId, Config, Service) ->
	{ok, Conns} = get_listen(SrvId, Config),
    {ok, Listeners} = make_listen_transps(SrvId, Conns),
	insert_listeners(SrvId, Listeners, Service).


plugin_stop(SrvId, _Config, _Service) ->
	nkserver_workers_sup:remove_all_childs(SrvId).


%% @doc
plugin_update(SrvId, NewConfig, OldConfig, Service) ->
	case NewConfig of
		OldConfig ->
			ok;
		_ ->
			plugin_start(SrvId, NewConfig, Service)
	end.



%% ===================================================================
%% Internal
%% ===================================================================




%% @private
get_listen(SrvId, #{sip_listen:=Url}=Config) ->
    SipConfig = nksip_syntax:make_config(Config),
	ResolveOpts = #{resolve_type => listen},
	case nkpacket_resolve:resolve(Url, ResolveOpts) of
		{ok, Conns} ->
            Debug = maps:get(sip_debug, Config, []),
			Tls = nkpacket_syntax:extract_tls(Config),
            Opts = Tls#{
                id => {?PACKAGE_CLASS_SIP, SrvId},
                class => {nksip, SrvId},
				debug => lists:member(nkpacket, Debug)
			},
            get_listen(Conns, Opts, SipConfig, []);
		{error, Error} ->
			{error, Error}
	end;

get_listen(_PkgId, _Config) ->
	{ok, []}.


%% @private
get_listen([], _Opts, _SipConfig, Acc) ->
    {ok, Acc};

get_listen([#nkconn{protocol=nksip_protocol, opts=COpts}=Conn|Rest], Opts, SipConfig, Acc) ->
    Opts2 = maps:merge(COpts, Opts),
    Opts3 = case Conn of
        #nkconn{transp=udp} ->
            #config{times=#call_times{t1=T1}, udp_max_size=MaxSize} = SipConfig,
            Opts2#{
                udp_starts_tcp => true,
                udp_stun_reply => true,
                udp_stun_t1 => T1,
				udp_max_size => MaxSize
            };
        #nkconn{transp=ws} ->
            Opts2#{ws_proto=>sip};
        #nkconn{transp=wss} ->
            Opts2#{ws_proto=>sip};
        _ ->
            Opts2
    end,
    get_listen(Rest, Opts, SipConfig, [Conn#nkconn{opts=Opts3}|Acc]);

get_listen(_, _Opts, _SipConfig, _Acc) ->
    {error, protocol_invalid}.


%% @private
make_listen_transps(SrvId, Conns) ->
	make_listen_transps(SrvId, Conns, []).


%% @private
make_listen_transps(_PkgId, [], Acc) ->
	{ok, Acc};

make_listen_transps(SrvId, [Conn|Rest], Acc) ->
	case nkpacket:get_listener(Conn) of
		{ok, _Id, Spec} ->
			make_listen_transps(SrvId, Rest, [Spec|Acc]);
		{error, Error} ->
			{error, Error}
	end.


%% @private
insert_listeners(SrvId, SpecList, Service) ->
	case nkserver_workers_sup:update_child_multi(SrvId, SpecList, #{}) of
		ok ->
			?SRV_LOG(info, "listeners started", [], Service),
			ok;
		not_updated ->
			?SRV_LOG(debug, "listeners didn't upgrade", [], Service),
			ok;
		upgraded ->
			?SRV_LOG(info, "listeners upgraded", [], Service),
			ok;
		{error, Error} ->
			?SRV_LOG(notice, "listeners start/update error: ~p", [Error], Service),
			{error, Error}
	end.



%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
