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

%%----------------------------------------------------------------
%% @doc Service plugin callbacks default implementation
%% @end
%%----------------------------------------------------------------

-module(nksip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include("nksip_call.hrl").


-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5]).
-export([sip_invite/2, sip_reinvite/2, sip_cancel/3, sip_ack/2, sip_bye/2]).
-export([sip_options/2, sip_register/2, sip_info/2, sip_update/2]).
-export([sip_subscribe/2, sip_resubscribe/2, sip_notify/2, sip_message/2]).
-export([sip_refer/2, sip_publish/2]).
-export([sip_dialog_update/3, sip_session_update/3]).

-export([nksip_preparse/2, nksip_user_callback/3, nksip_authorize_data/3,
		 nksip_transport_uac_headers/6, nksip_transport_uas_sent/1]).
-export([nksip_uac_pre_response/3, nksip_uac_response/4, nksip_parse_uac_opts/2,
		 nksip_uac_proxy_opts/2, nksip_make_uac_dialog/4, nksip_uac_pre_request/4,
		 nksip_uac_reply/3]).
-export([nksip_uas_send_reply/3, nksip_uas_sent_reply/1, nksip_uas_method/4,
		 nksip_parse_uas_opt/3, nksip_uas_timer/3, nksip_uas_dialog_response/4,
		 nksip_uas_process/2]).
-export([nksip_dialog_update/3, nksip_route/4]).
-export([nksip_connection_sent/2, nksip_connection_recv/2]).
% -export([handle_call/3, handle_cast/2, handle_info/2]).
-export([nksip_debug/3]).

-type continue() :: continue | {continue, list()}.




%% ===================================================================
%% SIP Callbacks
%% ===================================================================


%%----------------------------------------------------------------
%% @doc Callback to check a user password for a realm.
%% 
%% @end
%%----------------------------------------------------------------
-spec sip_get_user_pass(User, Realm, Req, Call) -> Result when 
		User 	:: binary(),
		Realm 	:: binary(),
		Req 	:: nksip:request(),
		Call 	:: nksip:call(),
		Result 	:: true 
			| false 
			| binary().

sip_get_user_pass(<<"anonymous">>, _, _Req, _Call) -> <<>>;
sip_get_user_pass(_User, _Realm, _Req, _Call) -> false.

%%----------------------------------------------------------------
%% @doc Called for every incoming request to be authorized or not.
%% @end
%%----------------------------------------------------------------
-spec sip_authorize(AuthList, Request, Call) -> Result when 
	    AuthList 	:: [ AuthData ],
		AuthData	:: dialog 
			| register 
			| {{digest, Realm}, boolean()},
	   	Request		:: nksip:request(),
		Call		:: nksip:call(),
		Realm		:: binary(),
		Result 		:: ok 
			| forbidden 
			| proxy_authenticate 
			| authenticate 
			| {authenticate, Realm} 
			| {proxy_authenticate, Realm} 
			| DefaultResult,
		DefaultResult :: ok.

sip_authorize(_AuthList, _Req, _Call) ->
    ok.
%%----------------------------------------------------------------
%% @doc This function is called by NkSIP for every new request, to check if it must be 
%% @end
%%----------------------------------------------------------------
-spec sip_route(Scheme, User, Domain, Request, Call) -> Result when
		Scheme		:: nksip:scheme(), 
		User		:: binary(), 
		Domain		:: binary(),
		Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result		:: proxy
			| process 
			| process_stateless 
			| {proxy, ruri} 
			| {proxy, UriSet} 
			| {proxy, ruri, OptsList} 
			| {proxy, UriSet, OptsList} 
			| {proxy_stateless, ruri} 
			| {proxy_stateless, UriSet} 
			| {proxy_stateless, ruri, OptsList} 
			| {proxy_stateless, UriSet, OptsList} 
			| {reply, SipReply} 
			| {reply_stateless, SipReply}
			| DefaultResult,
		UriSet 		:: nksip:uri_set(),
		SipReply 	:: nksip:sipreply(),
		OptsList 	:: nksip:optslist(),
		DefaultResult	:: process.

sip_route(_Scheme, _User, _Domain, _Req, _Call) ->
    process.

%%----------------------------------------------------------------
%% @doc Called when a OPTIONS request is received.
% 
%% ```DefaultResult = {reply, {ok, [contact, allow, allow_event, accept, supported]}}.'''
%
%% @end
%%----------------------------------------------------------------
-spec sip_options(Request, Call) -> Result when 
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply
			| {reply, nksip:sipreply()} 
			| DefaultResult,
		DefaultResult :: see_docs_on_this_function_for_default_results.

sip_options(_Req, _Call) ->
    {reply, {ok, [contact, allow, allow_event, accept, supported]}}.
    
%%----------------------------------------------------------------
%% @doc 
%%  This function is called by NkSIP to process a new incoming REGISTER request. 
%%
%% See also <A href="./nksip_callbacks.html#sip_invite-2">sip_invite(Request, Call)</A>
%%
%% See also <A href="./srv_id_dummy.html#cache_sip_allow-0">SrvId:cache_sip_allow()</A>
%% 
%% ```
%% Default Code  
%% ===================
%% sip_register(Req, _Call) ->
%%     {reply, {method_not_allowed, SrvId:cache_sip_allow()}}.'''
%% @end 
%%--------------------------------------------------------------------

-spec sip_register(Request, Call) -> Result when 
	    Request 	:: nksip:request(),
		Call 		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult	:: see_docs_on_this_function_for_default_results.

sip_register(_Req, Call) ->
	#call{srv_id=SrvId} = Call,
	Config = nksip_config:srv_config(SrvId),
	{reply, {method_not_allowed, Config#config.allow}}.


%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new INVITE request as an endpoint.
%%
%% See also <A href="./nksip_callbacks.html#sip_reinvite-2">sip_reinvite(Request, Call)</A>
%% @end
%%----------------------------------------------------------------
-spec sip_invite(Request, Call) -> Result when
	    Request 	:: nksip:request(),
		Call 		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult	:: {reply, decline}.

sip_invite(_Req, _Call) ->
    {reply, decline}.

%%----------------------------------------------------------------
%% @doc This function is called when a new in-dialog INVITE request is received.
%%
%%
% ```
% Default Code  
% ===================
% sip_reinvite(Request, Call) ->
%     {ok, SrvId} = nksip_request:srv_id(Req),
%     SrvId:sip_invite(Req, Call).  %%  Calls sip_invite(Request, Call) on the process that recieved the Request'''%% @end
%%----------------------------------------------------------------
-spec sip_reinvite(Request, Call) -> Result when
	    Request 	:: nksip:request(),
		Call 		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult	:: see_docs_on_this_function_for_default_results.

sip_reinvite(Req, Call) ->
    {ok, SrvId} = nksip_request:srv_id(Req),
    ?CALL_SRV(SrvId, sip_invite, [Req, Call]).

%%----------------------------------------------------------------
%% @doc Called when a pending INVITE request is cancelled.
%% @end
%%----------------------------------------------------------------
-spec sip_cancel(InviteReq, Request, Call) -> ok  when 
		InviteReq	:: nksip:request(),
		Request		:: nksip:request(),
		Call		:: nksip:call().

sip_cancel(_CancelledReq, _Req, _Call) ->
    ok.

%%----------------------------------------------------------------
%% @doc Called when a valid ACK request is received.
%% @end
%%----------------------------------------------------------------
-spec sip_ack(Request, Call) -> ok when
	    Request		:: nksip:request(),
		Call		:: nksip:call().

sip_ack(_Req, _Call) ->
    ok.

%%----------------------------------------------------------------
%% @doc Called when a valid BYE request is received.
%% @end
%%----------------------------------------------------------------
-spec sip_bye(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, ok}.
	
sip_bye(_Req, _Call) ->
    {reply, ok}.

%%----------------------------------------------------------------
%% @doc Called when a valid UPDATE request is received.
%% @end
%%----------------------------------------------------------------
-spec sip_update(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, decline}.

sip_update(_Req, _Call) ->
    {reply, decline}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new incoming SUBSCRIBE
%% @end
%%----------------------------------------------------------------
-spec sip_subscribe(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, decline}.

sip_subscribe(_Req, _Call) ->
    {reply, decline}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new in-subscription SUBSCRIBE
%% @end
%%----------------------------------------------------------------
-spec sip_resubscribe(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, ok}.

sip_resubscribe(_Req, _Call) ->
    {reply, ok}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new incoming NOTIFY
%% @end
%%----------------------------------------------------------------
-spec sip_notify(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, ok}.

sip_notify(_Req, _Call) ->
    {reply, ok}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new incoming REFER.
%% @end
%%----------------------------------------------------------------
-spec sip_refer(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, decline}.

sip_refer(_Req, _Call) ->
    {reply, decline}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new incoming PUBLISH request. 
%%
%% DefaultResult = {reply, {method_not_allowed, 
% 		<A href="./srv_id_dummy.html#cache_sip_allow-0">SrvId:cache_sip_allow()</A>}}.
%
% ```DefaultResult = {reply, {method_not_allowed,
% 		[ <<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
% 			<<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
% 			<<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">> ] } }'''
%
%% @end
%%----------------------------------------------------------------
-spec sip_publish(Request, Call) -> Result when
	    Request 	:: nksip:request(),
		Call 		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult	:: see_docs_on_this_function_for_default_result.
	
sip_publish(_Req, Call) ->
	#call{srv_id=SrvId} = Call,
	Config = nksip_config:srv_config(SrvId),
    {reply, {method_not_allowed, Config#config.allow}}.


%%----------------------------------------------------------------
%% @doc Called when a valid INFO request is received.
%% @end
%%----------------------------------------------------------------
-spec sip_info(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, ok}.

sip_info(_Req, _Call) ->
    {reply, ok}.

%%----------------------------------------------------------------
%% @doc This function is called by NkSIP to process a new incoming MESSAGE
%% @end
%%----------------------------------------------------------------
-spec sip_message(Request, Call) -> Result when
	    Request		:: nksip:request(),
		Call		:: nksip:call(),
		Result 		:: noreply 
			| {reply, nksip:sipreply()}
			| DefaultResult,
		DefaultResult :: {reply, decline}.

sip_message(_Req, _Call) ->
    {reply, decline}.

%%----------------------------------------------------------------
%% @doc Called when a dialog has changed its state.
%% @end
%%----------------------------------------------------------------
-spec sip_dialog_update(DialogStatus, Dialog, Call) -> ok when 
    DialogStatus :: start 
		| target_update 
		| stop 
		| InviteStatus 
		| InviteStatusStop 
		| InviteRefresh 
		| SubscribeStatus,
	Dialog :: nksip:dialog(),
	Call :: nksip:call(),
	InviteStatus :: {invite_status, nksip_dialog:invite_status()},
	InviteStatusStop :: {invite_status, {stop, nksip_dialog:stop_reason()}},
    InviteRefresh :: {invite_refresh, nksip_sdp:sdp()},
	SubscribeStatus :: {subscription_status, nksip_subscription:status(), nksip:subscription()}.
    
sip_dialog_update(_Status, _Dialog, _Call) ->
    ok.

%%----------------------------------------------------------------
%% @doc Called when a dialog has updated its SDP session parameters.
%% @end
%%----------------------------------------------------------------
-spec sip_session_update(SessionStatus, Dialog, Call) -> ok when 
        SessionStatus 	:: stop 
			| Start 
			| Update,
		Dialog			:: nksip:dialog(),
		Call			:: nksip:call(),
		Start 			:: {start, LocalSdp, RemoteSdp},
		Update 			:: {update, LocalSdp, RemoteSdp},
		LocalSdp		:: nksip_sdp:sdp(), 
		RemoteSdp		:: nksip_sdp:sdp().

sip_session_update(_Status, _Dialog, _Call) ->
    ok.




%% ===================================================================
%% Internal Callbacks
%% ===================================================================

%%----------------------------------------------------------------
%% @doc Allows to preparse the headers before parsing
%% @end
%%----------------------------------------------------------------
-spec nksip_preparse(nksip:request()|nksip:response(), [nksip:header()]) ->
	{ok, nksip:request()|nksip:response(), [nksip:header()]} | continue().

nksip_preparse(SipMsg, Headers) ->
	{ok, SipMsg, Headers}.



%%----------------------------------------------------------------
%% @doc This plugin callback function is used to call application-level 
%% Service callbacks.
%% @end
%%----------------------------------------------------------------
-spec nksip_user_callback( ServiceId, Function, Args ) -> Result when
            ServiceId 			:: nkserver:id(),
            Function 			:: atom(),
			Args 				:: list(),
			Result 				:: {ok, term()}
				| error 
				| continue().

nksip_user_callback(SrvId, Fun, Args) ->
	%lager:error("NKLOG CALLING ~p, ~p, ~p", [SrvId, Fun, Args]),
	case catch ?CALL_SRV(SrvId, Fun, Args) of
	    {'EXIT', Error} ->
	        ?CALL_LOG(error, "Error calling callback ~p/~p: ~p", [Fun, length(Args), Error]),
	        error;
	    Reply ->
	    	% ?CALL_LOG(warning, "Called ~p/~p (~p): ~p", [Fun, length(Args), Args, Reply], Call),
	    	% ?CALL_DEBUG("Called ~p/~p: ~p", [Fun, length(Args), Reply]),
	        {ok, Reply}
	end.


%%----------------------------------------------------------------
%% @doc This callback is called when the application use has implemented the
%% sip_authorize/3 callback, and a list with authentication tokens must be
%% generated
%% @end
%%----------------------------------------------------------------
-spec nksip_authorize_data( List, ReqTransaction, Call) -> Result when
				List 			:: list(), 
				ReqTransaction 	:: nksip_call:trans(),
				Call 			:: nksip_call:call(),
				Result 			:: {ok, list()} 
					| continue().

nksip_authorize_data(List, #trans{request=Req}, Call) ->
	Digest = nksip_auth:authorize_data(Req, Call),
	Dialog = case nksip_call_lib:check_auth(Req, Call) of
        true ->
			dialog;
        false ->
			[]
    end,
    {ok, lists:flatten([Digest, Dialog, List])}.

%%----------------------------------------------------------------
%% @doc Called after the UAC pre processes a response
%% @end
%%----------------------------------------------------------------
-spec nksip_uac_pre_response(Response, UacTransaction, Call) -> Result when
			Response 			:: nksip:response(),
			UacTransaction 		:: nksip_call:trans(), 
			Call 				:: nksip:call(),
			Result 				:: {ok, Call } 
				| continue().

nksip_uac_pre_response(Resp, UAC, Call) ->
    {continue, [Resp, UAC, Call]}.

%%----------------------------------------------------------------
%% @doc Called after the UAC processes a response
%% @end
%%----------------------------------------------------------------
-spec nksip_uac_response( Request, Response, UacTransaction, Call) -> Result when
			Request 			:: nksip:request(),
			Response 			:: nksip:response(),
			UacTransaction 		:: nksip_call:trans(), 
			Call 				:: nksip:call(),
			Result 				:: {ok, Call } 
				| continue().


nksip_uac_response(Req, Resp, UAC, Call) ->
    {continue, [Req, Resp, UAC, Call]}.

%%----------------------------------------------------------------
%% @doc Called to parse specific UAC options
%% @end
%%----------------------------------------------------------------
-spec nksip_parse_uac_opts( Request, OptionsList ) -> Result when
			Request 			:: nksip:request(),
			OptionsList 		:: [nksip_uac:req_option()],
			Result 				:: continue() | {error, term()}.

nksip_parse_uac_opts(Req, Opts) ->
	{continue, [Req, Opts]}.

%%----------------------------------------------------------------
%% @doc Called to add options for proxy UAC processing
%% @end
%%----------------------------------------------------------------
-spec nksip_uac_proxy_opts( Request, OptionsList ) -> Result when
			Request 			:: nksip:request(),
			OptionsList 		:: nksip:optslist(),
			Result 				:: {reply, Reply } 
				| continue(),
			Reply 				:: nksip:sipreply().

nksip_uac_proxy_opts(Req, ReqOpts) ->
	{continue, [Req, ReqOpts]}.

%%----------------------------------------------------------------
%% @doc Called when a new in-dialog request is being generated
%% @end
%%----------------------------------------------------------------
-spec nksip_make_uac_dialog( Method, Uri, OptionsList, Call) -> Result when
			Method 				:: nksip:method(),
			Uri 				:: nksip:uri(),
			OptionsList 		:: nksip:optslist(),
			Call 				:: nksip:call(),
			Result 				:: {continue, list()}.

nksip_make_uac_dialog(Method, Uri, Opts, Call) ->
	{continue, [Method, Uri, Opts, Call]}.

%%----------------------------------------------------------------
%% @doc Called when the UAC is preparing a request to be sent
%% @end
%%----------------------------------------------------------------
-spec nksip_uac_pre_request( Request, OptionsList, UacFrom, Call) -> Result when
			Request 			:: nksip:request(),
			OptionsList 		:: [nksip_uac:req_option()],
			UacFrom 			:: nksip_call_uac:uac_from(),
			Call 				:: nksip:call(),
			Result 				:: {continue, list()}.

nksip_uac_pre_request(Req, Opts, From, Call) ->
	{continue, [Req, Opts, From, Call]}.

%%----------------------------------------------------------------
%% @doc Called when the UAC transaction must send a reply to the user
%% @end
%%----------------------------------------------------------------
-spec nksip_uac_reply( Reply, UacTransaction, Call ) -> Result when
			Reply 				:: {req, Request} 
				| {resp, Response} 
				| {error, term()}, 
			Request 			:: nksip:request(),
			Response 			:: nksip:response(),
			UacTransaction 		:: nksip_call:trans(),
			Call 				:: nksip_call:call(),
			Result 				:: {ok, Call} 
				| {continue, list()}.

nksip_uac_reply(Class, UAC, Call) ->
    {continue, [Class, UAC, Call]}.

%%----------------------------------------------------------------
%% @doc Called to add headers just before sending the request
%% @end
%%----------------------------------------------------------------
-spec nksip_transport_uac_headers( Request, OptionsList, Scheme, Transport, Host, Port) -> Result when
			Request 			:: nksip:request(),
			OptionsList 		:: [nksip_uac:req_option()],
			Scheme 				:: nksip:scheme(),
			Transport 			:: nkpacket:transport(),
			Host 				:: binary(),
			Port 				:: inet:port_number(),
			Result 				:: {ok, Request}.

nksip_transport_uac_headers(Req, Opts, Scheme, Transp, Host, Port) ->
	Req2 = nksip_call_uac_transp:add_headers(Req, Opts, Scheme, Transp, Host, Port),
	{ok, Req2}.

%%----------------------------------------------------------------
%% @doc Called when a new reponse is going to be sent
%% @end
%%----------------------------------------------------------------
-spec nksip_uas_send_reply( ResponseData, UasTransaction, Call ) -> Result when
			ResponseData 		:: { Response, OptionsList },
			Response 			:: nksip:response(),
			OptionsList 		:: nksip:optslist(),
			UasTransaction		:: nksip_call:trans(), 
			Call  				:: nksip_call:call(),
			Result 				:: {error, term()} 
				| continue().

nksip_uas_send_reply({Resp, RespOpts}, UAS, Call) ->
	{continue, [{Resp, RespOpts}, UAS, Call]}.

%%----------------------------------------------------------------
%% @doc Called when a new reponse is sent
-spec nksip_uas_sent_reply( Call) -> Result when
			Call  			:: nksip_call:call(),
			Result 			:: {ok, Call } 
				| continue().

nksip_uas_sent_reply(Call) ->
	{continue, [Call]}.

%%----------------------------------------------------------------
%% @doc Called when a new request has to be processed
%% @end
%%----------------------------------------------------------------
-spec nksip_uas_method( Method, Request, UasTransaction, Call) -> Result when
			Method 			:: nksip:method(), 
			Request 		:: nksip:request(), 
			UasTransaction 	:: nksip_call:trans(), 
			Call 			:: nksip_call:call(),
			Result 			:: {ok, UasTransaction, Call} 
				| continue().

nksip_uas_method(Method, Req, UAS, Call) ->
	{continue, [Method, Req, UAS, Call]}.

%%----------------------------------------------------------------
%% @doc Called when a UAS timer is fired
%% @end
%%----------------------------------------------------------------
-spec nksip_uas_timer( Timer, UasTransaction, Call) -> Result when
			Timer 			:: nksip_call_lib:timer()
				| term(), 
			UasTransaction 	:: nksip_call:trans(), 
			Call 			:: nksip_call:call(),
			Result 			:: {ok, Call } 
				| continue().

nksip_uas_timer(Tag, UAS, Call) ->
	{continue, [Tag, UAS, Call]}.

%%----------------------------------------------------------------
%% @doc Called to parse specific UAS options
%% @end
%%----------------------------------------------------------------
-spec nksip_parse_uas_opt( Request, Response, OptionsList ) -> Result when
			Request 		:: nksip:request(),
			Response 		:: nksip:response(), 
			OptionsList 	:: nksip:optslist(),
			Result 			:: {error, term()} 
				| continue().

nksip_parse_uas_opt(Req, Resp, Opts) ->
	{continue, [Req, Resp, Opts]}.

%%----------------------------------------------------------------
%% @doc Called when preparing a UAS dialog response
%% @end
%%----------------------------------------------------------------
-spec nksip_uas_dialog_response( Request, Response, OptionsList, Call ) -> Result when
			Request 		:: nksip:request(),
			Response 		:: nksip:response(), 
			OptionsList 	:: nksip:optslist(),
			Call 			:: nksip:call(),
			Result 			:: {ok, Response, OptionsList}.

nksip_uas_dialog_response(_Req, Resp, Opts, _Call) ->
    {ok, Resp, Opts}.

%%----------------------------------------------------------------
%% @doc Called when the UAS is processing a request
%% @end
%%----------------------------------------------------------------
-spec nksip_uas_process( UasTransaction, Call) -> Result when
		UasTransaction 		:: nksip_call:trans(),
		Call 				:: nksip_call:call(),
		Result 				:: {ok, Call } 
			| {continue, list()}.

nksip_uas_process(UAS, Call) ->
	{continue, [UAS, Call]}.

%%----------------------------------------------------------------
%% @doc Called when a dialog must update its internal state
%% @end
%%----------------------------------------------------------------
-spec nksip_dialog_update( Type, Dialog, Call ) -> Result when
		Type 			:: term(),
		Dialog 			:: nksip:dialog(), 
		Call 			:: nksip_call:call(),
		Result 			:: {ok, Call } 
			| continue().

nksip_dialog_update(Type, Dialog, Call) ->
	{continue, [Type, Dialog, Call]}.

%%----------------------------------------------------------------
%% @doc Called when a proxy is preparing a routing
%% @end
%%----------------------------------------------------------------
-spec nksip_route( UriList, ProxyOptionsList, UasTransaction, Call) -> Result when
		UriList 			:: nksip:uri_set(), 
		ProxyOptionsList 	:: nksip:optslist(), 
		UasTransaction		:: nksip_call:trans(),
		Call 				:: nksip_call:call(),
		Result 				:: {continue, list()} 
			| {reply, SipReply, Call },
		SipReply 			:: nksip:sipreply().

nksip_route(UriList, ProxyOpts, UAS, Call) ->
	{continue, [UriList, ProxyOpts, UAS, Call]}.

%%----------------------------------------------------------------
%% @doc Called when a new message has been sent
%% @end
%%----------------------------------------------------------------
-spec nksip_connection_sent( RequestOrResponse, Packet ) -> Result when
		RequestOrResponse 	:: nksip:request()
			| nksip:response(), 
		Packet 				:: binary(),
		Result 				:: ok 
			| continue().

nksip_connection_sent(_SipMsg, _Packet) ->
	ok.


%%----------------------------------------------------------------
%% @doc Called when a new message has been received and parsed
%% @end
%%----------------------------------------------------------------
-spec nksip_connection_recv( RequestOrResponse, Packet ) -> Result when
		RequestOrResponse 	:: nksip:request()
			| nksip:response(), 
		Packet 				:: binary(),
		Result 				:: ok 
			| continue().

nksip_connection_recv(_SipMsg, _Packet) ->
	ok.


%%----------------------------------------------------------------
%% @doc Called when the transport has just sent a response
%% @end
%%----------------------------------------------------------------
-spec nksip_transport_uas_sent( Response ) -> Result when
		Response 	:: nksip:response(),
		Result 		:: ok 
			| continue().

nksip_transport_uas_sent(_Resp) ->
	ok.



%%----------------------------------------------------------------
%% @doc Called at specific debug points
%% @end
%%----------------------------------------------------------------
-spec nksip_debug( ServiceId, CallId, Info ) -> Result when
		ServiceId		:: nkserver:id(),
		CallId 			:: nksip:call_id(),
		Info 			:: term(),
		Result 			:: ok 
			| continue().

nksip_debug(_PkgId, _CallId, _Info) ->
    ok.

