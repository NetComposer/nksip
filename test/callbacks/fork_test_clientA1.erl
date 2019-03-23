%% -------------------------------------------------------------------
%%
%% fork_test: Forking Proxy Suite Test
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

-module(fork_test_clientA1).

-include_lib("nkserver/include/nkserver_module.hrl").

-export([sip_invite/2, sip_ack/2, sip_bye/2, sip_options/2]).


% Adds x-nk-id header
% Gets operation from body
sip_invite(Req, _Call) ->
    tests_util:save_ref(Req),
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([?MODULE|Ids])}],
    case nksip_request:body(Req) of
        {ok, Ops} when is_list(Ops) ->
            {ok, ReqId} = nksip_request:get_handle(Req),
            proc_lib:spawn(
                fun() ->
                    case nklib_util:get_value(?MODULE, Ops) of
                        {redirect, Contacts} ->
                            Code = 300,
                            nksip_request:reply({redirect, Contacts}, ReqId);
                        Code when is_integer(Code) -> 
                            case Code of
                                200 -> nksip_request:reply({ok, Hds}, ReqId);
                                _ -> nksip_request:reply({Code, Hds}, ReqId)
                            end;
                        {Code, Wait} when is_integer(Code), is_integer(Wait) ->
                            nksip_request:reply(ringing, ReqId),
                            timer:sleep(Wait),
                            case Code of
                                200 -> nksip_request:reply({ok, Hds}, ReqId);
                                _ -> nksip_request:reply({Code, Hds}, ReqId)
                            end;
                        _ -> 
                            Code = 580,
                            nksip_request:reply({580, Hds}, ReqId)
                    end,
                    tests_util:send_ref(Code, Req)
                end),
            noreply;
        {ok, _} ->
            {reply, {500, Hds}}
    end.


sip_ack(Req, _Call) ->
    tests_util:send_ref(ack, Req),
    ok.


sip_options(Req, _Call) ->
    {ok, Ids} = nksip_request:header(<<"x-nk-id">>, Req),
    Hds = [{add, "x-nk-id", nklib_util:bjoin([?MODULE|Ids])}],
    {reply, {ok, [contact|Hds]}}.


sip_bye(Req, _Call) ->
    tests_util:send_ref(bye, Req),
    {reply, ok}.

