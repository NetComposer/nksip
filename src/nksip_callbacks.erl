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

%% @doc SipApp plugin callbacks default implementation

-module(nksip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").
-export([nkcb_init/2, nkcb_handle_call/4, nkcb_handle_cast/3, 
	     nkcb_handle_info/3, nkcb_terminate/3, nkcb_sipapp_updated/2]).
-export([nkcb_call/3, nkcb_sip_method/2, nkcb_authorize_data/3]).

-type nkcb_common() :: continue | {continue, list()}.


%% @doc Called after starting the SipApp process and before calling application-level
%% init/1 callback. Can be used to store metadata.
-spec nkcb_init(nksip:app_id(), nksip_sipapp_srv:plugins_state()) ->
	{ok, nksip_sipapp_srv:plugins_state()} | nkcb_common().

nkcb_init(_AppId, PluginsState) ->
	{ok, PluginsState}.


%% @doc Called when the SipApp process receives a handle_call/3.
%% Return {ok, NewPluginState} (should call gen_server:reply/2) or continue.
-spec nkcb_handle_call(nksip:app_id(), term(), from(), nksip_sipapp_srv:plugins_state()) ->
	{ok, nksip_sipapp_srv:plugins_state()} | nkcb_common().

nkcb_handle_call(AppId, Msg, From, PluginsState) ->
	{continue, [AppId, Msg, From, PluginsState]}.


%% @doc Called when the SipApp process receives a handle_cast/3.
%% Return {ok, NewPluginState} or continue.
-spec nkcb_handle_cast(nksip:app_id(), term(), nksip_sipapp_srv:plugins_state()) ->
	{ok, nksip_sipapp_srv:plugins_state()} | nkcb_common().

nkcb_handle_cast(AppId, Msg, PluginsState) ->
	{continue, [AppId, Msg, PluginsState]}.


%% @doc Called when the SipApp process receives a handle_info/3.
%% Return {ok, NewPluginState} or continue.
-spec nkcb_handle_info(nksip:app_id(), term(), nksip_sipapp_srv:plugins_state()) ->
	{ok, nksip_sipapp_srv:plugins_state()} | nkcb_common().

nkcb_handle_info(AppId, Msg, PluginsState) ->
	{continue, [AppId, Msg, PluginsState]}.


%% @doc Called when the SipApp process receives a terminate/2.
-spec nkcb_terminate(nksip:app_id(), term(), nksip_sipapp_srv:plugins_state()) ->
	ok.

nkcb_terminate(_AppId, _Reason, _PluginsState) ->
	ok.

%% @doc Called when the SipApp is updated with a new configuration
-spec nkcb_sipapp_updated(nksip:app_id(), nksip_sipapp_srv:plugins_state()) ->
	{ok, nksip_sipapp_srv:plugins_state()} | nkcb_common().

nkcb_sipapp_updated(_AppId, PluginsState) ->
	{ok, PluginsState}.


%% @doc This plugin callback function is used to call application-level 
%% SipApp callbacks.
-spec nkcb_call(atom(), list(), nksip:app_id()) ->
	{ok, term()} | error | nkcb_common().

nkcb_call(Fun, Args, AppId) ->
	case catch apply(AppId, Fun, Args) of
	    {'EXIT', Error} -> 
	        ?call_error("Error calling callback ~p/~p: ~p", [Fun, length(Args), Error]),
	        error;
	    Reply ->
	    	% ?call_warning("Called ~p/~p (~p): ~p", [Fun, length(Args), Args, Reply]),
	    	% ?call_debug("Called ~p/~p: ~p", [Fun, length(Args), Reply]),
	        {ok, Reply}
	end.


%% @doc This plugin callback is called when a call to one of the method specific
%% application-level SipApp callbacks is needed.
-spec nkcb_sip_method(nksip_call:trans(), nksip_call:call()) ->
	{reply, nksip:sip_reply()} | noreply | nkcb_common().


nkcb_sip_method(#trans{method='ACK', request=Req}, #call{app_id=AppId}=Call) ->
	case catch AppId:sip_ack(Req, Call) of
		ok -> ok;
		Error -> ?call_error("Error calling callback ack/1: ~p", [Error])
	end,
	noreply;

nkcb_sip_method(#trans{method=Method, request=Req}, #call{app_id=AppId}=Call) ->
	#sipmsg{to={_, ToTag}} = Req,
	Fun = case Method of
		'INVITE' when ToTag == <<>> -> sip_invite;
		'INVITE' -> sip_reinvite;
		'UPDATE' -> sip_update;
		'BYE' -> sip_bye;
		'OPTIONS' -> sip_options;
		'REGISTER' -> sip_register;
		'PRACK' -> sip_prack;
		'INFO' -> sip_info;
		'MESSAGE' -> sip_message;
		'SUBSCRIBE' when ToTag == <<>> -> sip_subscribe;
		'SUBSCRIBE' -> sip_resubscribe;
		'NOTIFY' -> sip_notify;
		'REFER' -> sip_refer;
		'PUBLISH' -> sip_publish
	end,
	case catch AppId:Fun(Req, Call) of
		{reply, Reply} -> 
			{reply, Reply};
		noreply -> 
			noreply;
		Error -> 
			?call_error("Error calling callback ~p/2: ~p", [Fun, Error]),
			{reply, {internal_error, "SipApp Error"}}
	end.


%% @doc This callback is called when the application use has implemented the
%% sip_authorize/3 callback, and a list with authentication tokens must be
%% generated
-spec nkcb_authorize_data(list(), nksip_call:trans(), nksip_call:call()) ->
	{ok, list()} | nkcb_common().

nkcb_authorize_data(List, #trans{request=Req}, Call) ->
	Digest = nksip_auth:authorize_data(Req, Call),
	Dialog = case nksip_call_lib:check_auth(Req, Call) of
        true -> dialog;
        false -> []
    end,
    {ok, lists:flatten([Digest, Dialog, List])}.





