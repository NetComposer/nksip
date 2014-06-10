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

%% @doc SipApps configuration

-module(nksip_sipapp_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_config/1]).

-include("nksip.hrl").

-define(DEFAULT_LOG_LEVEL, 8).  % 8:debug, 7:info, 6:notice, 5:warning, 4:error
-define(DEFAULT_TRACE, false).


%% ===================================================================
%% Private
%% ===================================================================


%% @private Default config values
-spec default_config() ->
    nksip:optslist().

default_config() ->
    [
        {timer_t1, 500},                    % (msecs) 0.5 secs
        {timer_t2, 4000},                   % (msecs) 4 secs
        {timer_t4, 5000},                   % (msecs) 5 secs
        {timer_c,  180},                    % (secs) 3min
        {session_expires, 1800},            % (secs) 30 min
        {min_session_expires, 90},          % (secs) 90 secs (min 90, recomended 1800)
        {udp_timeout, 180},                 % (secs) 3 min
        {tcp_timeout, 180},                 % (secs) 3 min
        {sctp_timeout, 180},                % (secs) 3 min
        {ws_timeout, 180},                  % (secs) 3 min
        {nonce_timeout, 30},                % (secs) 30 secs
        {sipapp_timeout, 32},               % (secs) 32 secs  
        {max_calls, 100000},                % Each Call-ID counts as a call
        {max_connections, 1024}             % Per transport and SipApp
    ].


%% @private
parse_config(Opts) ->
    try
        Plugins0 = proplists:get_all_values(plugins, Opts),
        Plugins = parse_plugins(lists:flatten(Plugins0), []),
        Opts1 = apply_defaults(Opts, Plugins),
        Opts2 = parse_opts(Opts1, lists:reverse(Plugins), Opts1, []),
        Opts3 = [{plugins, Plugins}|Opts2],
        Cache = cache_syntax(Opts3),
        PluginCallbacks = plugin_callbacks_syntax([nksip|Plugins]),
        AppName = nksip_lib:get_value(name, Opts3, nksip),
        AppId = nksip_sipapp_srv:get_appid(AppName),
        PluginModules = [
            list_to_atom(atom_to_list(Plugin) ++ "_sipapp")
            || Plugin <- Plugins
        ],
        Module = nksip_lib:get_value(module, Opts3, nksip_sipapp),
        AppModules = [Module|PluginModules++[nksip_sipapp]],
        AppCallbacks = get_all_app_callbacks(AppModules),
        SipApp = [
            nksip_code_util:callback_expr(Mod, Fun, Arity)
            || {{Fun, Arity}, Mod} <- AppCallbacks
        ],
        Syntax = Cache ++ SipApp ++ PluginCallbacks,
        ok = nksip_code_util:compile(AppId, Syntax),
        {ok, AppId} 
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private Computes all default config
apply_defaults(Opts, Plugins) ->
    Base = nksip_lib:defaults(nksip_config_run:app_config(), default_config()),
    Opts1 = nksip_lib:defaults(Opts, Base),
    apply_defaults_plugins(Opts1, Plugins).


%% @private
apply_defaults_plugins(Opts, []) ->
    Opts;

apply_defaults_plugins(Opts, [Plugin|Rest]) ->
    Opts1 = case catch Plugin:default_config() of
        List when is_list(List) -> nksip_lib:defaults(Opts, List);
        _ -> Opts
    end,
    apply_defaults_plugins(Opts1, Rest).
        

%% @private Parse the list of app start options
parse_opts([], _Plugins, _AllOpts, Opts) ->
    Opts;

parse_opts([{plugins, _}|Rest], Plugins, AllOpts, Opts) ->
    parse_opts(Rest, Plugins, AllOpts, Opts);

parse_opts([Atom|Rest], Plugins, AllOpts, Opts) when is_atom(Atom) ->
    parse_opts([{Atom, true}|Rest], Plugins, AllOpts, Opts);

parse_opts([Term|Rest], Plugins, AllOpts, Opts) ->
    Op = case Term of

        % Internal options
        {name, _Name} ->
            update;
        {module, Module} when is_atom(Module) ->
            update;

        % System options
        {timer_t1, MSecs} when is_integer(MSecs), MSecs>=10, MSecs=<2500 ->
            update;
        {timer_t2, MSecs} when is_integer(MSecs), MSecs>=100, MSecs=<16000 ->
            update;
        {timer_t4, MSecs} when is_integer(MSecs), MSecs>=100, MSecs=<25000 ->
            update;
        {timer_c, Secs}  when is_integer(Secs), Secs>=1 ->
            update;
        {session_expires, Secs} when is_integer(Secs), Secs>=5 ->
            update;
        {min_session_expires, Secs} when is_integer(Secs), Secs>=1 ->
            update;
        {udp_timeout, Secs} when is_integer(Secs), Secs>=5 ->
            update;
        {tcp_timeout, Secs} when is_integer(Secs), Secs>=5 ->
            update;
        {sctp_timeout, Secs} when is_integer(Secs), Secs>=5 ->
            update;
        {ws_timeout, Secs} when is_integer(Secs), Secs>=5 -> 
            update;
        {nonce_timeout, Secs} when is_integer(Secs), Secs>=5 ->
            update;
        {sipapp_timeout, MSecs} when is_float(MSecs), MSecs>=0.01 ->
            update;
        {sipapp_timeout, Secs} when is_integer(Secs), Secs>=5, Secs=<180 ->
            update;
        {max_calls, Max} when is_integer(Max), Max>=1, Max=<1000000 ->
            update;
        {max_connections, Max} when is_integer(Max), Max>=1, Max=<1000000 ->
            update;

        % Startup options
        {transports, Transports} ->
            {update, parse_transports(Transports, [])};
        {certfile, File} ->
            {update, nksip_lib:to_list(File)};
        {keyfile, File} ->
            {update, nksip_lib:to_list(File)};
        {supported, Supported} ->
            case nksip_parse:tokens(Supported) of
                error -> error;
                Tokens -> {update, [T||{T, _}<-Tokens]}
            end;
        {allow, Allow} ->
            case nksip_parse:tokens(Allow) of
                error -> error;
                Tokens -> {update, [A||{A, _}<-Tokens]}
            end;
        {accept, Accept} ->
            case nksip_parse:tokens(Accept) of
                error -> error;
                Tokens -> {update, [A||{A, _}<-Tokens]}
            end;
        {events, Event} ->
            case nksip_parse:tokens(Event) of
                error -> error;
                Tokens -> {update, [T||{T, _}<-Tokens]}
            end;
        
        % Default headers and options
        {from, From} ->
            case nksip_parse:uris(From) of
                [Uri] -> {update, Uri};
                _ -> error 
            end;
        {route, Route} ->
            case nksip_parse:uris(Route) of
                error -> error;
                Uris -> {update, Uris}
            end;
        {pass, Pass} ->
            Pass1 = case Pass of
                _ when is_list(Pass) -> 
                    list_to_binary(Pass);
                _ when is_binary(Pass) -> 
                    Pass;
                {Pass0, Realm0} when 
                    (is_list(Pass0) orelse is_binary(Pass0)) andalso
                    (is_list(Realm0) orelse is_binary(Realm0)) ->
                    {nksip_lib:to_binary(Pass0), nksip_lib:to_binary(Realm0)};
                _ ->
                    throw({invalid_pass})
            end,
            OldPass = nksip_lib:get_value(passes, Opts, []),
            {update, passes, OldPass++[Pass1]};
        {local_host, Host} ->
            {update, nksip_lib:to_host(Host)};
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {update, nksip_lib:to_host(HostIp6, true)};
                error -> 
                    {update, nksip_lib:to_binary(Host)}
            end;
        {no_100, true} ->
            {update, true};

        {log_level, debug} -> {update, 8};
        {log_level, info} -> {update, 7};
        {log_level, notice} -> {update, 6};
        {log_level, warning} -> {update, 5};
        {log_level, error} -> {update, 4};
        {log_level, critical} -> {update, 3};
        {log_level, alert} -> {update, 2};
        {log_level, emergency} -> {update, 1};
        {log_level, none} -> {update, 0};
        {log_level, Level} when Level>=0, Level=<8 -> {update, Level};

        {trace, Trace} when is_boolean(Trace) ->
            {update, Trace};
        {store_trace, Trace} when is_boolean(Trace) ->
            {update, Trace};

        Other ->
            case parse_external_opt(Term, Plugins, AllOpts) of
                error ->
                    lager:notice("Ignoring unknown option ~p starting SipApp", 
                                 [Other]),
                    update;
                ExtUpdate ->
                    ExtUpdate
            end
    end,
    {Key, Val} = case Op of
        update -> {element(1, Term), element(2, Term)};
        {update, Val1} -> {element(1, Term), Val1};
        {update, Key1, Val1} -> {Key1, Val1};
        error -> throw({invalid, element(1, Term)})
    end,
    Opts1 = lists:keystore(Key, 1, Opts, {Key, Val}),
    parse_opts(Rest, Plugins, AllOpts, Opts1).


%% @doc
-spec parse_external_opt([{term(), term()}], [atom()], nksip:optslist()) ->
    update | {update, term()} | {update, atom(), term()} | error.

parse_external_opt(_Term, [], _Opts) ->
    error;

parse_external_opt(Term, [Plugin|Rest], Opts) ->
    case catch Plugin:parse_config(Term, Opts) of
        update -> update;
        {update, Value} -> {update, Value};
        {update, Key, Value} -> {update, Key, Value};
        _ -> parse_external_opt(Term, Rest, Opts)
    end.


%% @private
parse_transports([], Acc) ->
    lists:reverse(Acc);

parse_transports([Transport|Rest], Acc) ->
    case Transport of
        {Scheme, Ip, Port} -> TOpts = [];
        {Scheme, Ip, Port, TOpts} when is_list(TOpts) -> ok;
        _ -> Scheme=Ip=Port=TOpts=throw({invalid, transport})
    end,
    case 
        (Scheme==udp orelse Scheme==tcp orelse 
         Scheme==tls orelse Scheme==sctp orelse
         Scheme==ws  orelse Scheme==wss)
    of
        true -> ok;
        false -> throw({invalid, transport})
    end,
    Ip1 = case Ip of
        all ->
            {0,0,0,0};
        all6 ->
            {0,0,0,0,0,0,0,0};
        _ when is_tuple(Ip) ->
            case catch inet_parse:ntoa(Ip) of
                {error, _} -> throw({invalid, transport});
                {'EXIT', _} -> throw({invalid, transport});
                _ -> Ip
            end;
        _ ->
            case catch nksip_lib:to_ip(Ip) of
                {ok, PIp} -> PIp;
                _ -> throw({invalid, transport})
            end
    end,
    Port1 = case Port of
        any -> 0;
        _ when is_integer(Port), Port >= 0 -> Port;
        _ -> throw({invalid, transport})
    end,
    parse_transports(Rest, [{Scheme, Ip1, Port1, TOpts}|Acc]).


%% @private Parte the plugins list for the application
%% For each plugin, calls Plugin:version() to get the version, and
%% Plugin:deps() to get the dependency list ([Name::atom(), RE::binary()]).
%% it then builds a list of sorted list of plugin names, where every plugin 
%% is inserted after all of its dependencies.
parse_plugins([Name|Rest], PlugList) when is_atom(Name) ->
    case lists:keymember(Name, 1, PlugList) of
        true ->
            parse_plugins(Rest, PlugList);
        false ->
            case catch Name:version() of
                Ver when is_list(Ver); is_binary(Ver) ->
                    case catch Name:deps() of
                        Deps when is_list(Deps) ->
                            case parse_plugins_insert(PlugList, Name, Ver, Deps, []) of
                                {ok, PlugList1} -> 
                                    parse_plugins(Rest, PlugList1);
                                {insert, BasePlugin} -> 
                                    parse_plugins([BasePlugin, Name|Rest], PlugList)
                            end;
                        _ ->
                            throw({invalid_plugin, Name})
                    end;
                _ ->
                    throw({invalid_plugin, Name})
            end
    end;

parse_plugins([], PlugList) ->
    [Name || {Name, _} <- PlugList].


%% @private
parse_plugins_insert([{CurName, CurVer}=Curr|Rest], Name, Ver, Deps, Acc) ->
    case lists:keytake(CurName, 1, Deps) of
        false ->
            parse_plugins_insert(Rest, Name, Ver,  Deps, Acc++[Curr]);
        {value, {_, DepVer}, RestDeps} when is_list(DepVer); is_binary(DepVer) ->
            case re:run(CurVer, DepVer) of
                {match, _} ->
                    parse_plugins_insert(Rest, Name, Ver, RestDeps, Acc++[Curr]);
                nomatch ->
                    throw({incompatible_plugin, {CurName, CurVer, DepVer}})
            end;
        _ ->
            throw({invalid_plugin, Name})
    end;

parse_plugins_insert([], Name, Ver, [], Acc) ->
    {ok, Acc++[{Name, Ver}]};

parse_plugins_insert([], _Name, _Ver, [{DepName, _}|_], _Acc) ->
    {insert, DepName}.


%% @private Generates a ready-to-compile config getter functions
cache_syntax(Opts) ->
    Cache = [
        {name, nksip_lib:get_value(name, Opts)},
        {module, nksip_lib:get_value(module, Opts)},
        {config, Opts},
        {config_plugins, nksip_lib:get_value(plugins, Opts, [])},
        {config_log_level, nksip_lib:get_value(log_level, Opts, ?DEFAULT_LOG_LEVEL)},
        {config_trace, 
            {nksip_lib:get_value(trace, Opts, ?DEFAULT_TRACE), 
             nksip_lib:get_value(store_trace, Opts, false)}},
        {config_max_connections, nksip_lib:get_value(max_connections, Opts)},
        {config_max_calls, nksip_lib:get_value(max_calls, Opts)},
        {config_timers, {
            nksip_lib:get_value(timer_t1, Opts),
            nksip_lib:get_value(timer_t2, Opts),
            nksip_lib:get_value(timer_t4, Opts),
            1000*nksip_lib:get_value(timer_c, Opts)}},
        {config_sync_call_time, 1000*nksip_lib:get_value(sync_call_time, Opts)},
        {config_from, nksip_lib:get_value(from, Opts)},
        {config_no_100, lists:member({no_100, true}, Opts)},
        {config_supported, 
            nksip_lib:get_value(supported, Opts, ?SUPPORTED)},
        {config_allow, 
            nksip_lib:get_value(allow, Opts, ?ALLOW)},
        {config_accept, nksip_lib:get_value(accept, Opts)},
        {config_events, nksip_lib:get_value(events, Opts, [])},
        {config_route, nksip_lib:get_value(route, Opts, [])},
        {config_local_host, nksip_lib:get_value(local_host, Opts, auto)},
        {config_local_host6, nksip_lib:get_value(local_host6, Opts, auto)},
        {config_min_session_expires, nksip_lib:get_value(min_session_expires, Opts)},
        {config_uac, lists:flatten([
            tuple(local_host, Opts),
            tuple(local_host6, Opts),
            tuple(no_100, Opts),
            tuple(pass, Opts),
            tuple(from, Opts),
            tuple(route, Opts)
        ])},
        {config_uac_proxy, lists:flatten([
            tuple(local_host, Opts),
            tuple(local_host6, Opts),
            tuple(no_100, Opts),
            tuple(pass, Opts)
        ])},
        {config_uas, lists:flatten([
            tuple(local_host, Opts),
            tuple(local_host6, Opts)
        ])}
    ],
    lists:foldl(
        fun({Key, Value}, Acc) -> [nksip_code_util:getter(Key, Value)|Acc] end,
        [],
        Cache).


%% @private
tuple(Name, Opts) ->
    tuple(Name, Opts, []).


%% @private
tuple(Name, Opts, Default) ->
    case nksip_lib:get_value(Name, Opts) of
        undefined -> Default;
        Value -> {Name, Value}
    end.


%% @private Generates the ready-to-compile syntax of the generated callback module
%% taking all plugins' callback functions
plugin_callbacks_syntax(Plugins) ->
    plugin_callbacks_syntax(Plugins, dict:new()).


%% @private
plugin_callbacks_syntax([Name|Rest], Dict) ->
    Mod = list_to_atom(atom_to_list(Name)++"_callbacks"),
    case nksip_code_util:get_funs(Mod) of
        error ->
            plugin_callbacks_syntax(Rest, Dict);
        List ->
            Dict1 = plugin_callbacks_syntax(List, Mod, Dict),
            plugin_callbacks_syntax(Rest, Dict1)
    end;

plugin_callbacks_syntax([], Dict) ->
    dict:fold(
        fun({Fun, Arity}, {Value, Pos}, Syntax) ->
            [nksip_code_util:fun_expr(Fun, Arity, Pos, [Value])|Syntax]
        end,
        [],
        Dict).


%% @private
plugin_callbacks_syntax([{Fun, Arity}|Rest], Mod, Dict) ->
    case dict:find({Fun, Arity}, Dict) of
        error ->
            Pos = 1,
            Value = nksip_code_util:call_expr(Mod, Fun, Arity, Pos);
        {ok, {Syntax, Pos0}} ->
            Pos = Pos0+1,
            Value = nksip_code_util:case_expr(Mod, Fun, Arity, Pos, [Syntax])
    end,
    Dict1 = dict:store({Fun, Arity}, {Value, Pos}, Dict),
    plugin_callbacks_syntax(Rest, Mod, Dict1);

plugin_callbacks_syntax([], _, Dict) ->
    Dict.


%% @private Extracts all defined app callbacks
-spec get_all_app_callbacks([atom()]) ->
    [{{Fun::atom(), Arity::integer()}, Mod::atom()}].

get_all_app_callbacks(ModList) ->
    get_all_app_callbacks(ModList, []).


%% @private
get_all_app_callbacks([Mod|Rest], Acc) ->
    Acc1 = case nksip_code_util:get_funs(Mod) of
        error ->
            Acc;
        List ->
            lists:foldl(
                fun({Fun, Arity}, FAcc) ->
                    case lists:keymember({Fun, Arity}, 1, Acc) of
                        true -> FAcc;
                        false -> [{{Fun, Arity}, Mod}|FAcc]
                    end
                end,
                Acc,
                List)
    end,
    get_all_app_callbacks(Rest, Acc1);

get_all_app_callbacks([], Acc) ->
    Acc.










