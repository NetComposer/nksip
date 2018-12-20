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

%% ===================================================================
%% @doc Services management module.
%% 
%% @todo Define ServiceName better.
%% @todo Define options list better.
%% @end 
%% ===================================================================

-module(nksip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/2, stop/1, stop_all/0, update/2]).
-export([get_uuid/1]).

% -export([plugin_update_value/3]).

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkservice/include/nkservice.hrl").


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

%%----------------------------------------------------------------
%% @doc Starts a new Service.
%%
%% Example(s) Starting a process 
%% ```
%% > nksip:start(server, #{
%%         sip_local_host => "localhost",
%%         callback => nksip_tutorial_server_callbacks,
%%         plugins => [nksip_registrar],
%%         transports => "sip:all:5060, <sip:all:5061;transport=tls>"
%%     }).
%% ok
%% '''

%% @end
%%----------------------------------------------------------------
-spec start( ServiceName, OptionsMapOrList ) -> Result when 
            ServiceName      :: srv_name(), 
            OptionsMapOrList     :: optslist(),
            Result          :: {ok, srv_id()} 
                | {error, term()}.

start(Name, Opts) ->
    SipKeys = lists:filter(
        fun(Key) ->
            case nklib_util:to_list(Key) of
                "sip_" ++ _ -> true;
                "tls_" ++ _ -> true;
                _ -> false
            end
        end,
        maps:keys(Opts)),
    Base = maps:without(SipKeys, Opts),
    Config = maps:with(SipKeys, Opts),
    Listen = maps:get(sip_listen, Opts, "sip:all"),
    Service = Base#{
        class => <<"nksip">>,
        packages => [
            #{
                class => ?PACKAGE_CLASS_SIP,
                config => Config#{sip_listen => Listen}
            }
        ]
    },
    nkservice:start(Name, Service).


%%----------------------------------------------------------------
%% @doc Stops a started Service, stopping any registered transports.
%% @end
%%----------------------------------------------------------------
-spec stop( ServiceNameOrId ) -> Result when 
        ServiceNameOrId     :: srv_name()  
            | srv_id(),
        Result              :: ok 
            |  {error, not_running}.

stop(Srv) ->
    nkservice:stop(Srv).


%%----------------------------------------------------------------
%% @doc Stops all started Services.
%% @end
%%----------------------------------------------------------------
-spec stop_all() -> 
    ok.

stop_all() ->
    nkservice_srv:stop_all(<<"nksip">>).


%%----------------------------------------------------------------
%% @doc Updates the callback module or options of a running Service.
%% It is not allowed to change transports
%%
%% Example(s) 
%% ```
%% > nksip:update(me, #{log_level => debug}).     %% NOTE: Using map() for options
%%   ok
%% '''
%% or 
%% ```
%% > nksip:update(me, [{log_level,debug}]).     %% NOTE: Using list() and tuples for options
%%   ok
%% '''
%% @end
%%----------------------------------------------------------------
-spec update( ServiceNameOrId, OptionsMapOrList ) -> Result when 
            ServiceNameOrId     :: srv_name()
                | srv_id(),
            OptionsMapOrList         :: optslist(),
            Result              ::  {ok, srv_id()} 
                | {error, term()}.

update(Srv, Opts) ->
    Opts1 = nklib_util:to_map(Opts),
    Opts2 = case Opts1 of
        #{plugins:=Plugins} ->
            Opts1#{plugins=>[nksip|Plugins]};
        _ ->
            Opts1
    end,
    nkservice:update(Srv, Opts2).

    

%%----------------------------------------------------------------
%% @doc Gets service's UUID
%% @end
%%----------------------------------------------------------------
-spec get_uuid( ServiceId ) -> Result when
            ServiceId     :: srv_id(),
            Result            :: binary().

get_uuid(SrvId) ->
    ?CALL_SRV(SrvId, uuid, []).

