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

%% @doc NkSIP Registrar Server Plugin
-module(nksip_registrar).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("../include/nksip.hrl").
-include("nksip_registrar.hrl").

-export([find/3, find/5, qfind/3, qfind/5, delete/5, clear/2]).
-export([is_registered/1, request/1]).
-export_type([reg_contact/0]).


%% ===================================================================
%% Types and records
%% ===================================================================

-type reg_contact() :: #reg_contact{}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all current registered contacts for an AOR.
%% Use nksip_gruu:find/2 to process gruu options.
-spec find(nkservice:id(), nkservice:package_id(), nksip:aor() | nksip:uri()) ->
    [nksip:uri()].

find(SrvId, PkgId, {Scheme, User, Domain}) ->
    find(SrvId, PkgId, Scheme, User, Domain);

find(SrvId, PkgId, Uri) ->
    nksip_registrar_lib:find(SrvId, PkgId, Uri).


%% @doc Gets all current registered contacts for an AOR.
-spec find(nkservice:id(), nkservice:package_id(), nksip:scheme(), binary(), binary()) ->
    [nksip:uri()].

find(SrvId, PkgId, Scheme, User, Domain) ->
    nksip_registrar_lib:find(SrvId, PkgId, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nkservice:id(), nkservice:package_id(), AOR::nksip:aor()) ->
    nksip:uri_set().

qfind(SrvId, PkgId, {Scheme, User, Domain}) ->
    qfind(SrvId, PkgId, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nkservice:id(), nkservice:package_id(), nksip:scheme(), binary(), binary()) ->
    nksip:uri_set().

qfind(SrvId, PkgId, Scheme, User, Domain) ->
    nksip_registrar_lib:qfind(SrvId, PkgId, Scheme, User, Domain).


%% @doc Deletes all registered contacts for an AOR (<i>Address-Of-Record</i>).
-spec delete(nkservice:id(), nkservice:package_id(), nksip:scheme(), binary(), binary()) ->
    ok | not_found | callback_error.

delete(SrvId, PkgId, Scheme, User, Domain) ->
    AOR = {
        nklib_parse:scheme(Scheme),
        nklib_util:to_binary(User),
        nklib_util:to_binary(Domain)
    },
    nksip_registrar_lib:store_del(SrvId, PkgId, AOR).


%% @doc Finds if a request has a <i>From</i> that has been already registered
%% from the same transport, ip and port, or have a registered <i>Contact</i>
%% having the same received transport, ip and port.
-spec is_registered(Req::nksip:request()) ->
    boolean().

is_registered(#sipmsg{class={req, 'REGISTER'}}) ->
    false;

is_registered(SipMsg) ->
    #sipmsg{
        srv = SrvId,
        package = PkgId,
        from = {#uri{scheme=Scheme, user=User, domain=Domain}, _},
        nkport=NkPort
    } = SipMsg,
    case catch nksip_registrar_lib:store_get(SrvId, PkgId, {Scheme, User, Domain}) of
        {ok, Regs} ->
            nksip_registrar_lib:is_registered(Regs, NkPort);
        _ ->
            false
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
-spec clear(nkservice:id(), nkservice:package_id()) ->
    ok.

clear(SrvId, PkgId) ->
    nksip_registrar_lib:store_del_all(SrvId, PkgId),
    ok.
