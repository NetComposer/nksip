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

-module(nksip_call_fork).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, cancel/2, response/4, timer/3]).

-include("nksip.hrl").
-include("nksip_call.hrl").



%% @private
start(UAS, UriSet, Opts, #call{next=ForkId, forks=Forks}=SD) ->
    #trans{id=TransId, request=Req, method=Method, status=Status} = UAS,
    Timeout = nksip_config:get(proxy_timeout),
    Timer = erlang:start_timer(1000*Timeout, self(), {fork, timeout, ForkId}),
    Fork = #fork{
        id = ForkId,
        trans_id = TransId,
        uriset = UriSet,
        request  = Req,
        next = 1,
        pending = [],
        opts = Opts,
        responses = [],
        final = false,
        timeout = Timer
    },
    ?call_debug("UAS ~p ~p (~p) started fork ~p", 
                [TransId, Method, Status, ForkId], SD),
    SD1 = SD#call{forks=[Fork|Forks], next=ForkId+1},
    next(Fork, SD1).

next(#fork{pending=[], final=Final, uriset=UriSet, responses=Resps}=Fork, SD) ->
    case Final of
        false ->
            case UriSet of
                [] ->
                    Resp = best_response(Resps),
                    SD1 = send_reply(Resp, Fork, SD),
                    delete(Fork, SD1);
                [Next|Rest] ->
                    launch(Next, Fork#fork{uriset=Rest}, SD)
            end;
        true ->
            delete(Fork, SD)
    end;

next(#fork{id=Id}=Fork, #call{forks=[#fork{id=Id}|Rest]}=SD) ->
    SD#call{forks=[Fork|Rest]};

next(#fork{id=Id}=Fork, #call{forks=Forks}=SD) ->
    Forks1 = lists:keystore(Id, #fork.id, Forks, Fork),
    SD#call{forks=Forks1}.


launch([], Fork, SD) ->
    next(Fork, SD);

launch([Uri|Rest], Fork, SD) -> 
    #fork{id=Id, request=Req, next=Next, pending=Pending, responses=Resps} = Fork,
    Req1 = Req#sipmsg{ruri=Uri},
    case nksip_request:is_local_route(Req1) of
        true ->
            ?call_warning("Fork ~p tried to stateful proxy a request to itself", 
                         [], SD),
            Resp = nksip_reply:reply(Req, loop_detected),
            Fork1 = Fork#fork{responses=[Resp|Resps]},
            launch(Rest, Fork1, SD);
        false ->
            Req2 = nksip_transport_uac:add_via(Req1),
            RespFun = fun(Resp) -> 
                

                
            SD1 = nksip_call_uac:request(Req2, {fork, Id, Next}, SD),
            Fork1 = Fork#fork{next=Next+1, pending=[Next|Pending]},
            launch(Rest, Fork1, SD1)
    end.


cancel(#trans{id=TransId}, #call{forks=Forks}=SD) ->
    case lists:keyfind(TransId, #fork.trans_id, Forks) of
        #fork{}=Fork -> {ok, cancel_all(Fork, SD)};
        false -> not_found
    end.



response(_ForkId, _Pos, #sipmsg{response=Code}, SD) when Code < 101 ->
    SD;

response(ForkId, Pos, Resp, #call{forks=Forks}=SD) ->
    #sipmsg{vias=[_|Vias], to_tag=ToTag, response=Code} = Resp,
    case lists:keyfind(ForkId, #fork.id, Forks) of
        #fork{pending=Pending}=Fork ->
            Resp1 = Resp#sipmsg{vias=Vias},
            ?call_debug("Fork ~p received ~p (~p)", [ForkId, Code, ToTag], SD),
            case lists:member(Pos, Pending) of
                true -> 
                    waiting(Code, Resp1, Pos, Fork, SD);
                false -> 
                    ?call_info("Fork ~p received unexpected response ~p from ~p",
                               [ForkId, Code, ToTag], SD),
                    SD
            end;
        false ->
            ?call_notice("Fork ~p received ~p while expired", [ForkId, Code], SD),
            SD
    end.

% 1xx
waiting(Code, Resp, _Pos, #fork{final=Final}=Fork, SD) when Code < 200 ->
    case Final of
        false -> send_reply(Resp, Fork, SD);
        true -> SD
    end;
    
% 2xx
waiting(Code, Resp, Pos, Fork, SD) when Code < 300 ->
    #fork{final=Final, pending=Pending} = Fork,
    SD1 = case Final=/='6xx' of
        true -> send_reply(Resp, Fork, SD);
        false -> SD
    end,
    Fork1 = Fork#fork{pending=Pending--[Pos], final='2xx'},
    next(Fork1, SD1);

% 3xx
waiting(Code, Resp, Pos, Fork, SD) when Code < 400 ->
    #fork{
        id = Id,
        final = Final,
        pending = Pending,
        opts = Opts,
        responses = Resps,
        request = #sipmsg{contacts=Contacts, ruri=RUri}
    } = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos]},
    case lists:member(follow_redirects, Opts) of
        true when Final=:=false, Contacts =/= [] -> 
            Contacts1 = case RUri#uri.scheme of
                sips -> [Contact || #uri{scheme=sips}=Contact <- Contacts];
                _ -> Contacts
            end,
            ?call_debug("Fork ~p redirect to ~p", [Id, Contacts1], SD),
            launch(Contacts1, Fork1, SD);
        _ ->
            Fork2 = Fork1#fork{responses=[Resp|Resps]},
            next(Fork2, SD)
    end;

% 45xx
waiting(Code, Resp, Pos, Fork, SD) when Code < 600 ->
    #fork{pending=Pending, responses=Resps} = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos], responses=[Resp|Resps]},
    next(Fork1, SD);

% 6xx
waiting(Code, Resp, Pos, Fork, SD) when Code >= 600 ->
    #fork{final=Final, pending=Pending} = Fork,
    SD1 = cancel_all(Fork, SD),
    Fork1 = Fork#fork{pending=Pending--[Pos]},
    case Final of
        false -> 
            SD2 = send_reply(Resp, Fork, SD1),
            Fork2 = Fork1#fork{final='6xx'},
            next(Fork2, SD2);
        _ ->
            next(Fork1, SD1)
    end.





timer(timeout, #fork{final=false}=Fork, SD) ->
    delete(Fork#fork{timeout=undefined}, SD);

timer(timeout, #fork{request=Req}=Fork, SD) ->
    Resp = nksip_reply:reply(Req, {timeout, <<"Proxy Timeout">>}),
    SD1 = send_reply(Resp, Fork, SD),
    delete(Fork#fork{timeout=undefined}, SD1).



%% ===================================================================
%% Internal
%% ===================================================================


delete(#fork{id=Id, timeout=Timer}, #call{forks=Forks}=SD) ->
    nksip_lib:cancel_timer(Timer),
    Forks1 = lists:keydelete(Id, #fork.id, Forks),
    SD#call{forks=Forks1, hibernate=true}.


send_reply(Resp, #fork{trans_id=TransId}, SD) ->
    nksip_call_uas:sipapp_reply(fork, TransId, Resp, SD).




%% @private
-spec best_response([#sipmsg{}]) ->
    nksip:response() | nksip:sipreply().

best_response(Resps) ->
    Sorted = lists:sort([
        if
            Code =:= 401; Code =:= 407 -> 
                {3999, Resp};
            Code =:= 415; Code =:= 420; Code =:= 484 -> 
                {4000, Resp};
            Code =:= 503 -> 
                {5000, Resp#sipmsg{response=500}};
            Code >= 600 -> 
                {Code, Resp};
            true -> 
                {10*Code, Resp}
        end
        || #sipmsg{response=Code}=Resp <- Resps
    ]),
    case Sorted of
        [{3999, Best}|_] ->
            Names = [<<"WWW-Authenticate">>, <<"Proxy-Authenticate">>],
            Headers1 = [
                nksip_lib:delete(Best#sipmsg.headers, Names) |
                [
                    nksip_lib:extract(Headers, Names) || 
                    #sipmsg{response=Code, headers=Headers}
                    <- Resps, Code=:=401 orelse Code=:=407
                ]
            ],
            Best#sipmsg{headers=lists:flatten(Headers1)};
        [{_, Best}|_] ->
            Best;
        _ ->
            temporarily_unavailable
    end.

cancel_all(_Fork, SD) ->
    SD.




