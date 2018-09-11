%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Call UAS Management
-module(nksip_call_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/2, reply/3, do_reply/3]).
-export_type([status/0, incoming/0]).
-dialyzer(no_missing_calls).

-import(nksip_call_lib, [update/2]).
-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type status() ::  
    invite_proceeding | invite_accepted | invite_completed | invite_confirmed | 
    trying | proceeding | completed | 
    ack | finished.

-type incoming() :: 
    nksip:sipreply() | {nksip:response(), nksip:optslist()}.


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Called when a new request is received.
-spec request(nksip:request(), nksip_call:call()) ->
    nksip_call:call().

request(Req, Call) -> 
    case is_trans_ack(Req, Call) of
        {true, InvUAS} -> 
            process_trans_ack(InvUAS, Call);
        false ->
            case is_retrans(Req, Call) of
                {true, UAS} ->
                    process_retrans(UAS, Call);
                {false, ReqTransId} ->
                    case is_own_ack(Req) of
                        true ->
                            Call;
                        false ->
                            process_request(Req, ReqTransId, Call)
                    end
            end
    end.


%% @private Checks if `Req' is an ACK matching an existing transaction
%% (for a non 2xx responses, ACK is in the same transaction as the INVITE)
-spec is_trans_ack(nksip:request(), nksip_call:call()) ->
    {true, nksip_call:trans()} | false.

is_trans_ack(#sipmsg{class={req, 'ACK'}}=Req, #call{trans=Trans}) ->
    TransReq = Req#sipmsg{class={req, 'INVITE'}},
    ReqTransId = nksip_call_lib:uas_transaction_id(TransReq),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=InvUAS -> 
            {true, InvUAS};
        false when ReqTransId < 0 ->
            % Pre-RFC3261 style
            case lists:keyfind(ReqTransId, #trans.ack_trans_id, Trans) of
                #trans{}=InvUAS -> 
                    {true, InvUAS};
                false -> 
                    false
            end;
        false ->
            false
    end;

is_trans_ack(_, _) ->
    false.


%% @private
-spec process_trans_ack(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

process_trans_ack(InvUAS, Call) ->
    #trans{id=_Id, status=Status, transp=Transp} = InvUAS,
    case Status of
        invite_completed ->
            InvUAS1 = InvUAS#trans{response=undefined},
            InvUAS2 = nksip_call_lib:retrans_timer(cancel, InvUAS1, Call),
            InvUAS4 = case Transp of 
                udp -> 
                    InvUAS3 = InvUAS2#trans{status=invite_confirmed},
                    nksip_call_lib:timeout_timer(timer_i, InvUAS3, Call);
                _ ->
                    InvUAS3 = InvUAS2#trans{status=finished},
                    nksip_call_lib:timeout_timer(cancel, InvUAS3, Call)
            end,
            ?CALL_DEBUG("InvUAS ~p received in-transaction ACK", [_Id], Call),
            update(InvUAS4, Call);
        invite_confirmed ->
            ?CALL_DEBUG("InvUAS ~p received non 2xx ACK in ~p", [_Id, Status], Call),
            Call;
        _ ->
            ?CALL_LOG(notice, "InvUAS ~p received non 2xx ACK in ~p", [_Id, Status], Call),
            Call
    end.


%% @private Checks if request is a retransmission
-spec is_retrans(nksip:request(), nksip_call:call()) ->
    {true, nksip_call:trans()} | {false, integer()}.

is_retrans(Req, #call{trans=Trans}) ->
    ReqTransId = nksip_call_lib:uas_transaction_id(Req),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> 
            {true, UAS};
        _ -> 
            {false, ReqTransId}
    end.


%% @private
-spec process_retrans(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

process_retrans(UAS, Call) ->
    #trans{id=_Id, status=Status, method=_Method, response=Resp} = UAS,
    case 
        Status==invite_proceeding orelse Status==invite_completed
        orelse Status==proceeding orelse Status==completed
    of
        true when is_record(Resp, sipmsg) ->
            #sipmsg{class={resp, _Code, _Reason}} = Resp,
            case nksip_call_uas_transp:resend_response(Resp, []) of
                {ok, _} ->
                    ?CALL_LOG(info, "UAS ~p ~p (~p) sending ~p retransmission",
                               [_Id, _Method, Status, _Code], Call);
                {error, _} ->
                    ?CALL_LOG(notice, "UAS ~p ~p (~p) could not send ~p retransmission",
                                  [_Id, _Method, Status, _Code], Call)
            end;
        _ ->
            ?CALL_LOG(info, "UAS ~p ~p received retransmission in ~p",
                       [_Id, _Method, Status], Call)
    end,
    Call.


%% @doc Returns true if the request is an ACK to a [3456]xx response generated
%% automatically by NkSIP
-spec is_own_ack(nksip:request()) ->
    boolean().

is_own_ack(#sipmsg{class={req, 'ACK'}}=Req) ->
    #sipmsg{
        to = {_, ToTag},
        vias = [#via{opts=ViaOpts}|_]
    } = Req,
    Branch = nklib_util:get_binary(<<"branch">>, ViaOpts),
    GlobalId = nksip_config:get_config(global_id),
    nklib_util:hash({GlobalId, Branch}) == ToTag;

is_own_ack(_) ->
    false.


%% @private
-spec process_request(nksip:request(), nksip_call:trans_id(), nksip_call:call()) ->
    nksip_call:call().

process_request(Req, UASTransId, Call) ->
    Req1 = preprocess(Req),
    #sipmsg{
        class = {req, Method}, 
        id = MsgId, 
        ruri = RUri, 
        nkport = NkPort, 
        to = {_, ToTag}
    } = Req1,

    #call{
        trans = Trans, 
        next = NextId, 
        msgs = Msgs
    } = Call,
    ?CALL_DEBUG("UAS ~p started for ~p (~s)", [NextId, Method, MsgId], Call),
    LoopId = loop_id(Req1),
    DialogId = nksip_dialog_lib:make_id(uas, Req1),
    Status = case Method of
        'INVITE' ->
            invite_proceeding;
        'ACK' ->
            ack;
        _ ->
            trying
    end,
    {ok, {_, Transp, _, _}} = nkpacket:get_local(NkPort),
    UAS = #trans{
        id = NextId,
        class = uas,
        status = Status,
        start = nklib_util:timestamp(),
        from = undefined,
        opts = [],
        trans_id = UASTransId, 
        request = Req1#sipmsg{dialog_id=DialogId},
        method = Method,
        ruri = RUri,
        transp = Transp,
        response = undefined,
        code = 0,
        to_tags = [],
        stateless = true,
        iter = 1,
        cancel = undefined,
        loop_id = LoopId,
        timeout_timer = undefined,
        retrans_timer = undefined,
        next_retrans = undefined,
        expire_timer = undefined,
        ack_trans_id = undefined,
        meta = []
    },
     UAS1 = case Method of
        'INVITE' -> 
            nksip_call_lib:timeout_timer(timer_c, UAS, Call);
        'ACK' -> 
            UAS;
        _ -> 
            nksip_call_lib:timeout_timer(noinvite, UAS, Call)
    end,
    Msg = {MsgId, NextId, DialogId},
    Call1 = Call#call{trans=[UAS1|Trans], next=NextId+1, msgs=[Msg|Msgs]},
    case ToTag==(<<>>) andalso lists:keymember(LoopId, #trans.loop_id, Trans) of
        true -> 
            do_reply(loop_detected, UAS1, Call1);
        false -> 
            nksip_call_uas_route:launch(UAS1, Call1)
    end.


%% @doc Sends a transaction reply
-spec reply(incoming(), nksip_call:trans(), nksip_call:call()) ->
    {ok | {error, term()}, nksip_call:call()}.

reply(Reply, Trans, Call) ->
    nksip_call_uas_reply:reply(Reply, Trans, Call).


%% @doc Sends a transaction reply
-spec do_reply(incoming(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_reply(Reply, Trans, Call) ->
    {_, Call1} = nksip_call_uas_reply:reply(Reply, Trans, Call),
    Call1.



%% ===================================================================
%% Utils
%% ===================================================================

%% @private
-spec loop_id(nksip:request()) ->
    integer().
    
loop_id(#sipmsg{from={_, FromTag}, cseq={CSeq, Method}}) ->
    erlang:phash2({FromTag, CSeq, Method}).


%% @doc Preprocess an incoming request.
%%  - Adds rport, received and transport options to Via.
%%  - Generates a To Tag candidate.
%%  - Performs strict routing processing.
%%  - Updates the request if maddr is present.
%%  - Removes first route if it is poiting to us.
-spec preprocess(nksip:request()) ->
    nksip:request().

preprocess(Req) ->
    #sipmsg{
        to = {_, ToTag},
        nkport = NkPort, 
        vias = [Via|ViaR]
    } = Req,
    {ok, {_, Transp, Ip, Port}} = nkpacket:get_remote(NkPort),
    Received = nklib_util:to_host(Ip, false), 
    ViaOpts1 = [{<<"received">>, Received}|Via#via.opts],
    % For UDP, we honor the rport option
    % For connection transports, we force inclusion of remote port 
    % to reuse the same connection
    ViaOpts2 = case lists:member(<<"rport">>, ViaOpts1) of
        false when Transp==udp -> 
            ViaOpts1;
        _ -> 
            [{<<"rport">>, nklib_util:to_binary(Port)} | ViaOpts1 -- [<<"rport">>]]
    end,
    Via1 = Via#via{opts=ViaOpts2},
    Branch = nklib_util:get_binary(<<"branch">>, ViaOpts2),
    GlobalId = nksip_config:get_config(global_id),
    ToTag1 = case ToTag of
        <<>> -> 
            nklib_util:hash({GlobalId, Branch});
        _ -> 
            ToTag
    end,
    Req1 = Req#sipmsg{
        vias = [Via1|ViaR], 
        to_tag_candidate = ToTag1
    },
    Req2 = strict_router(Req1),
    ruri_has_maddr(Req2).


%% @private If the Request-URI has a value we have placed on a Record-Route header, 
%% change it to the last Route header and remove it. This gets back the original 
%% RUri "stored" at the end of the Route header when proxing through a strict router
%% This could happen if
%% - in a previous request, we added a Record-Route header with our ip
%% - the response generated a dialog
%% - a new in-dialog request has arrived from a strict router, that copied our Record-Route
%%   in the ruri
%%
%% TODO: Is this working?
strict_router(#sipmsg{srv_id=SrvId, ruri=RUri, routes=Routes}=Request) ->
    case
        nklib_util:get_value(<<"nksip">>, RUri#uri.opts) /= undefined 
        andalso nksip_util:is_local(SrvId, RUri) of
    true ->
        case lists:reverse(Routes) of
            [] ->
                Request;
            [RUri1|RestRoutes] ->
                ?CALL_LOG(notice, "recovering RURI from strict router request", []),
                Request#sipmsg{ruri=RUri1, routes=lists:reverse(RestRoutes)}
        end;
    false ->
        Request
    end.    


%% @private If RUri has a maddr address that corresponds to a local ip and has the 
% same transport class and local port than the transport, change the Ruri to
% this address, default port and no transport parameter
ruri_has_maddr(Request) ->
    #sipmsg{
        srv_id = SrvId,
        ruri = RUri,
        nkport = NkPort
    } = Request,
    {ok, {_, Transp, _, LPort}} = nkpacket:get_local(NkPort),
    case nklib_util:get_binary(<<"maddr">>, RUri#uri.opts) of
        <<>> ->
            Request;
        MAddr -> 
            case nksip_util:is_local(SrvId, RUri#uri{domain=MAddr}) of
                true ->
                    case nksip_parse:transport(RUri) of
                        {Transp, _, LPort} ->
                            RUri1 = RUri#uri{
                                port = 0,
                                opts = nklib_util:delete(RUri#uri.opts, 
                                                        [<<"maddr">>, <<"transport">>])
                            },
                            Request#sipmsg{ruri=RUri1};
                        _ ->
                            Request
                    end;
                false ->
                    Request
            end
    end.


