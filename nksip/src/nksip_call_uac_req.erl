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

%% @doc Call UAC Management: Request sending
-module(nksip_call_uac_req).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/4, resend_auth/3]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type uac_from() :: none | {srv, from()} | {fork, nksip_call_fork:id()}.


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Starts a new UAC transaction.
-spec request(nksip:request(), nksip_lib:proplist(), uac_from(), nksip_call:call()) ->
    nksip_call:call().

request(Req, Opts, From, Call) ->
    #sipmsg{method=Method, id=MsgId} = Req,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req, GlobalId, AppOpts)
    end,
    {#trans{id=Id}=UAC, Call1} = new_uac(Req1, Opts, From, Call),
    case lists:member(async, Opts) andalso From of
        {srv, SrvFrom} when Method=:='ACK' -> 
            gen_server:reply(SrvFrom, async);
        {srv, SrvFrom} ->
            gen_server:reply(SrvFrom, {async, MsgId});
        _ ->
            ok
    end,
    case From of
        {fork, ForkId} ->
            ?call_debug("UAC ~p sending request ~p ~p (~s, fork: ~p)", 
                        [Id, Method, Opts, MsgId, ForkId], Call);
        _ ->
            ?call_debug("UAC ~p sending request ~p ~p (~s)", 
                        [Id, Method, Opts, MsgId], Call)
    end,
    send(Method, UAC, Call1).


%% @private
-spec resend_auth(nksip:request(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

resend_auth(Req, UAC, Call) ->
     #trans{
        id = Id,
        status = Status,
        opts = Opts,
        method = Method, 
        iter = Iter,
        from = From
    } = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    #sipmsg{vias=[_|Vias]} = Req,
    ?call_debug("UAC ~p ~p (~p) resending authorized request", 
                [Id, Method, Status], Call),
    {CSeq, Call1} = nksip_call_uac_dialog:new_local_seq(Req, Call),
    Req1 = Req#sipmsg{vias=Vias, cseq=CSeq},
    Req2 = nksip_transport_uac:add_via(Req1, GlobalId, AppOpts),
    Opts1 = nksip_lib:delete(Opts, make_contact),
    {NewUAC, Call2} = new_uac(Req2, Opts1, From, Call1),
    NewUAC1 = NewUAC#trans{iter=Iter+1},
    send(Method, NewUAC1, update(NewUAC1, Call2)).
    

%% @private
-spec new_uac(nksip:request(), nksip_lib:proplist(), uac_from(), nksip_call:call()) ->
    {nksip_call:trans(), nksip_call:call()}.

new_uac(Req, Opts, From, Call) ->
    #sipmsg{id=MsgId, method=Method, ruri=RUri} = Req, 
    #call{next=Id, trans=Trans, msgs=Msgs} = Call,
    Status = case Method of
        'ACK' -> ack;
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    UAC = #trans{
        id = Id,
        class = uac,
        status = Status,
        start = nksip_lib:timestamp(),
        from = From,
        opts = Opts,
        trans_id = nksip_call_uac:transaction_id(Req),
        request = Req,
        method = Method,
        ruri = RUri,
        response = undefined,
        code = 0,
        to_tags = [],
        cancel = undefined,
        iter = 1
    },
    Msg = {MsgId, Id, nksip_dialog:id(Req)},
    {UAC, Call#call{trans=[UAC|Trans], msgs=[Msg|Msgs], next=Id+1}}.


% @private
-spec send(nksip:method(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

send('ACK', UAC, Call) ->
    #trans{id=Id, request=Req, opts=Opts} = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    case nksip_transport_uac:send_request(Req, GlobalId, Opts++AppOpts) of
       {ok, SentReq} ->
            ?call_debug("UAC ~p sent 'ACK' request", [Id], Call),
            Call1 = nksip_call_uac_reply:reply({req, SentReq}, UAC, Call),
            Call2 = case lists:member(no_dialog, Opts) of
                true -> Call1;
                false -> nksip_call_uac_dialog:ack(SentReq, Call1)
            end,
            UAC1 = UAC#trans{status=finished, request=SentReq},
            update(UAC1, Call2);
        error ->
            ?call_debug("UAC ~p error sending 'ACK' request", [Id], Call),
            Call1 = nksip_call_uac_reply:reply({error, network_error}, UAC, Call),
            UAC1 = UAC#trans{status=finished},
            update(UAC1, Call1)
    end;

send(_, UAC, Call) ->
    #trans{method=Method, id=Id, request=Req, opts=Opts} = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    DialogResult = case lists:member(no_dialog, Opts) of
        true -> {ok, Call};
        false -> nksip_call_uac_dialog:request(Req, Call)
    end,
    case DialogResult of
        {ok, Call1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req, Opts++AppOpts);
                _ -> nksip_transport_uac:send_request(Req, GlobalId, Opts++AppOpts)
            end,
            case Send of
                {ok, SentReq} ->
                    ?call_debug("UAC ~p sent ~p request", [Id, Method], Call),
                    Call2 = nksip_call_uac_reply:reply({req, SentReq}, UAC, Call1),
                    #sipmsg{transport=#transport{proto=Proto}} = SentReq,
                    UAC1 = UAC#trans{request=SentReq, proto=Proto},
                    UAC2 = sent_method(Method, UAC1, Call2),
                    update(UAC2, Call2);
                error ->
                    ?call_debug("UAC ~p error sending ~p request", 
                                [Id, Method], Call),
                    Call2 = nksip_call_uac_reply:reply({error, network_error}, 
                                                       UAC, Call1),
                    update(UAC#trans{status=finished}, Call2)
            end;
        {error, finished} ->
            Call1 = nksip_call_uac_reply:reply({error, unknown_dialog}, UAC, Call),
            update(UAC#trans{status=finished}, Call1);
        {error, request_pending} ->
            Call1 = nksip_call_uac_reply:reply({error, request_pending}, UAC, Call),
            update(UAC#trans{status=finished}, Call1)
    end.


%% @private 
-spec sent_method(nksip:method(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:trans().

sent_method('INVITE', #trans{proto=Proto}=UAC, Call) ->
    UAC1 = UAC#trans{status=invite_calling},
    UAC2 = nksip_call_lib:expire_timer(expire, UAC1, Call),
    UAC3 = nksip_call_lib:timeout_timer(timer_b, UAC2, Call),
    case Proto of 
        udp -> nksip_call_lib:retrans_timer(timer_a, UAC3, Call);
        _ -> UAC3
    end;

sent_method(_Other, #trans{proto=Proto}=UAC, Call) ->
    UAC1 = UAC#trans{status=trying},
    UAC2 = nksip_call_lib:timeout_timer(timer_f, UAC1, Call),
    case Proto of 
        udp -> nksip_call_lib:retrans_timer(timer_e, UAC2, Call);
        _ -> UAC2
    end.
    

