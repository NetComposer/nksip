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

%% @doc Call UAS Management
-module(nksip_call_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/2, fork_reply/3, send_reply/4, timer/3]).
-export([terminate_request/2, transaction_id/1]).
-export_type([status/0, id/0]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-type status() ::  authorize | route | ack |
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed | finished.

-type id() :: integer().

-type trans() :: nksip_call:trans().

-type call() :: nksip_call:call().


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Called when a new request is received.
-spec request(nksip:request(), call()) ->
    #call{}.

request(Req, #call{opts=#call_opts{global_id=GlobalId}}=Call) -> 
    case is_trans_ack(Req, Call) of
        {true, UAS} -> 
            process_trans_ack(UAS, Call);
        false ->
            case is_retrans(Req, Call) of
                {true, UAS} ->
                    process_retrans(UAS, Call);
                {false, ReqTransId} ->
                    case nksip_uas_lib:preprocess(Req, GlobalId) of
                        own_ack -> 
                            Call;
                        Req1 -> 
                            nksip_call_uas_request:request(Req1, ReqTransId, Call)
                    end
            end
    end.



%% @private
-spec process_trans_ack(trans(), call()) ->
    call().

process_trans_ack(UAS, Call) ->
    #trans{id=Id, status=Status, proto=Proto} = UAS,
    case Status of
        invite_completed ->
            UAS1 = UAS#trans{response=undefined},
            UAS2 = nksip_call_lib:cancel_timers([retrans, timeout], UAS1),
            UAS4 = case Proto of 
                udp -> 
                    UAS3 = UAS2#trans{status=invite_confirmed},
                    nksip_call_lib:timeout_timer(timer_i, UAS3, Call);
                _ ->
                    UAS2#trans{status=finished}
            end,
            ?call_debug("UAS ~p received in-transaction ACK", [Id], Call),
            update(UAS4, Call);
        _ ->
            ?call_notice("UAS ~p received non 2xx ACK in ~p", [Id, Status], Call),
            Call
    end.


%% @private
-spec process_retrans(trans(), call()) ->
    call().

process_retrans(UAS, Call) ->
    #trans{id=Id, status=Status, method=Method, response=Resp} = UAS,
    case 
        Status=:=invite_proceeding orelse Status=:=invite_completed
        orelse Status=:=proceeding orelse Status=:=completed
    of
        true when is_record(Resp, sipmsg) ->
            #sipmsg{response=Code} = Resp,
            #call{opts=#call_opts{app_opts=Opts}} = Call,
            case nksip_transport_uas:resend_response(Resp, Opts) of
                {ok, _} ->
                    ?call_info("UAS ~p ~p (~p) sending ~p retransmission", 
                               [Id, Method, Status, Code], Call);
                error ->
                    ?call_notice("UAS ~p ~p (~p) could not send ~p retransmission", 
                                  [Id, Method, Status, Code], Call)
            end;
        _ ->
            ?call_info("UAS ~p ~p received retransmission in ~p", 
                       [Id, Method, Status], Call)
    end,
    Call.



%% ===================================================================
%% App/Fork reply
%% ===================================================================


%% @private Called by a fork when it has a response available.
-spec fork_reply(id(), {nksip:response(), nksip_lib:proplist()}, call()) ->
    call().

fork_reply(TransId, Reply, #call{trans=Trans}=Call) ->
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            nksip_call_uas_reply:reply(Reply, UAS, Call);
        _ ->
            ?call_debug("Unknown UAS ~p received fork reply",
                        [TransId], Call),
            Call
    end.


% @doc Sends a syncrhonous request reply
-spec send_reply(nksip:sipreply(), trans(), {srv, from()}|none, call()) ->
    call().

send_reply(Reply, UAS, From, Call) ->
    {Result, Call1} = nksip_call_uas_reply:send_reply(Reply, UAS, Call),
    case From of
        {srv, SrvFrom} -> gen_server:reply(SrvFrom, Result);
        _ -> ok
    end,
    Call1.



%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), trans(), call()) ->
    call().

timer(timer_c, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p Timer C fired", [Id, Method], Call),
    nksip_call_uas_reply:reply({timeout, <<"Timer C Timeout">>}, UAS, Call);

timer(noinvite, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p No-INVITE timer fired", [Id, Method], Call),
    nksip_call_uas_reply:reply({timeout, <<"No-INVITE Timeout">>}, UAS, Call);

% INVITE 3456xx retrans
timer(timer_g, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{response=Code} = Resp,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    UAS1 = case nksip_transport_uas:resend_response(Resp, Opts) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", 
                       [Id, Code], Call),
            nksip_call_lib:retrans_timer(timer_g, UAS, Call);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p response", 
                         [Id, Code], Call),
            nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished})
    end,
    update(UAS1, Call);

% INVITE accepted finished
timer(timer_l, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer L fired", [Id], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE confirmed finished
timer(timer_i, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% NoINVITE completed finished
timer(timer_j, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_debug("UAS ~p ~p Timer J fired", [Id, Method], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE completed timeout
timer(timer_h, #trans{id=Id}=UAS, Call) ->
    ?call_notice("UAS ~p 'INVITE' timeout (Timer H) fired, no ACK received", 
                [Id], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:cancel_timers([timeout, retrans], UAS1),
    update(UAS2, Call);

timer(expire, #trans{id=Id, method=Method, status=Status}=UAS, Call) ->
    ?call_debug("UAS ~p ~p (~p) Timer Expire fired: sending 487",
                [Id, Method, Status], Call),
    terminate_request(UAS, Call);

timer(Timer, #trans{id=Id, method=Method}=UAS, Call)
      when Timer=:=authorize; Timer=:=route; Timer=:=invite; Timer=:=bye;
           Timer=:=options; Timer=:=register ->
    UAS1 = nksip_call_lib:cancel_timers([app], UAS),
    ?call_notice("UAS ~p ~p timeout, no SipApp response", [Id, Method], Call),
    Msg = {internal_error, <<"No SipApp Response">>},
    nksip_call_uas_reply:reply(Msg, UAS1, update(UAS1, Call)).



%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec terminate_request(trans(), call()) ->
    call().

terminate_request(#trans{status=Status, from=From}=UAS, Call) ->
    if 
        Status=:=authorize; Status=:=route ->
            case From of
                {fork, _ForkId} -> ok;
                _ -> app_cast(cancel, [], UAS, Call)
            end,
            UAS1 = UAS#trans{cancel=cancelled},
            Call1 = update(UAS1, Call),
            nksip_call_uas_reply:reply(request_terminated, UAS1, Call1);
        Status=:=invite_proceeding ->
            case From of
                {fork, ForkId} -> 
                    nksip_call_fork:cancel(ForkId, Call);
                _ ->  
                    app_cast(cancel, [], UAS, Call),
                    UAS1 = UAS#trans{cancel=cancelled},
                    Call1 = update(UAS1, Call),
                    nksip_call_uas_reply:reply(request_terminated, UAS1, Call1)
            end;
        true ->
            Call
    end.


%% @private
-spec app_cast(atom(), list(), trans(), call()) ->
    call().

app_cast(Fun, Args, UAS, Call) ->
    #trans{id=Id, method=Method, status=Status, request=Req} = UAS,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    ?call_debug("UAS ~p ~p (~p) casting SipApp's ~p", 
                [Id, Method, Status, Fun], Call),
    Args1 = Args ++ [Req],
    Args2 = Args ++ [Req#sipmsg.id],
    nksip_sipapp_srv:sipapp_cast(AppId, Module, Fun, Args1, Args2),
    Call.


%% @doc Checks if `Req' is an ACK matching an existing transaction
%% (for a non 2xx response)
-spec is_trans_ack(nksip:request(), call()) ->
    {true, trans()} | false.

is_trans_ack(#sipmsg{method='ACK'}=Req, #call{trans=Trans}) ->
    ReqTransId = transaction_id(Req#sipmsg{method='INVITE'}),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> 
            {true, UAS};
        false when ReqTransId < 0 ->
            % Pre-RFC3261 style
            case lists:keyfind(ReqTransId, #trans.ack_trans_id, Trans) of
                #trans{}=UAS -> {true, UAS};
                false -> false
            end;
        false ->
            false
    end;

is_trans_ack(_, _) ->
    false.


%% @doc Checks if `Req' is a retransmission
-spec is_retrans(nksip:request(), call()) ->
    {true, trans()} | {false, integer()}.

is_retrans(Req, #call{trans=Trans}) ->
    ReqTransId = transaction_id(Req),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas}=UAS -> {true, UAS};
        _ -> {false, ReqTransId}
    end.


%% @private
-spec transaction_id(nksip:request()) ->
    integer().
    
transaction_id(Req) ->
        #sipmsg{
            app_id = AppId, 
            ruri = RUri, 
            method = Method,
            from_tag = FromTag, 
            to_tag = ToTag, 
            vias = [Via|_], 
            call_id = CallId, 
            cseq = CSeq
        } = Req,
    {_Transp, ViaIp, ViaPort} = nksip_parse:transport(Via),
    case nksip_lib:get_value(branch, Via#via.opts) of
        <<"z9hG4bK", Branch/binary>> ->
            erlang:phash2({AppId, CallId, Method, ViaIp, ViaPort, Branch});
        _ ->
            % pre-RFC3261 style
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            -erlang:phash2({AppId, UriIp, UriPort, FromTag, ToTag, CallId, CSeq, 
                            Method, ViaIp, ViaPort})
    end.





