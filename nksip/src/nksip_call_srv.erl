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
-module(nksip_call_srv).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-behaviour(gen_server).

-export([start/3, stop/1, reply/3, sync_work/5, async_work/2, get_data/1, next/1]).
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-define(MSG_KEEP_TIME, 5).   % Time to keep removed sip msgs in memory


%% ===================================================================
%% Private
%% ===================================================================


start(AppId, CallId, AppOpts) ->
    gen_server:start(?MODULE, [AppId, CallId, AppOpts], []).

stop(Pid) ->
    gen_server:cast(Pid, stop).

reply(Pid, ReqId, Reply) ->
    gen_server:call(Pid, {reply, ReqId, Reply}, 60000).

sync_work(Pid, Ref, Sender, Work, From) ->
    gen_server:cast(Pid, {sync_work, Ref, Sender, Work, From}).

async_work(Pid, Work) ->
    gen_server:cast(Pid, {async_work, Work}).

get_data(Pid) ->
    gen_server:call(Pid, get_data).





%% ===================================================================
%% gen_server
%% ===================================================================


% @private 
init([AppId, CallId, AppOpts]) ->
    nksip_counters:async([nksip_calls]),
    SD = #call{
        app_id = AppId, 
        call_id = CallId, 
        keep_time = nksip_lib:get_integer(msg_keep_time, AppOpts, ?MSG_KEEP_TIME),
        send_100 = not lists:member(no_100, AppOpts),
        next = erlang:phash2(make_ref()),
        hibernate = false,
        trans = [],
        msgs = [],
        dialogs = []
    },
    ?call_debug("Call process started: ~p", [self()], SD),
    {ok, SD, ?SRV_TIMEOUT}.


%% @private
handle_call(get_data, _From, #call{trans=Trans, msgs=Msgs, dialogs=Dialogs}=SD) ->
    {reply, {Msgs, Trans, Dialogs}, SD};

handle_call(Msg, _From, SD) ->
    lager:error("Module ~p received unexpected sync event: ~p", [?MODULE, Msg]),
    {noreply, SD}.

%% @private
handle_cast({sync_work, Ref, Pid, Work, From}, SD) ->
    Pid ! {sync_work_ok, Ref},
    next(work(Work, From, SD));

handle_cast({async_work, Work}, SD) ->
    next(work(Work, none, SD));

handle_cast(stop, SD) ->
    {stop, normal, SD};

handle_cast(Msg, SD) ->
    lager:error("Module ~p received unexpected event: ~p", [?MODULE, Msg]),
    {noreply, SD}.

%% @private
handle_info({timeout, Ref, Type}, SD) ->
    next(timeout(Type, Ref, SD));

handle_info(timeout, SD) ->
    next(SD);

handle_info(Info, FsmData) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, FsmData}.


%% @private
code_change(_OldVsn, FsmData, _Extra) -> 
    {ok, FsmData}.


%% @private
terminate(_Reason, SD) ->
    ?call_debug("Call process stopped", [], SD),
    ok.




%% ===================================================================
%% Internal
%% ===================================================================


work({incoming, RawMsg}, none, SD) ->
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
            next(SD);
        #sipmsg{class1=Class}=SipMsg ->
            case Class of
                req -> nksip_call_uas:request(SipMsg, SD);
                resp -> nksip_call_uac:response(SipMsg, SD)
            end
    end;

work({sipapp_reply, Fun, Id, Reply}, none, SD) ->
    nksip_call_uas:sipapp_reply(Fun, Id, Reply, SD);

work({sync_reply, ReqId, Reply}, From, SD) ->
    case find_msg_trans(ReqId, SD) of
        {ok, UAS} -> 
            nksip_call_uas:sync_reply(Reply, UAS, From, SD);
        not_found -> 
            gen_server:reply(From, {error, unknown_call}),
            SD
    end;

work({send, Req}, From, SD) ->
    nksip_call_uac:request(Req, From, SD);

work({get_cancel, ReqId, Opts}, From, SD) ->
    case find_msg_trans(ReqId, SD) of
        {ok, UAS} -> 
            nksip_call_uac:get_cancel(UAS, Opts, From, SD);
        not_found -> 
            gen_server:reply(From, {error, request_not_found}),
            SD
    end;

work({make_dialog, DialogId, Method, Opts}, From, SD) ->
    nksip_call_uac:make_dialog(DialogId, Method, Opts, From, SD);

work({get_dialog, DialogId}, From, SD) ->
    Reply = case find_dialog(DialogId, SD) of
        {ok, Dialog} -> {ok, Dialog};
        not_found -> {error, unknown_dialog}
    end,
    gen_server:reply(From, Reply),
    SD;

work({get_dialog_fields, DialogId, Fields}, From, SD) ->
    Reply = case find_dialog(DialogId, SD) of
        {ok, Dialog} -> nksip_dialog:fields(Dialog, Fields);
        not_found -> {error, unknown_dialog}
    end,
    gen_server:reply(From, Reply),
    SD;

work(get_all_dialogs, From, #call{dialogs=Dialogs}=SD) ->
    Ids = [Dialog#dialog.id || Dialog <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    SD;

work({stop_dialog, DialogId}, none, SD) ->
    case find_dialog(DialogId, SD) of
        {ok, Dialog} ->
            Dialog1 = nksip_call_dialog_lib:status_update({stop, forced}, Dialog),
            ksip_call_dialog_lib:update(Dialog1, SD);
        not_found ->
            SD
    end;

work({get_sipmsg, MsgId}, From, SD) ->
    Reply = case find_sipmsg(MsgId, SD) of
        {ok, Msg} -> {ok, Msg};
        not_found -> {error, unknown_sipmsg}
    end,
    gen_server:reply(From, Reply),
    SD;

work({get_sipmsg_fields, MsgId, Fields}, From, SD) ->
    Reply = case find_sipmsg(MsgId, SD) of
        {ok, Msg} -> nksip_sipmsg:fields(Msg, Fields);
        not_found -> {error, unknown_sipmsg}
    end,
    gen_server:reply(From, Reply),
    SD;

work({get_sipmsg_header, MsgId, Name}, From, SD) ->
    Reply = case find_sipmsg(MsgId, SD) of
        {ok, Msg} -> nksip_sipmsg:header(Msg, Name);
        not_found -> {error, unknown_sipmsg}
    end,
    gen_server:reply(From, Reply),
    SD;

work(get_all_sipmsgs, From, #call{msgs=Msgs}=SD) ->
    Ids = [SipMsg#sipmsg.id || SipMsg <- Msgs],
    gen_server:reply(From, {ok, Ids}),
    SD.


timeout({remove_msg, MsgId}, _Ref, #call{msgs=Msgs}=SD) ->
    ?call_debug("Trans removing message ~p", [MsgId], SD),
    nksip_counters:async([{nksip_msgs, -1}]),
    case lists:keydelete(MsgId, #sipmsg.id, Msgs) of
        [] -> SD#call{msgs=[], hibernate=true};
        Msgs1 -> SD#call{msgs=Msgs1}
    end;

timeout({uac, Tag, Id}, _Ref, #call{trans=Trans}=SD) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uac}=UAC ->
            nksip_call_uac:timer(Tag, UAC, SD);
        false ->
            ?call_warning("Call ignoring uac timer (~p, ~p)", [Tag, Id], SD),
            SD
    end;


timeout({uas, Tag, Id}, _Ref, #call{trans=Trans}=SD) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            nksip_call_uas:timer(Tag, UAS, SD);
        false ->
            ?call_warning("Call ignoring uas timer (~p, ~p)", [Tag, Id], SD),
            SD
    end;

timeout({dlg, Tag, Id}, _Ref, #call{dialogs=Dialogs}=SD) ->
    case lists:keyfind(Id, #dialog.id, Dialogs) of
        #dialog{} = Dialog -> 
            nksip_call_dialog_lib:timer(Tag, Dialog, SD);
        false ->
            ?call_warning("Call ignoring dialog timer (~p, ~p)", [Tag, Id], SD),
            SD
    end;

timeout({fork, Tag, Id}, _Ref, #call{forks=Forks}=SD) ->
    case lists:keyfind(Id, #fork.id, Forks) of
        #fork{}=Fork ->
            nksip_call_fork:timer(Tag, Fork, SD);
        false ->
            ?call_warning("Call ignoring fork timer (~p, ~p)", [Tag, Id], SD),
            SD
    end.



next(#call{trans=[], msgs=[], dialogs=[]}=SD) -> 
    {stop, normal, SD};
next(#call{hibernate=true}=SD) -> 
    {noreply, SD#call{hibernate=false}, hibernate};
next(SD) ->
    {noreply, SD}.


find_msg_trans(ReqId, #call{trans=Trans}) ->
    do_find_msg_trans(ReqId, Trans).

do_find_msg_trans(ReqId, [#trans{request=#sipmsg{id=ReqId}}=UAS|_]) -> 
    {ok, UAS};
do_find_msg_trans(ReqId, [_|Rest]) -> 
    do_find_msg_trans(ReqId, Rest);
do_find_msg_trans(_, []) -> 
    not_found.

find_sipmsg(MsgId, #call{msgs=Msgs}) ->
    case lists:keyfind(MsgId, #sipmsg.id, Msgs) of
        false -> not_found;
        SipMsg -> {ok, SipMsg}
    end.

find_dialog(DialogId, #call{dialogs=Dialogs}) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        false -> not_found;
        Dialog -> {ok, Dialog}
    end.



