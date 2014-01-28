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
    
process(#trans{method=Method, request=Req}=UAS, Call) ->
    check_supported(Method, Req, UAS, Call).


%% @private
-spec check_supported(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_supported(Method, Req, UAS, Call) when Method=='ACK'; Method=='CANCEL' ->
    check_missing_dialog(Method, Req, UAS, Call);

check_supported(Method, Req, UAS, Call) ->
    #sipmsg{require=Require, event=Event} = Req,
    #call{opts=#call_opts{app_opts=AppOpts}} = Call,
    Supported = nksip_lib:get_value(supported, AppOpts, ?SUPPORTED),
    SupportedTokens = [T || {T, _} <- Supported],
    case [T || {T, _} <- Require, not lists:member(T, SupportedTokens)] of
        [] when Method=='SUBSCRIBE'; Method=='PUBLISH' ->
            SupEvents = nksip_lib:get_value(event, AppOpts, []),
            case Event of
                {Type, _} ->
                    case lists:member(Type, [<<"refer">>|SupEvents]) of
                        true -> check_missing_dialog(Method, Req, UAS, Call);
                        false -> reply(bad_event, UAS, Call)
                    end;
                _ ->
                    reply(bad_event, UAS, Call)
            end;
        [] ->
            check_missing_dialog(Method, Req, UAS, Call);
        BadRequires -> 
            RequiresTxt = nksip_lib:bjoin(BadRequires),
            reply({bad_extension,  RequiresTxt}, UAS, Call)
    end.


%% @private
-spec check_missing_dialog(nksip:method(), nksip:request(), 
                           nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_missing_dialog('ACK', #sipmsg{to_tag=(<<>>)}, UAS, Call) ->
    ?call_notice("received out-of-dialog ACK", [], Call),
    update(UAS#trans{status=finished}, Call);
    
check_missing_dialog(Method, #sipmsg{to_tag=(<<>>)}, UAS, Call)
        when Method=='BYE'; Method=='INFO'; Method=='PRACK'; Method=='UPDATE';
             Method=='NOTIFY' ->
    reply(no_transaction, UAS, Call);

check_missing_dialog(Method, Req, UAS, Call) ->
    check_422(Method, Req, UAS, Call).


%% @private
-spec check_422(nksip:method(), nksip:request(), 
                nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_422(Method, Req, UAS, Call) ->
    case nksip_call_timer:uas_check_422(Req, Call) of
        continue -> 
            dialog(Method, Req, UAS, Call);
        {update, Req1, Call1} ->
            UAS1 = UAS#trans{request=Req1},
            dialog(Method, Req1, UAS1, update(UAS1, Call1));
        {reply, Reply, Call1} ->
            reply(Reply, UAS, Call1)
    end.


%% @private
-spec dialog(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

dialog(Method, Req, UAS, Call) ->
    % lager:error("DIALOG: ~p\n~p\n~p\n~p", [Method, Req, UAS, Call]),
    #sipmsg{to_tag=ToTag} = Req,
    #trans{id=Id, opts=Opts, stateless=Stateless} = UAS,
    case Stateless of
        true ->
            method(Method, Req, UAS, Call);
        false when ToTag == <<>> ->
            method(Method, Req, UAS, Call);
        false ->           
            case nksip_call_uas_dialog:request(Req, Call) of
                {ok, Call1} -> 
                    method(Method, Req, UAS, Call1);
                {error, Error} when Method=='ACK' -> 
                    ?call_notice("UAS ~p 'ACK' dialog request error: ~p", 
                                [Id, Error], Call),
                    UAS1 = UAS#trans{status=finished},
                    update(UAS1, Call);
                {error, Error} ->
                    UAS1 = UAS#trans{opts=[no_dialog|Opts]},
                    reply(Error, UAS1, Call)
            end
    end.


%% @private
-spec method(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

method('INVITE', #sipmsg{to_tag=ToTag}, UAS, Call) ->
    Fields = [app_id, aor, dialog_id, content_type, body],
    UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
    Fun = case ToTag of
        <<>> -> invite;
        _ -> reinvite
    end,
    process_call(Fun, Fields, UAS1, update(UAS1, Call));
    
method('ACK', _Req, UAS, Call) ->
    Fields = [app_id, dialog_id, content_type, body],
    UAS1 = UAS#trans{status=finished},
    process_call(ack, Fields, UAS1, update(UAS1, Call));

method('BYE', _Req, UAS, Call) ->
    Fields = [app_id, aor, dialog_id],
    process_call(bye, Fields, UAS, Call);

method('INFO', _Req, UAS, Call) ->
    Fields = [app_id, aor, content_type, body],
    process_call(info, Fields, UAS, Call);
    
method('OPTIONS', _Req, UAS, Call) ->
    Fields = [app_id, aor, allow, supported, content_type, body],
    process_call(options, Fields, UAS, Call); 

method('REGISTER', Req, UAS, Call) ->
    #sipmsg{supported=Supported} = Req,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    Registrar = lists:member(registrar, Opts),
    Fields = [
        app_id, 
        {value, registrar, Registrar}, 
        {value, req, Req}
    ],
    case nksip_sipmsg:header(Req, <<"Path">>, uris) of
        error ->
            reply(invalid_request, UAS, Call);
        [] ->
            process_call(register, Fields, UAS, Call); 
        Path ->
            case lists:keymember(<<"path">>, 1, Supported) of
                true ->
                    Fields1 = Fields++[{path, Path}],
                    process_call(register, Fields1, UAS, Call); 
                false ->
                    reply({bad_extension, <<"path">>}, UAS, Call)
            end
    end;

method('PRACK', Req, UAS, Call) ->
    #sipmsg{dialog_id=DialogId} = Req,
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
        Fields = [app_id, dialog_id, content_type, body],
        process_call(prack, Fields, UAS, update(OrigUAS3, Call))
    catch
        throw:Reply -> reply(Reply, UAS, Call)
    end;             

method('UPDATE', _Req, UAS, Call) ->
    Fields = [app_id, dialog_id, content_type, body],
    process_call(update, Fields, UAS, Call);
    
method('SUBSCRIBE', #sipmsg{to_tag=ToTag}, UAS, Call) ->
    Fields = [app_id, aor, dialog_id, event, subscription_id, parsed_expires],
    Fun = case ToTag of
        <<>> -> subscribe;
        _ -> resubscribe
    end,
    process_call(Fun, Fields, UAS, Call);

method('NOTIFY', Req, UAS, Call) ->
    Status = nksip_subscription:notify_status(Req),
    Fields = [app_id, aor, dialog_id, event, subscription_id, 
              {value, notify_status, Status}, content_type, body],
    process_call(notify, Fields, UAS, Call);

method('MESSAGE', Req, UAS, Call) ->
    #sipmsg{expires=Expires, start=Start} = Req,
    Expired = case is_integer(Expires) of
        true ->
            case nksip_sipmsg:header(Req, <<"Date">>, dates) of
                [Date] ->
                    Final = nksip_lib:gmt_to_timestamp(Date) + Expires,
                    case nksip_lib:timestamp() of
                        TS when TS > Final -> true;
                        _ -> false
                    end;
                _ ->
                    Final = Start/1000 + Expires,
                    case nksip_lib:timestamp() of
                        TS when TS > Final -> true;
                        _ -> false
                    end
            end;
        _ ->
            false
    end,
    Fields = [app_id, aor, {value, expired, Expired}, content_type, body],
    process_call(message, Fields, UAS, Call);

method('REFER', #sipmsg{headers=Headers}, UAS, Call) ->
    case proplists:get_all_values(<<"Refer-To">>, Headers) of
        [ReferTo] ->
            Fields = [app_id, aor, dialog_id, subscription_id, 
                      {value, refer_to, ReferTo}],
            process_call(refer, Fields, UAS, Call);
        _ ->
            reply(invalid_request, UAS, Call)    
    end;

method('PUBLISH', Req, UAS, Call) ->
    case nksip_sipmsg:header(Req, <<"SIP-If-Match">>) of
        [Tag] -> ok;
        _ -> Tag = <<>>
    end,
    Fields = [app_id, aor, event, {value, etag, Tag}, parsed_expires, body],
    process_call(publish, Fields, UAS, Call);

method(_Method, _Req, UAS, Call) ->
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
-spec process_call(atom(), list(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

process_call(Fun, Fields, UAS, Call) ->
    #trans{request=#sipmsg{id=ReqId}=Req, method=Method} = UAS,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    Meta = nksip_sipmsg:named_fields(Req, Fields),
    case nksip_call_uas:app_call(Fun, [Meta], UAS, Call) of
        {reply, _} when Method=='ACK' ->
            update(UAS, Call);
        {reply, Reply} ->
            reply(Reply, UAS, Call);
        not_exported when Method=='ACK' ->
            Call;
        % Not exported and no in-line
        not_exported ->
            Meta1 = [{app_opts, Opts}|Meta],
            {reply, Reply, []} = apply(nksip_sipapp, Fun, [ReqId, Meta1, none, []]),
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









