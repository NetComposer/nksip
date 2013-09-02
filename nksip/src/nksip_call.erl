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

-behaviour(gen_server).

-export([start/3, stop/1, sync_work/5, async_work/2]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-export([get_data/1]).

-export_type([call/0, trans/0, fork/0, work/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MSG_KEEP_TIME, 5).          % Time to keep removed sip msgs in memory


%% ===================================================================
%% Types
%% ===================================================================


-type call() :: #call{}.

-type trans() :: #trans{}.

-type fork() :: #fork{}.

-type work() :: {incoming, #raw_sipmsg{}} | 
                {app_reply, atom(), nksip_call_uas:id(), term()} |
                {sync_reply, nksip_call_uas:id(), nksip:sipreply()} |
                {send, nksip:request()} |
                {cancel, nksip_call_uac:id(), nksip_lib:proplist()} |
                {make_dialog, nksip_dialog:id(), nksip:method(), nksip_lib:proplist()} |
                {dialog_new_cseq, nksip_dialog:id()} | 
                {apply_dialog, nksip_dialog:id(), function()} |
                get_all_dialogs | 
                {stop_dialog, nksip_dialog:id()} |
                {apply_sipmsg, nksip_request:id()|nksip_response:id(), function()} |
                get_all_sipmsgs.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Starts a new call
-spec start(nksip:app_id(), nksip:call_id(), nksip_lib:proplist()) ->
    {ok, pid()}.

start(AppId, CallId, AppOpts) ->
    gen_server:start(?MODULE, [AppId, CallId, AppOpts], []).


%% @doc Stops a call (deleting  all associated transactions, dialogs and forks!)
-spec stop(pid()) ->
    ok.

stop(Pid) ->
    gen_server:cast(Pid, stop).


%% @doc Sends a synchronous piece of {@link work()} to the call.
%% After receiving the work, the call will send `{sync_work_ok, Ref}' to `Sender'
-spec sync_work(pid(), reference(), pid(), work(), from()|none) ->
    ok.

sync_work(Pid, Ref, Sender, Work, From) ->
    gen_server:cast(Pid, {sync_work, Ref, Sender, Work, From}).


%% doc Sends an asynchronous piece of {@link work()} to the call.
-spec async_work(pid(), work()) ->
    ok.

async_work(Pid, Work) ->
    gen_server:cast(Pid, {async_work, Work}).


%% ===================================================================
%% gen_server
%% ===================================================================


% @private 
-spec init(term()) ->
    gen_server_init(call()).

init([AppId, CallId, AppOpts]) ->
    nksip_counters:async([nksip_calls]),
    MaxTransTime = nksip_config:get(transaction_timeout),
    MaxDialogTime = nksip_config:get(dialog_timeout),
    Call = #call{
        app_id = AppId, 
        call_id = CallId, 
        keep_time = nksip_lib:get_integer(msg_keep_time, AppOpts, ?MSG_KEEP_TIME),
        max_trans_time = MaxTransTime,
        max_dialog_time = MaxDialogTime,
        send_100 = not lists:member(no_100, AppOpts),
        next = erlang:phash2(make_ref()),
        hibernate = false,
        msgs = [],
        trans = [],
        forks = [],
        dialogs = []
    },
    erlang:start_timer(round(1000*MaxTransTime/2), self(), check_call),
    ?call_debug("Call process started: ~p", [self()], Call),
    {ok, Call, ?SRV_TIMEOUT}.


%% @private
-spec handle_call(term(), from(), call()) ->
    gen_server_call(call()).

handle_call(get_data, _From, Call) ->
    #call{msgs=Msgs, trans=Trans, forks=Forks, dialogs=Dialogs} = Call,
    {reply, {Msgs, Trans, Forks, Dialogs}, Call};

handle_call(Msg, _From, Call) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, Call}.


%% @private
-spec handle_cast(term(), call()) ->
    gen_server_cast(call()).

handle_cast({sync_work, Ref, Pid, Work, From}, Call) ->
    Pid ! {sync_work_ok, Ref},
    next(work(Work, From, Call));

handle_cast({async_work, Work}, Call) ->
    next(work(Work, none, Call));

handle_cast(stop, Call) ->
    {stop, normal, Call};

handle_cast(Msg, Call) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, Call}.


%% @private
-spec handle_info(term(), call()) ->
    gen_server_info(call()).

handle_info({timeout, Ref, Type}, Call) ->
    next(timeout(Type, Ref, Call));

handle_info(timeout, Call) ->
    next(Call);

handle_info(Info, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, FsmData}.


%% @private
-spec code_change(term(), call(), term()) ->
    gen_server_code_change(call()).

code_change(_OldVsn, Call, _Extra) -> 
    {ok, Call}.


%% @private
-spec terminate(term(), call()) ->
    gen_server_terminate().

terminate(_Reason, Call) ->
    ?call_debug("Call process stopped", [], Call),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec work(work(), from()|none, call()) ->
    call().

work({incoming, RawMsg}, none, Call) ->
    #raw_sipmsg{
        sipapp_id = AppId, 
        call_id = CallId, 
        class = {_, _, Binary},
        transport = #transport{proto=Proto}
    } = RawMsg,
    case nksip_parse:raw_sipmsg(RawMsg) of
        error ->
            ?notice(AppId, CallId, "SIP ~p message could not be decoded: ~s", 
                    [Proto, Binary]),
            Call;
        #sipmsg{class=req}=Req ->
            nksip_call_uas:request(Req, Call);
        #sipmsg{class=resp}=Resp ->
            nksip_call_uac:response(Resp, Call)
    end;

work({app_reply, Fun, Id, Reply}, none, Call) ->
    nksip_call_uas:app_reply(Fun, Id, Reply, Call);

work({sync_reply, ReqId, Reply}, From, Call) ->
    case find_msg_trans(ReqId, Call) of
        {ok, UAS} -> 
            nksip_call_uas:sync_reply(Reply, UAS, From, Call);
        not_found -> 
            gen_server:reply(From, {error, unknown_call}),
            Call
    end;

work({send, Req}, From, Call) ->
    nksip_call_uac:request(Req, From, Call);

work({cancel, ReqId, Opts}, From, Call) ->
    case find_msg_trans(ReqId, Call) of
        {ok, UAC} -> 
            nksip_call_uac:cancel(UAC, Opts, From, Call);
        not_found -> 
            gen_server:reply(From, {error, unknown_request}),
            Call
    end;

work({make_dialog, DialogId, Method, Opts}, From, Call) ->
    nksip_call_uac:make_dialog(DialogId, Method, Opts, From, Call);

work({dialog_new_cseq, DialogId}, From, Call) ->
    case find_dialog(DialogId, Call) of
        {ok, Dialog} ->
            {CSeq, Call1} = nksip_call_dialog_lib:new_local_seq(Dialog, Call),
            gen_server:reply(From, {ok, CSeq}),
            Call1;
        not_found ->
            gen_server:reply(From, error),
            Call
    end;

work({apply_dialog, DialogId, Fun}, From, Call) ->
    Reply = case find_dialog(DialogId, Call) of
        {ok, Dialog} -> Fun(Dialog);
        not_found -> {error, unknown_dialog}
    end,
    gen_server:reply(From, Reply),
    Call;

work(get_all_dialogs, From, #call{dialogs=Dialogs}=Call) ->
    Ids = [Dialog#dialog.id || Dialog <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({stop_dialog, DialogId}, none, Call) ->
    case find_dialog(DialogId, Call) of
        {ok, Dialog} ->
            Dialog1 = nksip_call_dialog_lib:status_update({stop, forced}, Dialog),
            nksip_call_dialog_lib:update(Dialog1, Call);
        not_found ->
            Call
    end;

work({apply_sipmsg, MsgId, Fun}, From, Call) ->
    Reply = case find_sipmsg(MsgId, Call) of
        {ok, Msg} -> Fun(Msg);
        not_found -> {error, unknown_sipmsg}
    end,
    gen_server:reply(From, Reply),
    Call;

work(get_all_sipmsgs, From, #call{msgs=Msgs}=Call) ->
    Ids = [SipMsg#sipmsg.id || SipMsg <- Msgs],
    gen_server:reply(From, {ok, Ids}),
    Call.


%% @private
-spec timeout(term(), reference(), call()) ->
    call().

timeout({remove_msg, MsgId}, _Ref, #call{msgs=Msgs}=Call) ->
    ?call_debug("Call removing message ~p", [MsgId], Call),
    nksip_counters:async([{nksip_msgs, -1}]),
    case lists:keydelete(MsgId, #sipmsg.id, Msgs) of
        [] -> Call#call{msgs=[], hibernate=true};
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
            nksip_call_dialog_lib:timer(Tag, Dialog, Call);
        false ->
            ?call_warning("Call ignoring dialog timer (~p, ~p)", [Tag, Id], Call),
            Call
    end;

timeout(check_call, _Ref, #call{max_trans_time=MaxTime}=Call) ->
    Now = nksip_lib:timestamp(),
    Trans1 = check_call_trans(Now, Call),
    Forks1 = check_call_forks(Now, Call),
    Dialogs1 = check_call_dialogs(Now, Call),
    erlang:start_timer(round(1000*MaxTime/2), self(), check_call),
    next(Call#call{trans=Trans1, forks=Forks1, dialogs=Dialogs1}).


check_call_trans(Now, #call{trans=Trans, max_trans_time=MaxTime}=Call) ->
    lists:filter(
        fun(#trans{id=Id, start=Start}) ->
            case Now - Start < MaxTime of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired transaction ~p", [Id], Call),
                    false
            end
        end,
        Trans).

check_call_forks(Now, #call{forks=Forks, max_trans_time=MaxTime}=Call) ->
    lists:filter(
        fun(#fork{id=Id, start=Start}) ->
            case Now - Start < MaxTime of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired fork ~p", [Id], Call),
                    false
            end
        end,
        Forks).

check_call_dialogs(Now, #call{dialogs=Dialogs, max_dialog_time=MaxTime}=Call) ->
    lists:filter(
        fun(#dialog{id=Id, created=Start}) ->
            case Now - Start < MaxTime of
                true ->
                    true;
                false ->
                    ?call_warning("Call removing expired fork ~p", [Id], Call),
                    false
            end
        end,
        Dialogs).


%% @private
-spec next(call()) ->
    gen_server_cast(call()).

next(#call{trans=[], msgs=[], dialogs=[]}=Call) -> 
    {stop, normal, Call};
next(#call{hibernate=true}=Call) -> 
    {noreply, Call#call{hibernate=false}, hibernate};
next(Call) ->
    {noreply, Call}.


%% @private
-spec find_msg_trans(nksip_request:id(), call()) ->
    {ok, trans()} | not_found.

find_msg_trans(ReqId, #call{trans=Trans}) ->
    do_find_msg_trans(ReqId, Trans).

do_find_msg_trans(ReqId, [#trans{request=#sipmsg{id=ReqId}}=UAS|_]) -> 
    {ok, UAS};
do_find_msg_trans(ReqId, [_|Rest]) -> 
    do_find_msg_trans(ReqId, Rest);
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

%% @private
get_data(Pid) ->
    gen_server:call(Pid, get_data).






