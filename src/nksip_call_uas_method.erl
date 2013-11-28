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
-module(nksip_call_uas_method).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([process/4]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec process(nksip:method(), nksip_dialog:id(), 
                 nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

process('INVITE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> ->
            reply(no_transaction, UAS, Call);
        _ ->
            UAS1 = nksip_call_lib:expire_timer(expire, UAS, Call),
            #trans{request=#sipmsg{to_tag=ToTag}} = UAS,
            Fun = case ToTag of
                <<>> -> invite;
                _ -> reinvite
            end,
            process_call(Fun, UAS1, update(UAS1, Call))
    end;
    
process('ACK', DialogId, UAS, Call) ->
    UAS1 = UAS#trans{status=finished},
    case DialogId of
        <<>> -> 
            ?call_notice("received out-of-dialog ACK", [], Call),
            update(UAS1, Call);
        _ -> 
            process_call(ack, UAS1, update(UAS1, Call))
    end;

process('BYE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> -> reply(no_transaction, UAS, Call);
        _ -> process_call(bye, UAS, Call)
    end;

process('INFO', DialogId, UAS, Call) ->
    case DialogId of
        <<>> -> reply(no_transaction, UAS, Call);
        _ -> process_call(info, UAS, Call)
    end;

process('OPTIONS', _DialogId, UAS, Call) ->
    process_call(options, UAS, Call); 

process('REGISTER', _DialogId, UAS, Call) ->
    process_call(register, UAS, Call); 

process('PRACK', DialogId, UAS, Call) ->
    #trans{request=Req} = UAS,
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

process('UPDATE', DialogId, UAS, Call) ->
    case DialogId of
        <<>> -> reply(no_transaction, UAS, Call);
        _ -> process_call(update, UAS, Call)
    end;

process(_Method, _DialogId, UAS, Call) ->
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    reply({method_not_allowed, nksip_sipapp_srv:allowed(Opts)}, UAS, Call).




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
        {reply, _} when Method=:='ACK' ->
            update(UAS, Call);
        {reply, Reply} ->
            reply(Reply, UAS, Call);
        not_exported when Method=:='ACK' ->
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









