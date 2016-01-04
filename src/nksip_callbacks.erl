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

%% @doc Service plugin callbacks default implementation
-module(nksip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-export([plugin_deps/0, plugin_syntax/0, 
		 plugin_config/2, plugin_listen/2, plugin_start/2, plugin_stop/2]).
-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5]).
-export([sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_ack/2, sip_bye/2]).
-export([sip_options/2, sip_register/2, sip_info/2, sip_update/2]).
-export([sip_subscribe/2, sip_resubscribe/2, sip_notify/2, sip_message/2]).
-export([sip_refer/2, sip_publish/2]).
-export([sip_dialog_update/3, sip_session_update/3]).

-export([nks_sip_call/3, nks_sip_method/2, nks_sip_authorize_data/3, 
		 nks_sip_transport_uac_headers/6, nks_sip_transport_uas_sent/1]).
-export([nks_sip_uac_pre_response/3, nks_sip_uac_response/4, nks_sip_parse_uac_opts/2,
		 nks_sip_uac_proxy_opts/2, nks_sip_make_uac_dialog/4, nks_sip_uac_pre_request/4,
		 nks_sip_uac_reply/3]).
-export([nks_sip_uas_send_reply/3, nks_sip_uas_sent_reply/1, nks_sip_uas_method/4, 
		 nks_sip_parse_uas_opt/3, nks_sip_uas_timer/3, nks_sip_uas_dialog_response/4, 
		 nks_sip_uas_process/2]).
-export([nks_sip_dialog_update/3, nks_sip_route/4]).
-export([nks_sip_connection_sent/2, nks_sip_connection_recv/4]).
-export([nks_sip_debug/3]).

-type nks_sip_common() :: continue | {continue, list()}.



%% ===================================================================
%% Plugin callbacks
%% ===================================================================


-spec plugin_deps() ->
    [module()].

plugin_deps() ->
    [].


-spec plugin_syntax() ->
	map().

plugin_syntax() ->
	nksip_syntax:syntax().


-spec plugin_config(nkservice:config(), nkservice:service()) ->
	{ok, tuple()}.

plugin_config(Config, _Service) ->
	{ok, Config, nksip_syntax:make_config(Config)}.


-spec plugin_listen(nkservice:config(), nkservice:service()) ->
	list().

plugin_listen(Data, #{id:=Id, config_nksip:=Config}) ->
	case Data of
		#{sip_listen:=Listen} ->
		    nksip_util:adapt_transports(Id, Listen, Config);
		_ ->
			[]	  
	end.


-spec plugin_start(nkservice:config(), nkservice:service()) ->
	{ok, nkservice:service()} | {error, term()}.

plugin_start(Config, #{name:=Name}) ->
	ok = nksip_app:start(),
    lager:info("Plugin nksip started for service ~s", [Name]),
    {ok, Config}.


-spec plugin_stop(nkservice:config(), nkservice:service()) ->
    {ok, nkservice:service()} | {stop, term()}.

plugin_stop(Config, #{name:=Name}) ->
    lager:info("Plugin nksip stopped for service ~s", [Name]),
    {ok, Config}.



%% ===================================================================
%% Sip callbacks
%% ===================================================================


%% @doc Called to check a user password for a realm.
-spec sip_get_user_pass(User::binary(), Realm::binary(), Req::nksip:request(), 
                        Call::nksip:call()) ->
    true | false | binary().

sip_get_user_pass(<<"anonymous">>, _, _Req, _Call) -> <<>>;
sip_get_user_pass(_User, _Realm, _Req, _Call) -> false.



%% @doc Called for every incoming request to be authorized or not.
-spec sip_authorize(AuthList, Req::nksip:request(), Call::nksip:call()) ->
    ok | forbidden | authenticate | {authenticate, Realm::binary()} |
    proxy_authenticate | {proxy_authenticate, Realm::binary()}
    when AuthList :: [dialog|register|{{digest, Realm::binary}, boolean()}].

sip_authorize(_AuthList, _Req, _Call) ->
    ok.


%% @doc This function is called by NkSIP for every new request, to check if it must be 
-spec sip_route(Scheme::nksip:scheme(), User::binary(), Domain::binary(), 
            Req::nksip:request(), Call::nksip:call()) ->
    proxy | {proxy, ruri | nksip:uri_set()} | 
    {proxy, ruri | nksip:uri_set(), nksip:optslist()} | 
    proxy_stateless | {proxy_stateless, ruri | nksip:uri_set()} | 
    {proxy_stateless, ruri | nksip:uri_set(), nksip:optslist()} | 
    process | process_stateless |
    {reply, nksip:sipreply()} | {reply_stateless, nksip:sipreply()}.

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.


%% @doc Called when a OPTIONS request is received.
-spec sip_options(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_options(_Req, _Call) ->
    {reply, {ok, [contact, allow, allow_event, accept, supported]}}.
    

%% @doc This function is called by NkSIP to process a new incoming REGISTER request. 
-spec sip_register(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_register(Req, _Call) ->
    {ok, SrvId} = nksip_request:srv_id(Req),
    {reply, {method_not_allowed, ?GET_CONFIG(SrvId, allow)}}.


%% @doc This function is called by NkSIP to process a new INVITE request as an endpoint.
-spec sip_invite(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_invite(_Req, _Call) ->
    {reply, decline}.


%% @doc This function is called when a new in-dialog INVITE request is received.
-spec sip_reinvite(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_reinvite(Req, Call) ->
    {ok, SrvId} = nksip_request:srv_id(Req),
    SrvId:sip_invite(Req, Call).


%% @doc Called when a pending INVITE request is cancelled.
-spec sip_cancel(InviteReq::nksip:request(), Req::nksip:request(), Call::nksip:call()) ->
    ok.

sip_cancel(_CancelledReq, _Req, _Call) ->
    ok.


%% @doc Called when a valid ACK request is received.
-spec sip_ack(Req::nksip:request(), Call::nksip:call()) ->
    ok.

sip_ack(_Req, _Call) ->
    ok.


%% @doc Called when a valid BYE request is received.
-spec sip_bye(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_bye(_Req, _Call) ->
    {reply, ok}.


%% @doc Called when a valid UPDATE request is received.
-spec sip_update(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_update(_Req, _Call) ->
    {reply, decline}.


%% @doc This function is called by NkSIP to process a new incoming SUBSCRIBE
-spec sip_subscribe(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_subscribe(_Req, _Call) ->
    {reply, decline}.


%% @doc This function is called by NkSIP to process a new in-subscription SUBSCRIBE
-spec sip_resubscribe(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_resubscribe(_Req, _Call) ->
    {reply, ok}.


%% @doc This function is called by NkSIP to process a new incoming NOTIFY
-spec sip_notify(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_notify(_Req, _Call) ->
    {reply, ok}.


%% @doc This function is called by NkSIP to process a new incoming REFER.
-spec sip_refer(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_refer(_Req, _Call) ->
    {reply, decline}.


%% @doc This function is called by NkSIP to process a new incoming PUBLISH request. 
-spec sip_publish(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_publish(Req, _Call) ->
    {ok, SrvId} = nksip_request:srv_id(Req),
    {reply, {method_not_allowed, ?GET_CONFIG(SrvId, allow)}}.


%% @doc Called when a valid INFO request is received.
-spec sip_info(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_info(_Req, _Call) ->
    {reply, ok}.


%% @doc This function is called by NkSIP to process a new incoming MESSAGE
-spec sip_message(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.

sip_message(_Req, _Call) ->
    {reply, decline}.


%% @doc Called when a dialog has changed its state.
-spec sip_dialog_update(DialogStatus, Dialog::nksip:dialog(), Call::nksip:call()) ->
    ok when 
      DialogStatus :: start | target_update | stop |
                      {invite_status, nksip_dialog:invite_status() | {stop, nksip_dialog:stop_reason()}} |
                      {invite_refresh, SDP::nksip_sdp:sdp()} |
                      {subscription_status, nksip_subscription:status(), nksip:subscription()}.
    
sip_dialog_update(_Status, _Dialog, _Call) ->
    ok.


%% @doc Called when a dialog has updated its SDP session parameters.
-spec sip_session_update(SessionStatus, Dialog::nksip:dialog(), Call::nksip:call()) ->
    ok when 
        SessionStatus :: {start, Local, Remote} | {update, Local, Remote} | stop,
                         Local::nksip_sdp:sdp(), Remote::nksip_sdp:sdp().

sip_session_update(_Status, _Dialog, _Call) ->
    ok.


%% ===================================================================
%% Internal callbacks
%% ===================================================================


%% @doc This plugin callback function is used to call application-level 
%% Service callbacks.
-spec nks_sip_call(atom(), list(), nksip:srv_id()) ->
	{ok, term()} | error | nks_sip_common().

nks_sip_call(Fun, Args, SrvId) ->
	case catch apply(SrvId, Fun, Args) of
	    {'EXIT', Error} -> 
	        ?call_error("Error calling callback ~p/~p: ~p", [Fun, length(Args), Error]),
	        error;
	    Reply ->
	    	% ?call_warning("Called ~p/~p (~p): ~p", [Fun, length(Args), Args, Reply]),
	    	% ?call_debug("Called ~p/~p: ~p", [Fun, length(Args), Reply]),
	        {ok, Reply}
	end.


%% @doc This plugin callback is called when a call to one of the method specific
%% application-level Service callbacks is needed.
-spec nks_sip_method(nksip_call:trans(), nksip_call:call()) ->
	{reply, nksip:sipreply()} | noreply | nks_sip_common().


nks_sip_method(#trans{method='ACK', request=Req}, #call{srv_id=SrvId}=Call) ->
	case catch SrvId:sip_ack(Req, Call) of
		ok -> ok;
		Error -> ?call_error("Error calling callback ack/1: ~p", [Error])
	end,
	noreply;

nks_sip_method(#trans{method=Method, request=Req}, #call{srv_id=SrvId}=Call) ->
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
	case catch SrvId:Fun(Req, Call) of
		{reply, Reply} -> 
			{reply, Reply};
		noreply -> 
			noreply;
		Error -> 
			?call_error("Error calling callback ~p/2: ~p", [Fun, Error]),
			{reply, {internal_error, "Service Error"}}
	end.


%% @doc This callback is called when the application use has implemented the
%% sip_authorize/3 callback, and a list with authentication tokens must be
%% generated
-spec nks_sip_authorize_data(list(), nksip_call:trans(), nksip_call:call()) ->
	{ok, list()} | nks_sip_common().

nks_sip_authorize_data(List, #trans{request=Req}, Call) ->
	Digest = nksip_auth:authorize_data(Req, Call),
	Dialog = case nksip_call_lib:check_auth(Req, Call) of
        true -> dialog;
        false -> []
    end,
    {ok, lists:flatten([Digest, Dialog, List])}.


%% @doc Called after the UAC pre processes a response
-spec nks_sip_uac_pre_response(nksip:response(),  nksip_call:trans(), nksip:call()) ->
	{ok, nksip:call()} | nks_sip_common().

nks_sip_uac_pre_response(Resp, UAC, Call) ->
    {continue, [Resp, UAC, Call]}.


%% @doc Called after the UAC processes a response
-spec nks_sip_uac_response(nksip:request(), nksip:response(), 
					    nksip_call:trans(), nksip:call()) ->
	{ok, nksip:call()} | nks_sip_common().

nks_sip_uac_response(Req, Resp, UAC, Call) ->
    {continue, [Req, Resp, UAC, Call]}.


%% @doc Called to parse specific UAC options
-spec nks_sip_parse_uac_opts(nksip:request(), nksip:optslist()) ->
	{error, term()} | nks_sip_common().

nks_sip_parse_uac_opts(Req, Opts) ->
	{continue, [Req, Opts]}.


%% @doc Called to add options for proxy UAC processing
-spec nks_sip_uac_proxy_opts(nksip:request(), nksip:optslist()) ->
	{reply, nksip:sipreply()} | nks_sip_common().

nks_sip_uac_proxy_opts(Req, ReqOpts) ->
	{continue, [Req, ReqOpts]}.


%% @doc Called when a new in-dialog request is being generated
-spec nks_sip_make_uac_dialog(nksip:method(), nksip:uri(), nksip:optslist(), nksip:call()) ->
	{continue, list()}.

nks_sip_make_uac_dialog(Method, Uri, Opts, Call) ->
	{continue, [Method, Uri, Opts, Call]}.


%% @doc Called when the UAC is preparing a request to be sent
-spec nks_sip_uac_pre_request(nksip:request(), nksip:optslist(), 
                           nksip_call_uac:uac_from(), nksip:call()) ->
    {continue, list()}.

nks_sip_uac_pre_request(Req, Opts, From, Call) ->
	{continue, [Req, Opts, From, Call]}.


%% @doc Called when the UAC transaction must send a reply to the user
-spec nks_sip_uac_reply({req, nksip:request()} | {resp, nksip:response()} | {error, term()}, 
                     nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip:call()} | {continue, list()}.

nks_sip_uac_reply(Class, UAC, Call) ->
    {continue, [Class, UAC, Call]}.


%% @doc Called to add headers just before sending the request
-spec nks_sip_transport_uac_headers(nksip:request(), nksip:optslist(), nksip:scheme(),
							     nkpacket:transport(), binary(), inet:port_number()) ->
	{ok, nksip:request()}.

nks_sip_transport_uac_headers(Req, Opts, Scheme, Transp, Host, Port) ->
	Req1 = nksip_call_uac_transp:add_headers(Req, Opts, Scheme, Transp, Host, Port),
	{ok, Req1}.


%% @doc Called when a new reponse is going to be sent
-spec nks_sip_uas_send_reply({nksip:response(), nksip:optslist()}, 
							 nksip_call:trans(), nksip_call:call()) ->
	{error, term()} | nks_sip_common().

nks_sip_uas_send_reply({Resp, RespOpts}, UAS, Call) ->
	{continue, [{Resp, RespOpts}, UAS, Call]}.


%% @doc Called when a new reponse is sent
-spec nks_sip_uas_sent_reply(nksip_call:call()) ->
	{ok, nksip_call:call()} | nks_sip_common().

nks_sip_uas_sent_reply(Call) ->
	{continue, [Call]}.

	
%% @doc Called when a new request has to be processed
-spec nks_sip_uas_method(nksip:method(), nksip:request(), 
					  nksip_call:trans(), nksip_call:call()) ->
	{ok, nksip_call:trans(), nksip_call:call()} | nks_sip_common().

nks_sip_uas_method(Method, Req, UAS, Call) ->
	{continue, [Method, Req, UAS, Call]}.


%% @doc Called when a UAS timer is fired
-spec nks_sip_uas_timer(nksip_call_lib:timer()|term(), nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip_call:call()} | nks_sip_common().

nks_sip_uas_timer(Tag, UAS, Call) ->
	{continue, [Tag, UAS, Call]}.


%% @doc Called to parse specific UAS options
-spec nks_sip_parse_uas_opt(nksip:request(), nksip:response(), nksip:optslist()) ->
	{error, term()} | nks_sip_common().

nks_sip_parse_uas_opt(Req, Resp, Opts) ->
	{continue, [Req, Resp, Opts]}.


%% @doc Called when preparing a UAS dialog response
-spec nks_sip_uas_dialog_response(nksip:request(), nksip:response(), 
                               nksip:optslist(), nksip:call()) ->
    {ok, nksip:response(), nksip:optslist()}.

nks_sip_uas_dialog_response(_Req, Resp, Opts, _Call) ->
    {ok, Resp, Opts}.


%% @doc Called when the UAS is proceesing a request
-spec nks_sip_uas_process(nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip:call()} | {continue, list()}.

nks_sip_uas_process(UAS, Call) ->
	{continue, [UAS, Call]}.


%% @doc Called when a dialog must update its internal state
-spec nks_sip_dialog_update(term(), nksip:dialog(), nksip_call:call()) ->
    {ok, nksip_call:call()} | nks_sip_common().

nks_sip_dialog_update(Type, Dialog, Call) ->
	{continue, [Type, Dialog, Call]}.


%% @doc Called when a proxy is preparing a routing
-spec nks_sip_route(nksip:uri_set(), nksip:optslist(), 
                 nksip_call:trans(), nksip_call:call()) -> 
    {continue, list()} | {reply, nksip:sipreply(), nksip_call:call()}.

nks_sip_route(UriList, ProxyOpts, UAS, Call) ->
	{continue, [UriList, ProxyOpts, UAS, Call]}.


%% @doc Called when a new message has been sent
-spec nks_sip_connection_sent(nksip:request()|nksip:response(), binary()) ->
	ok | nks_sip_common().

nks_sip_connection_sent(_SipMsg, _Packet) ->
	ok.


%% @doc Called when a new message has been received and parsed
-spec nks_sip_connection_recv(nksip:srv_id(), nksip:call_id(), 
					       nkpacket:nkport(), binary()) ->
    ok | nks_sip_common().

nks_sip_connection_recv(_SrvId, _CallId, _Transp, _Packet) ->
	ok.


%% @doc Called when the transport has just sent a response
-spec nks_sip_transport_uas_sent(nksip:response()) ->
    ok | nks_sip_common().

nks_sip_transport_uas_sent(_Resp) ->
	ok.



%% doc Called at specific debug points
-spec nks_sip_debug(nksip:srv_id(), nksip:call_id(), term()) ->
    ok | nks_sip_common().

nks_sip_debug(_SrvId, _CallId, _Info) ->
    ok.



