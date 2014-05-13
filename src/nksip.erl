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

-export([start/4, stop/1, stop_all/0, get_all/0, update/2]).
-export([get/2, get/3, put/3, del/2]).
-export([get_pid/1, find_app/1]).
-export([get_uuid/1, get_gruu_pub/1, get_gruu_temp/1]).

-include("nksip.hrl").

-export_type([app_id/0, id/0, request/0, response/0, call/0, transport/0, sipreply/0]).
-export_type([uri/0, user_uri/0, header/0, header_value/0]).
-export_type([scheme/0, protocol/0, method/0, response_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, invite/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

% Util types
-type name() :: binary() | string() | atom().
-type value() :: binary() | string() | uri() | token() | atom() | integer().


%% Unique Id of each started SipApp
-type app_id() :: term().

%% External request, response, dialog or event id
-type id() :: binary().

%% Parsed SIP Request
-type request() :: #sipmsg{}.

%% Parsed SIP Response
-type response() :: #sipmsg{}.

%% Full call 
-type call() :: nksip_call:call().

%% User's response to a request
-type sipreply() :: nksip_reply:sipreply().

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

%% SIP Generic Header Value
-type header_value() :: value() | uri() | via() | [value() | uri() | via()].

%% SIP Generic Header
-type header() :: {name(), header_value()}.

%% Recognized transport schemes
-type protocol() :: udp | tcp | tls | sctp | ws | wss | binary().

%% Recognized SIP schemes
-type scheme() :: sip | sips | tel | mailto | binary().

%% SIP Method
-type method() :: 'INVITE' | 'ACK' | 'CANCEL' | 'BYE' | 'REGISTER' | 'OPTIONS' |
                  'SUBSCRIBE' | 'NOTIFY' | 'PUBLISH' | 'REFER' | 'MESSAGE' |
                  'INFO' | 'PRACK' | 'UPDATE' | binary().

%% SIP Response's Code
-type response_code() :: 100..699.


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


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new SipApp.
-spec start(term(), atom(), term(), nksip_lib:optslist()) -> 
	{ok, app_id()} | {error, term()}.

start(AppName, Module, Args, Opts) ->
    case get_pid(AppName) of
        error ->
            Config = nksip_config_cache:app_config(),
            Opts1 = Config ++ [{name, AppName}, {module, Module}|Opts],
            case nksip_sipapp_config:parse_config(Opts1) of
                {ok, AppId} ->
                    case nksip_sup:start_core(AppId, Args) of
                        ok -> {ok, AppId};
                        {error, Error} -> {error, Error}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        _ ->
            {error, already_started}
    end.


%% @doc Stops a started SipApp, stopping any registered transports.
-spec stop(term()|app_id()) -> 
    ok | error.

stop(App) ->
    case find_app(App) of
        {ok, AppId} ->
            case nksip_sup:stop_core(AppId) of
                ok ->
                    nksip_registrar:clear(AppId),
                    ok;
                error ->
                    error
            end;
        _ ->
            error
    end.


%% @doc Stops all started SipApps.
-spec stop_all() -> 
    ok.

stop_all() ->
    lists:foreach(fun({_, AppId}) -> stop(AppId) end, get_all()).


%% @doc Updates the callback module or options of a running SipApp.
%% It is not allowed to change transports
-spec update(term()|app_id(), nksip_lib:optslist()) ->
    {ok, app_id()} | {error, term()}.

update(App, Opts) ->
    case find_app(App) of
        {ok, AppId} ->
            Opts1 = nksip_lib:delete(Opts, transport),
            Opts2 = AppId:config() ++ Opts1,
            nksip_sipapp_config:parse_config(Opts2);
        not_found ->
            {error, sipapp_not_found}
    end.

    

%% @doc Gets the user and internal ids of all started SipApps.
-spec get_all() ->
    [{AppName::term(), AppId::app_id()}].

get_all() ->
    [{AppId:name(), AppId} 
      || {AppId, _Pid} <- nksip_proc:values(nksip_sipapps)].


%% @doc Gets a value from SipApp's store
-spec get(term()|nksip:app_id(), term()) ->
    {ok, term()} | not_found | error.

get(App, Key) ->
    case find_app(App) of
        {ok, AppId} -> nksip_sipapp_srv:get(AppId, Key);
        not_found -> error
    end.


%% @doc Gets a value from SipApp's store, using a default if not found
-spec get(term()|nksip:app_id(), term(), term()) ->
    {ok, term()} | error.

get(AppId, Key, Default) ->
    case get(AppId, Key) of
        not_found -> {ok, Default};
        {ok, Value} -> {ok, Value};
        error -> error
    end.


%% @doc Inserts a value in SipApp's store
-spec put(term()|nksip:app_id(), term(), term()) ->
    ok | error.

put(App, Key, Value) ->
    case find_app(App) of
        {ok, AppId} -> nksip_sipapp_srv:put(AppId, Key, Value);
        not_found -> error
    end.


%% @doc Deletes a value from SipApp's store
-spec del(term()|nksip:app_id(), term()) ->
    ok | error.

del(App, Key) ->
    case find_app(App) of
        {ok, AppId} -> nksip_sipapp_srv:del(AppId, Key);
        not_found -> error
    end.


%% @doc Gets the SipApp's gen_server process pid().
-spec get_pid(term()|app_id()) -> 
    pid() | error.

get_pid(App) ->
    case find_app(App) of
        {ok, AppId} -> 
            case whereis(AppId) of
                undefined -> error;
                Pid -> Pid
            end;
        _ ->
            error
    end.


%% @doc Gets the internal name of an existing SipApp
-spec find_app(term()) ->
    {ok, app_id()} | not_found.

find_app(App) when is_atom(App) ->
    case erlang:function_exported(App, config_local_host, 0) of
        true ->
            {ok, App};
        false ->
            case nksip_proc:values({nksip_sipapp_name, App}) of
                [] -> not_found;
                [{AppId, _}] -> {ok, AppId}
            end
    end;

find_app(App) ->
    case nksip_proc:values({nksip_sipapp_name, App}) of
        [] -> not_found;
        [{AppId, _}] -> {ok, AppId}
    end.



%% @doc Gets SipApp's UUID
-spec get_uuid(term()|nksip:app_id()) -> 
    {ok, binary()} | error.

get_uuid(App) ->
    case find_app(App) of
        {ok, AppId} ->
            case nksip_proc:values({nksip_sipapp_uuid, AppId}) of
                [{UUID, _Pid}] -> {ok, <<"<urn:uuid:", UUID/binary, ">">>};
                [] -> error
            end;
        not_found -> 
            error
    end.


%% @doc Gets the last detected public GRUU
-spec get_gruu_pub(term()|nksip:app_id()) ->
    undefined | nksip:uri() | error.

get_gruu_pub(App) ->
    case find_app(App) of
        {ok, AppId} -> nksip_config:get({nksip_gruu_pub, AppId});
        _ -> error
    end.


%% @doc Gets the last detected temporary GRUU
-spec get_gruu_temp(term()|nksip:app_id()) ->
    undefined | nksip:uri() | error.

get_gruu_temp(App) ->
    case find_app(App) of
        {ok, AppId} -> nksip_config:get({nksip_gruu_temp, AppId});
        _ -> error
    end.







%% ===================================================================
%% Private
%% ===================================================================


% %% @doc Gets SipApp's first listening port on this transport protocol.
% -spec get_port(term()|app_id(), protocol(), ipv4|ipv6) -> 
%     inet:port_number() | error.

% get_port(App, Proto, Class) ->
%     case find_app(App) of
%         {ok, AppId} -> 
%             case nksip_transport:get_listening(AppId, Proto, Class) of
%                 [{#transport{listen_port=Port}, _Pid}|_] -> Port;
%                 _ -> error
%             end;
%         error ->
%             error
%     end.



