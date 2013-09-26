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

%% @doc Call Server
%%
%% {@link nksip_call_router} starts a new call server process for each new
%% incoming different Call-Id.
%%
%% Each call server process controls each transaction, fork and dialog associated 
%% with this Call-Id.
%%
%% It also stores all SipMsgs (requests and responses) having this Call-Id

-module(nksip_call).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send/2, send/4, send_dialog/3, cancel/1, sync_reply/2]).
-export([get_authorized_list/1, clear_authorized_list/1, stop_dialog/1]).
-export([get_all/0, clear_all/0]).
-export([app_reply/5, work/3, timeout/3]).
-import(nksip_call_router, [send_work_sync/3, send_work_async/3]).

-export_type([call/0, trans/0, fork/0, work/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Types
%% ===================================================================


-type call() :: #call{}.

-type trans() :: #trans{}.

-type fork() :: #fork{}.

-type work() :: {incoming, #raw_sipmsg{}} | 
                {app_reply, atom(), nksip_call_uas:id(), term()} |
                {sync_reply, nksip_call_uas:id(), nksip:sipreply()} |
                {make, nksip:method(), nksip:user_uri(), nksip_lib:proplist()} |
                {send, nksip:request(), nksip_lib:proplist()} |
                {send, nksip:method(), nksip:user_uri(), nksip_lib:proplist()} |
                {send_dialog, nksip_dialog:id(), nksip:method(), nksip_lib:proplist()} |
                {cancel, nksip_call_uac:id()} |
                {make_dialog, nksip_dialog:id(), nksip:method(), nksip_lib:proplist()} |
                {apply_dialog, nksip_dialog:id(), function()} |
                get_all_dialogs | 
                {stop_dialog, nksip_dialog:id()} |
                {apply_sipmsg, nksip_request:id()|nksip_response:id(), function()} |
                get_all_sipmsgs |
                {apply_transaction, nksip_request:id()|nksip_response:id(), function()} |
                get_all_transactions |
                {get_authorized_list, nksip_dialog:id()} | 
                {clear_authorized_list, nksip_dialog:id()}.

%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new request
-spec send(nksip:request(), nksip_lib:proplist()) ->
    nksip_uac:send_common() | nksip_uac:send_ack() | {error, nksip_uac:send_error()}.

send(#sipmsg{app_id=AppId, call_id=CallId}=Req, Opts) ->
    send_work_sync(AppId, CallId, {send, Req, Opts}).


%% @doc Generates and sends a new request
-spec send(nksip:app_id(), nksip:method(), nksip:user_uri(), nksip_lib:proplist()) ->
    nksip_uac:send_common() | nksip_uac:send_ack() | {error, nksip_uac:make_error()}.

send(AppId, Method, Uri, Opts) ->
    case nksip_lib:get_binary(call_id, Opts) of
        <<>> -> CallId = nksip_lib:luid();
        CallId -> ok
    end,
    send_work_sync(AppId, CallId, {send, Method, Uri, Opts}).


%% @doc Generates and sends a new in-dialog request
-spec send_dialog(nksip_dialog:spec(), nksip:method(), nksip_lib:proplist()) ->
    nksip_uac:send_common() | nksip_uac:send_ack() | {error, nksip_uac:send_error()}.

send_dialog(DialogSpec, Method, Opts) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, Id} ->
            send_work_sync(AppId, CallId, {send_dialog, Id, Method, Opts});
        undefined ->
            {error, unknown_dialog}
    end.


%% @doc Cancels an ongoing INVITE request
-spec cancel(nksip:request_id()) ->
    ok | {error, nksip_uac:cancel_error()}.

cancel(ReqSpec) ->
    {req, AppId, CallId, Id, _DlgId} = nksip_request:id(ReqSpec),
    send_work_sync(AppId, CallId, {cancel, Id}).


%% @doc Sends a callback SipApp response
-spec app_reply(nksip:app_id(), nksip:call_id(), atom(), nksip_call_uas:id(), term()) ->
    ok.

app_reply(AppId, CallId, Fun, TransId, Reply) ->
    send_work_async(AppId, CallId, {app_reply, Fun, TransId, Reply}).


%% @doc Sends a synchronous request reply
-spec sync_reply(nksip:request_id(), nksip:sipreply()) ->
    {ok, nksip:response()} | {error, Error}
    when Error :: invalid_call | nksip_call_router:sync_error().

sync_reply({req, AppId, CallId, MsgId, _DlgId}, Reply) ->
    send_work_sync(AppId, CallId, {sync_reply, MsgId, Reply}).


%% @doc Get authorized list
-spec get_authorized_list(nksip_dialog:spec()) ->
    [{nksip:protocol(), inet:ip_address(), inet:port_number()}].

get_authorized_list(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DlgId} ->
            case send_work_sync(AppId, CallId, {get_authorized_list, DlgId}) of
                {ok, List} -> List;
                _ -> []
            end;
        undefined ->
            []
    end.


%% @doc Clear authorized list
-spec clear_authorized_list(nksip_dialog:spec()) ->
    ok | error.

clear_authorized_list(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DlgId} ->
            case send_work_sync(AppId, CallId, {clear_authorized_list, DlgId}) of
                ok -> ok;
                _ -> error
            end;
        undefined ->
            error
    end.


%% @doc Stops (deletes) a dialog
-spec stop_dialog(nksip_dialog:spec()) ->
    ok | {error, unknown_dialog}.
 
stop_dialog(DialogSpec) ->
    case nksip_dialog:id(DialogSpec) of
        {dlg, AppId, CallId, DialogId} ->
            send_work_sync(AppId, CallId, {stop_dialog, DialogId});
        undefined ->
            {error, unknown_dialog}
    end.


%% @doc Get all started calls
-spec get_all() ->
    [{nksip:app_id(), nksip:call_id(), pid()}].

get_all() ->
    nksip_call_router:get_all_calls().


%% @private 
clear_all() ->
    nksip_call_router:clear_all_calls().


%% ===================================================================
%% Call works
%% ===================================================================


%% @private
-spec work(work(), from()|none, call()) ->
    call().

work({incoming, RawMsg}, none, Call) ->
    #raw_sipmsg{
        app_id = AppId, 
        call_id = CallId, 
        class = {_, _, Binary},
        transport = #transport{proto=Proto}
    } = RawMsg,
    #call{opts=#call_opts{global_id=GlobalId}} = Call,
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            ?notice(AppId, CallId, "SIP ~p message could not be decoded: ~s", 
                    [Proto, Binary]),
            Call;
        #sipmsg{class=req}=Req ->
            nksip_call_uas:request(Req, Call);
        #sipmsg{class=resp}=Resp ->
            case nksip_uac_lib:is_stateless(Resp, GlobalId) of
                true -> nksip_call_proxy:response_stateless(Resp, Call);
                false -> nksip_call_uac:response(Resp, Call)
            end
    end;

work({app_reply, Fun, Id, Reply}, none, Call) ->
    nksip_call_uas:app_reply(Fun, Id, Reply, Call);

work({sync_reply, ReqId, Reply}, From, Call) ->
    case find_msg_trans(ReqId, Call) of
        {ok, UAS} -> 
            nksip_call_uas:sync_reply(Reply, UAS, {srv, From}, Call);
        not_found -> 
            gen_server:reply(From, {error, invalid_call}),
            Call
    end;

work({make, Method, Uri, Opts}, From, Call) ->
    #call{app_id=AppId, call_id=CallId, opts=CallOpts} = Call,
    #call_opts{app_opts=AppOpts} = CallOpts,
    Opts1 = [{call_id, CallId} | Opts],
    Reply = nksip_uac_lib:make(AppId, Method, Uri, Opts1, AppOpts),
    gen_server:reply(From, Reply),
    Call;

work({send, Req, Opts}, From, Call) ->
    nksip_call_uac:request(Req, Opts, {srv, From}, Call);

work({send, Method, Uri, Opts}, From, Call) ->
    #call{app_id=AppId, call_id=CallId, opts=CallOpts} = Call,
    #call_opts{app_opts=AppOpts} = CallOpts,
    Opts1 = [{call_id, CallId} | Opts],
    case nksip_uac_lib:make(AppId, Method, Uri, Opts1, AppOpts) of
        {ok, Req, ReqOpts} -> 
            work({send, Req, ReqOpts}, From, Call);
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            Call
    end;

work({send_dialog, DialogId, Method, Opts}, From, Call) ->
    case nksip_call_dialog_uac:make(DialogId, Method, Opts, Call) of
        {ok, {RUri, Opts1}, Call1} -> 
            work({send, Method, RUri, Opts1}, From, Call1);
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            Call
    end;

work({cancel, ReqId}, From, Call) ->
    case find_msg_trans(ReqId, Call) of
        {ok, UAC} -> 
            gen_server:reply(From, ok),
            nksip_call_uac:cancel(UAC, Call);
        not_found -> 
            gen_server:reply(From, {error, unknown_request}),
            Call
    end;

work({apply_dialog, DialogId, Fun}, From, Call) ->
    case find_dialog(DialogId, Call) of
        {ok, Dialog} ->
            case catch Fun(Dialog) of
                {Reply, {update, #dialog{}=Dialog1}} ->
                    gen_server:reply(From, Reply),
                    nksip_call_dialog:update(Dialog1, Call);
                Reply ->
                    gen_server:reply(From, Reply),
                    Call
            end;
        not_found -> 
            gen_server:reply(From, {error, unknown_dialog}),
            Call
    end;
    
work(get_all_dialogs, From, #call{dialogs=Dialogs}=Call) ->
    Ids = [nksip_dialog:id(Dialog) || Dialog <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({stop_dialog, DialogId}, From, Call) ->
    case find_dialog(DialogId, Call) of
        {ok, Dialog} ->
            gen_fsm:reply(From, ok),
            Dialog1 = nksip_call_dialog:status_update(uac, {stop, forced}, Dialog, Call),
            nksip_call_dialog:update(Dialog1, Call);
        not_found ->
            gen_fsm:reply(From, {error, unknown_dialog}),
            Call
    end;

work({apply_sipmsg, MsgId, Fun}, From, Call) ->
    case find_sipmsg(MsgId, Call) of
        {ok, Msg} -> 
            case catch Fun(Msg) of
                {Reply, {update, #sipmsg{}=SipMsg1}} ->
                    gen_server:reply(From, Reply),
                    nksip_call_lib:update_sipmsg(SipMsg1, Call);
                Reply ->
                    gen_server:reply(From, Reply),
                    Call
            end;
        not_found -> 
            gen_server:reply(From, {error, unknown_sipmsg}),
            Call
    end;

work(get_all_sipmsgs, From, #call{msgs=Msgs}=Call) ->
    Ids = [
        case Class of
            req -> nksip_request:id(SipMsg);
            resp -> nksip_response:id(SipMsg)
        end
        ||
        #sipmsg{class=Class}=SipMsg <- Msgs
    ],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({apply_transaction, MsgId, Fun}, From, Call) ->
    case find_msg_trans(MsgId, Call) of
        {ok, Trans} -> gen_server:reply(From, catch Fun(Trans));
        not_found ->  gen_server:reply(From, {error, unknown_transaction})
    end,
    Call;

work(get_all_transactions, From, Call) ->
    #call{app_id=AppId, call_id=CallId, trans=Trans} = Call,
    Ids = [{Class, AppId, CallId, Id} || #trans{id=Id, class=Class} <- Trans],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({get_authorized_list, DlgId}, From, #call{auths=Auths}=Call) ->
    List = [{Proto, Ip, Port} || 
            {D, Proto, Ip, Port} <- Auths, D=:=DlgId],
    gen_server:reply(From, {ok, List}),
    Call;

work({clear_authorized_list, DlgId}, From, #call{auths=Auths}=Call) ->
    Auths1 = [{D, Proto, Ip, Port} || 
              {D, Proto, Ip, Port} <- Auths, D=/=DlgId],
    gen_server:reply(From, ok),
    Call#call{auths=Auths1};

work(crash, _, _) ->
    error(forced_crash).


%% ===================================================================
%% Call timeouts
%% ===================================================================


%% @private
-spec timeout(term(), reference(), call()) ->
    call().

timeout({remove_msg, MsgId}, _Ref, #call{msgs=Msgs}=Call) ->
    ?call_debug("Call removing message ~p", [MsgId], Call),
    nksip_counters:async([{nksip_msgs, -1}]),
    case lists:keydelete(MsgId, #sipmsg.id, Msgs) of
        [] -> Call#call{msgs=[], hibernate=removed_msg};
        Msgs1 -> Call#call{msgs=Msgs1}
    end;

timeout({uac, Tag, Id}, _Ref, #call{trans=Trans}=Call) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uac}=UAC ->
            nksip_call_uac:timer(Tag, UAC, Call);
        false ->
            ?call_warning("Call ignoring uac timer (~p, ~p)", [Tag, Id], Call),
            Call
    end;


timeout({uas, Tag, Id}, _Ref, #call{trans=Trans}=Call) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            nksip_call_uas:timer(Tag, UAS, Call);
        false ->
            ?call_warning("Call ignoring uas timer (~p, ~p)", [Tag, Id], Call),
            Call
    end;

timeout({dlg, Tag, Id}, _Ref, #call{dialogs=Dialogs}=Call) ->
    case lists:keyfind(Id, #dialog.id, Dialogs) of
        #dialog{} = Dialog -> 
            nksip_call_dialog:timer(Tag, Dialog, Call);
        false ->
            ?call_warning("Call ignoring dialog timer (~p, ~p)", [Tag, Id], Call),
            Call
    end;

timeout(check_call, _Ref, #call{opts=CallOpts}=Call) ->
    #call_opts{
        max_trans_time = MaxTrans,
        max_dialog_time = MaxDialog
    } = CallOpts,
    Now = nksip_lib:timestamp(),
    Trans1 = check_call_trans(Now, MaxTrans, Call),
    Forks1 = check_call_forks(Now, MaxTrans, Call),
    Dialogs1 = check_call_dialogs(Now, MaxDialog, Call),
    erlang:start_timer(round(2*MaxTrans), self(), check_call),
    Call#call{trans=Trans1, forks=Forks1, dialogs=Dialogs1}.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec check_call_trans(nksip_lib:timestamp(), integer(), call()) ->
    [trans()].

check_call_trans(Now, MaxTime, #call{trans=Trans}=Call) ->
    lists:filter(
        fun(#trans{id=Id, start=Start}) ->
            case Now - Start < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired transaction ~p", [Id], Call),
                    false
            end
        end,
        Trans).


%% @private
-spec check_call_forks(nksip_lib:timestamp(), integer(), call()) ->
    [fork()].

check_call_forks(Now, MaxTime, #call{forks=Forks}=Call) ->
    lists:filter(
        fun(#fork{id=Id, start=Start}) ->
            case Now - Start < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired fork ~p", [Id], Call),
                    false
            end
        end,
        Forks).


%% @private
-spec check_call_dialogs(nksip_lib:timestamp(), integer(), call()) ->
    [nksip_dialog:dialog()].

check_call_dialogs(Now, MaxTime, #call{dialogs=Dialogs}=Call) ->
    lists:filter(
        fun(#dialog{id=Id, created=Start}) ->
            case Now - Start < MaxTime/1000 of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired dialog ~p", [Id], Call),
                    false
            end
        end,
        Dialogs).



%% @private
-spec find_msg_trans(nksip_request:id()|nksip_response:id(), call()) ->
    {ok, trans()} | not_found.

find_msg_trans(MsgId, #call{trans=Trans}) ->
    do_find_msg_trans(MsgId, Trans).

do_find_msg_trans(MsgId, [#trans{request=#sipmsg{id=MsgId}}=UA|_]) -> 
    {ok, UA};
do_find_msg_trans(MsgId, [#trans{response=#sipmsg{id=MsgId}}=UA|_]) -> 
    {ok, UA};
do_find_msg_trans(MsgId, [_|Rest]) -> 
    do_find_msg_trans(MsgId, Rest);
do_find_msg_trans(_, []) -> 
    not_found.


%% @private
-spec find_sipmsg(nksip_request:id()|nksip_response:id(), call()) ->
    {ok, #sipmsg{}} | not_found.

find_sipmsg(MsgId, #call{msgs=Msgs}) ->
    case lists:keyfind(MsgId, #sipmsg.id, Msgs) of
        false -> not_found;
        SipMsg -> {ok, SipMsg}
    end.


%% @private
-spec find_dialog(nksip_dialog:id(), call()) ->
    {ok, #dialog{}} | not_found.

find_dialog(DialogId, #call{dialogs=Dialogs}) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        false -> not_found;
        Dialog -> {ok, Dialog}
    end.







