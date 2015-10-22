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

%% @doc NkSIP Registrar Server Plugin
-module(nksip_registrar).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("../include/nksip.hrl").
-include("nksip_registrar.hrl").

-export([find/2, find/4, qfind/2, qfind/4, delete/4, clear/1]).
-export([is_registered/1, request/1]).
-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).
-export_type([reg_contact/0]).


%% ===================================================================
%% Types and records
%% ===================================================================

-type reg_contact() :: #reg_contact{}.



%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.2".


%% @doc Dependant plugins
-spec deps() ->
    [atom()].
    
deps() ->
    [nksip].


plugin_start(#{id:=SrvId}=SrvSpec) ->
    case nkservice_util:parse_syntax(SrvSpec, syntax(), defaults()) of
        {ok, SrvSpec1} ->
            UpdFun = fun(Allow) -> nklib_util:store_value(<<"REGISTER">>, Allow) end,
            SrvSpec2 = nksip:plugin_update_value(sip_allow, UpdFun, SrvSpec1),
            #{
                sip_registrar_min_time := Min, 
                sip_registrar_max_time := Max,
                sip_registrar_default_time := Default,
                cache := OldCache
            } = SrvSpec2,
            Timers = #nksip_registrar_time{min=Min, max=Max, default=Default},
            Cache = #{sip_registrar_time=>Timers},
            lager:info("Plugin ~p started (~p)", [?MODULE, SrvId]),
            {ok, SrvSpec2#{cache:=maps:merge(OldCache, Cache)}};
        {error, Error} ->
            {stop, Error}
    end.


plugin_stop(#{id:=SrvId}=SrvSpec) ->
    clear(SrvId),
    UpdFun = fun(Allow) -> Allow -- [<<"REGISTER">>] end,
    SrvSpec1 = nksip:plugin_update_value(sip_allow, UpdFun, SrvSpec),
    SrvSpec2 = maps:without(maps:keys(syntax()), SrvSpec1),
    lager:info("Plugin ~p stopped (~p)", [?MODULE, SrvId]),
    {ok, SrvSpec2}.


syntax() ->
    #{
        sip_registrar_default_time => {integer, 5, none},
        sip_registrar_min_time => {integer, 1, none},
        sip_registrar_max_time => {integer, 60, none}
    }.

defaults() ->
    #{
        sip_registrar_default_time => 3600,     % (secs) 1 hour
        sip_registrar_min_time => 60,           % (secs) 1 min
        sip_registrar_max_time => 86400         % (secs) 24 hour
    }.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all current registered contacts for an AOR.
%% Use nksip_gruu:find/2 to process gruu options.
-spec find(nkservice:name()|nksip:srv_id(), nksip:aor() | nksip:uri()) ->
    [nksip:uri()].

find(Srv, {Scheme, User, Domain}) ->
    find(Srv, Scheme, User, Domain);

find(Srv, Uri) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> nksip_registrar_lib:find(SrvId, Uri);
        _ -> []
    end.


%% @doc Gets all current registered contacts for an AOR.
-spec find(nkservice:name()|nksip:srv_id(), nksip:scheme(), binary(), binary()) ->
    [nksip:uri()].

find(Srv, Scheme, User, Domain) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> nksip_registrar_lib:find(SrvId, Scheme, User, Domain);
        _ -> []
    end.


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nkservice:name()|nksip:srv_id(), AOR::nksip:aor()) ->
    nksip:uri_set().

qfind(Srv, {Scheme, User, Domain}) ->
    qfind(Srv, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nkservice:name()|nksip:srv_id(), nksip:scheme(), binary(), binary()) ->
    nksip:uri_set().

qfind(Srv, Scheme, User, Domain) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> nksip_registrar_lib:qfind(SrvId, Scheme, User, Domain);
        _ ->
            []
    end.


%% @doc Deletes all registered contacts for an AOR (<i>Address-Of-Record</i>).
-spec delete(nkservice:name()|nksip:srv_id(), nksip:scheme(), binary(), binary()) ->
    ok | not_found | callback_error.

delete(Srv, Scheme, User, Domain) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} ->
            AOR = {
                nklib_parse:scheme(Scheme), 
                nklib_util:to_binary(User), 
                nklib_util:to_binary(Domain)
            },
            nksip_registrar_lib:store_del(SrvId, AOR);
        _ ->
            not_found
    end.


%% @doc Finds if a request has a <i>From</i> that has been already registered
%% from the same transport, ip and port, or have a registered <i>Contact</i>
%% having the same received transport, ip and port.
-spec is_registered(Req::nksip:request()) ->
    boolean().

is_registered(#sipmsg{class={req, 'REGISTER'}}) ->
    false;

is_registered(#sipmsg{
                srv_id = SrvId, 
                from = {#uri{scheme=Scheme, user=User, domain=Domain}, _},
                nkport=NkPort
            }) ->
    case catch nksip_registrar_lib:store_get(SrvId, {Scheme, User, Domain}) of
        {ok, Regs} -> nksip_registrar_lib:is_registered(Regs, NkPort);
        _ -> false
    end.


%% @doc Process a REGISTER request. 
%% Can return:
%% <ul>
%%  <li>`unsupported_uri_scheme': if R-RUI scheme is not `sip' or `sips'.</li>
%%  <li>`invalid_request': if the request is not valid for any reason.</li>
%%  <li>`interval_too_brief': if <i>Expires</i> is lower than the minimum configured
%%       registration time (defined in `registrar_min_time' global parameter).</li>
%% </ul>
%%
%% If <i>Expires</i> is 0, the indicated <i>Contact</i> will be unregistered.
%% If <i>Contact</i> header is `*', all previous contacts will be unregistered.
%%
%% The requested <i>Contact</i> will replace a previous registration if it has 
%% the same `reg-id' and `+sip_instace' values, or has the same transport scheme,
%% protocol, user, domain and port.
%%
%% If the request is successful, a 200-code `nksip:sipreply()' is returned,
%% including one or more <i>Contact</i> headers (for all of the current registered
%% contacts), <i>Date</i> and <i>Allow</i> headers.
-spec request(nksip:request()) ->
    nksip:sipreply().

request(Req) ->
    nksip_registrar_lib:request(Req).


%% @doc Clear all stored records by a Service's core.
-spec clear(nkservice:name()|nksip:srv_id()) -> 
    ok | callback_error | service_not_found.

clear(Srv) -> 
    case nkservice_server:find(Srv) of
        {ok, SrvId} ->
            case nksip_registrar_lib:store_del_all(SrvId) of
                ok -> ok;
                _ -> callback_error
            end;
        _ ->
            service_not_found
    end.

