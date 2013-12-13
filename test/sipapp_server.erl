%% -------------------------------------------------------------------
%%
%% sipapp_server: Server Callback module for all tests
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

-module(sipapp_server).
-behaviour(nksip_sipapp).

-export([start/2, stop/1, get_domains/1, set_domains/2]).
-export([init/1, get_user_pass/3, authorize/4, route/6, 
        handle_call/3, handle_cast/2, handle_info/2]).

-include("../include/nksip.hrl").


start(Id, Opts) ->
    nksip:start(Id, ?MODULE, Id, Opts).

stop(Id) ->
    nksip:stop(Id).

get_domains(Id) ->
    nksip:call(Id, get_domains).

set_domains(Id, Domains) ->
    nksip:call(Id, {set_domains, Domains}).    



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks %%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    id,
    domains,
    callbacks
}).

init(Id) ->
    % Sets the domains for each combination of test/server
    Domains = case Id of
        {fork, _} -> [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>];
        {_, server1} -> [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>];
        {_, server2} -> [<<"nksip2">>, <<"127.0.0.1">>, <<"[::1]">>];
        _ -> []
    end,
    {ok, #state{id=Id, domains=Domains, callbacks=[]}}.


% Password for user "client1", any realm, is "1234"
% For user "client2", any realm, is "4321"
get_user_pass(<<"client1">>, _, State) -> 
    {reply, "1234", State};
get_user_pass(<<"client2">>, _, State) -> 
    {reply, "4321", State};
get_user_pass(_User, _Realm, State) -> 
    {reply, false, State}.


% Authorization is only used for "auth" suite
authorize(_ReqId, Auth, _From, #state{id={auth, Id}}=State) ->
    % ?P("AUTH AT ~p: ~p", [Id, Auth]),
    Reply = case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
        true ->
            true;
        false ->
            BinId = nksip_lib:to_binary(Id) ,
            case nksip_lib:get_value({digest, BinId}, Auth) of
                true -> true;
                false -> false;
                undefined -> {proxy_authenticate, BinId}
            end
    end,
    {reply, Reply, State};
authorize(_ReqId, _Auth, _From, State) ->
    {reply, ok, State}.


% Route for "basic" test suite. Allways add Record-Route and Nksip-Server headers
% If no user, use Nksip-Op to select an operation
% If user and domain is nksip, proxy to registered contacts
% Any other case simply route
route(ReqId, Scheme, User, Domain, _From, 
        #state{id={Test, Id}=AppId, domains=Domains}=State)
        when Test=:=basic; Test=:=uas ->
    Opts = [
        record_route,
        {headers, [{'Nksip-Server', Id}]}
    ],
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            case nksip_request:header(AppId, ReqId, <<"Nksip-Op">>) of
                [<<"reply-request">>] ->
                    Request = nksip_request:get_request(AppId, ReqId),
                    Body = base64:encode(term_to_binary(Request)),
                    Hds = [{<<"Content-Type">>, <<"nksip/request">>}],
                    {reply, {200, Hds, Body, [make_contact]}, State};
                [<<"reply-stateless">>] ->
                    {reply, {response, ok, [stateless]}, State};
                [<<"reply-stateful">>] ->
                    {reply, {response, ok}, State};
                [<<"reply-invalid">>] ->
                    {reply, {response, 'INVALID'}, State};
                [<<"force-error">>] ->
                    error(test_error);
                _ ->
                    {reply, {process, Opts}, State}
            end;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        _ ->
            {reply, {proxy, ruri, Opts}, State}
    end;

% Route for stateless and stateful test suites
% If header Nk-Rr is "true" will add a Record-Route header
% If RUri is "client2_op@nksip" will find client2@op and use body as erlang term
% with options to route
% If domain is nksip2, route to 127.0.0.1:5080/5081
route(ReqId, Scheme, User, Domain, _From, 
        #state{id={Test, Id}=AppId, domains=Domains}=State) 
    when Test=:=stateless; Test=:=stateful ->
    Opts = lists:flatten([
        case Test of stateless -> stateless; _ -> [] end,
        {headers, [{<<"Nk-Id">>, Id}]},
        case nksip_request:header(AppId, ReqId, <<"Nk-Rr">>) of
            [<<"true">>] -> record_route;
            _ -> []
        end
    ]),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            {reply, {process, Opts}, State};
        true when User =:= <<"client2_op">>, Domain =:= <<"nksip">> ->
            UriList = nksip_registrar:find(AppId, sip, <<"client2">>, Domain),
            Body = nksip_request:body(AppId, ReqId),
            ServerOpts = binary_to_term(base64:decode(Body)),
            {reply, {proxy, UriList, ServerOpts++Opts}, State};
        true when Domain =:= <<"nksip">>; Domain =:= <<"nksip2">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> 
                    % ?P("FIND ~p: []", [{AppId, Scheme, User, Domain}]),
                    {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        true ->
            {reply, {proxy, ruri, Opts}, State};
        false when Domain =:= <<"nksip">> ->
            {reply, {proxy, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]}, State};
        false when Domain =:= <<"nksip2">> ->
            {reply, {proxy, ruri, [{route, "<sips:127.0.0.1:5081;lr>"}|Opts]}, State};
        false ->
            {reply, {proxy, ruri, Opts}, State}
    end;

% Route for serverR in fork test
% Adds Nk-Id header, and Record-Route if Nk-Rr is true
% If Nk-Redirect will follow redirects
route(ReqId, Scheme, User, Domain, _From, 
        #state{id={fork, serverR}=AppId, domains=Domains}=State) ->
    Opts = lists:flatten([
        {headers, [{<<"Nk-Id">>, serverR}]},
        case nksip_request:header(AppId, ReqId, <<"Nk-Rr">>) of
            [<<"true">>] -> record_route;
            _ -> []
        end,
        case nksip_request:header(AppId, ReqId, <<"Nk-Redirect">>) of
            [<<"true">>] -> follow_redirects;
            _ -> []
        end
    ]),
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            {reply, {process, Opts}, State};
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:qfind(AppId, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end;
        true ->
            {reply, {proxy, ruri, Opts}, State};
        false ->
            {reply, forbidden, State}
    end;

% Route for the rest of servers in fork test
% Adds Nk-Id header. serverA is stateless, rest are stateful
% Always Record-Route
% If domain is "nksip" routes to serverR
route(_, _, _, Domain, _From, #state{id={fork, Id}, domains=Domains}=State) ->
    Opts = lists:flatten([
        case Id of server1 -> stateless; _ -> [] end,
        record_route,
        {headers, [{<<"Nk-Id">>, Id}]}
    ]),
    case lists:member(Domain, Domains) of
        true when Domain =:= <<"nksip">> ->
            {reply, {proxy, ruri, [{route, "<sip:127.0.0.1;lr>"}|Opts]}, State};
        true ->
            {reply, {proxy, ruri, Opts}, State};
        false ->
            {reply, forbidden, State}
    end;

% Route for server1 in auth tests
% Finds the user and proxies to server2
route(_ReqId, Scheme, User, Domain, _From, #state{id={auth, server1}}=State) ->
    Opts = [{route, "<sip:127.0.0.1:5061;lr>"}],
    case User of
        <<>> -> 
            {reply, process, State};
        _ when Domain =:= <<"127.0.0.1">> ->
            {reply, proxy, State};
        _ ->
            case nksip_registrar:find({auth, server1}, Scheme, User, Domain) of
                [] -> {reply, temporarily_unavailable, State};
                UriList -> {reply, {proxy, UriList, Opts}, State}
            end
    end;

route(_ReqId, _Scheme, _User, _Domain, _From, #state{id={auth, server2}}=State) ->
    {reply, {proxy, ruri, [record_route]}, State};

% Route for "ipv6" test suite.
route(_ReqId, Scheme, User, Domain, _From, 
        #state{id={ipv6, server1}=AppId, domains=Domains}=State) ->
    Opts = [
        {headers, [{'Nk-Id', server1}]},
        stateless,
        {route, "<sip:[::1]:5061;lr;transport=tcp>"}
    ],
    case lists:member(Domain, Domains) of
        true when User =:= <<>> ->
            {reply, {process, Opts}, State};
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(AppId, Scheme, User, Domain) of
                [] -> 
                    {reply, temporarily_unavailable, State};
                UriList -> 
                    {reply, {proxy, UriList, Opts}, State}
            end;
        _ ->
            {reply, {proxy, ruri, Opts}, State}
    end;

route(_ReqId, _Scheme, _User, _Domain, _From, #state{id={ipv6, server2}}=State) ->
    Opts = [
        record_route,
        {headers, [{'Nk-Id', server2}]}
    ],
    {reply, {proxy, ruri, Opts}, State};


route(_ReqId, Scheme, _User, _Domain, _From, #state{id={torture, server1}}=State)
      when Scheme=/=sip, Scheme=/=sips ->
    {reply, unsupported_uri_scheme, State};

route(_, _, _, _, _, #state{id={torture, server1}}=State) ->
    {reply, process, State}.





%%%%%%%%%%%%%%%%%%%%%%%  NkSipCore gen_server CallBacks %%%%%%%%%%%%%%%%%%%%%


handle_call({set_domains, Domains}, _From, #state{id=Id}=State) ->
    {reply, {ok, Id}, State#state{domains=Domains}};

handle_call(get_domains, _From, #state{id=Id, domains=Domains}=State) ->
    {reply, {ok, Id, Domains}, State}.

handle_cast({cast_test, Ref, Pid}, #state{id=Id}=State) ->
    Pid ! {Ref, {cast_test, Id}},
    {noreply, State}.

handle_info({info_test, Ref, Pid}, #state{id=Id}=State) ->
    Pid ! {Ref, {info_test, Id}},
    {noreply, State}.








