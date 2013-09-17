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

%% @private Call fork processing module
-module(nksip_call_fork).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, cancel/2, response/3]).
-export_type([id/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-type id() :: integer().

-type call() :: nksip_call:call().

-type fork() :: #fork{}.


%% ===================================================================
%% Private
%% ===================================================================

%% @private
%% Recognized options are: follow_redirects
-spec start(nksip_call:trans(), nksip:uri_set(), nksip_lib:proplist(),call()) ->
   call().

start(Trans, UriSet, Opts, #call{next=ForkId, forks=Forks}=Call) ->
    #trans{id=TransId, class=Class, request=Req, method=Method} = Trans,
    Fork = #fork{
        id = ForkId,
        class = Class,
        trans_id = TransId,
        start = nksip_lib:timestamp(),
        uriset = UriSet,
        request  = Req,
        opts = Opts,
        next = 1000*ForkId,
        pending = [],
        responses = [],
        final = false
    },
    ?call_debug("Fork ~p ~p started from UAS ~p", 
                [ForkId, Method, TransId], Call),
    Call1 = Call#call{forks=[Fork|Forks], next=ForkId+1},
    next(Fork, Call1).


%% @private
-spec next(fork(), call()) ->
   call().

next(#fork{pending=[]}=Fork, Call) ->
    #fork{id=Id, final=Final, uriset=UriSet, responses=Resps} = Fork,
    ?call_debug("Fork ~p no pending left: ~p, ~p, ~p", 
               [Id, Final, UriSet, length(Resps)], Call),
    case Final of
        false ->
            case UriSet of
                [] ->
                    Resp = best_response(Resps),
                    ?call_debug("Fork ~p selected ~p response", 
                                [Id, Resp#sipmsg.response], Call),
                    Call1 = send_reply(Resp, Fork, Call),
                    delete(Fork, Call1);
                [Next|Rest] ->
                    launch(Next, Fork#fork{uriset=Rest}, Call)
            end;
        _ ->
            delete(Fork, Call)
    end;

next(#fork{id=Id, pending=Pending}=Fork, #call{forks=[#fork{id=Id}|Rest]}=Call) ->
    ?call_debug("Fork ~p waiting, ~p pending", [Id, length(Pending)], Call),
    Call#call{forks=[Fork|Rest]};

next(#fork{id=Id, pending=Pending}=Fork, #call{forks=Forks}=Call) ->
    ?call_debug("Fork ~p waiting, ~p pending", [Id, length(Pending)], Call),
    Call#call{forks=lists:keystore(Id, #fork.id, Forks, Fork)}.


%% @private
-spec launch([nksip:uri()], fork(), call()) ->
   call().

launch([], Fork, Call) ->
    next(Fork, Call);

launch([Uri|Rest], Fork, Call) -> 
    #fork{id=Id, request=Req, next=Next, pending=Pending, responses=Resps} = Fork,
    #sipmsg{method=Method} = Req,
    Req1 = Req#sipmsg{ruri=Uri},
    case nksip_request:is_local_route(Req1) of
        true ->
            ?call_warning("Fork ~p tried to stateful proxy a request to itself", 
                         [], Call),
            {Resp, _} = nksip_reply:reply(Req, loop_detected),
            Fork1 = Fork#fork{responses=[Resp|Resps]},
            launch(Rest, Fork1, Call);
        false ->
            ?call_debug("Fork ~p launching to ~s", [Id, nksip_unparse:uri(Uri)], Call),
            Call1 = nksip_call_uac:request(Req1, {fork, Next}, Call),
            Fork1 = case Method of
                'ACK' -> Fork#fork{next=Next+1};
                _ -> Fork#fork{next=Next+1, pending=[Next|Pending]}
            end,
            launch(Rest, Fork1, Call1)
    end.


%% @private Called when a launched UAC has a response
-spec response(id(), nksip:response(),call()) ->
   call().

response(_, #sipmsg{response=Code}, Call) when Code < 101 ->
    Call;

response(Id, #sipmsg{vias=[_|Vias]}=Resp, #call{forks=Forks}=Call) ->
    ForkId = Id div 1000,
    Pos = Id - ForkId,
    #sipmsg{to_tag=ToTag, response=Code} = Resp,
    case lists:keyfind(ForkId, #fork.id, Forks) of
        #fork{pending=Pending}=Fork ->
            ?call_debug("Fork ~p received ~p (~p)", [ForkId, Code, ToTag], Call),
            Resp1 = Resp#sipmsg{vias=Vias},
            case lists:member(Pos, Pending) of
                true -> 
                    waiting(Code, Resp1, Pos, Fork, Call);
                false when Code>=200, Code<300 ->
                    send_reply(Resp1, Fork, Call);
                false -> 
                    ?call_info("Fork ~p received unexpected response ~p from ~p",
                               [ForkId, Code, ToTag], Call),
                    Call
            end;
        false ->
            ?call_notice("Fork ~p received ~p while expired", [ForkId, Code], Call),
            Call
    end.


%% @private
-spec waiting(nksip:response_code(), nksip:response(), integer(), fork(), call()) ->
   call().

% 1xx
waiting(Code, Resp, _Pos, #fork{final=Final}=Fork, Call) when Code < 200 ->
    case Final of
        false -> send_reply(Resp, Fork, Call);
        _ -> Call
    end;
    
% 2xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 300 ->
    #fork{final=Final, pending=Pending} = Fork,
    Fork1 = case Final of
        false -> Fork#fork{pending=Pending--[Pos], final='2xx'};
        _ -> Fork#fork{pending=Pending--[Pos]}
    end,
    next(Fork1, send_reply(Resp, Fork, Call));

% 3xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 400 ->
    #fork{
        id = Id,
        final = Final,
        pending = Pending,
        responses = Resps,
        request = #sipmsg{contacts=Contacts, ruri=RUri},
        opts = Opts
    } = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos]},
    case lists:member(follow_redirects, Opts) of
        true when Final=:=false, Contacts =/= [] -> 
            Contacts1 = case RUri#uri.scheme of
                sips -> [Contact || #uri{scheme=sips}=Contact <- Contacts];
                _ -> Contacts
            end,
            ?call_debug("Fork ~p redirect to ~p", [Id, Contacts1], Call),
            launch(Contacts1, Fork1, Call);
        _ ->
            Fork2 = Fork1#fork{responses=[Resp|Resps]},
            next(Fork2, Call)
    end;

% 45xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 600 ->
    #fork{pending=Pending, responses=Resps} = Fork,
    Fork1 = Fork#fork{pending=Pending--[Pos], responses=[Resp|Resps]},
    next(Fork1, Call);

% 6xx
waiting(Code, Resp, Pos, Fork, Call) when Code >= 600 ->
    #fork{final=Final, pending=Pending} = Fork,
    Call1 = cancel_all(Fork, Call),
    Fork1 = Fork#fork{pending=Pending--[Pos]},
    case Final of
        false -> 
            Call2 = send_reply(Resp, Fork, Call1),
            Fork2 = Fork1#fork{final='6xx'},
            next(Fork2, Call2);
        _ ->
            next(Fork1, Call1)
    end.


%% @private Called from the UAS when a Cancel is received
-spec cancel(id(), call()) ->
   call().

cancel(ForkId, #call{forks=Forks}=Call) ->
    case lists:keyfind(ForkId, #fork.trans_id, Forks) of
        #fork{}=Fork -> cancel_all(Fork, Call);
        false -> Call
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec delete(fork(), call()) ->
   call().

delete(#fork{id=Id}, #call{forks=Forks}=Call) ->
    ?call_debug("Fork ~p deleted", [Id], Call),
    Forks1 = lists:keydelete(Id, #fork.id, Forks),
    Call#call{forks=Forks1, hibernate=fork_finished}.


%% @private
-spec send_reply(nksip:response(), fork(), call()) ->
   call().

send_reply(#sipmsg{response=Code}=Resp, #fork{id=Id, trans_id=TransId}, Call) ->
    ?call_debug("Fork ~p send reply to ~p: ~p", [Id, TransId, Code], Call),
    nksip_call_uas:fork_reply(TransId, Resp, Call).


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


%% @private
-spec cancel_all(fork(), call()) ->
   call().
    
cancel_all(#fork{id=Id}, Call) ->
    nksip_call_uac:fork_cancel(Id, Call).




