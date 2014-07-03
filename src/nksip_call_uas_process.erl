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
    #sipmsg{app_id=AppId, require=Require, event=Event} = Req,
    Supported = AppId:config_supported(),
    case [T || T <- Require, not lists:member(T, Supported)] of
        [] when Method=='SUBSCRIBE'; Method=='PUBLISH' ->
            SupEvents = AppId:config_events(),
            case Event of
                {Type, _} ->
                    case lists:member(Type, [<<"refer">>|SupEvents]) of
                        true -> check_notify(Method, Req, UAS, Call);
                        false -> reply(bad_event, UAS, Call)
                    end;
                _ ->
                    reply(bad_event, UAS, Call)
            end;
        [] ->
            check_notify(Method, Req, UAS, Call);
        BadRequires -> 
            RequiresTxt = nksip_lib:bjoin(BadRequires),
            reply({bad_extension,  RequiresTxt}, UAS, Call)
    end.


%% @private
-spec check_notify(nksip:method(), nksip:request(), 
                      nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_notify('NOTIFY', Req, UAS, Call) ->
    case nksip_subscription:subscription_state(Req) of
        invalid -> reply({invalid_request, "Invalid Subscription-State"}, UAS, Call);
        _ -> check_missing_dialog('NOTIFY', Req, UAS, Call)
    end;
check_notify(Method, Req, UAS, Call) ->
    check_missing_dialog(Method, Req, UAS, Call).



%% @private
-spec check_missing_dialog(nksip:method(), nksip:request(), 
                           nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_missing_dialog('ACK', #sipmsg{to={_, <<>>}}, UAS, Call) ->
    ?call_notice("received out-of-dialog ACK", []),
    update(UAS#trans{status=finished}, Call);
    
check_missing_dialog(Method, #sipmsg{to={_, <<>>}}, UAS, Call)
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
    #sipmsg{to={_, ToTag}} = Req,
    #trans{id=Id, opts=Opts, stateless=Stateless} = UAS,
    #call{app_id=AppId} = Call,
    try
        case Stateless orelse ToTag == <<>> of
            true ->
                case AppId:nkcb_uas_method(Method, Req, UAS, Call) of
                    {continue, [Method1, Req1, UAS1, Call1]} ->
                        {UAS2, Call2} = method(Method1, Req1, UAS1, Call1);
                    {ok, UAS2, Call2} ->
                        ok
                end,
                case AppId:nkcb_sip_method(UAS2, Call2) of
                    {reply, Reply} -> reply(Reply, UAS2, Call2);
                    noreply -> Call2
                end;
            false ->           
                case nksip_call_uas_dialog:request(Req, Call) of
                    {ok, Call1} ->
                        case AppId:nkcb_uas_method(Method, Req, UAS, Call1) of
                            {continue, [Method2, Req2, UAS2, Call2]} ->
                                {UAS3, Call3} = method(Method2, Req2, UAS2, Call2);
                            {ok, UAS3, Call3} ->
                                ok
                        end,
                        case AppId:nkcb_sip_method(UAS3, Call3) of
                            {reply, Reply} -> reply(Reply, UAS3, Call3);
                            noreply -> Call3
                        end;
                    {error, Error} when Method=='ACK' -> 
                        ?call_notice("UAS ~p 'ACK' dialog request error: ~p", 
                                     [Id, Error]),
                        UAS2 = UAS#trans{status=finished},
                        update(UAS2, Call);
                    {error, Error} ->
                        UAS2 = UAS#trans{opts=[no_dialog|Opts]},
                        reply(Error, UAS2, Call)
                end
        end
    catch
        throw:{reply, TReply} -> reply(TReply, UAS, Call)
    end.


%% @private
-spec method(nksip:method(), nksip:request(), 
             nksip_call:trans(), nksip_call:call()) ->
    {nksip_call:trans(), nksip_call:call()}.

method('INVITE', _Req, UAS, Call) ->
    UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
    {UAS1, update(UAS1, Call)};
    
method('ACK', _Req, UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    {UAS1, update(UAS1, Call)};

method('BYE', _Req, UAS, Call) ->
    {UAS, Call};

method('INFO', _Req, UAS, Call) ->
    {UAS, Call};
    
method('OPTIONS', _Req, UAS, Call) ->
    {UAS, Call};

method('REGISTER', Req, UAS, Call) ->
    #sipmsg{supported=Supported} = Req,
    case nksip_sipmsg:header(<<"path">>, Req, uris) of
        error ->
            throw({reply, invalid_request});
        [] ->
            {UAS, Call};
        _Path ->
            case lists:member(<<"path">>, Supported) of
                true -> {UAS, Call};
                false -> throw({reply, {bad_extension, <<"path">>}})
            end
    end;

% method('PRACK', Req, UAS, Call) ->
%     #sipmsg{dialog_id=DialogId} = Req,
%     #call{trans=Trans} = Call,
%     {RSeq, CSeq, Method} = case nksip_sipmsg:header(<<"rack">>, Req) of
%         [RACK] ->
%             case nksip_lib:tokens(RACK) of
%                 [RSeqB, CSeqB, MethodB] ->
%                     {
%                         nksip_lib:to_integer(RSeqB),
%                         nksip_lib:to_integer(CSeqB),
%                         nksip_parse:method(MethodB)
%                     };
%                 _ ->
%                     throw({reply, {invalid_request, <<"Invalid RAck">>}})
%             end;
%         _ ->
%             throw({reply, {invalid_request, <<"Invalid RAck">>}})
%     end,
%     OrigUAS = find_prack_trans(RSeq, CSeq, Method, DialogId, Trans),
%     Meta = lists:keydelete(nksip_100rel_pracks, 1, OrigUAS#trans.meta),
%     OrigUAS1 = OrigUAS#trans{meta=Meta},
%     OrigUAS2 = nksip_call_lib:retrans_timer(cancel, OrigUAS1, Call),
%     OrigUAS3 = nksip_call_lib:timeout_timer(timer_c, OrigUAS2, Call),
%     {UAS, update(OrigUAS3, Call)};

method('UPDATE', _Req, UAS, Call) ->
    {UAS, Call};
    
method('SUBSCRIBE', _Req, UAS, Call) ->
    {UAS, Call};

method('NOTIFY', _Req, UAS, Call) ->
    {UAS, Call};

method('MESSAGE', Req, UAS, Call) ->
    #sipmsg{expires=Expires, start=Start} = Req,
    _Expired = case is_integer(Expires) of
        true ->
            case nksip_sipmsg:header(<<"date">>, Req, dates) of
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
    {UAS, Call};

method('REFER', #sipmsg{headers=Headers}, UAS, Call) ->
    case proplists:get_all_values(<<"refer-to">>, Headers) of
        [_ReferTo] -> {UAS, Call};
        _ -> throw({reply, invalid_request})
    end;

method('PUBLISH', Req, UAS, Call) ->
    _ETag = case nksip_sipmsg:header(<<"sip-if-match">>, Req) of
        [Tag] -> Tag;
        _ -> <<>>
    end,
    {UAS, Call};

method(_Method, #sipmsg{app_id=AppId}, _UAS, _Call) ->
    throw({reply, {method_not_allowed, AppId:config_allow()}}).




%% ===================================================================
%% Utils
%% ===================================================================


%% @private Sends a transaction reply
-spec reply(nksip:sipreply() | {nksip:response(), nksip:optslist()}, 
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply(Reply, UAS, Call) ->
    {_, Call1} = nksip_call_uas_reply:reply(Reply, UAS, Call),
    Call1.









