
%% -------------------------------------------------------------------
%%
%% basic_test: Basic Test Suite
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

-module(basic_test_server).

-export([sip_route/5, config/1]).
-export([srv_init/2, srv_handle_call/4, srv_handle_cast/3, srv_handle_info/3]).

-include_lib("nkserver/include/nkserver_module.hrl").



config(Opts) ->
    Opts#{
        sip_from => "\"NkSIP Basic SUITE Test Server\" <sip:?MODULE@nksip>",
        sip_listen => "sip://all;tcp_listeners=10, sips:all:5061",
        plugins => [nksip_registrar, nksip_trace]
        %sip_trace => true,
        %sip_debug=>[nkpacket, call, packet]
    }.


sip_route(Scheme, User, Domain, Req, _Call) ->
    Domains = nkserver:get(?MODULE, domains),
    Opts = [
        record_route,
        {insert, "x-nk-server", ?MODULE}
    ],
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            case nksip_request:header(<<"x-nk-op">>, Req) of
                {ok, [<<"reply-request">>]} ->
                    Body = base64:encode(term_to_binary(Req)),
                    {reply, {ok, [{body, Body}, contact]}};
                {ok, [<<"reply-stateless">>]} ->
                    {reply_stateless, ok};
                {ok, [<<"reply-stateful">>]} ->
                    {reply, ok};
                {ok, [<<"reply-invalid">>]} ->
                    {reply, 'INVALID'};
                {ok, [<<"force-error">>]} ->
                    error(test_error);
                {ok, _} ->
                    process
            end;
        true when Domain =:= <<"nksip">> ->
            lager:error("NKLOG MY PROCESS2"),
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable};
                UriList -> {proxy, UriList, Opts}
            end;
        _ ->
            lager:error("NKLOG MY PROCESS3"),
            {proxy, ruri, Opts}
    end.


srv_init(#{id:=PkgId}, State) ->
    ok =  nkserver:put(PkgId, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State#{my_name=>PkgId}}.



srv_handle_call(get_domains, _From, _Service, #{my_name:=?MODULE}=State) ->
    Domains = nkserver:get(?MODULE, domains),
    {reply, {ok, Domains}, State};

srv_handle_call({set_domains, Domains}, _From, _Service, #{my_name:=?MODULE}=State) ->
    ok =  nkserver:put(?MODULE, domains, Domains),
    {reply, ok, State};

srv_handle_call(_Msg, _From, _Service, _State) ->
    continue.



srv_handle_cast({cast_test, Ref, Pid}, _Service, #{my_name:=?MODULE}=State) ->
    Pid ! {Ref, {cast_test, ?MODULE}},
    {noreply, State};

srv_handle_cast(_Msg, _Service, _State) ->
    continue.


srv_handle_info({info_test, Ref, Pid}, _Service, #{my_name:=?MODULE}=State) ->
    Pid ! {Ref, {info_test, ?MODULE}},
    {noreply, State};

srv_handle_info(_Msg, _Service, _State) ->
    continue.















