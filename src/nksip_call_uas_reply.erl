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

%% @doc Call UAS Management: Reply
-module(nksip_call_uas_reply).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([reply/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Sends a transaction reply
-spec reply(nksip:sipreply()|{nksip:response(), nksip_lib:proplist()}, 
                  nksip_call:trans(), nksip_call:call()) ->
    {{ok, nksip:response()} | {error, invalid_call}, nksip_call:call()}.

reply(Reply, #trans{method='ACK', id=Id, status=Status}=UAS, Call) ->
    ?call_notice("UAC ~p 'ACK' (~p) trying to send a reply ~p", 
                 [Id, Status, Reply], Call),
    UAS1 = UAS#trans{status=finished},
    {{error, invalid_call}, nksip_call_lib:update(UAS1, Call)};

reply(Reply, #trans{status=Status, method=Method}=UAS, Call)
          when Status=:=authorize; Status=:=route ->
    UAS1 = case Method of
        'INVITE' -> UAS#trans{status=invite_proceeding};
        _ -> UAS#trans{status=trying}
    end,
    reply(Reply, UAS1, nksip_call_lib:update(UAS1, Call));

reply({#sipmsg{class={resp, Code, _Reason}, id=MsgId}=Resp, SendOpts}, 
           #trans{status=Status, code=LastCode}=UAS, 
           #call{msgs=Msgs}=Call)
           when Status=:=invite_proceeding orelse 
                Status=:=trying orelse 
                Status=:=proceeding orelse
                (
                    (
                        Status=:=invite_accepted orelse 
                        Status=:=invite_confirmed orelse
                        Status=:=completed
                    ) andalso (
                        Code>=200 andalso Code<300 andalso 
                        LastCode>=200 andalso LastCode<300
                    )
                ) ->

    #trans{
        id = Id, 
        opts = Opts,
        method = Method,
        request = Req,
        stateless = Stateless,
        code = LastCode
    } = UAS,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    DialogId = nksip_dialog:class_id(uas, Resp),
    Resp1 = Resp#sipmsg{dialog_id=DialogId},
    case nksip_transport_uas:send_response(Resp1, GlobalId, SendOpts++AppOpts) of
        {ok, Resp2} -> ok;
        error -> {Resp2, _} = nksip_reply:reply(Req, service_unavailable)
    end,
    #sipmsg{class={resp, Code1, _Reason}} = Resp2,
    Call1 = case Req of
        #sipmsg{} when Code1>=200, Code<300 ->
            nksip_call_lib:update_auth(DialogId, Req, Call);
        _ ->
            Call
    end,
    Call2 = case lists:member(no_dialog, Opts) of
        true -> Call1;
        false -> nksip_call_uas_dialog:response(Req, Resp2, Call1)
    end,
    UAS1 = case LastCode < 200 of
        true -> UAS#trans{response=Resp2, code=Code};
        false -> UAS
    end,
    Msg = {MsgId, Id, DialogId},
    Call3 = Call2#call{msgs=[Msg|Msgs]},
    case Stateless of
        true when Method=/='INVITE' ->
            ?call_debug("UAS ~p ~p stateless reply ~p", 
                        [Id, Method, Code1], Call3),
            UAS2 = UAS1#trans{status=finished},
            UAS3 = nksip_call_lib:cancel_timers([timeout], UAS2),
            {{ok, Resp2}, nksip_call_lib:update(UAS3, Call3)};
        _ ->
            ?call_debug("UAS ~p ~p stateful reply ~p", 
                        [Id, Method, Code1], Call3),
            UAS2 = stateful_reply(Status, Code1, UAS1, Call3),
            {{ok, Resp2}, nksip_call_lib:update(UAS2, Call3)}
    end;

reply({#sipmsg{class={resp, Code, _Reason}}, _}, #trans{code=LastCode}=UAS, Call) ->
    #trans{status=Status, id=Id, method=Method} = UAS,
    ?call_info("UAS ~p ~p cannot send ~p response in ~p (last code was ~p)", 
               [Id, Method, Code, Status, LastCode], Call),
    {{error, invalid_call}, Call};

reply(SipReply, #trans{request=#sipmsg{}=Req}=UAS, Call) ->
    reply(nksip_reply:reply(Req, SipReply), UAS, Call);

reply(SipReply, #trans{id=Id, method=Method, status=Status}, Call) ->
    ?call_info("UAS ~p ~p cannot send ~p response in ~p (no stored request)", 
               [Id, Method, SipReply, Status], Call),
    {{error, invalid_call}, Call}.



%% @private
-spec stateful_reply(nksip_call_uas:status(), nksip:response_code(), 
                     nksip_call:trans(), nksip_call:call()) ->
    nksip_call:trans().

stateful_reply(invite_proceeding, Code, UAS, Call) when Code < 200 ->
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS),
    nksip_call_lib:timeout_timer(timer_c, UAS1, Call);

stateful_reply(invite_proceeding, Code, UAS, Call) when Code < 300 ->
    #trans{id=Id, request=Req, response=Resp, app_timer=AppTimer} = UAS,
    UAS1 = case Id < 0 of
        true -> 
            % In old-style transactions, save Id to be used in
            % detecting ACKs
            #sipmsg{to_tag=ToTag} = Resp,
            ACKTrans = nksip_call_uas:transaction_id(Req#sipmsg{to_tag=ToTag}),
            UAS#trans{ack_trans_id=ACKTrans};
        _ ->
            UAS
    end,
    % If the invite/3 call has not returned, maintain values
    UAS2 = case AppTimer of
        undefined -> UAS1#trans{request=undefined, response=undefined};
        _ -> UAS1
    end,
    UAS3 = nksip_call_lib:cancel_timers([timeout, expire], UAS2),
    % RFC6026 accepted state, to wait for INVITE retransmissions
    % Dialog will send 2xx retransmissionshrl
    UAS4 = UAS3#trans{status=invite_accepted},
    nksip_call_lib:timeout_timer(timer_l, UAS4, Call);

stateful_reply(invite_proceeding, Code, UAS, Call) when Code >= 300 ->
    #trans{proto=Proto, app_timer=AppTimer} = UAS,
    UAS1 = UAS#trans{status=invite_completed},
    UAS2 = nksip_call_lib:cancel_timers([timeout, expire], UAS1),
    UAS3 = case AppTimer of
        undefined -> UAS2#trans{request=undefined};
        _ -> UAS2
    end,
    UAS4 = nksip_call_lib:timeout_timer(timer_h, UAS3, Call),
    case Proto of 
        udp -> nksip_call_lib:retrans_timer(timer_g, UAS4, Call);
        _ -> UAS4#trans{response=undefined}
    end;

stateful_reply(trying, Code, UAS, Call) ->
    stateful_reply(proceeding, Code, UAS#trans{status=proceeding}, Call);

stateful_reply(proceeding, Code, UAS, _Call) when Code < 200 ->
    UAS;

stateful_reply(proceeding, Code, UAS, Call) when Code >= 200 ->
    #trans{proto=Proto, app_timer=AppTimer} = UAS,
    UAS1 = UAS#trans{request=undefined, status=completed},
    UAS2 = nksip_call_lib:cancel_timers([timeout], UAS1),
    case Proto of
        udp -> 
            UAS3 = case AppTimer of
                undefined ->  UAS2#trans{request=undefined};
                _ -> UAS2
            end,
            nksip_call_lib:timeout_timer(timer_j, UAS3, Call);
        _ -> 
            UAS2#trans{status=finished}
    end;

stateful_reply(_, _Code, UAS, _Call) ->
    UAS.

