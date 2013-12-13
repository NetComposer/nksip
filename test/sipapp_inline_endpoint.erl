%% -------------------------------------------------------------------
%%
%% sipapp_inline_endpoint: Inline Test Suite Endpoint
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

-module(sipapp_inline_endpoint).
-behaviour(nksip_sipapp).

-export([start/2, stop/1]).
-export([init/1, options/3, invite/3, reinvite/3, cancel/2, ack/3, bye/3, info/3]).
-export([dialog_update/2, session_update/2]).

-include("../include/nksip.hrl").


start(AppId, Opts) ->
    nksip:start(AppId, ?MODULE, [], Opts).

stop(AppId) ->
    nksip:stop(AppId).



%%%%%%%%% Inline functions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
    {ok, []}.

invite(Req, _Meta, From) ->
    send_reply(Req, invite),
    case nksip_sipmsg:header(Req, <<"Nk-Op">>) of
        [<<"wait">>] ->
            spawn(
                fun() ->
                    nksip_request:reply(Req, ringing),
                    timer:sleep(1000),
                    nksip:reply(From, ok)
                end),
            async;
        _ ->
            {ok, [], nksip_sipmsg:field(Req, body)}
    end.

reinvite(Req, _Meta, _From) ->
    send_reply(Req, reinvite),
    {ok, [], nksip_sipmsg:field(Req, body)}.

cancel(Req, _Meta) ->
    send_reply(Req, cancel),
    ok.

bye(Req, _Meta, _From) ->
    send_reply(Req, bye),
    ok.

info(Req, _Meta, _From) ->
    send_reply(Req, info),
    ok.

ack(Req, _Meta, _From) ->
    send_reply(Req, ack),
    ok.

options(Req, _Meta, From) ->
    send_reply(Req, options),
    spawn(
        fun() ->
            [Server] = nksip_sipmsg:header(Req, <<"Nk-Id">>),
            {inline, Id} = nksip_sipmsg:field(Req, app_id),
            Reply = {ok, [{<<"Nk-Id">>, nksip_lib:bjoin([Server, Id])}]},
            nksip:reply(From, Reply)
        end),
    async.

dialog_update(Dialog, State) ->
    case State of
        start -> send_reply(Dialog, dialog_start);
        stop -> send_reply(Dialog, dialog_stop);
        _ -> ok
    end.

session_update(Dialog, State) ->
    case State of
        {start, _, _} -> send_reply(Dialog, session_start);
        stop -> send_reply(Dialog, session_stop);
        _ -> ok
    end.



%%%%%%%%%%% Util %%%%%%%%%%%%%%%%%%%%


send_reply(Elem, Msg) ->
    AppId = case Elem of
        #sipmsg{} -> nksip_sipmsg:field(Elem, app_id);
        #dialog{} -> nksip_dialog:field(Elem, app_id);
        _ -> lager:error("ELEM: ~p", [Msg]), error(a)
    end,
    case nksip_config:get(inline_test) of
        {Ref, Pid} -> Pid ! {Ref, {AppId, Msg}};
        _ -> ok
    end.


