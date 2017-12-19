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

%% @doc NkSIP SIP basic message print and trace tool
%%
%% This module implements a simple but useful SIP trace utility. 
%% You can configure any Service to trace SIP messages sent or received
%% from specific IPs, to console or a disk file.
-module(nksip_trace).

-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-compile({no_auto_import, [get/1, put/2]}).

-export([get_all/0, start/0, start/1, start/2, start/3, stop/0, stop/1]).
-export([print/1, print/2, sipmsg/5]).
-export([get_config/2, open_file/2, close_file/1]).

-include_lib("nkpacket/include/nkpacket.hrl").
-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-type file() :: console | string() | binary().
-type ip_list() :: all | string() | binary() | [string()|binary()].
-type sip_content() :: { sip_content,[binary()] }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Get all Services currently tracing messages.
-spec get_all() ->
    [{Srv::nkservice:name(), File::console|binary(), IpList::all|[binary()]}].

get_all() ->
    Fun = fun({SrvId, SrvName, _Pid}, Acc) ->
        case catch SrvId:config_nksip_trace() of
            {'EXIT', _} -> Acc;
            {File, IpList} -> [{SrvName, File, IpList}]
        end
    end,
    lists:foldl(Fun, [], nkservice:get_all(nksip)).


%% @doc Equivalent to `start(SrvId, console, all)' for all started Services.
-spec start() -> 
    [{nkservice:name(), ok|{error, term()}}].

start() -> 
    lists:map(
        fun({SrvId, SrvName, _Pid}) -> {SrvName, start(SrvId)} end, 
        nkservice:get_all(nksip)).


%% @doc Equivalent to `start(SrvId, console, all)'.
-spec start(nksip:srv_id()|nkservice:name()) -> 
    ok | {error, term()}.

start(Srv) -> 
    start(Srv, console, all).


%% @doc Equivalent to `start(Srv, File, all)'.
-spec start(nksip:srv_id()|nkservice:name(), file()) ->
    ok | {error, term()}.

start(all, File) ->
    lists:map(
        fun({SrvId, SrvName, _Pid}) -> {SrvName, start(SrvId,File)} end,
        nkservice:get_all(nksip));

start(Srv, File) -> 
    start(Srv, File, all).

%% @doc Equivalent to `start(Srv, File, IpList)'.
-spec start(nksip:srv_id()|nkservice:name(), file(), ip_list()|sip_content()) ->
    ok | {error, term()}.

start(all, File,IpList) ->
    lists:map(
        fun({SrvId, SrvName, _Pid}) -> {SrvName, start(SrvId,File,IpList)} end,
        nkservice:get_all(nksip));

start(Srv, File, IpList) ->
    case checkTraceOptions(IpList) of
         ok ->
            case nkservice_srv:get_srv_id(Srv) of
                {ok, SrvId} ->
                    Plugins1 = SrvId:plugins(),
                    Plugins2 = nklib_util:store_value(nksip_trace, Plugins1),
                    case nksip:update(SrvId, #{plugins=>Plugins2, sip_trace=>{File, IpList}}) of
                        ok -> ok;
                        {error, Error} -> {error, Error}
                    end;
                not_found ->
                    {error, service_not_found}
            end;
        Err ->
            Err
    end.


%% @doc Stop all tracing processes, closing all open files.
-spec stop() -> 
    ok.

stop() ->
    lists:map(
        fun({SrvId, SrvName, _Pid}) -> {SrvName, stop(SrvId)} end, 
        nkservice:get_all(nksip)).


%% @doc Stop tracing a specific trace process, closing file if it is opened.
-spec stop(nksip:srv_id()|nkservice:name()) ->
    ok | {error, term()}.

stop(Srv) ->
    case nkservice_srv:get_srv_id(Srv) of
        {ok, SrvId} ->
            Plugins = SrvId:plugins() -- [nksip_trace],
            case nksip:update(Srv, #{plugins=>Plugins}) of
                ok -> ok;
                {error, Error} -> {error, Error}
            end;
        not_found ->
            {error, service_not_found}
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
-spec sipmsg(nksip:srv_id(), nksip:call_id(), binary(), 
             nkpacket:nkport(), binary()) ->
    ok.

sipmsg(SrvId, _CallId, Header, Transport, Binary) ->
    case SrvId:config_nksip_trace() of
        {File, all} ->
            SrvName = SrvId:name(),
            Msg = print_packet(SrvName, Header, Transport, Binary),
            write(SrvId, File, Msg);
        {File, {sip_content,ContentList}} ->
            case binary:match(Binary,ContentList) of
                nomatch ->
                    ok;
                _Match ->
                    SrvName = SrvId:name(),
                    Msg = print_packet(SrvName, Header, Transport, Binary),
                    write(SrvId, File, Msg)
            end;
        {File, IpList} ->
            #nkport{local_ip=Ip1, remote_ip=Ip2} = Transport,
            case has_ip([Ip1, Ip2], IpList) of
                true ->
                    SrvName = SrvId:name(),
                    Msg = print_packet(SrvName, Header, Transport, Binary),
                    write(SrvId, File, Msg);
                false ->
                    ok
            end;
        _ ->
            ok
    end.


%% ===================================================================
%% Private
%% ===================================================================



%% @doc
get_config(Id, Trace) ->
    try
        {File, IpList} = case Trace of
            {File0, IpList0} -> 
                case norm_file(File0) of
                    {ok, File1} ->
                        case norm_iplist(IpList0, []) of
                            {ok, IpList1} -> {File1, IpList1};
                            error -> throw({invalid_re, IpList0})
                        end;
                    error ->
                        throw({invalid_file, File0})
                end;
            File0 -> 
                case norm_file(File0) of
                    {ok, File1} -> 
                        {File1, all};
                    error ->
                        throw({invalid_file, File0})
                end
        end,
        close_file(Id),
        case open_file(Id, File) of
            ok -> 
                close_file(Id),
                case compile_ips(IpList, []) of
                    {ok, CompIpList} ->
                        {ok, {File, CompIpList}};
                    error ->
                        throw({invalid_re, IpList})
                end;
            error -> 
                throw({invalid_config, {could_not_open, File}})
        end
    catch
        throw:Error -> {error, Error}
    end.


%% @private
norm_file(console) -> 
    {ok, console};
norm_file(File) when is_binary(File) ->
    {ok, File};
norm_file(File) when is_list(File) -> 
    {ok, list_to_binary(File)};
norm_file(_) -> 
    error.

%% @private
norm_iplist([], Acc) -> 
    {ok, lists:reverse(Acc)};
norm_iplist(all, []) -> 
    {ok, all};
norm_iplist({sip_content,ContentList}, []) ->
    {ok, {sip_content,ContentList}};
norm_iplist(List, Acc) when is_integer(hd(List)) -> 
    norm_iplist(list_to_binary(List), Acc);
norm_iplist([Ip|Rest], Acc) when is_binary(Ip) -> 
    norm_iplist(Rest, [Ip|Acc]);
norm_iplist([Ip|Rest], Acc) when is_list(Ip) -> 
    norm_iplist(Rest, [list_to_binary(Ip)|Acc]);
norm_iplist([Re|Rest], Acc) when element(1, Re)==re_pattern ->
    norm_iplist(Rest, [Re|Acc]);
norm_iplist([_|_], _bAcc) ->
    error;
norm_iplist(Term, Acc) ->
    norm_iplist([Term], Acc).


%% @private
close_file(SrvId) ->
    case nksip_app:get({nksip_trace_file, SrvId}) of
        undefined -> 
            ok;
        {File, OldDevice} ->
            ?notice(SrvId, <<>>, "Closing file ~s (~p)", [File, OldDevice]),
            nksip_app:del({nksip_trace_file, SrvId}),
            file:close(OldDevice),
            ok
    end.
 

%% @private
open_file(_SrvId, console) ->
    ok;

open_file(SrvId, File) ->
    case file:open(binary_to_list(File), [append]) of
        {ok, IoDevice} -> 
            ?notice(SrvId, <<>>, "File ~s opened for trace (~p)", [File, IoDevice]),
            nksip_app:put({nksip_trace_file, SrvId}, {File, IoDevice}),
            ok;
        {error, _Error} -> 
            error
    end.


%% @private
compile_ips(all, []) ->
    {ok, all};
compile_ips({sip_content,ContentList }, []) ->
    {ok, {sip_content,ContentList }};

compile_ips([], Acc) ->
    {ok, lists:reverse(Acc)};

compile_ips([Ip|Rest], Acc) when is_binary(Ip) ->
    case re:compile(Ip) of
        {ok, Comp} -> compile_ips(Rest, [Comp|Acc]);
        {error, _Error} -> error
    end;

compile_ips([Re|Rest], Acc) when element(1, Re)==re_pattern ->
    compile_ips(Rest, [Re|Acc]).


%% @private
write(SrvId, File, Msg) -> 
    Time = nklib_util:l_timestamp_to_float(nklib_util:l_timestamp()), 
    case File of
        console ->
            io:format("\n        ---- ~f ~s", [Time, Msg]);
        _ ->
            case nksip_app:get({nksip_trace_file, SrvId}) of
                {File, Device} ->
                    Txt = io_lib:format("\n        ---- ~f ~s", [Time, Msg]),
                    catch file:write(Device, Txt);
                _ ->
                    ok
            end
    end.


%% @private
print_packet(SrvId, Info, 
                #nkport{
                    transp = Transp,
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
                    [SrvId, Info, RHost, RPort, 
                    Transp, LHost, LPort, self(), list_to_binary(Lines)]).



%% @private
has_ip([], _) ->
    false;
has_ip([Ip|Rest], IpList) ->
    case has_ip2(Ip, IpList) of
        true -> true;
        false -> has_ip(Rest, IpList)
    end.


%% @private
has_ip2(_Ip, []) ->
    false;
has_ip2(Ip, [Re|Rest]) ->
    case re:run(inet_parse:ntoa(Ip), Re) of
        {match, _} -> true;
        nomatch -> has_ip2(Ip, Rest)
    end.

%% @private
checkTraceOptions(Options) ->
    case Options of
        all ->
            ok;
        {sip_content,Opt }->
            is_binList(Opt);
        Opts when is_list(Options)->
            is_ipaddList(Opts);
        _oth ->
            {error, invalid_input_options}
    end.

%% @private
is_ipaddList([]) ->
    ok;
is_ipaddList([H|T])->
    case inet_parse:ntoa(H) of
        {error,Val} ->
            {error,Val};
        _Oth ->
            is_ipaddList(T)
    end.

%% @private
is_binList([]) ->
    ok;

is_binList([H|T])->
    case is_binary(H) of
        false ->
            {error, not_binary_list};
        true ->
            is_binList(T)
    end.



