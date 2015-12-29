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

%% @doc Services management module.

-module(nksip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, stop/1, stop_all/0, update/2]).
-export([get_config/1, get_uuid/1]).
-export([plugin_update_value/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-export_type([srv_id/0, srv_name/0, handle/0]).
-export_type([request/0, response/0, sipreply/0, optslist/0]).
-export_type([call/0, uri/0, user_uri/0]).
-export_type([header/0, header_name/0, header_value/0]).
-export_type([scheme/0, method/0, sip_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, invite/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

%% User Name of each started Service
-type srv_name() :: nkservice:name().

%% Internal Name of each started Service
-type srv_id() :: nkservice:id().

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

%% @doc Starts a new Service.
-spec start(srv_name(), optslist()) -> 
	{ok, srv_id()} | {error, term()}.

start(Name, Opts) ->
    Opts1 = nklib_util:to_map(Opts),
    Opts2 = Opts1#{
        class => nksip,
        plugins => [nksip|maps:get(plugins, Opts1, [])],
        sip_listen => maps:get(transports, Opts1, "sip:all")
    },
    nkservice:start(Name, Opts2).


%% @doc Stops a started Service, stopping any registered transports.
-spec stop(srv_name()|srv_id()) -> 
    ok | {error, not_running}.

stop(Srv) ->
    nkservice:stop(Srv).


%% @doc Stops all started Services.
-spec stop_all() -> 
    ok.

stop_all() ->
    lists:foreach(
        fun({SrvId, _, _}) -> stop(SrvId) end, 
        nkservice:get_all(nksip)).


%% @doc Updates the callback module or options of a running Service.
%% It is not allowed to change transports
-spec update(srv_name()|srv_id(), optslist()) ->
    {ok, srv_id()} | {error, term()}.

update(Srv, Opts) ->
    Opts1 = nklib_util:to_map(Opts),
    Opts2 = case Opts1 of
        #{plugins:=Plugins} ->
            Opts1#{plugins=>[nksip|Plugins]};
        _ ->
            Opts1
    end,
    nkservice:update(Srv, Opts2).

    

%% @doc Gets service's UUID
-spec get_uuid(nkservice:name()|srv_id()) -> 
    binary().

get_uuid(Srv) ->
    case nkservice_server:get_srv_id(Srv) of
        {ok, SrvId} -> 
            UUID = SrvId:uuid(),
            <<"<urn:uuid:", UUID/binary, ">">>;
        not_found ->
            error(service_not_found)
    end.


%% @doc Gets service's config
-spec get_config(nkservice:name()|srv_id()) -> 
    map().

get_config(SrvName) ->
    nkservice_server:get_cache(SrvName, config_sip).




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
plugin_update_value(Key, Fun, SrvSpec) ->
    Value1 = maps:get(Key, SrvSpec, undefined),
    Value2 = Fun(Value1),
    SrvSpec2 = maps:put(Key, Value2, SrvSpec),
    OldCache = maps:get(cache, SrvSpec, #{}),
    Cache = case lists:member(Key, nksip_syntax:cached()) of
        true -> maps:put(Key, Value2, #{});
        false -> #{}
    end,
    SrvSpec2#{cache=>maps:merge(OldCache, Cache)}.

