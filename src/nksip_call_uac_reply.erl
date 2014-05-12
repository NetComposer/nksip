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
    CB = nksip_lib:get_value(callback, Opts),
    Async = lists:member(async, Opts),
    case 
        is_function(CB, 1) andalso 
        (Async orelse lists:member(get_request, Opts))
    of
        true -> call(CB, {req, Req, Call});
        false -> ok
    end,
    case Async of
        true -> ok;
        false -> gen_server:reply(From, ok)
    end,
    Call;

reply({req, Req}, #trans{from={srv, _From}, opts=Opts}, Call) ->
    CB = nksip_lib:get_value(callback, Opts),
    case is_function(CB, 1) andalso lists:member(get_request, Opts) of
        true -> call(CB, {req, Req, Call});
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
                {subscription_state, 
                    case Code>=200 of 
                        true -> {terminated, noresource}; 
                        false -> active
                    end}
            ],
            nksip_uac:notify(SubsId, NotifyOpts)
    end,
    CB = nksip_lib:get_value(callback, Opts),
    Async = lists:member(async, Opts),
    case 
        is_function(CB, 1) andalso Code>100 andalso 
        (Code<200 orelse Async)
    of
        true -> call(CB, {resp, Code, Resp, Call});
        false -> ok
    end,
    case Async of
        false when Code>=200 -> gen_server:reply(From, response(Resp, Opts));
        _ -> ok
    end,
    Call;

reply({error, Error}, #trans{from={srv, From}, opts=Opts}, Call) ->
    CB = nksip_lib:get_value(callback, Opts),
    Async = lists:member(async, Opts),
    case is_function(CB, 1) andalso Async of
        true -> call(CB, {error, Error});
        false -> ok
    end,
    case Async of
        true -> ok;
        false -> gen_server:reply(From, {error, Error})
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
        {'EXIT', Error} -> 
            ?call_warning("Error calling UAC callback function: ~p", [Error]);
        _ -> 
            ok
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

