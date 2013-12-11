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

%% @private Call UAS Management: Request Processing
-module(nksip_call_uas_process).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([process/2]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private 
-spec process(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().
    

process(#trans{request=#sipmsg{class={req, 'ACK'}, to_tag = <<>>}}=UAS, Call) ->
    ?call_notice("received out-of-dialog ACK", [], Call),
    update(UAS#trans{status=finished}, Call);
    
process(#trans{request=#sipmsg{class={req, Method}, to_tag = <<>>}}=UAS, Call)
        when Method=='BYE'; Method=='INFO'; Method=='PRACK'; Method=='UPDATE';
             Method=='NOTIFY' ->
    reply(no_transaction, UAS, Call);

process(#trans{request=Req}=UAS, Call) ->
    #sipmsg{class={req, Method}, require=Require, event=Event} = Req,
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    case Method=='CANCEL' orelse Method=='ACK' of
        true ->
            do_process(UAS, Call);
        false ->
            Supported = nksip_lib:get_value(supported, AppOpts, ?SUPPORTED),
            SupportedTokens = [T || {T, _} <- Supported],
            case [T || {T, _} <- Require, not lists:member(T, SupportedTokens)] of
                [] when Method=='SUBSCRIBE' ->
                    SupEvents = nksip_lib:get_value(event, AppOpts, []),
                    case Event of
                        {Type, _} ->
                            case lists:member(Type, SupEvents) of
                                true -> do_process(UAS, Call);
                                false -> reply(bad_event, UAS, Call)
                            end;
                        _ ->
                            reply(bad_event, UAS, Call)
                    end;
                [] ->
                    do_process(UAS, Call);
                BadRequires -> 
                    RequiresTxt = nksip_lib:bjoin(BadRequires),
                    reply({bad_extension,  RequiresTxt}, UAS, Call)
            end
    end.

%% @private 
do_process(UAS, Call) ->
    #trans{method=Method, request=Req, stateless=Stateless} = UAS,
    #sipmsg{to_tag=ToTag} = Req,
    case Stateless of
        true ->
            method(Method, UAS, Call);
        false when ToTag == <<>> ->
            method(Method, UAS, Call);
        false ->           
            case nksip_call_uas_dialog:request(Req, Call) of
                {ok, Call1} -> method(Method, UAS, Call1);
                {error, Error}  -> process_dialog_error(Error, UAS, Call)
            end
    end.


%% @private
process_dialog_error(Error, #trans{method='ACK', id=Id}=UAS, Call) ->
    ?call_notice("UAS ~p 'ACK' dialog request error: ~p", [Id, Error], Call),
    UAS1 = UAS#trans{status=finished},
    update(UAS1, Call);

process_dialog_error(Error, #trans{method=Method, id=Id, opts=Opts}=UAS, Call) ->
    Reply = case Error of
        request_pending ->
            request_pending;
        retry -> 
            {500, [{<<"Retry-After">>, crypto:rand_uniform(0, 11)}], 
                        <<>>, [{reason, <<"Processing Previous INVITE">>}]};
        old_cseq ->
            {internal, <<"Old CSeq in Dialog">>};
        no_transaction ->
            no_transaction;
        _ ->
            ?call_info("UAS ~p ~p dialog request error: ~p", 
                        [Id, Method, Error], Call),
            no_transaction
    end,
    reply(Reply, UAS#trans{opts=[no_dialog|Opts]}, Call).


%% @private
-spec method(nksip:method(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

method('INVITE', #trans{request=#sipmsg{to_tag=ToTag}}=UAS, Call) ->
    UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
    Fun = case ToTag of
        <<>> -> invite;
        _ -> reinvite
    end,
    process_call(Fun, UAS1, update(UAS1, Call));
    
method('ACK', UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    process_call(ack, UAS1, update(UAS1, Call));

method('BYE', UAS, Call) ->
    process_call(bye, UAS, Call);

method('INFO', UAS, Call) ->
    process_call(info, UAS, Call);
    
method('OPTIONS', UAS, Call) ->
    process_call(options, UAS, Call); 

method('REGISTER', UAS, Call) ->
    process_call(register, UAS, Call); 

method('PRACK', UAS, Call) ->
    #trans{request=#sipmsg{dialog_id=DialogId}=Req} = UAS,
    #call{trans=Trans} = Call,
    try
        {RSeq, CSeq, Method} = case nksip_sipmsg:header(Req, <<"RAck">>) of
            [RACK] ->
                case nksip_lib:tokens(RACK) of
                    [RSeqB, CSeqB, MethodB] ->
                        {
                            nksip_lib:to_integer(RSeqB),
                            nksip_lib:to_integer(CSeqB),
                            nksip_parse:method(MethodB)
                        };
                    _ ->
                        throw({invalid_request, <<"Invalid RAck">>})
                end;
            _ ->
                throw({invalid_request, <<"Invalid RAck">>})
        end,
        case lists:keyfind([{RSeq, CSeq, Method, DialogId}], #trans.pracks, Trans) of
            #trans{status=invite_proceeding} = OrigUAS -> ok;
            _ -> OrigUAS = throw(no_transaction)
        end,
        OrigUAS1 = OrigUAS#trans{pracks=[]},
        OrigUAS2 = nksip_call_lib:retrans_timer(cancel, OrigUAS1, Call),
        OrigUAS3 = nksip_call_lib:timeout_timer(timer_c, OrigUAS2, Call),
        process_call(prack, UAS, update(OrigUAS3, Call))
    catch
        throw:Reply -> reply(Reply, UAS, Call)
    end;             

method('UPDATE', UAS, Call) ->
    process_call(update, UAS, Call);
    
method('SUBSCRIBE', UAS, Call) ->
    process_call(subscribe, UAS, Call);

method('NOTIFY', UAS, Call) ->
    process_call(notify, UAS, Call);

method(_Method, UAS, Call) ->
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    Allowed = case lists:member(registrar, AppOpts) of
        true -> <<(?ALLOW)/binary, ", REGISTER">>;
        false -> ?ALLOW
    end,
    reply({method_not_allowed, Allowed}, UAS, Call).




%% ===================================================================
%% Utils
%% ===================================================================


%% @private
-spec process_call(atom(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

process_call(Fun, UAS, Call) ->
    #trans{request=#sipmsg{id=ReqId}, method=Method} = UAS,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case nksip_call_uas:app_call(Fun, [], UAS, Call) of
        {reply, _} when Method=='ACK' ->
            update(UAS, Call);
        {reply, Reply} ->
            reply(Reply, UAS, Call);
        not_exported when Method=='ACK' ->
            Call;
        not_exported ->
            {reply, Reply, _} = apply(nksip_sipapp, Fun, [ReqId, none, Opts]),
            reply(Reply, UAS, Call);
        #call{} = Call1 -> 
            Call1
    end.


%% @private Sends a transaction reply
-spec reply(nksip:sipreply() | {nksip:response(), nksip_lib:proplist()}, 
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply(Reply, UAS, Call) ->
    {_, Call1} = nksip_call_uas_reply:reply(Reply, UAS, Call),
    Call1.









