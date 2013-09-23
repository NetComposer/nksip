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

%% @private Call proxy management functions
-module(nksip_call_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([check/4, response_stateless/2]).
-export([normalize_uriset/1]).

-include("nksip.hrl").
-include("nksip_call.hrl").

-type opt() ::  stateless | record_route | follow_redirects |
                {headers, [nksip:header()]} | 
                {route, nksip:user_uri() | [nksip:user_uri()]} |
                remove_routes | remove_headers.



%% ===================================================================
%% Private
%% ===================================================================

%% @private Routes a `Request' to set of uris, serially and/or in parallel.
%% See {@link nksip_sipapp:route/6} for an options description.
-spec check(nksip_call:trans(), nksip:uri_set(), [opt()], nksip_call:call()) -> 
    {fork, nksip_call:trans(), nksip:uri_set()} | stateless_proxy | 
    {reply, nksip:sipreply()}.

check(UAS, UriList, ProxyOpts, Call) ->
    case normalize_uriset(UriList) of
        [[]] -> {reply, temporarily_unavailable};
        UriSet -> route(UAS, UriSet, ProxyOpts, Call)
    end.


%% @private
-spec route(nksip_call:trans(), nksip:uri_set(), [opt()], nksip_call:call()) -> 
    {fork, nksip_call:trans(), nksip:uri_set()} | stateless_proxy | 
    {reply, nksip:sipreply()}.

route(#trans{method='ACK'}=UAS, [[First|_]|_]=UriSet, ProxyOpts, Call) ->
    Stateless = lists:member(stateless, ProxyOpts),
    case check_forwards(UAS) of
        ok when Stateless -> route_stateless(UAS, First, ProxyOpts, Call);
        ok -> route_stateful(UAS, UriSet, ProxyOpts);
        {reply, Reply} ->{reply, Reply}
    end;

route(UAS, [[First|_]|_]=UriSet, ProxyOpts, Call) ->
    #trans{request=Req} = UAS,
    Stateless = lists:member(stateless, ProxyOpts),
    case check_forwards(UAS) of
        ok -> 
            case nksip_sipmsg:header(Req, <<"Proxy-Require">>, tokens) of
                [] when not Stateless ->
                    route_stateful(UAS, UriSet, ProxyOpts);
                [] when Stateless ->
                    route_stateless(UAS, First, ProxyOpts, Call);
                PR ->
                    Text = nksip_lib:bjoin([T || {T, _} <- PR]),
                    {reply, {bad_extension, Text}}
            end;
        {reply, Reply} ->
            {reply, Reply}
    end.


%% @private
-spec route_stateful(nksip_call:trans(), nksip:uri_set(), [opt()]) -> 
    {fork, nksip_call:trans(), nksip:uri_set()}.

route_stateful(#trans{request=Req}=UAS, UriSet, ProxyOpts) ->
    Req1 = preprocess(Req, ProxyOpts),
    {fork, UAS#trans{request=Req1}, UriSet}.


%% @private
-spec route_stateless(nksip_call:trans(), nksip:uri(), [opt()], nksip_call:call()) -> 
    stateless_proxy | {reply, nksip:sipreply()}.

route_stateless(#trans{request=Req}, Uri, ProxyOpts, Call) ->
    #sipmsg{method=Method} = Req,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,    
    Req1 = preprocess(Req#sipmsg{ruri=Uri}, ProxyOpts),
    case nksip_request:is_local_route(Req1) of
        true -> 
            ?call_notice("Stateless proxy tried to loop a request to itself", 
                         [], Call),
            {reply, loop_detected};
        false ->
            Req2 = nksip_transport_uac:add_via(Req1, GlobalId, [stateless|AppOpts]),
            case nksip_transport_uac:send_request(Req2, GlobalId, ProxyOpts++AppOpts) of
                {ok, _} ->  
                    ?call_debug("Stateless proxy routing ~p to ~s", 
                                [Method, nksip_unparse:uri(Uri)], Call);
                error -> 
                    ?call_notice("Stateless proxy could not route ~p to ~s",
                                 [Method, nksip_unparse:uri(Uri)], Call)
                end,
            stateless_proxy
    end.
    

%% @private Called from nksip_call_uac when a stateless request is received
-spec response_stateless(nksip:response(), nksip_call:call()) -> 
    nksip_call:call().

response_stateless(#sipmsg{response=Code}, Call) when Code < 101 ->
    Call;

response_stateless(#sipmsg{vias=[_|RestVia]}=Resp, Call) when RestVia=/=[] ->
    #sipmsg{cseq_method=Method, response=Code} = Resp,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    Resp1 = Resp#sipmsg{vias=RestVia},
    case nksip_transport_uas:send_response(Resp1, GlobalId, AppOpts) of
        {ok, _} -> 
            ?call_debug("Stateless proxy sent ~p ~p response", 
                        [Method, Code], Call);
        error -> 
            ?call_notice("Stateless proxy could not send ~p ~p response", 
                         [Method, Code], Call)
    end,
    Call;

response_stateless(_, Call) ->
    ?call_notice("Stateless proxy could not send response: no Via", [], Call),
    Call.



%%====================================================================
%% Internal 
%%====================================================================


%% @private
-spec check_forwards(nksip_call:trans()) ->
    ok | {reply, nksip:sipreply()}.

check_forwards(#trans{request=#sipmsg{method=Method, forwards=Forwards}}) ->
    if
        is_integer(Forwards), Forwards > 0 ->   
            ok;
        Forwards=:=0, Method=:='OPTIONS' ->
            {reply, {ok, [], <<>>, [make_supported, make_accept, make_allow, 
                                        {reason, <<"Max Forwards">>}]}};
        Forwards=:=0 ->
            {reply, too_many_hops};
        true -> 
            {reply, invalid_request}
    end.


%% @private
-spec preprocess(nksip:request(), [opt()]) ->
    nksip:request().

preprocess(#sipmsg{forwards=Forwards, routes=Routes, headers=Headers}=Req, ProxyOpts) ->
    Routes1 = case lists:member(remove_routes, ProxyOpts) of
        true -> [];
        false -> Routes
    end,
    Headers1 = case lists:member(remove_headers, ProxyOpts) of
        true -> [];
        false -> Headers
    end,
    Headers2 = lists:flatten([proplists:get_all_values(headers, ProxyOpts), Headers1]),
    Routes2 = nksip_parse:uris(
                lists:flatten(proplists:get_all_values(route, ProxyOpts), Routes1)),
    Req#sipmsg{forwards=Forwards-1, headers=Headers2, routes=Routes2}.


%% @private Process a UriSet generating a standard [[nksip:uri()]]
%% See test bellow for examples
-spec normalize_uriset(nksip:uri_set()) ->
    [[nksip:uri()]].

normalize_uriset(#uri{}=Uri) ->
    [[Uri]];

normalize_uriset(UriSet) when is_binary(UriSet) ->
    case nksip_parse:uris(UriSet) of
        [] -> [[]];
        UriList -> [UriList]
    end;

normalize_uriset(UriSet) when is_list(UriSet) ->
    case nksip_lib:is_string(UriSet) of
        true ->
            case nksip_parse:uris(UriSet) of
                [] -> [[]];
                UriList -> [UriList]
            end;
        false ->
            normalize_uriset(single, UriSet, [], [])
    end;

normalize_uriset(_) ->
    [[]].


normalize_uriset(single, [#uri{}=Uri|R], Acc1, Acc2) -> 
    normalize_uriset(single, R, Acc1++[Uri], Acc2);

normalize_uriset(multi, [#uri{}=Uri|R], Acc1, Acc2) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[[Uri]]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[[Uri]])
    end;

normalize_uriset(single, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    normalize_uriset(single, R, Acc1++nksip_parse:uris(Bin), Acc2);

normalize_uriset(multi, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[nksip_parse:uris(Bin)]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[nksip_parse:uris(Bin)])
    end;

normalize_uriset(single, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true -> normalize_uriset(single, R, Acc1++nksip_parse:uris(List), Acc2);
        false -> normalize_uriset(multi, [List|R], Acc1, Acc2)
    end;

normalize_uriset(multi, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true when Acc1=:=[] ->
            normalize_uriset(multi, R, [], Acc2++[nksip_parse:uris(List)]);
        true ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[nksip_parse:uris(List)]);
        false when Acc1=:=[] ->  
            normalize_uriset(multi, R, [], Acc2++[nksip_parse:uris(List)]);
        false ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[nksip_parse:uris(List)])
    end;

normalize_uriset(Type, [_|R], Acc1, Acc2) ->
    normalize_uriset(Type, R, Acc1, Acc2);

normalize_uriset(_Type, [], [], []) ->
    [[]];

normalize_uriset(_Type, [], [], Acc2) ->
    Acc2;

normalize_uriset(_Type, [], Acc1, Acc2) ->
    Acc2++[Acc1].



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


normalize_test() ->
    UriA = #uri{domain=(<<"a">>)},
    UriB = #uri{domain=(<<"b">>)},
    UriC = #uri{domain=(<<"c">>)},
    UriD = #uri{domain=(<<"d">>)},
    UriE = #uri{domain=(<<"e">>)},

    ?assert(normalize_uriset([]) =:= [[]]),
    ?assert(normalize_uriset(a) =:= [[]]),
    ?assert(normalize_uriset([a,b]) =:= [[]]),
    ?assert(normalize_uriset("sip:a") =:= [[UriA]]),
    ?assert(normalize_uriset(<<"sip:b">>) =:= [[UriB]]),
    ?assert(normalize_uriset("other") =:= [[]]),
    ?assert(normalize_uriset(UriC) =:= [[UriC]]),
    ?assert(normalize_uriset([UriD]) =:= [[UriD]]),
    ?assert(normalize_uriset(["sip:a", "sip:b", UriC, <<"sip:d">>, "sip:e"]) 
                                            =:= [[UriA, UriB, UriC, UriD, UriE]]),
    ?assert(normalize_uriset(["sip:a", ["sip:b", UriC], <<"sip:d">>, ["sip:e"]]) 
                                            =:= [[UriA], [UriB, UriC], [UriD], [UriE]]),
    ?assert(normalize_uriset([["sip:a", "sip:b", UriC], <<"sip:d">>, "sip:e"]) 
                                            =:= [[UriA, UriB, UriC], [UriD], [UriE]]),
    ok.

-endif.



