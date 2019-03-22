%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% ===================================================================
%% @doc Services management module.
%% 
%% @todo Define ServiceName better.
%% @todo Define options list better.
%% @end 
%% ===================================================================

-module(nksip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start_link/2, stop/1, update/2, get_sup_spec/2]).

% -export([plugin_update_value/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").



-export_type([id/0, handle/0]).
-export_type([request/0, response/0, sipreply/0, optslist/0]).
-export_type([call/0, uri/0, user_uri/0]).
-export_type([header/0, header_name/0, header_value/0]).
-export_type([scheme/0, method/0, sip_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, invite/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

%% Internal Name of each started Service
-type id() :: nkserver:id().

-type config() ::
    #{
        plugins => [any()],
        sip_listen => binary(),
        sip_allow => binary(),
        sip_supported => binary(),
        sip_timer_t1 => integer(),
        sip_timer_t2 => integer(),
        sip_timer_t4 => integer(),
        sip_timer_c => integer(),
        sip_trans_timeout => integer(),
        sip_dialog_timeout => integer(),
        sip_event_expires => integer(),
        sip_event_expires_offset => integer(),
        sip_nonce_timeout => integer(),
        sip_from => binary(),
        sip_accept => binary(),
        sip_events => binary(),
        sip_route => binary(),
        sip_no_100 => boolean(),
        sip_max_calls => binary(),
        sip_local_host => binary(),
        sip_local_host6 => binary(),
        sip_debug => [nkpacket|call|protocol],
        sip_udp_max_size => integer(),

        tls_verify => host | boolean(),
        tls_certfile => string(),
        tls_keyfile => string(),
        tls_cacertfile => string(),
        tls_password => string(),
        tls_depth => 0..16,
        tls_versions => [atom()],

        idle_timeout => integer(),
        sctp_out_streams => integer(),
        sctp_in_streams => integer(),
        tcp_max_connections => integer(),
        tcp_listeners => integer(),

        connect_timeout => integer(),
        no_dns_cache => boolean()
    }.


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
% -type optslist() :: nksip_util:optslist().  %% Note there is no longer a nksip_util:optslist()
-type optslist() :: list() | map().

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

%% @doc Starts a new nksip service
%% Module must implement nksip behaviour

-spec start_link(id(), config()) ->
    {ok, pid()} | {error, term()}.

start_link(Id, Config) ->
    Config2 = nklib_util:to_map(Config),
    Plugins = maps:get(plugins, Config, []),
    Config3 = Config2#{plugins => [nksip|Plugins]},
    nkserver:start_link(?PACKAGE_CLASS_SIP, Id, Config3).


stop(Id) ->
    nkserver_srv_sup:stop(Id).


%% @doc Retrieves a service as a supervisor child specification
-spec get_sup_spec(id(), config()) ->
    supervisor:child_spec().

get_sup_spec(Id, Config) ->
    Config2 = nklib_util:to_map(Config),
    Plugins = maps:get(plugins, Config, []),
    Config3 = Config2#{plugins => [nksip|Plugins]},
    nkserver:get_sup_spec(?PACKAGE_CLASS_SIP, Id, Config3).



-spec update(id(), config()) ->
    ok | {error, term()}.

update(Id, Config) ->
    Config2 = nklib_util:to_map(Config),
    Config3 = case Config2 of
        #{plugins:=Plugins} ->
            Config2#{plugins:=[nksip|Plugins]};
        _ ->
            Config2
    end,
    nkserver:update(Id, Config3).

