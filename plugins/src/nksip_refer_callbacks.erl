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

%% @doc NkSIP REFER Plugin Callbacks
-module(nksip_refer_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").


-export([nks_parse_uac_opts/2, nks_sip_method/2, nks_call/3, nks_uac_reply/3]).


%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%


%% @doc Called to parse specific UAC options
-spec nks_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {error, term()}|{continue, list()}.

nks_parse_uac_opts(Req, Opts) ->
    case lists:keyfind(refer_subscription_id, 1, Opts) of
        {refer_subscription_id, Refer} when is_binary(Refer) ->
            {continue, [Req, Opts]};
        {refer_subscription_id, _} ->
            {error, {invalid_config, refer_subscription_id}};
        false ->
            {continue, [Req, Opts]} 
    end.


%% @private This plugin callback is called when a call to one of the method specific
%% application-level SipApp callbacks is needed.
-spec nks_sip_method(nksip_call:trans(), nksip_call:call()) ->
    {reply, nksip:sipreply()} | noreply.

nks_sip_method(#trans{method='REFER', request=Req}, #call{app_id=AppId}=Call) ->
    Module = AppId:module(),
    case 
        Module/=nksip_sipapp andalso
        erlang:function_exported(Module, sip_refer, 2) 
    of
        true ->
            continue;
        false ->
            {reply, nksip_refer:process(Req, Call)}
    end;

nks_sip_method(#trans{method='SUBSCRIBE', request=Req}, _Call) ->
    case Req#sipmsg.event of
        {<<"refer">>, [{<<"id">>, _ReferId}]} ->
            {reply, ok};
        _ ->
            continue
    end;

nks_sip_method(#trans{method='NOTIFY', request=Req}, Call) ->
    case Req#sipmsg.event of
        {<<"refer">>, [{<<"id">>, _ReferId}]} ->
            {ok, Body} = nksip_request:body(Req),
            SubsHandle = nksip_subscription_lib:get_handle(Req),
            #call{app_id=AppId} = Call,
            catch AppId:sip_refer_update(SubsHandle, {notify, Body}, Call),
            {reply, ok};
        _ ->
            continue
    end;


nks_sip_method(_Trans, _Call) ->
    continue.


%% @doc This plugin callback function is used to call application-level 
%% SipApp callbacks.
-spec nks_call(atom(), list(), nksip:app_id()) ->
    continue.

nks_call(sip_dialog_update, 
          [
            {
                subscription_status, 
                Status, 
                {user_subs, #subscription{event={<<"refer">>, _}}, _}=Subs
            }, 
            _Dialog, Call
          ], 
          _AppId) ->
    #call{app_id=AppId} = Call,
    {ok, SubsId} = nksip_subscription:get_handle(Subs),
    Status1 = case Status of
        init -> init;
        active -> active;
        middle_timer -> middle_timer;
        {terminated, _} -> terminated
    end,
    catch AppId:sip_refer_update(SubsId, Status1, Call),
    continue;

nks_call(_, _, _) ->
    continue.



    %% @doc Called when the UAC must send a reply to the user
-spec nks_uac_reply({req, nksip:request()} | {resp, nksip:response()} | {error, term()}, 
                     nksip_call:trans(), nksip_call:call()) ->
    {ok, nksip:call()} | {continue, list()}.

nks_uac_reply({resp, Resp}, #trans{from={srv, _}, opts=Opts}=UAC, Call) ->
    #sipmsg{class={resp, Code, Reason}} = Resp,
    case nklib_util:get_value(refer_subscription_id, Opts) of
        undefined -> 
            ok;
        SubsId ->
            Sipfrag = <<
                "SIP/2.0 ", (nklib_util:to_binary(Code))/binary, 32,
                Reason/binary
            >>,
            NotifyOpts = [
                async, 
                {content_type, <<"message/sipfrag;version=2.0">>}, 
                {body, Sipfrag},
                {subscription_state, 
                    case Code>=200 of 
                        true -> {terminated, noresource}; 
                        false -> active
                    end}
            ],
            nksip_uac:notify(SubsId, NotifyOpts)
    end,
    {continue, [{resp, Resp}, UAC, Call]};

nks_uac_reply(Class, UAC, Call) ->
    {continue, [Class, UAC, Call]}.

