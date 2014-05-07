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

%% @private Call UAC Management: Reply
-module(nksip_call_uac_reply).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([reply/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec reply(req | resp | {error, term()}, nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply({req, Req}, #trans{from={srv, From}, method='ACK', opts=Opts}, Call) ->
    Async = lists:member(async, Opts),
    Get = lists:member(get_request, Opts),
    CB = nksip_lib:get_value(callback, Opts),
    case Get andalso is_function(CB, 1) of
        true -> call(CB, {req, Req});
        false -> ok
    end,
    case Async of
        true when is_function(CB, 1), not Get -> call(CB, ok);
        true -> ok;
        false -> gen_server:reply(From, ok)
    end,
    Call;

reply({req, Req}, #trans{from={srv, _From}, opts=Opts}, Call) ->
    Get = lists:member(get_request, Opts),
    CB = nksip_lib:get_value(callback, Opts),
    case Get andalso is_function(CB, 1) of
        true -> call(CB, {req, Req});
        false -> ok
    end,
    Call;

reply({resp, Resp}, #trans{from={srv, From}, opts=Opts}, Call) ->
    #sipmsg{class={resp, Code, Reason}} = Resp,
    case nksip_lib:get_value(refer_subscription_id, Opts) of
        undefined -> 
            ok;
        SubsId ->
            Sipfrag = <<
                "SIP/2.0 ", (nksip_lib:to_binary(Code))/binary, 32,
                Reason/binary
            >>,
            NotifyOpts = [
                async, 
                {content_type, <<"message/sipfrag;version=2.0">>}, 
                {body, Sipfrag},
                {state, 
                    case Code>=200 of 
                        true -> {terminated, noresource}; 
                        false -> active
                    end}
            ],
            nksip_uac:notify(SubsId, NotifyOpts)
    end,
    Async = lists:member(async, Opts),
    % Get = lists:member(get_response, Opts),
    CB = nksip_lib:get_value(callback, Opts),
    if
        Code<101 -> ok;
        Code<200, is_function(CB, 1) -> call(CB, {ok, Code, Resp});
        % Code<200, Get, is_function(CB, 1) -> call(CB, {resp, Resp});
        % Code<200, is_function(CB, 1) -> CB({resp, response(UAC, Call)});
        Code<200 -> ok;
        Async, is_function(CB, 1) -> call(CB, {ok, Code, Resp});
        % Async, Get, is_function(CB, 1) -> call(CB, {resp, Resp});
        % Async, is_function(CB, 1) -> CB({resp, response(UAC, Call)});
        Async -> ok;
        true -> gen_server:reply(From, response(Resp, Opts))
    end,
    Call;

reply({error, Error}, #trans{from={srv, From}, opts=Opts}, Call) ->
    Async = lists:member(async, Opts),
    CB = nksip_lib:get_value(callback, Opts),
    if
        Async, is_function(CB, 1) -> call(CB, {error, Error});
        Async -> ok;
        true -> gen_server:reply(From, {error, Error})
    end,
    Call;

reply({req, _}, #trans{from={fork, _}}, Call) ->
    Call;

reply({resp, Resp}, #trans{id=Id, from={fork, ForkId}}, Call) ->
    nksip_call_fork:response(ForkId, Id, Resp, Call);

reply({error, Error}, #trans{id=Id, from={fork, ForkId}, request=Req}, Call) ->
    Reply = case nksip_reply:parse(Error) of
        error -> 
            ?call_notice("Invalid proxy internal response: ~p", [Error]),
            {internal_error, <<"Invalid Internal Proxy UAC Response">>};
        {ErrCode, ErrOpts} ->
            {ErrCode, ErrOpts}
    end,
    {Resp, _} = nksip_reply:reply(Req, Reply),
    % nksip_call_fork:response() is going to discard first Via
    Resp1 = Resp#sipmsg{vias=[#via{}|Resp#sipmsg.vias]},
    nksip_call_fork:response(ForkId, Id, Resp1, Call);

reply(_, #trans{from=none}, Call) ->
    Call.


%% @private
call(CB, Arg) ->
    case catch CB(Arg) of
        {'EXIT', Error} -> ?call_warning("Error calling callback function: ~p", [Error]);
        _ -> ok
    end.


%% @private
response(Resp, Opts) ->
    #sipmsg{class={resp, Code, _}, cseq={_, Method}}=Resp,
    Fields0 = case Method of
        'INVITE' when Code>100, Code<300 -> 
            [{dialog_id, nksip_dialog:get_id(Resp)}];
        'SUBSCRIBE' when Code>=200, Code<300 -> 
            [{subscription_id, nksip_subscription:get_id(Resp)}];
        'REFER' when Code>=200, Code<300 -> 
            [{subscription_id, nksip_subscription:get_id(Resp)}];
        'PUBLISH' when Code>=200, Code<300 ->
            Expires = nksip_sipmsg:meta(expires, Resp),
            case nksip_sipmsg:header(<<"sip-etag">>, Resp) of
                [SipETag] -> [{sip_etag, SipETag}, {expires, Expires}];
                _ -> []
            end;
        _ -> 
            []
    end,
    Values = case nksip_lib:get_value(meta, Opts, []) of
        [] ->
            Fields0;
        Fields when is_list(Fields) ->
            Fields0 ++ [{Field, nksip_sipmsg:meta(Field, Resp)} || Field <- Fields];
        _ ->
            Fields0
    end,
    {ok, Code, Values}.

