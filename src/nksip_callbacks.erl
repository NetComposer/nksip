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
-export([app_call/3, app_method/2]).


%% @private
-spec app_call(atom(), list(), nksip:app_id()) ->
	ok | error.

app_call(Fun, Args, AppId) ->
	case catch apply(AppId, Fun, Args) of
	    {'EXIT', Error} -> 
	        ?call_error("Error calling callback ~p/~p: ~p", [Fun, length(Args), Error]),
	        error;
	    Reply ->
	    	% ?call_warning("Called ~p/~p (~p): ~p", [Fun, length(Args), Args, Reply]),
	    	% ?call_debug("Called ~p/~p: ~p", [Fun, length(Args), Reply]),
	        {ok, Reply}
	end.


%% @private
app_method(#trans{method='ACK', request=Req}, #call{app_id=AppId}=Call) ->
	case catch AppId:sip_ack(Req, Call) of
		ok -> ok;
		Error -> ?call_error("Error calling callback ack/1: ~p", [Error])
	end,
	noreply;

app_method(#trans{method=Method, request=Req}, #call{app_id=AppId}=Call) ->
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












% callback1() ->
% 	io:format("NKSIP: CALLBACK1\n"),
%     ok1.

% callback2(A) ->
% 	io:format("NKSIP: CALLBACK2(~p)\n", [A]),
%     A.

% callback3(A, B, C) ->
% 	io:format("NKSIP: CALLBACK3(~p, ~p, ~p)\n", [A, B, C]),
% 	{A,B,C}.
