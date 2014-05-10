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

%% @doc SipApp Tutorial client callback module implementation.
%% This modules implements a client callback module for NkSIP Tutorial.

-module(nksip_tutorial_sipapp_client).
-behaviour(nksip_sipapp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/1, sip_invite/4, sip_options/4]).

%% ===================================================================
%% Callbacks
%% ===================================================================

-record(state, {
    id
}).

%% @doc SipApp intialization.
init([Id]) ->
    {ok, #state{id=Id}}.


%% @doc Called when an INVITE is received.
%% If the request has a SDP body, reply 180 Ringing, wait 2 seconds and reply 
%% 200 Ok with the same body (spawns a new process to avoid blocking the process).
%% If not, reply 488 Not Acceptable with a Warning header.
sip_invite(ReqId, Meta, From, State) ->
    SDP = nksip_lib:get_value(body, Meta),
    case nksip_sdp:is_sdp(SDP) of
        true ->
            Fun = fun() ->
                nksip_request:reply(ringing, ReqId),
                timer:sleep(2000),
                nksip:reply(From, {answer, SDP})
            end,
            spawn(Fun),
            {noreply, State};
        false ->
            {reply, {not_acceptable, <<"Invalid SDP">>}, State}
    end.


%% @doc Called when an OPTIONS is received.
%% Reply 200 Ok with a custom header and some options.
sip_options(_ReqId, _Meta, _From, #state{id=Id}=State) ->
    Headers = [{"x-nk-id", Id}],
    Opts = [contact, allow, accept, supported],
    {reply, {ok, Headers, <<>>, Opts}, State}.


