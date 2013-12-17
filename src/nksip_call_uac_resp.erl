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

%% @doc Call UAC Management: Response processing
-module(nksip_call_uac_resp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([response/2]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MAX_AUTH_TRIES, 5).


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Called when a new response is received.
-spec response(nksip:response(), nksip_call:call()) ->
    nksip_call:call().

response(Resp, #call{trans=Trans}=Call) ->
    #sipmsg{class={resp, Code, _Reason}, cseq_method=Method} = Resp,
    TransId = nksip_call_uac:transaction_id(Resp),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uac, from=From}=UAC -> 
            IsProxy = case From of {fork, _} -> true; _ -> false end,
            DialogId = nksip_call_uac_dialog:uac_id(Resp, IsProxy, Call),
            Resp1 = Resp#sipmsg{dialog_id=DialogId},
            case is_prack_retrans(Resp1, UAC) of
                true ->
                    ?call_info("UAC received retransmission of reliable provisional "
                               "response", [], Call),
                    Call;
                false ->
                    response(Resp1, UAC, Call)
            end;
        _ -> 
            ?call_info("UAC received ~p ~p response for unknown request", 
                       [Method, Code], Call),
            Call
    end.


%% @private
-spec response(nksip:response(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

response(Resp, UAC, Call) ->
    #sipmsg{
        class = {resp, Code, _Reason}, 
        id = MsgId, 
        dialog_id = DialogId,
        transport = Transport
    } = Resp,
    #trans{
        id = Id, 
        start = Start, 
        status = Status,
        opts = Opts,
        method = Method,
        request = Req, 
        ruri = RUri
    } = UAC,
    #call{msgs=Msgs, opts=#call_opts{app_opts=AppOpts, max_trans_time=MaxTime}} = Call,
    Now = nksip_lib:timestamp(),
    case Now-Start < MaxTime of
        true -> 
            Code1 = Code,
            Resp1 = Resp#sipmsg{ruri=RUri, dialog_id=DialogId};
        false -> 
            Code1 = 408,
            Reply = {timeout, <<"Transaction Timeout">>},
            {Resp1, _} = nksip_reply:reply(Req, Reply, AppOpts)
    end,
    Call1 = case Code1>=200 andalso Code1<300 of
        true -> nksip_call_lib:update_auth(DialogId, Resp1, Call);
        false -> Call
    end,
    UAC1 = UAC#trans{response=Resp1, code=Code1},
    Call2 = update(UAC1, Call1),
    NoDialog = lists:member(no_dialog, Opts),
    case Transport of
        undefined -> 
            ok;    % It is own-generated
        _ -> 
            ?call_debug("UAC ~p ~p (~p) ~sreceived ~p", 
                        [Id, Method, Status, 
                         if NoDialog -> "(no dialog) "; true -> "" end, Code1], Call1)
    end,
    Call3 = case NoDialog of
        true -> Call2;
        false -> nksip_call_uac_dialog:response(Req, Resp1, Call2)
    end,
    Call4 = case 
        Code>=300 andalso (Method=='SUBSCRIBE' orelse Method=='REFER')
    of
        true -> nksip_call_event:remove_event(Req, Call3);
        false -> Call3
    end,
    Msg = {MsgId, Id, DialogId},
    Call5 = Call4#call{msgs=[Msg|Msgs]},
    Call6 = response_status(Status, Resp1, UAC1, Call5),
    check_prack(Resp, UAC1, Call6).


%% @private
-spec response_status(nksip_call_uac:status(), nksip:response(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

response_status(invite_calling, Resp, UAC, Call) ->
    UAC1 = UAC#trans{status=invite_proceeding},
    UAC2 = nksip_call_lib:retrans_timer(cancel, UAC1, Call),
    response_status(invite_proceeding, Resp, UAC2, Call);

response_status(invite_proceeding, Resp, #trans{code=Code}=UAC, Call) 
                   when Code < 200 ->
    #trans{cancel=Cancel} = UAC,
    % Add another 3 minutes
    UAC1 = nksip_call_lib:timeout_timer(timer_c, UAC, Call),
    Call1 = nksip_call_uac_reply:reply({resp, Resp}, UAC1, Call),
    case Cancel of
        to_cancel -> nksip_call_uac:cancel(UAC1, undefined, update(UAC1, Call1));
        _ -> update(UAC1, Call1)
    end;


% Final 2xx response received
% Enters new RFC6026 'invite_accepted' state, to absorb 2xx retransmissions
% and forked responses
response_status(invite_proceeding, Resp, #trans{code=Code, opts=Opts}=UAC, Call) 
                   when Code < 300 ->
    #sipmsg{to_tag=ToTag, dialog_id=DialogId} = Resp,
    Call1 = nksip_call_uac_reply:reply({resp, Resp}, UAC, Call),
    UAC1 = UAC#trans{
        cancel = undefined,
        status = invite_accepted, 
        response = undefined,       % Leave the request in case a new 2xx 
        to_tags = [ToTag]           % response is received
    },
    UAC2 = nksip_call_lib:expire_timer(cancel, UAC1, Call1),
    UAC3 = nksip_call_lib:timeout_timer(timer_m, UAC2, Call),
    Call2 = update(UAC3, Call1),
    case lists:member(auto_2xx_ack, Opts) of
        true -> send_2xx_ack(DialogId, Call2);
        false -> Call2
    end;


% Final [3456]xx response received, own error response
response_status(invite_proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = nksip_call_uac_reply:reply({resp, Resp}, UAC, Call),
    UAC1 = UAC#trans{status=finished, cancel=undefined},
    UAC2 = nksip_call_lib:timeout_timer(cancel, UAC1, Call),
    UAC3 = nksip_call_lib:expire_timer(cancel, UAC2, Call),
    update(UAC3, Call1);


% Final [3456]xx response received, real response
response_status(invite_proceeding, Resp, UAC, Call) ->
    #sipmsg{to=To, to_tag=ToTag} = Resp,
    #trans{request=Req, proto=Proto} = UAC,
    UAC1 = UAC#trans{
        request = Req#sipmsg{to=To, to_tag=ToTag}, 
        response = undefined, 
        to_tags = [ToTag], 
        cancel = undefined
    },
    UAC2 = nksip_call_lib:timeout_timer(cancel, UAC1, Call),
    UAC3 = nksip_call_lib:expire_timer(cancel, UAC2, Call),
    send_ack(UAC3, Call),
    UAC5 = case Proto of
        udp -> 
            UAC4 = UAC3#trans{status=invite_completed},
            nksip_call_lib:timeout_timer(timer_d, UAC4, Call);
        _ -> 
            UAC3#trans{status=finished}
    end,
    do_received_auth(Req, Resp, UAC5, update(UAC5, Call));


response_status(invite_accepted, _Resp, #trans{code=Code}, Call) 
                   when Code < 200 ->
    Call;

response_status(invite_accepted, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, status=Status, to_tags=ToTags} = UAC,
    case ToTags of
        [ToTag|_] ->
            ?call_debug("UAC ~p (~p) received ~p retransmission",
                        [Id, Status, Code], Call),
            Call;
        _ ->
            do_received_hangup(Resp, UAC, Call)
    end;

response_status(invite_completed, Resp, UAC, Call) ->
    #sipmsg{class={resp, RespCode, _Reason}, to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, to_tags=ToTags} = UAC,
    case ToTags of 
        [ToTag|_] ->
            case RespCode of
                Code ->
                    send_ack(UAC, Call);
                _ ->
                    ?call_info("UAC ~p (invite_completed) ignoring new ~p response "
                               "(previous was ~p)", [Id, RespCode, Code], Call)
            end,
            Call;
        _ ->  
            do_received_hangup(Resp, UAC, Call)
    end;

response_status(trying, Resp, UAC, Call) ->
    UAC1 = UAC#trans{status=proceeding},
    UAC2 = nksip_call_lib:retrans_timer(cancel, UAC1, Call),
    response_status(proceeding, Resp, UAC2, Call);

response_status(proceeding, #sipmsg{class={resp, Code, _Reason}}=Resp, UAC, Call) 
                   when Code < 200 ->
    nksip_call_uac_reply:reply({resp, Resp}, UAC, Call);

% Final response received, own error response
response_status(proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = nksip_call_uac_reply:reply({resp, Resp}, UAC, Call),
    UAC1 = UAC#trans{status=finished},
    UAC2 = nksip_call_lib:timeout_timer(cancel, UAC1, Call),
    update(UAC2, Call1);

% Final response received, real response
response_status(proceeding, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{proto=Proto, request=Req} = UAC,
    UAC2 = case Proto of
        udp -> 
            UAC1 = UAC#trans{
                status = completed, 
                request = undefined, 
                response = undefined,
                to_tags = [ToTag]
            },
            nksip_call_lib:timeout_timer(timer_k, UAC1, Call);
        _ -> 
            UAC1 = UAC#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAC1, Call)
    end,
    do_received_auth(Req, Resp, UAC2, update(UAC2, Call));

response_status(completed, Resp, UAC, Call) ->
    #sipmsg{class={resp, Code, _Reason}, cseq_method=Method, to_tag=ToTag} = Resp,
    #trans{id=Id, to_tags=ToTags} = UAC,
    case ToTags of
        [ToTag|_] ->
            ?call_info("UAC ~p ~p (completed) received ~p retransmission", 
                       [Id, Method, Code], Call),
            Call;
        _ ->
            ?call_info("UAC ~p ~p (completed) received new ~p response", 
                       [Id, Method, Code], Call),
            UAC1 = case lists:member(ToTag, ToTags) of
                true -> UAC;
                false -> UAC#trans{to_tags=ToTags++[ToTag]}
            end,
            update(UAC1, Call)
    end.


%% @private
-spec do_received_hangup(nksip:response(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_received_hangup(Resp, UAC, Call) ->
    #sipmsg{id=_RespId, to_tag=ToTag, dialog_id=DialogId} = Resp,
    #trans{id=Id, code=Code, status=Status, to_tags=ToTags} = UAC,
    #call{app_id=AppId} = Call,
    UAC1 = case lists:member(ToTag, ToTags) of
        true -> UAC;
        false -> UAC#trans{to_tags=ToTags++[ToTag]}
    end,
    case Code < 300 of
        true ->
            ?call_info("UAC ~p (~p) sending ACK and BYE to secondary response " 
                       "(dialog ~s)", [Id, Status, DialogId], Call),
            spawn(
                fun() ->
                    case nksip_uac:ack(AppId, DialogId, []) of
                        ok ->
                            case nksip_uac:bye(AppId, DialogId, []) of
                                {ok, 200, []} ->
                                    ok;
                                ByeErr ->
                                    ?call_notice("UAC ~p could not send BYE: ~p", 
                                               [Id, ByeErr], Call)
                            end;
                        AckErr ->
                            ?call_notice("UAC ~p could not send ACK: ~p", 
                                       [Id, AckErr], Call)
                    end
                end);
        false ->       
            ?call_info("UAC ~p (~p) received new ~p response",
                        [Id, Status, Code], Call)
    end,
    update(UAC1, Call).


%% @private 
-spec do_received_auth(nksip:request(), nksip:response(), 
                       nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_received_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = Id,
        opts = Opts,
        method = Method, 
        code = Code, 
        iter = Iter,
        from = From
    } = UAC,
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    IsFork = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code==401 orelse Code==407) andalso Iter < ?MAX_AUTH_TRIES
        andalso Method/='CANCEL' andalso (not IsFork) andalso
        nksip_auth:make_request(Req, Resp, Opts++AppOpts) 
    of
        false ->
            nksip_call_uac_reply:reply({resp, Resp}, UAC, Call);
        {ok, Req1} ->
            nksip_call_uac_req:resend_auth(Req1, UAC, Call);
        {error, Error} ->
            ?call_debug("UAC ~p could not generate new auth request: ~p", 
                        [Id, Error], Call),    
            nksip_call_uac_reply:reply({resp, Resp}, UAC, Call)
    end.


%% @private
-spec send_ack(nksip_call:trans(), nksip_call:call()) ->
    ok.

send_ack(#trans{request=Req, id=Id}, Call) ->
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    Ack = nksip_uac_lib:make_ack(Req),
    case nksip_transport_uac:resend_request(Ack, Opts) of
        {ok, _} -> 
            ok;
        error -> 
            #sipmsg{app_id=AppId, call_id=CallId} = Ack,
            ?notice(AppId, CallId, "UAC ~p could not send non-2xx ACK", [Id])
    end.


%% @private
-spec send_2xx_ack(nksip_dialog:id(), nksip_call:call()) ->
    nksip_call:call().

send_2xx_ack(DialogId, Call) ->
    #call{app_id=AppId, call_id=CallId, opts=CallOpts} = Call,
    #call_opts{app_opts=AppOpts} = CallOpts,
    case nksip_call_uac_dialog:make(DialogId, 'ACK', [async], Call) of
        {ok, {RUri, Opts1}, Call1} -> 
            Opts2 = [{call_id, CallId} | Opts1],
            case nksip_uac_lib:make(AppId, 'ACK', RUri, Opts2, AppOpts) of
                {ok, Req, ReqOpts} -> 
                    nksip_call_uac_req:request(Req, ReqOpts, none, Call1);
                {error, Error} ->
                    ?call_warning("Could not generate 2xx ACK: ~p", [Error], Call),
                    Call1
            end;
        {error, Error} ->
            ?call_warning("Could not generate 2xx ACK: ~p", [Error], Call),
            Call
    end.


%% @private
-spec is_prack_retrans(nksip:response(), nksip_call:trans()) ->
    boolean().

is_prack_retrans(Resp, UAC) ->
    #sipmsg{dialog_id=DialogId, cseq=CSeq, cseq_method=Method} = Resp,
    #trans{pracks=PRAcks} = UAC,
    case nksip_sipmsg:header(Resp, <<"RSeq">>, integers) of
        [RSeq] when is_integer(RSeq) ->
            lists:member({RSeq, CSeq, Method, DialogId}, PRAcks);
        _ ->
            false
    end.


%% @private
-spec check_prack(nksip:response(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_prack(Resp, UAC, Call) ->
    #sipmsg{
        class = {resp, Code, _Reason}, 
        dialog_id = DialogId,
        require = Require
    } = Resp,
    #trans{
        id = Id, 
        from = From,
        method = Method
    } = UAC,
    case From of
        {fork, _} ->
            Call;
        _ ->
            case Method of
                'INVITE' when Code>100, Code<200 ->
                    case lists:keymember(<<"100rel">>, 1, Require) of
                        true -> send_prack(Resp, Id, DialogId, Call);
                        false -> Call
                    end;
                _ ->
                    Call
            end
    end.


%% @private
-spec send_prack(nksip:response(), nksip_call_uac:id(), 
                 nksip_dialog:id(), nksip_call:call()) ->
    nksip_call:call().

send_prack(Resp, Id, DialogId, Call) ->
    #sipmsg{cseq=CSeq} = Resp,
    #call{
        app_id = AppId, 
        trans = Trans, 
        opts = #call_opts{app_opts=AppOpts}
    } = Call,
    try
        case nksip_sipmsg:header(Resp, <<"RSeq">>, integers) of
            [RSeq] when RSeq > 0 -> ok;
            _ -> RSeq = throw(invalid_rseq)
        end,
        case lists:keyfind(Id, #trans.id, Trans) of
            #trans{} = UAC -> ok;
            _ -> UAC = throw(no_transaction)
        end,
        #trans{
            method = Method, 
            rseq = LastRSeq, 
            pracks = PRAcks,
            opts = UACOpts
        } = UAC,
        case LastRSeq of
            0 -> ok;
            _ when RSeq==LastRSeq+1 -> ok;
            _ -> throw(rseq_out_of_order)
        end,
        case nksip_call_dialog:find(DialogId, Call) of
            #dialog{invite=#invite{sdp_offer={remote, invite, RemoteSDP}}} -> ok;
            _ -> RemoteSDP = <<>>
        end,
        Body = case nksip_lib:get_value(prack, UACOpts) of
            Fun when is_function(Fun, 2) -> 
                case catch Fun(RemoteSDP, Resp) of
                    Bin when is_binary(Bin) ->
                        Bin;
                    #sdp{} = LocalSDP -> 
                        LocalSDP;
                    Other ->
                        ?call_warning("error calling prack_sdp/2: ~p", 
                                      [Other], Call),
                        <<>>
                end;
            _ ->
                <<>>
        end,
        RAck = list_to_binary([ 
            integer_to_list(RSeq),
            32,
            integer_to_list(CSeq),
            32,
            nksip_lib:to_list(Method)
        ]),
        Opts2 = [{post_headers, [{<<"RAck">>, RAck}]}, {body, Body}],
        case nksip_call_uac_dialog:make(DialogId, 'PRACK', Opts2, Call) of
            {ok, {Uri, Opts3}, Call1} -> 
                case nksip_uac_lib:make(AppId, 'PRACK', Uri, Opts3, AppOpts) of
                   {ok, Req, ReqOpts} -> 
                        PRAcks1 = [{RSeq, CSeq, Method, DialogId}|PRAcks],
                        UAC1 = UAC#trans{rseq=RSeq, pracks=PRAcks1},
                        Call2 = update(UAC1, Call1),
                        nksip_call_uac_req:request(Req, ReqOpts, none, Call2);
                    {error, Error} ->
                        throw(Error)
                end;
            {error, Error} ->
                throw(Error)
        end
    catch
        throw:TError ->
            ?call_warning("could not send PRACK: ~p", [TError], Call),
            Call
    end.



