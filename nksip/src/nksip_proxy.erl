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

%% @private Proxy core process
%%
%% This module implements the process functionality of a SIP stateful proxy

-module(nksip_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-export([start/3, total/0, total/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
            handle_info/2]).

-include("nksip.hrl").

-define(CHECK_TIMEOUT, 500).



%% ===================================================================
%% private
%% ===================================================================

%% @doc Gets the total number of active stateful proxy processes
-spec total() -> 
    integer().

total() -> 
    nksip_counters:value(nksip_proxy).


%% @doc Gets the total number of active stateful proxy processes belongig to specific
%% SipApp.
-spec total(nksip:sipapp_id()) -> 
    integer().

total(AppId) -> 
    nksip_counters:value({nksip_proxy, AppId}).


%% @private
-spec start(nksip:uri_set(), nksip:request(), nksip_lib:proplist()) ->
    ok.

start(UriSet, Req, Opts) ->
    Pid = nksip_transaction_uas:start(Req),
    {ok, _} = gen_server:start(?MODULE, [UriSet, Req#sipmsg{pid=Pid}, Opts], []),
    ok.
    


%% ===================================================================
%% gen_server
%% ===================================================================


% Models each sent request
-record(reqdata, {
    ref :: reference(),                  % An unique reference for this request
    request :: nksip:request(),          % 
    response :: nksip:response(),        % Reveived full response
    expire :: 0 | nksip_lib:timestamp(), % At this time it will epire (0: no expire)
    to_cancel :: true | false | cancelled 
}).

-record(state, {
    uriset :: nksip:uri_set(),          % Remaining uriset to send
    request :: nksip:request(),         % Original request
    record_route :: boolean(),
    opts :: nksip_lib:proplist(),       % Opts: record_route, follow_redirects
    responses :: [#reqdata{}],          % All responses received
    final_sent :: false | '2xx' | '6xx',    
    timer_c :: non_neg_integer()        % Reference Timer C
}).


%% @private
init([UriSet, Req, Opts]) ->
    #sipmsg{sipapp_id=AppId, method=Method, call_id=CallId, from_tag=FromTag} = Req,
    SD = #state{
        uriset = UriSet,
        request = Req,
        record_route = lists:member(record_route, Opts),
        opts = Opts,
        responses = [],
        final_sent = false,
        timer_c = nksip_config:get(timer_c)
    },
    nksip_sipapp_srv:register(AppId, proxy),
    ?debug(AppId, CallId, "Proxy process started for ~p: ~p", [Method, self()]),
    ProxyTimeout = nksip_config:get(proxy_timeout),
    erlang:start_timer(1000*ProxyTimeout, self(), proxy_timeout),
    nksip_proc:put({nksip_proxy_callid, AppId, CallId, FromTag}),
    nksip_counters:async([nksip_proxy, {nksip_proxy, AppId}]),
    {ok, SD, 0}.


%% @private
handle_call({response, Ref, #sipmsg{vias=[_|Vias]}=Resp}, From, SD) when Vias=/=[] ->
    #sipmsg{sipapp_id=AppId, response=Code, call_id=CallId, vias=[_|Vias]} = Resp,
    #state{responses=Responses, timer_c=TimerC} = SD, 
    ?debug(AppId, CallId, "Proxy received ~p (~p)", [Code, Resp#sipmsg.to_tag]),
    Resp1 = Resp#sipmsg{vias=Vias},
    case lists:keytake(Ref, #reqdata.ref, Responses) of
        {value, #reqdata{expire=Expire, response=OldResp}=ReqData, ReqRest} ->
            gen_server:reply(From, ok),
            if 
                Expire=:=0, Code>=200, Code<300 ->
                    % A remote party has sent another final 2xx response
                    ?notice(AppId, CallId, 
                          "Proxy received secondary 2xx response: ~p", [Code]),
                    ReqData1 = ReqData#reqdata{response=Resp1},
                    process(SD#state{responses=[ReqData1|ReqRest]});
                Expire=:=0 ->
                    % A remote party has sent another response
                    case OldResp#sipmsg.response of
                        408 ->
                            ok;
                        OldCode ->
                            ?notice(AppId, CallId, 
                                "Proxy ignoring secondary response: ~p (old was ~p)", 
                                [Code, OldCode])
                    end,
                    next(SD);
                Code < 200 ->
                    % Provisional response, no final yet
                    Now = nksip_lib:timestamp(),
                    ReqData1 = ReqData#reqdata{expire=Now+TimerC, response=Resp1},
                    process(SD#state{responses=[ReqData1|ReqRest]});
                Code >= 200 ->
                    % Final 2xx response
                    ReqData1 = ReqData#reqdata{expire=0, response=Resp1},
                    process(SD#state{responses=[ReqData1|ReqRest]})
            end;
        false ->
            ?notice(AppId, CallId, "Proxy received unexpected response", []),
            {reply, error, SD}
    end;
    
handle_call({response, _, Resp}, _From, SD) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, vias=Vias} = Resp,
    ?notice(AppId, CallId, "Proxy received invalid Via response: ~p", [Vias]),
    {reply, error, SD};
    
handle_call(Msg, _From, SD) ->
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, SD}.


%% @private: Launch a serie of parallel requests
handle_cast(launch, #state{uriset=[]}=SD) -> 
    next(SD);

handle_cast(launch, SD) ->
    #state{uriset=[UriList|RUriSet], responses=Responses, timer_c=TimerC} = SD,
    Expire = nksip_lib:timestamp() + TimerC,
    Responses1 = send_requests(UriList, Expire, SD, []),
    next(SD#state{uriset=RUriSet, responses=Responses++Responses1});

handle_cast(cancel, #state{responses=Responses}=SD) ->
    Responses1 = set_cancel_all(Responses),
    next(SD#state{uriset=[], responses=Responses1}).


%% @private
handle_info(timeout, SD) ->
    next(SD);

handle_info({timeout, _, proxy_timeout}, SD) ->
    #state{request=SDReq, final_sent=FinalSent, responses=Responses} = SD,
    #sipmsg{sipapp_id=AppId, call_id=CallId} = SDReq,
    ?notice(AppId, CallId, "Proxy Timeout (final sent: ~p)", [FinalSent]),
    case FinalSent of
        false -> 
            Opts = [{reason, <<"Proxy Timeout">>}],
            Fun = fun(#reqdata{expire=Exp, request=Req, response=Resp}=ReqData) ->
                case Exp > 0 andalso Resp of
                    false ->
                        ReqData;
                    #sipmsg{to_tag=ToTag}=Resp when ToTag =/= <<>> ->
                        Resp1 = Resp#sipmsg{response=408, headers=[], content_type=[], 
                                     body=(<<>>), opts=Opts},
                        nksip_dialog_proxy:response(Req, Resp1),
                        ReqData#reqdata{expire=0, response=Resp1};
                    _ ->
                        Resp1 = nksip_reply:reply(Req, {408, [], <<>>, Opts}),
                        nksip_dialog_proxy:response(Req, Resp1),
                        ReqData#reqdata{expire=0, response=Resp1}
                end
            end,
            Responses1 = lists:map(Fun, Responses),
            next(SD#state{uriset=[], responses=Responses1});
        _ -> 
            next(SD#state{uriset=[]})
    end;
    
handle_info(Info, SD) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, SD}.


%% @private
code_change(_OldVsn, SD, _Extra) ->
    {ok, SD}.


%% @private
terminate(_Reason, #state{request=#sipmsg{sipapp_id=AppId, call_id=CallId}}) ->  
    % Stop secondary dialogs not accepted 
    % (for example created from several 180 responses)
    % TODO: Does not work for reINVITES!
    _Fun = fun(DialogId) -> 
        case nksip_dialog:field(state, DialogId) of
            proceeding_uac ->
                ?debug(AppId, CallId, 
                        "Proxy stopping dialog ~s in proceeding_uac", [DialogId]),
                nksip_dialog:stop(DialogId);
            _ ->
                ok
        end
    end,
    % lists:foreach(Fun, nksip_dialog:find_callid(AppId, CallId)),
    ?debug(AppId, CallId, "Proxy process ~p stopped", [self()]),
    ok.




%%====================================================================
%% Internal 
%%====================================================================

%% @private
-spec send_requests([nksip:uri()], nksip_lib:timestamp(),  #state{}, [#reqdata{}]) ->
    [#reqdata{}].

send_requests([], _Expire, _SD, Acc) ->
    Acc;

send_requests([Uri|Rest], Expire, SD, Acc) -> 
    #state{request=Req, record_route=RecordRoute} = SD,
    #sipmsg{sipapp_id=AppId, call_id=CallId, vias=Vias, method=Method} = Req,
    Ref = make_ref(),
    Self = self(),
    RespFun = fun(#sipmsg{response=Code}=Resp) -> 
        ProcFun = fun() ->
            ?debug(AppId, CallId, "Proxy received response ~p (~p)", 
                   [Code, Resp#sipmsg.to_tag]),
            DialogResponse = if
                Method=:='INVITE', Code>100, Code<300, RecordRoute ->
                    nksip_dialog_proxy:response(Req, Resp);
                Method=:='INVITE' -> 
                    ok;     % Do not create dialog
                true -> 
                    nksip_dialog_proxy:response(Req, Resp)
            end,
            case DialogResponse of
                ok ->
                    ok;
                {error, Error} ->
                    ?notice(AppId, CallId,
                            "Proxy dialog response error for ~p: ~p", [Method, Error])
            end,
            case catch gen_server:call(Self, {response, Ref, Resp}) of
                ok ->
                    ok;
                _ when Method=:='INVITE', Code>=200, Code<300 ->
                    ?notice(AppId, CallId, 
                           "Proxy (terminated) received ~p ~p response. "
                           "Sending ACK and BYE", [Method, Code]),
                    case nksip_uac:ack(Resp, []) of
                        ok -> nksip_uac:bye(Resp, [async]);
                        _ -> error
                    end;
                _ ->
                    % Proxy process in no longer available. It could have failed,
                    % or it could be a secondary response from a forking proxy
                    ?debug(AppId, CallId, 
                           "Proxy (terminated) ignoring received ~p ~p response",
                           [Method, Code])
            end
        end,
        proc_lib:spawn_link(ProcFun)
    end,
    Req1 = Req#sipmsg{ruri=Uri},
    case nksip_request:is_local_route(Req1) of
        true ->
            ?warning(AppId, CallId, "tried to stateful proxy a request to itself", []),
            Resp = nksip_reply:reply(Req#sipmsg{vias=[#via{}|Vias]}, loop_detected),
            RespFun(Resp),
            Req4 = Req1#sipmsg{pid=undefined};
        false ->
            case nksip_dialog_proxy:request(Req1) of
                ok ->
                    ok;
                {error, Error} ->
                    ?notice(AppId, CallId, 
                            "Proxy dialog request error for ~p: ~p", [Method, Error])
            end,
            RUriBin = nksip_unparse:uri(Uri),
            Req2 = nksip_transport_uac:add_via(Req1),
            Pid = nksip_transaction_uac:start(Req2),
            case nksip_transport_uac:send_request(Req2) of
                {ok, Req3} ->
                    ?debug(AppId, CallId, "routing statefully ~p to ~s", 
                           [Method, RUriBin]),
                    nksip_transaction_uac:request(Req3, RespFun),
                    Req4 = Req3#sipmsg{pid=Pid};
                error  -> 
                    ?notice(AppId, CallId, "could not route statefully to ~s: ~p", 
                          [RUriBin, network_error]),
                    Resp = nksip_reply:reply(Req#sipmsg{vias=[#via{}|Vias]}, 
                                                    service_unavailable),
                    RespFun(Resp),
                    Req4 = Req1#sipmsg{pid=undefined}
            end
    end,
    ReqData = #reqdata{
        ref = Ref, 
        request = Req4,
        expire = Expire, 
        response = undefined, 
        to_cancel = false
    },
    send_requests(Rest, Expire, SD, [ReqData|Acc]).

%% @private Process a received valid response
-spec process(#state{}) ->
    {noreply, #state{}, non_neg_integer()} | {stop, normal, #state{}}.

process(SD) ->
    #state{responses=[#reqdata{ref=Ref, request=Req, response=Resp}|_]=Responses, 
           uriset=UriSet, final_sent=FinalSent, opts=Opts} = SD,
    #sipmsg{sipapp_id=AppId, response=Code, cseq_method=Method, contacts=Contacts} = Resp,
    #sipmsg{call_id=CallId} = Req,
    ?debug(AppId, CallId, "Proxy received response ~p for ~p (final ~p)", 
           [Code, Method, FinalSent]),
    if
        Code < 101 ->
            next(SD);
        Code < 200, FinalSent =:= false ->
            send_response(Resp, SD),
            next(SD);
        Code < 200 ->
            next(SD);
        Code < 300, FinalSent =/= '6xx' ->
            % Each 2xx is sent every time, even if secondary
            send_response(Resp, SD),
            Responses1 = set_cancel_all(Responses),
            % If we have created other dialogs (i.e from several 180 responses)
            % they will reamain. We don't delete the dialogs here, 
            % when final responses arrive we can send ACK and BYE
            next(SD#state{final_sent='2xx', uriset=[], responses=Responses1});
        Code < 300 ->
            next(SD);
        Code < 400 ->
            case lists:member(follow_redirects, Opts) of
                true when FinalSent =:= false, Contacts =/= [] -> 
                    Contacts1 = case (Req#sipmsg.ruri)#uri.scheme of
                        sips -> [Contact || #uri{scheme=sips}=Contact <- Contacts];
                        _ -> Contacts
                    end,
                    ?debug(AppId, CallId, "proxy redirect to ~p", [Contacts1]),
                    Responses1 = lists:keydelete(Ref, #reqdata.ref, Responses),
                    SD1 = SD#state{uriset=[Contacts1|UriSet], responses=Responses1},
                    handle_cast(launch, SD1);
                _ ->
                    next(SD)
            end;
        Code < 600 ->
            next(SD);
        Code >= 600, FinalSent =:= false->
            send_response(Resp, SD),
            Responses1 = set_cancel_all(Responses),
            next(SD#state{final_sent='6xx', uriset=[], responses=Responses1});
        Code >= 600 ->
            Responses1 = set_cancel_all(Responses),
            next(SD#state{uriset=[], responses=Responses1})
    end.


%% @private: Check expired, start next parallel block, stops execution if necessary
-spec next(#state{}) ->
    {noreply, #state{}, non_neg_integer()} | {stop, normal, #state{}}.

next(SD) ->
    #state{uriset=UriSet, responses=Responses, final_sent=FinalSent, 
           record_route=RR} = SD,
    Now = nksip_lib:timestamp(),
    Update = fun(ReqData) -> check_cancel(check_expired(Now, RR, ReqData)) end,
    Responses1 = lists:map(Update, Responses),
    SD1 = SD#state{responses=Responses1},
    case [true || #reqdata{expire=Expire} <- Responses1, Expire>0] of
        [] when FinalSent =/= false ->
            % No waiting for any other response and final response already sent
            {stop, normal, SD1};
        [] when UriSet =/= [] ->
            % No waiting for any other response: parallel launch has finished
            gen_server:cast(self(), launch),
            {noreply, SD1, ?CHECK_TIMEOUT};
        [] ->
            send_response(best_response(Responses1), SD),
            {stop, normal, SD1};
        _ ->
            % We have pending responses
            {noreply, SD1, ?CHECK_TIMEOUT}
    end.


%% @private
-spec best_response([#reqdata{}]) ->
    nksip:response() | nksip:sipreply().

best_response(Responses) ->
    Sorted = lists:sort([
        if
            Code =:= 401; Code =:= 407 -> 
                {3999, Response};
            Code =:= 415; Code =:= 420; Code =:= 484 -> 
                {4000, Response};
            Code =:= 503 -> 
                Opts1 = [{reason, <<"Communications Error">>}|Opts],
                {5000, Response#sipmsg{response=500, opts=Opts1}};
            Code >= 600 -> 
                {Code, Response};
            true -> 
                {10*Code, Response}
        end
        || #reqdata{response=#sipmsg{response=Code, opts=Opts}=Response} 
            <- Responses, Code>=200
    ]),
    case Sorted of
        [{3999, BestResponse}|_] ->
            Names = [<<"WWW-Authenticate">>, <<"Proxy-Authenticate">>],
            Headers = [
                nksip_lib:delete(BestResponse#sipmsg.headers, Names) |
                [
                    nksip_lib:extract(Headers, Names) || 
                    #reqdata{response=#sipmsg{response=Code, headers=Headers}} 
                        <- Responses, Code=:=401 orelse Code=:=407
                ]
            ],
            BestResponse#sipmsg{headers=lists:flatten(Headers)};
        [{_, BestResponse}|_] ->
            BestResponse;
        _ ->
            temporarily_unavailable
    end.


%% @private Sends a response back to the client
-spec send_response(nksip:response() | nksip:sipreply(), #state{}) ->
    ok.

send_response(#sipmsg{}=Resp, #state{request=Req, final_sent=FinalSent}) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId, pid=Pid} = Req,
    case nksip_transport_uas:send_response(Resp) of
        {ok, Resp1} -> 
            case FinalSent of
                false -> nksip_transaction_uas:response(Pid, Resp1);
                _ -> ok
            end;
        error -> 
            ?notice(AppId, CallId, "Proxy could not send response", [])
    end;

send_response(Reply, #state{request=Req}=SD) ->
    #sipmsg{} = Resp = nksip_reply:reply(Req, Reply),
    send_response(Resp, SD).


-spec set_cancel_all([#reqdata{}]) ->
    [#reqdata{}].

set_cancel_all(ReqDataList) ->
    Fun = fun(#reqdata{expire=Expire, to_cancel=ToCancel}=ReqData) ->
        case Expire>0 andalso ToCancel=:=false of
            true -> ReqData#reqdata{to_cancel=true};
            false -> ReqData
        end
    end,
    lists:map(Fun, ReqDataList).


%% @private
-spec check_cancel(#reqdata{}) ->
    #reqdata{}.

check_cancel(#reqdata{request=#sipmsg{method='INVITE'}=Req, to_cancel=true}=ReqData) ->
    #sipmsg{sipapp_id=AppId, call_id=CallId} = Req,
    ?debug(AppId, CallId, "Proxy sending CANCEL to ~s", 
           [nksip_unparse:uri(Req#sipmsg.ruri)]),
    Cancel = nksip_uac_lib:make_cancel(Req),
    nksip_uac:send_request(Cancel, [async]),
    ReqData#reqdata{to_cancel=cancelled};

check_cancel(ReqData) ->
    ReqData.


%% @private Each expired request is set to expire=0, code=408

-spec check_expired(nksip_lib:timestamp(), boolean(), #reqdata{}) ->
    #reqdata{}.

check_expired(Now, RecordRoute, ReqData) ->
    #reqdata{request=Req, response=Resp, expire=Expire} = ReqData,
    case Expire > 0 andalso Now > Expire of
        true ->
            Opts = [{reason, <<"Timer C Timeout">>}],
            Resp1 = case Resp of 
                #sipmsg{to_tag=ToTag} when ToTag =/= <<>> -> 
                    Resp#sipmsg{response=408, headers=[], content_type=[], 
                                    body=(<<>>), opts = Opts};
                _ ->
                    #sipmsg{vias=[_|Vias]} = Req,
                    nksip_reply:reply(Req#sipmsg{vias=Vias}, {408, [], <<>>, Opts})
            end,
            case RecordRoute of
                true -> nksip_dialog_proxy:response(Req, Resp1);
                false -> ok
            end,
            ReqData#reqdata{expire=0, to_cancel=true, response=Resp1};
        false ->
            ReqData
    end.

