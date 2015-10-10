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

%% @doc SipApps management module.

-module(nksip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, stop/1, stop_all/0, update/2]).
-export([get_config/1, get_uuid/1]).
-export([version/0, deps/0, plugin_start/1, plugin_stop/1]).


-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-export_type([app_name/0, app_id/0, handle/0]).
-export_type([request/0, response/0, sipreply/0, optslist/0]).
-export_type([call/0, transport/0, uri/0, user_uri/0]).
-export_type([header/0, header_name/0, header_value/0]).
-export_type([scheme/0, protocol/0, method/0, sip_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, invite/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

%% User Name of each started SipApp
-type app_name() :: nkservice:service_name().

%% Interna Name of each started SipApp
-type app_id() :: nkservice:service_id().

%% External handle for a request, response, dialog or event
%% It is a binary starting with:
%% R_: requests
%% S_: responses
%% D_: dialogs
%% U_: subscriptions
-type handle() :: binary().

%% Parsed SIP Request
-type request() :: #sipmsg{}.

%% Parsed SIP Response
-type response() :: #sipmsg{}.

%% Full call 
-type call() :: nksip_call:call().

%% User's response to a request
-type sipreply() :: nksip_reply:sipreply().

%% Generic options list
-type optslist() :: nksip_util:optslist().

%% Transport
-type transport() :: #transport{}.

%% Parsed SIP Uri
-type uri() :: #uri{}.

%% User specified uri
-type user_uri() :: string() | binary() | uri().

%% Parsed SIP Via
-type via() :: #via{}.

%% Token
-type token() :: {name(), [{name(), value()}]}.

%% Sip Generic Header Name
-type header_name() :: name().

% Util types
-type header_value() :: 
    value() | uri() | token() | via() | [value() | uri() | token() | via()].

%% SIP Generic Header
-type header() :: {header_name(), header_value()}.

%% Recognized transport schemes
-type protocol() :: udp | tcp | tls | sctp | ws | wss | binary().

%% Recognized SIP schemes
-type scheme() :: sip | sips | tel | mailto | binary().

%% SIP Method
-type method() :: 'INVITE' | 'ACK' | 'CANCEL' | 'BYE' | 'REGISTER' | 'OPTIONS' |
                  'SUBSCRIBE' | 'NOTIFY' | 'PUBLISH' | 'REFER' | 'MESSAGE' |
                  'INFO' | 'PRACK' | 'UPDATE' | binary().

%% SIP Response's Code
-type sip_code() :: 100..699.


%% SIP Message's Call-ID
-type call_id() :: binary().

%% SIP Message's CSeq
-type cseq() :: pos_integer().

%% Tag in From and To headers
-type tag() :: binary().

%% SIP Message body
-type body() :: binary() | string() | nksip_sdp:sdp() | term().

%% Uri Set used to order proxies
-type uri_set() :: nksip:user_uri() | [nksip:user_uri() | [nksip:user_uri()]].

%% Address of Record
-type aor() :: {Scheme::scheme(), User::binary(), Domain::binary()}.

%% Dialog
-type dialog() :: #dialog{}.

%% Dialog
-type subscription() :: {user_subs, #subscription{}, #dialog{}}.

%% Dialog
-type invite() :: #invite{}.

%% Reason
-type error_reason() :: 
    {sip|q850, pos_integer()} |
    {sip|q850, pos_integer(), string()|binary()}.


%% Generic Name
-type name() :: binary() | string() | atom().

% Generic Value
-type value() :: binary() | string() | atom() | integer().


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new SipApp.
-spec start(app_name(), atom(), term(), optslist()) -> 
	{ok, app_id()} | {error, term()}.

start(AppName, Module, Args, Opts) ->
    Opts2 = Opts#{
        name => AppName, 
        class => nksip,
        args => Args,
        callback => Module,
        plugins => [nksip|maps:get(plugins, Opts, [])]
    },
    SrvId = get_appid(AppName),
    case nkservice_server:start(SrvId, Opts2) of
        ok -> {ok, SrvId};
        {error, Error} -> {error, Error}
    end.



%% @doc Stops a started SipApp, stopping any registered transports.
-spec stop(app_name()|app_id()) -> 
    ok | {error, not_found}.

stop(App) ->
    nkservice_server:stop(App).


%% @doc Stops all started SipApps.
-spec stop_all() -> 
    ok.

stop_all() ->
    lists:foreach(
        fun({AppId, _, _}) -> stop(AppId) end, 
        nkservice_server:get_all(nksip)).


%% @doc Updates the callback module or options of a running SipApp.
%% It is not allowed to change transports
-spec update(app_name()|app_id(), optslist()) ->
    {ok, app_id()} | {error, term()}.

update(App, Opts) ->
    Opts1 = case Opts of
        #{plugins:=Plugins} ->
            Opts#{plugins=>[nksip|Plugins]};
        _ ->
            Opts
    end,
    nkservice_server:update(App, Opts1).

    

%% @doc Gets service's UUID
-spec get_uuid(nksip:app_name()|nksip:app_id()) -> 
    binary().

get_uuid(Srv) ->
    case nkservice_server:find(Srv) of
        {ok, SrvId} -> 
            UUID = SrvId:uuid(),
            <<"<urn:uuid:", UUID/binary, ">">>;
        not_found ->
            error(service_not_found)
    end.


%% @doc Generates a internal name (an atom()) for any term
-spec get_appid(nksip:app_name()) ->
    nksip:app_id().

get_appid(AppName) ->
    list_to_atom(
        string:to_lower(
            case binary_to_list(nklib_util:hash36(AppName)) of
                [F|Rest] when F>=$0, F=<$9 -> [$A+F-$0|Rest];
                Other -> Other
            end)).


%% @doc Gets service's config
-spec get_config(nksip:app_name()|nksip:app_id()) -> 
    map().

get_config(AppName) ->
    nkservice_server:get_cache(AppName, config_sip).


%% ===================================================================
%% Pugin functions
%% ===================================================================

version() ->
    {ok, Vsn} = application:get_key(nksip, vsn),
    Vsn.

deps() ->
    [].

plugin_start(SrvSpec) ->
    try
        lager:notice("Plugin NKSIP starting: ~p", [maps:get(id, SrvSpec)]),
        Def = nksip_config_cache:app_config(),
        ParsedDef = case nksip_util:parse_syntax(Def) of
            {ok, ParsedDef0} -> ParsedDef0;
            {error, ParseError1} -> throw(ParseError1)
        end,
        Config1 = case nksip_util:parse_syntax(SrvSpec, ParsedDef) of
            {ok, ParsedOpts0} -> ParsedOpts0;
            {error, ParseError2} -> throw(ParseError2)
        end,
        Timers = #call_timers{
            t1 = maps:get(sip_timer_t1, Config1),
            t2 = maps:get(sip_timer_t2, Config1),
            t4 = maps:get(sip_timer_t4, Config1),
            tc = maps:get(sip_timer_c, Config1),
            trans = maps:get(sip_trans_timeout, Config1),
            dialog = maps:get(sip_dialog_timeout, Config1)},
        Config2 = maps:with(cached(), Config1#{sip=>Config1, sip_timers=>Timers}),
        nkservice_util:add_config(Config2, SrvSpec)
    catch
        throw:Throw -> {stop, Throw}
    end.


plugin_stop(SrvSpec) ->
    lager:notice("Plugin NKSIP stopping: ~p", [maps:get(id, SrvSpec)]),
    nkservice_util:del_config(cached(), SrvSpec).


cached() ->
    [sip, sip_max_connections, sip_max_calls, sip_from, 
     sip_no_100, sip_supported, sip_allow, sip_accept, sip_events, sip_route, 
     sip_local_host, sip_local_host6, sip_max_calls, sip_timers].
