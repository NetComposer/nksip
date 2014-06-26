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

%% @doc NkSIP SIP basic message print and trace tool
%%
%% This module implements a simple but useful SIP trace utility. 
%% You can configure any <i>SipApp</i> to trace SIP messages sent or received
%% from specific IPs, to console or a disk file.
%%
%% It also allows to store (in memory) detailed information about 
%% every request or response sent or received for debug purposes.

-module(nksip_trace).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([version/0, deps/0, parse_config/2, terminate/2]).

-export([get_all/0, start/0, start/1, start/2, start/3, stop/0, stop/1]).
-export([print/1, print/2, sipmsg/5]).

-include("nksip.hrl").
-include("nksip_call.hrl").


% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.1".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Defaults = [
        {nksip_trace, {console, all}}
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),    
    case parse_config(PluginOpts1, [], Config) of
        {ok, Unknown, Config1} ->
            Trace = nksip_lib:get_value(nksip_trace, Config1),
            Cached1 = nksip_lib:get_value(cached_configs, Config1, []),
            Cached2 = nksip_lib:store_value(config_nksip_trace, Trace, Cached1),
            Config2 = nksip_lib:store_value(cached_configs, Cached2, Config1),
            {ok, Unknown, Config2};
        {error, Error} ->
            {error, Error}
    end.


%% @doc Called when the plugin is shutdown
-spec terminate(nksip:app_id(), nksip_sipapp_srv:state()) ->
    {ok, nksip_sipapp_srv:state()}.

terminate(AppId, SipAppState) ->  
    close_file(AppId),
    {ok, SipAppState}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Get all SipApps currently tracing messages.
-spec get_all() ->
    [AppId::term()].

get_all() ->
    Fun = fun(AppId) -> nksip_config:get({nksip_trace, AppId}) /= undefined end,
    lists:filter(Fun, nksip:get_all()).


%% @doc Equivalent to `start(AppId, [], console)' for all started SipApps.
-spec start() -> 
    ok.
start() -> 
    lists:foreach(fun(AppId) -> start(AppId) end, nksip:get_all()).


%% @doc Equivalent to `start(AppId, [], console)'.
-spec start(nksip:app_id()) -> 
    ok.
start(AppId) -> 
    start(AppId, [], console).


%% @doc Equivalent to `start(AppId, [], File)'.
-spec start(nksip:app_id(), console | string()) -> 
    ok | {error, file:posix()}.

start(AppId, Out) -> 
    start(AppId, [], Out).


%% @doc Configures a <i>SipApp</i> to start tracing SIP messages.
%% Any request or response sent or received by the SipApp, 
%% and using any of the IPs in `IpList' 
%% (or <i>all of them</i> if it list is empty) will be traced to `console' 
%% or a file, that will opened in append mode.
-spec start(nksip:app_id(), [inet:ip_address()], console|string()) ->
    ok | {error, file:posix()}.

start(AppId, IpList, Out) when is_list(IpList) ->
    case nksip_config:get({nksip_trace, AppId}) of
        undefined -> ok;
        {_, console} -> ok;
        {_, IoDevice0} -> catch file:close(IoDevice0)
    end,
    case Out of
        console ->
            nksip_config:put({nksip_trace, AppId}, {IpList, console});
        _ ->            
            case file:open(Out, [append]) of
                {ok, IoDevice} -> 
                    nksip_config:put({nksip_trace, AppId}, {IpList, IoDevice});
                {error, Error} -> 
                    {error, Error}
            end
    end.


%% @doc Stop all tracing processes, closing all open files.
-spec stop() -> 
    ok.

stop() ->
    lists:foreach(fun(AppId) -> stop(AppId) end, nksip:get_all()).


%% @doc Stop tracing a specific trace process, closing file if it is opened.
-spec stop(nksip:app_id()) ->
    ok | not_found.

stop(AppId) ->
    case nksip_config:get({nksip_trace, AppId}) of
        undefined -> 
            not_found;
        {_, console} ->
            nksip_config:del({nksip_trace, AppId}),
            ok;
        {_, IoDevice} ->
            catch file:close(IoDevice),
            nksip_config:del({nksip_trace, AppId}),
            ok
    end.


%% @doc Pretty-print a `Request' or `Response'.
-spec print(Input::nksip:request()|nksip:response()) ->
 ok.

print(#sipmsg{}=SipMsg) -> 
    print(<<>>, SipMsg).


%% @doc Pretty-print a `Request' or `Response' with a tag.
-spec print(string()|binary(), Input::nksip:request()|nksip:response()) ->
    ok.

print(Header, #sipmsg{}=SipMsg) ->
    Binary = nksip_unparse:packet(SipMsg),
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    io:format("\n        ---- ~s\n~s\n", [Header, list_to_binary(Lines)]).


%% @private
-spec sipmsg(nksip:app_id(), nksip:call_id(), binary(), 
             nksip_transport:transport(), binary()) ->
    ok.

sipmsg(AppId, _CallId, Header, Transport, Binary) ->
    case AppId:config_trace() of
        {true, _} ->
            #transport{local_ip=Ip1, remote_ip=Ip2} = Transport,
            AppName = AppId:name(),
            Msg = print_packet(AppName, Header, Transport, Binary),
            % lager:debug([{app, AppName}, {call_id, CallId}], "~s", 
            %         [print_packet(AppName, Header, Transport, Binary)]),
            write(Msg, console),


            case nksip_config:get({nksip_trace, AppId}) of
                undefined -> 
                    ok;
                {[], IoDevice} ->
                    Msg = print_packet(AppName, Header, Transport, Binary),
                    write(Msg, IoDevice);
                {IpList, IoDevice} ->
                    case lists:member(Ip1, IpList) orelse lists:member(Ip2, IpList) of
                        true -> 
                            Msg = print_packet(AppName, Header, Transport, Binary),
                            write(Msg, IoDevice);
                        false -> 
                            ok
                    end
            end;
        _ ->
            ok
    end.



%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec parse_config(PluginConfig, Unknown, Config) ->
    {ok, Unknown, Config} | {error, term()}
    when PluginConfig::nksip:optslist(), Unknown::nksip:optslist(), 
         Config::nksip:optslist().

parse_config([], Unknown, Config) ->
    {ok, Unknown, Config};

parse_config([Term|Rest], Unknown, Config) ->
    Op = case Term of
        {nksip_trace, true} ->
            {update, {console, all}};
        {nksip_trace, {File, IpList}} -> 
            AppId = nksip_lib:get_value(id, Config),
            close_file(AppId),
            case open_file(AppId, File) of
                {ok, IoDevice} when IpList==all ->
                    {update, {IoDevice, all}};
                {ok, IoDevice} ->
                    case compile_ips(IpList, []) of
                        {ok, CompIpList} -> {update, {IoDevice, CompIpList}};
                        {error, Error} -> {error, Error}
                    end;
                {error, Error} -> 
                    {error, Error}
            end;
        {nksip_trace, File} ->
            AppId = nksip_lib:get_value(id, Config),
            close_file(AppId),
            case open_file(AppId, File) of
                {ok, IoDevice} -> {update, {IoDevice, all}};
                {error, Error} -> {error, Error}
            end;
        _ ->
            unknown
    end,
    case Op of
        {update, Trace} ->
            Config1 = [{nksip_trace, Trace}|lists:keydelete(nksip_trace, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        {error, OpError} ->
            {error, OpError};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.


%% @private
close_file(AppId) ->
    case nksip_config:get({nksip_trace_file, AppId}) of
        undefined -> 
            ok;
        {File, OldDevice} ->
            ?notice(AppId, <<>>, "Closing file ~s (~p)", [File, OldDevice]),
            file:close(OldDevice)
    end.
 

%% @private
open_file(_AppId, console) ->
    {ok, console};

open_file(AppId, File) when is_binary(File) ->
    open_file(AppId, binary_to_list(File));

open_file(AppId, File) ->
    case file:open(File, [append]) of
        {ok, IoDevice} -> 
            ?notice(AppId, <<>>, "File ~s opened for trace (~p)", [File, IoDevice]),
            nksip_config:put({nksip_trace_file, AppId}, {File, IoDevice}),
            {ok, file};
        {error, _Error} -> 
            lager:warning("File: ~p", [File]),
            {error, {could_not_open, File}}
    end.


%% @private
compile_ips([], Acc) ->
    lists:reverse(Acc);

compile_ips(Ip, Acc) when is_binary(Ip) ->
    compile_ips(binary_to_list(Ip), Acc);

compile_ips([First|_]=String, Acc) when is_integer(First) ->
    compile_ips([String], Acc);

compile_ips([Ip|Rest], Acc) ->
    case re:compile(Ip) of
        {ok, Comp} -> compile_ips(Rest, [Comp|Acc]);
        {error, _Error} -> {error, {invalid_ip, Ip}}
    end.


%% @private
write(Msg, console) -> 
    Time = nksip_lib:l_timestamp_to_float(nksip_lib:l_timestamp()), 
    io:format("\n        ---- ~f ~s", [Time, Msg]);

write(Msg, IoDevice) -> 
    Time = nksip_lib:l_timestamp_to_float(nksip_lib:l_timestamp()), 
    catch file:write(IoDevice, io_lib:format("\n        ---- ~f ~s", [Time, Msg])).


%% @private
print_packet(AppId, Info, 
                #transport{
                    proto = Proto,
                    local_ip = LIp, 
                    local_port = LPort, 
                    remote_ip = RIp, 
                    remote_port = RPort
                }, 
                Binary) ->
    case catch inet_parse:ntoa(RIp) of
        {error, _} -> RHost = <<"undefined">>;
        {'EXIT', _} -> RHost = <<"undefined">>;
        RHost -> ok
    end,
    case catch inet_parse:ntoa(LIp) of
        {error, _} -> LHost = <<"undefined">>;
        {'EXIT', _} -> LHost = <<"undefined">>;
        LHost -> ok
    end,
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    io_lib:format("~p ~s ~s:~p (~p, ~s:~p) (~p)\n\n~s", 
                    [AppId, Info, RHost, RPort, 
                    Proto, LHost, LPort, self(), list_to_binary(Lines)]).





