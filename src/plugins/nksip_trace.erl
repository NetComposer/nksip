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

%% @doc NkSIP SIP basic message print and trace tool
%%
%% This module implements a simple but useful SIP trace utility. 
%% You can configure any Service to trace SIP messages sent or received
%% from specific IPs, to console or a disk file.
-module(nksip_trace).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([start/1, start/2, start/3, stop/1]).
-export([print/1, print/2, sipmsg/5]).
-export([open_file/2, close_file/1]).

-include_lib("nkpacket/include/nkpacket.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkserver/include/nkserver.hrl").


-type file() :: console | string() | binary().
-type ip_list() :: all | string() | binary() | [string()|binary()].




%% ===================================================================
%% Public
%% ===================================================================


%% @doc Equivalent to `start(SrvId, console, all)'.
-spec start(nkserver:id()) ->
    ok | {error, term()}.

start(PkgId) ->
    start(PkgId, console, []).


%% @doc Equivalent to `start(PkgId, File, all)'.
-spec start(nkserver:id(), file()) ->
    ok | {error, term()}.

start(PkgId, File) ->
    start(PkgId, File, []).


%% @doc Configures a Service to start tracing SIP messages.
-spec start(nkserver:id(), file(), ip_list()) ->
    ok | {error, term()}.

start(PkgId, File, IpList) ->
    Config1 = ?CALL_PKG(PkgId, config, []),
    Plugins1 = maps:get(plugins, Config1),
    Plugins2 = nklib_util:store_value(nksip_trace, Plugins1),
    Config2 = Config1#{
        plugins:=Plugins2,
        nksip_trace => true,
        nksip_trace_file => File,
        nksip_trace_ips => IpList
    },
    nkserver:replace(PkgId, Config2).



%% @doc Stop tracing a specific trace process, closing file if it is opened.
-spec stop(nkserver:id()) ->
    ok | {error, term()}.

stop(PkgId) ->
    Config1 = ?CALL_PKG(PkgId, config, []),
    Plugins1 = maps:get(plugins, Config1),
    Plugins2 = Plugins1 -- [nksip_trace],
    Config2 = Config1#{plugins:=Plugins2},
    Config3 = maps:without([nksip_trace, nksip_trace_file, nksip_trace_ips], Config2),
    nkserver:replace(PkgId, Config3).



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
-spec sipmsg(nkserver:id(), nksip:call_id(), binary(),
             nkpacket:nkport(), binary()) ->
    ok.

sipmsg(PkgId, _CallId, Header, Transport, Binary) ->
    case nkserver:get_plugin_config(PkgId, nksip_trace, config) of
        {true, File, []} ->
            Msg = print_packet(PkgId, Header, Transport, Binary),
            write(PkgId, File, Msg);
        {true, File, IpList} ->
            #nkport{local_ip=Ip1, remote_ip=Ip2} = Transport,
            case has_ip([Ip1, Ip2], IpList) of
                true ->
                    Msg = print_packet(PkgId, Header, Transport, Binary),
                    write(PkgId, File, Msg);
                false ->
                    ok
            end;
        _ ->
            ok
    end.


%% ===================================================================
%% Private
%% ===================================================================



%% @private
close_file(PkgId) ->
    case nksip_app:get({nksip_trace_file, PkgId}) of
        undefined -> 
            ok;
        {File, OldDevice} ->
            ?SIP_LOG(notice, "Closing file ~s (~p)", [File, OldDevice]),
            nksip_app:del({nksip_trace_file, PkgId}),
            file:close(OldDevice),
            ok
    end.
 

%% @private
open_file(_PkgId, console) ->
    ok;

open_file(PkgId, File) ->
    case file:open(File, [append]) of
        {ok, IoDevice} -> 
            ?SIP_LOG(notice, "File ~s opened for trace (~p)", [File, IoDevice]),
            nksip_app:put({nksip_trace_file, PkgId}, {File, IoDevice}),
            ok;
        {error, _Error} -> 
            error
    end.




%% @private
write(PkgId, File, Msg) ->
    Time = nklib_util:l_timestamp_to_float(nklib_util:l_timestamp()), 
    case File of
        console ->
            io:format("\n        ---- ~f ~s", [Time, Msg]);
        _ ->
            case nksip_app:get({nksip_trace_file, PkgId}) of
                {File, Device} ->
                    Txt = io_lib:format("\n        ---- ~f ~s", [Time, Msg]),
                    catch file:write(Device, Txt);
                _ ->
                    ok
            end
    end.


%% @private
print_packet(PkgId, Info,
                #nkport{
                    transp = Transp,
                    local_ip = LIp, 
                    local_port = LPort, 
                    remote_ip = RIp, 
                    remote_port = RPort
                }, 
                Binary) ->
    RHost = case catch inet_parse:ntoa(RIp) of
        {error, _} ->
            <<"undefined">>;
        {'EXIT', _} ->
            <<"undefined">>;
        RHost0 ->
            RHost0
    end,
    LHost = case catch inet_parse:ntoa(LIp) of
        {error, _} ->
            <<"undefined">>;
        {'EXIT', _} ->
            <<"undefined">>;
        LHost0 ->
            LHost0
    end,
    Lines = [
        [<<"        ">>, Line, <<"\n">>]
        || Line <- binary:split(Binary, <<"\r\n">>, [global])
    ],
    io_lib:format("~p ~s ~s:~p (~p, ~s:~p) (~p)\n\n~s", 
                    [PkgId, Info, RHost, RPort,
                    Transp, LHost, LPort, self(), list_to_binary(Lines)]).



%% @private
has_ip([], _) ->
    false;
has_ip([Ip|Rest], IpList) ->
    case has_ip2(Ip, IpList) of
        true ->
            true;
        false ->
            has_ip(Rest, IpList)
    end.


%% @private
has_ip2(_Ip, []) ->
    false;
has_ip2(Ip, [Re|Rest]) ->
    case re:run(inet_parse:ntoa(Ip), Re) of
        {match, _} ->
            true;
        nomatch ->
            has_ip2(Ip, Rest)
    end.





