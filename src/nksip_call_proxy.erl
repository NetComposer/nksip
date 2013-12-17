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

%% @doc Call Proxy Management
-module(nksip_call_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([route/4, response_stateless/2]).
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

%% @doc Tries to route a request to set of uris, serially and/or in parallel.
-spec route(nksip_call:trans(), nksip:uri_set(), [opt()], nksip_call:call()) -> 
    {fork, nksip_call:trans(), nksip:uri_set()} | stateless_proxy | 
    {reply, nksip:sipreply()}.

route(UAS, UriList, ProxyOpts, Call) ->
    try
        UriSet = case normalize_uriset(UriList) of
            [[]] -> throw(temporarily_unavailable);
            UriSet0 -> UriSet0
        end,
        check_forwards(UAS),
        #trans{request=Req, method=Method} = UAS,
        Req1 = preprocess(Req, ProxyOpts),
        Stateless = lists:member(stateless, ProxyOpts),
        case Method of
            'ACK' when Stateless ->
                [[First|_]|_] = UriSet,
                route_stateless(Req1, First, ProxyOpts, Call);
            'ACK' ->
                {fork, UAS#trans{request=Req1}, UriSet};
            _ ->
                case nksip_sipmsg:header(Req, <<"Proxy-Require">>, tokens) of
                    [] -> 
                        ok;
                    PR ->
                        Text = nksip_lib:bjoin([T || {T, _} <- PR]),
                        throw({bad_extension, Text})
                end,
                case 
                    Method=='REGISTER' andalso lists:member(make_path, ProxyOpts)
                of
                    true ->
                        #sipmsg{supported=Supported} = Req,
                        case lists:keymember(<<"path">>, 1, Supported) of
                            true -> ok;
                            false -> throw({extension_required, <<"path">>})
                        end;
                    false ->
                        ok
                end,
                case Stateless of
                    true -> 
                        [[First|_]|_] = UriSet,
                        route_stateless(Req1, First, ProxyOpts, Call);
                    false ->
                        {fork, UAS#trans{request=Req1}, UriSet}
                end
        end
    catch
        throw:Reply -> {reply, Reply}
    end.


%% @private
-spec route_stateless(nksip:request(), nksip:uri(), [opt()], nksip_call:call()) -> 
    stateless_proxy.

route_stateless(Req, Uri, ProxyOpts, Call) ->
    #sipmsg{class={req, Method}} = Req,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,    
    Req1 = Req#sipmsg{ruri=Uri},
    case nksip_request:is_local_route(Req1) of
        true -> 
            ?call_notice("Stateless proxy tried to loop a request to itself", 
                         [], Call),
            throw(loop_detected);
        false ->
            SendOpts = [stateless_via | ProxyOpts++AppOpts],
            case nksip_transport_uac:send_request(Req1, GlobalId, SendOpts) of
                {ok, _} ->  
                    ?call_debug("Stateless proxy routing ~p to ~s", 
                                [Method, nksip_unparse:uri(Uri)], Call);
                error -> 
                    ?call_notice("Stateless proxy could not route ~p to ~s",
                                 [Method, nksip_unparse:uri(Uri)], Call)
                end,
            stateless_proxy
    end.
    

%% @doc Called from {@link nksip_call} when a stateless request is received.
-spec response_stateless(nksip:response(), nksip_call:call()) -> 
    nksip_call:call().

response_stateless(#sipmsg{class={resp, Code, _}}, Call) when Code < 101 ->
    Call;

response_stateless(#sipmsg{vias=[]}, Call) ->
    ?call_notice("Stateless proxy could not send response: no Via", [], Call),
    Call;

response_stateless(#sipmsg{vias=[_|RestVia]}=Resp, Call) ->
    #sipmsg{cseq_method=Method, class={resp, Code, _}} = Resp,
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
    Call.




%%====================================================================
%% Internal 
%%====================================================================


%% @private
-spec check_forwards(nksip_call:trans()) ->
    ok.

check_forwards(#trans{request=#sipmsg{class={req, Method}, forwards=Forwards}}) ->
    if
        is_integer(Forwards), Forwards > 0 ->   
            ok;
        Forwards==0, Method=='OPTIONS' ->
            throw({ok, [], <<>>, [make_supported, make_accept, make_allow, 
                                        {reason_phrase, <<"Max Forwards">>}]});
        Forwards==0 ->
            throw(too_many_hops);
        true -> 
            throw(invalid_request)
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
    SpecRoutes = lists:flatten(proplists:get_all_values(route, ProxyOpts), Routes1),
    case nksip_parse:uris(SpecRoutes) of
        error -> Routes2 = Routes1;
        Routes2 -> ok
    end,
    Req#sipmsg{forwards=Forwards-1, headers=Headers2, routes=Routes2}.


%% @doc Process a UriSet generating a standard `[[nksip:uri()]]'.
%% See test code for examples.
-spec normalize_uriset(nksip:uri_set()) ->
    [[nksip:uri()]].

normalize_uriset(#uri{}=Uri) ->
    [[uri2ruri(Uri)]];

normalize_uriset(UriSet) when is_binary(UriSet) ->
    [pruris(UriSet)];

normalize_uriset(UriSet) when is_list(UriSet) ->
    case nksip_lib:is_string(UriSet) of
        true -> [pruris(UriSet)];
        false -> normalize_uriset(single, UriSet, [], [])
    end;

normalize_uriset(_) ->
    [[]].


normalize_uriset(single, [#uri{}=Uri|R], Acc1, Acc2) -> 
    normalize_uriset(single, R, Acc1++[uri2ruri(Uri)], Acc2);

normalize_uriset(multi, [#uri{}=Uri|R], Acc1, Acc2) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[[uri2ruri(Uri)]]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[[uri2ruri(Uri)]])
    end;

normalize_uriset(single, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    normalize_uriset(single, R, Acc1++pruris(Bin), Acc2);

normalize_uriset(multi, [Bin|R], Acc1, Acc2) when is_binary(Bin) -> 
    case Acc1 of
        [] -> normalize_uriset(multi, R, [], Acc2++[pruris(Bin)]);
        _ -> normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(Bin)])
    end;

normalize_uriset(single, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true -> normalize_uriset(single, R, Acc1++pruris(List), Acc2);
        false -> normalize_uriset(multi, [List|R], Acc1, Acc2)
    end;

normalize_uriset(multi, [List|R], Acc1, Acc2) when is_list(List) -> 
    case nksip_lib:is_string(List) of
        true when Acc1==[] ->
            normalize_uriset(multi, R, [], Acc2++[pruris(List)]);
        true ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(List)]);
        false when Acc1==[] ->  
            normalize_uriset(multi, R, [], Acc2++[pruris(List)]);
        false ->
            normalize_uriset(multi, R, [], Acc2++[Acc1]++[pruris(List)])
    end;

normalize_uriset(Type, [_|R], Acc1, Acc2) ->
    normalize_uriset(Type, R, Acc1, Acc2);

normalize_uriset(_Type, [], [], []) ->
    [[]];

normalize_uriset(_Type, [], [], Acc2) ->
    Acc2;

normalize_uriset(_Type, [], Acc1, Acc2) ->
    Acc2++[Acc1].


uri2ruri(Uri) ->
    Uri#uri{ext_opts=[], ext_headers=[]}.

pruris(RUri) ->
    case nksip_parse:uris(RUri) of
        error -> [];
        RUris -> [uri2ruri(Uri) || Uri <- RUris]
    end.



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

    ?assert(normalize_uriset([]) == [[]]),
    ?assert(normalize_uriset(a) == [[]]),
    ?assert(normalize_uriset([a,b]) == [[]]),
    ?assert(normalize_uriset("sip:a") == [[UriA]]),
    ?assert(normalize_uriset(<<"sip:b">>) == [[UriB]]),
    ?assert(normalize_uriset("other") == [[]]),
    ?assert(normalize_uriset(UriC) == [[UriC]]),
    ?assert(normalize_uriset([UriD]) == [[UriD]]),
    ?assert(normalize_uriset(["sip:a", "sip:b", UriC, <<"sip:d">>, "sip:e"]) 
                                            == [[UriA, UriB, UriC, UriD, UriE]]),
    ?assert(normalize_uriset(["sip:a", ["sip:b", UriC], <<"sip:d">>, ["sip:e"]]) 
                                            == [[UriA], [UriB, UriC], [UriD], [UriE]]),
    ?assert(normalize_uriset([["sip:a", "sip:b", UriC], <<"sip:d">>, "sip:e"]) 
                                            == [[UriA, UriB, UriC], [UriD], [UriE]]),
    ok.

-endif.



