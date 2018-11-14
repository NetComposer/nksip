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

-export([plugin_deps/0, plugin_config/3, plugin_start/4, plugin_update/5]).
-export([get_config/2, get_debug/3]).


-define(LLOG(Type, Txt, Args), lager:Type("NkSIP Plugin: "++Txt, Args)).


%% ===================================================================
%% Plugin callbacks
%% ===================================================================


-spec plugin_deps() ->
    [module()].

plugin_deps() ->
    [].


%% @doc
plugin_config(?PACKAGE_CLASS_SIP, #{id:=PkgId, config:=Config}=Spec, #{id:=SrvId}) ->
	Syntax = (nksip_syntax:app_syntax())#{listenUrl=>binary},
    case nklib_syntax:parse(Config, Syntax) of
		{ok, Config2, _} ->
			case get_listen(SrvId, PkgId, Config2) of
				{ok, _Conns} ->
                    Spec2 = Spec#{config:=Config2},
					Spec3 = add_cache(Spec2),
					Spec4 = add_debug(Spec3),
					{ok, Spec4};
				{error, Error} ->
					{error, Error}
			end;
		{error, Error} ->
			{error, Error}
	end;

plugin_config(_Class, _Package, _Service) ->
	continue.


%% @doc
plugin_start(?PACKAGE_CLASS_SIP, #{id:=PkgId, config:=Config}, Pid, #{id:=SrvId}) ->
	{ok, Conns} = get_listen(SrvId, PkgId, Config),
    {ok, Listeners} = make_listen_transps(SrvId, PkgId, Conns),
	insert_listeners(Pid, Listeners);

plugin_start(_Id, _Spec, _Pid, _Service) ->
	continue.


%% @doc
%% Even if we are called only with modified config, we check if the spec is new
plugin_update(?PACKAGE_CLASS_SIP, #{id:=PkgId}=NewConfig, OldSpec, Pid, #{id:=SrvId}) ->
	case OldSpec of
		#{config:=NewConfig} ->
			ok;
		_ ->
			{ok, Conns} = get_listen(SrvId, PkgId, NewConfig),
			{ok, Listeners} = make_listen_transps(SrvId, PkgId, Conns),
			insert_listeners(Pid, Listeners)
	end;

plugin_update(_Class, _NewSpec, _OldSpec, _Pid, _Service) ->
	ok.



%% ===================================================================
%% Core config
%% ===================================================================




%% ===================================================================
%% Getters
%% ===================================================================

%% @doc Gets cached config
-spec get_cache(nkservice:id(), nkservice:packge_id(), term()) ->
	term().

get_cache(SrvId, PkgId, CacheKey) ->
	nkservice_util:get_cache(SrvId, nksip, PkgId, CacheKey).


%% @doc Gets cached config
-spec get_config(nkservice:id(), nkservice:packge_id()) ->
    term().

get_config(SrvId, PkgId) ->
    get_cache(SrvId, PkgId, config).


%% @doc Gets cached config
-spec get_debug(nkservice:id(), nkservice:packge_id(), call) ->
	[atom()].


get_debug(SrvId, PkgId, Item) ->
	nkservice_util:get_debug(SrvId, nksip, PkgId, Item).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
add_cache(#{id:=PkgId, config:=Config}=Spec) ->
	SipConfig = nksip_syntax:make_config(Config),
    CacheItems1 = #{
        config => SipConfig
    },
    nkservice_config_util:set_cache_items(nksip, PkgId, CacheItems1, Spec).


%% @private
add_debug(#{id:=PkgId, config:=Config}=Spec) ->
	Debug = maps:get(sip_debug, Config, []),
	Items = lists:foldl(
        fun(Key, Acc) -> Acc#{Key => lists:member(Key, Debug)} end,
        #{},
        [call, packet]),
	nkservice_config_util:set_debug_items(nksip, PkgId, Items, Spec).


%% @private
get_listen(SrvId, PkgId, #{listenUrl:=Url}=Config) ->
    SipConfig = nksip_syntax:make_config(Config),
	ResolveOpts = #{resolve_type => listen},
	case nkpacket_resolve:resolve(Url, ResolveOpts) of
		{ok, Conns} ->
            Debug = maps:get(sip_debug, Config, []),
			Opts = #{
                id => {?PACKAGE_CLASS_SIP, SrvId, PkgId},
                class => {nksip, SrvId, PkgId},
				debug => lists:member(nkpacket, Debug)
			},
			get_listen(Conns, Opts, SipConfig, []);
		{error, Error} ->
			{error, Error}
	end;

get_listen(_SrvId, _PkgId, _Config) ->
	{ok, []}.


%% @private
get_listen([], _Opts, _SipConfig, Acc) ->
    {ok, Acc};

get_listen([#nkconn{protocol=nksip_protocol, opts=COpts}=Conn|Rest], Opts, SipConfig, Acc) ->
    Opts2 = maps:merge(COpts, Opts),
    Opts3 = case Conn of
        #nkconn{transp=udp} ->
            #config{times=#call_times{t1=T1}} = SipConfig,
            Opts2#{
                udp_starts_tcp => true,
                udp_stun_reply => true,
                udp_stun_t1 => T1
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
make_listen_transps(SrvId, PkgId, Conns) ->
	make_listen_transps(SrvId, PkgId, Conns, []).


%% @private
make_listen_transps(_SrvId, _PkgId, [], Acc) ->
	{ok, Acc};

make_listen_transps(SrvId, PkgId, [Conn|Rest], Acc) ->
	case nkpacket:get_listener(Conn) of
		{ok, _Id, Spec} ->
			make_listen_transps(SrvId, PkgId, Rest, [Spec|Acc]);
		{error, Error} ->
			{error, Error}
	end.


%% @private
insert_listeners(Pid, SpecList) ->
	case nkservice_packages_sup:update_child_multi(Pid, SpecList, #{}) of
		ok ->
			?LLOG(debug, "started", []),
			ok;
		not_updated ->
			?LLOG(debug, "didn't upgrade", []),
			ok;
		upgraded ->
			?LLOG(info, "upgraded ~s", []),
			ok;
		{error, Error} ->
			?LLOG(notice, "start/update error: ~p", [Error]),
			{error, Error}
	end.



%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
