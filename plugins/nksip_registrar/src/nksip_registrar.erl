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

%% @doc NkSIP Registrar Server Plugin
-module(nksip_registrar).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("nksip_registrar.hrl").

-export([find/2, find/4, qfind/2, qfind/4, delete/4, clear/1]).
-export([is_registered/1, request/1]).
-export([internal_get_all/0, internal_clear/0, internal_print_all/0]).
-export([version/0, deps/0, parse_config/2]).

-export_type([reg_contact/0, index/0, times/0]).


%% ===================================================================
%% Types and records
%% ===================================================================

-type reg_contact() :: #reg_contact{}.

-type index() :: 
    {
        Scheme::sip|sips,
        Proto::nksip:protocol(), 
        User::binary(),
        Domain::binary(), 
        Port::inet:port_number()
    } 
    |
    {ob, Instance::binary(), RegId::binary()}.

-type times() :: {integer(), integer(), integer(), integer(), integer()}.



%% ===================================================================
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
        {registrar_default_time, 3600},     % (secs) 1 hour
        {registrar_min_time, 60},           % (secs) 1 min
        {registrar_max_time, 86400}         % (secs) 24 hour
    ],
    PluginOpts1 = nksip_lib:defaults(PluginOpts, Defaults),
    Allow = nksip_lib:get_value(allow, Config),
    Config1 = case lists:member(<<"REGISTER">>, Allow) of
        true -> Config;
        false -> lists:keystore(allow, 1, Config, {allow, Allow++[<<"REGISTER">>]})
    end,
    nksip_registrar_lib:parse_config(PluginOpts1, [], Config1).



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all current registered contacts for an AOR.
-spec find(nksip:app_name()|nksip:app_id(), nksip:aor() | nksip:uri()) ->
    [nksip:uri()].

find(App, {Scheme, User, Domain}) ->
    find(App, Scheme, User, Domain);

find(App, Uri) ->
    case nksip:find_app(App) of
        {ok, AppId} -> nksip_registrar_lib:find(AppId, Uri);
        _ -> []
    end.


%% @doc Gets all current registered contacts for an AOR.
-spec find(nksip:app_name()|nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [nksip:uri()].

find(App, Scheme, User, Domain) ->
    case nksip:find_app(App) of
        {ok, AppId} -> nksip_registrar_lib:find(AppId, Scheme, User, Domain);
        _ -> []
    end.


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nksip:app_name()|nksip:app_id(), AOR::nksip:aor()) ->
    nksip:uri_set().

qfind(App, {Scheme, User, Domain}) ->
    qfind(App, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nksip:app_name()|nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    nksip:uri_set().

qfind(App, Scheme, User, Domain) ->
    case nksip:find_app(App) of
        {ok, AppId} -> nksip_registrar_lib:qfind(AppId, Scheme, User, Domain);
        _ ->
            []
    end.


%% @doc Deletes all registered contacts for an AOR (<i>Address-Of-Record</i>).
-spec delete(nksip:app_name()|nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    ok | not_found | callback_error.

delete(App, Scheme, User, Domain) ->
    case nksip:find_app(App) of
        {ok, AppId} ->
            AOR = {
                nksip_parse:scheme(Scheme), 
                nksip_lib:to_binary(User), 
                nksip_lib:to_binary(Domain)
            },
            nksip_registrar_lib:store_del(AppId, AOR);
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
                app_id = AppId, 
                from = {#uri{scheme=Scheme, user=User, domain=Domain}, _},
                transport=Transport
            }) ->
    case catch nksip_registrar_lib:store_get(AppId, {Scheme, User, Domain}) of
        {ok, Regs} -> nksip_registrar_lib:is_registered(Regs, Transport);
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


%% @doc Clear all stored records by a SipApp's core.
-spec clear(nksip:app_name()|nksip:app_id()) -> 
    ok | callback_error | sipapp_not_found.

clear(App) -> 
    case nksip:find_app(App) of
        {ok, AppId} ->
            case nksip_registrar_lib:store_del_all(AppId) of
                ok -> ok;
                _ -> callback_error
            end;
        _ ->
            sipapp_not_found
    end.


%% ===================================================================
%% Utilities available only using internal store
%% ===================================================================


% @private Get all current registrations. Use it with care.

-spec internal_get_all() ->
    [{nksip:app_id(), nksip:aor(), [#reg_contact{}]}].

internal_get_all() ->
    [
        {AppId, AOR, nksip_store:get({nksip_registrar, AppId, AOR}, [])}
        || {AppId, AOR} <- internal_all()
    ].


%% @private
internal_print_all() ->
    Now = nksip_lib:timestamp(),
    Print = fun({AppId, {Scheme, User, Domain}, Regs}) ->
        io:format("\n --- ~p --- ~p:~s@~s ---\n", [AppId:name(), Scheme, User, Domain]),
        lists:foreach(
            fun(#reg_contact{contact=Contact, expire=Expire, q=Q}) ->
                io:format("    ~s, ~p, ~p\n", [nksip_unparse:uri(Contact), Expire-Now, Q])
            end, Regs)
    end,
    lists:foreach(Print, internal_get_all()),
    io:format("\n\n").


%% @private Clear all stored records for all SipApps, only with buil-in database
%% Returns the number of deleted items.
-spec internal_clear() -> 
    integer().

internal_clear() ->
    Fun = fun(AppId, AOR, _Val, Acc) ->
        nksip_store:del({nksip_registrar, AppId, AOR}),
        Acc+1
    end,
    internal_fold(Fun, 0).


%% @private
internal_all() -> 
    internal_fold(fun(AppId, AOR, _Value, Acc) -> [{AppId, AOR}|Acc] end, []).


%% @private
internal_fold(Fun, Acc0) when is_function(Fun, 4) ->
    FoldFun = fun(Key, Value, Acc) ->
        case Key of
            {nksip_registrar, AppId, AOR} -> Fun(AppId, AOR, Value, Acc);
            _ -> Acc
        end
    end,
    nksip_store:fold(FoldFun, Acc0).


