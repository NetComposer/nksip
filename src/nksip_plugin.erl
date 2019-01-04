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

-export([plugin_deps/0, plugin_config/4, plugin_cache/4,  plugin_start/4,
	     plugin_stop/4, plugin_update/5]).



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


-spec plugin_deps() ->
    [module()].

plugin_deps() ->
    [].


%% @doc
plugin_config(PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
	Syntax1 = nksip_syntax:app_syntax(),
	Syntax2 = Syntax1#{'__defaults' => #{sip_listen => <<"sip:all">>}},
    case nklib_syntax:parse_all(Config, Syntax2) of
		{ok, Config2} ->
			case get_listen(PkgId, Config2) of
				{ok, _Conns} ->
					{ok, Config2};
				{error, Error} ->
					{error, Error}
			end;
		{error, Error} ->
			{error, Error}
	end.


plugin_cache(_PkgId, ?PACKAGE_CLASS_SIP, Config, _Package) ->
	{ok, #{all_config=>nksip_syntax:make_config(Config)}}.


%% @doc
plugin_start(PkgId, ?PACKAGE_CLASS_SIP, Config, Package) ->
	{ok, Conns} = get_listen(PkgId, Config),
    {ok, Listeners} = make_listen_transps(PkgId, Conns),
	insert_listeners(PkgId, Listeners, Package).


plugin_stop(PkgId, ?PACKAGE_CLASS_SIP, _Config, _Package) ->
	nkserver_workers_sup:remove_all_childs(PkgId).


%% @doc
plugin_update(PkgId, ?PACKAGE_CLASS_SIP, NewConfig, OldConfig, Package) ->
	case NewConfig of
		OldConfig ->
			ok;
		_ ->
			plugin_start(PkgId, ?PACKAGE_CLASS_SIP, NewConfig, Package)
	end.



%% ===================================================================
%% Internal
%% ===================================================================




%% @private
get_listen(PkgId, #{sip_listen:=Url}=Config) ->
    SipConfig = nksip_syntax:make_config(Config),
	ResolveOpts = #{resolve_type => listen},
	case nkpacket_resolve:resolve(Url, ResolveOpts) of
		{ok, Conns} ->
            Debug = maps:get(sip_debug, Config, []),
			Tls = nkpacket_syntax:extract_tls(Config),
            Opts = Tls#{
                id => {?PACKAGE_CLASS_SIP, PkgId},
                class => {nksip, PkgId},
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
make_listen_transps(PkgId, Conns) ->
	make_listen_transps(PkgId, Conns, []).


%% @private
make_listen_transps(_PkgId, [], Acc) ->
	{ok, Acc};

make_listen_transps(PkgId, [Conn|Rest], Acc) ->
	case nkpacket:get_listener(Conn) of
		{ok, _Id, Spec} ->
			make_listen_transps(PkgId, Rest, [Spec|Acc]);
		{error, Error} ->
			{error, Error}
	end.


%% @private
insert_listeners(PkgId, SpecList, Package) ->
	case nkserver_workers_sup:update_child_multi(PkgId, SpecList, #{}) of
		ok ->
			?PKG_LOG(info, "listeners started", [], Package),
			ok;
		not_updated ->
			?PKG_LOG(debug, "listeners didn't upgrade", [], Package),
			ok;
		upgraded ->
			?PKG_LOG(info, "listeners upgraded", [], Package),
			ok;
		{error, Error} ->
			?PKG_LOG(notice, "listeners start/update error: ~p", [Error], Package),
			{error, Error}
	end.



%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
