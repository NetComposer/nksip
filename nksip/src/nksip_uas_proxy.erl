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

%% @doc UAS FSM proxy management functions

-module(nksip_uas_proxy).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([proxy/3, response_stateless/1]).
-export([normalize_uriset/1]).

-include("nksip.hrl").

-type opt() :: stateless | record_route | follow_redirects |
                {headers, [nksip:header()]} | 
                {route, nksip:user_uri() | [nksip:user_uri()]} |
                remove_routes | remove_headers.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Routes a `Request' to set of uris, serially and/or in parallel.
%% See {@link nksip_sipapp:route/6} for an options description.
-spec proxy(nksip:request(), nksip:uri_set(), [opt()]) -> 
    ignore | nksip:sipreply() .

proxy(Req, UriSet, Opts) ->
    #sipmsg{sipapp_id=AppId, method=Method, opts=ReqOpts, call_id=CallId} = Req,
    case normalize_uriset(UriSet) of
        [[]] when Method =:= 'ACK' -> 
            ?notice(AppId, CallId, "proxy has no URI to route ACK", []),
            temporarily_unavailable;
        [[]] -> 
            temporarily_unavailable;
        [[Uri|_]|_] when Method =:= 'CANCEL' -> 
            cancel(Req, Uri, Opts);
        [[Uri|_]|_] when Method =:= 'ACK' -> 
            case check_forwards(Req) of
                ok -> route_stateless(Req, Uri, Opts);
                {reply, Reply} -> Reply
            end;
        [[Uri|_]|_] = NUriSet -> 
            Request1 = case lists:member(record_route, Opts) of 
                true when Method=:='INVITE' -> 
                    Req#sipmsg{opts=[record_route|ReqOpts]};
                _ -> 
                    % TODO 16.6.4: If ruri or top route has sips, and not received with 
                    % tls, must record_route. If received with tls, and no sips in ruri
                    % or top route, must record_route also
                    Req
            end,
            Stateless = lists:member(stateless, Opts),
            case check_forwards(Req) of
                ok -> 
                    case nksip_parse:header_tokens(<<"Proxy-Require">>, Req) of
                        [] when not Stateless ->
                            route_stateful(Request1, NUriSet, Opts);
                        [] when Stateless ->
                            route_stateless(Request1, Uri, Opts);
                        PR ->
                            Text = nksip_lib:bjoin([T || {T, _} <- PR]),
                            {bad_extension, Text}
                    end;
                {reply, Reply} ->
                    Reply
            end
    end.


%% @private
-spec cancel(nksip:request(), nksip:uri(), [opt()]) -> 
    ignore | nksip:sipreply() .

cancel(#sipmsg{sipapp_id=AppId, call_id=CallId, from_tag=FromTag}=Req, Uri, Opts) ->
    case nksip_transaction_uas:is_cancel(Req) of
        {true, _Req} ->
            lists:foreach(
                fun({_, ProxyPid}) -> gen_server:cast(ProxyPid, cancel) end,
                nksip_proc:values({nksip_proxy_callid, AppId, CallId, FromTag})),
            ok;
        false  ->
            route_stateless(Req, Uri, Opts)
    end.


%% @private
-spec route_stateful(nksip:request(), nksip:uri_set(), nksip_lib:proplist()) ->
    ignore.

route_stateful(Req, UriSet, Opts) ->
    Req1 = preprocess(Req, Opts),
    nksip_proxy:start(UriSet, Req1, Opts),
    ignore.


%% @private
-spec route_stateless(nksip:request(), nksip:uri(), nksip_lib:proplist()) -> 
    ignore.

route_stateless(#sipmsg{sipapp_id=AppId, call_id=CallId, method=Method, opts=ROpts}=Req, 
                Uri, Opts) ->
    Req1 = preprocess(Req#sipmsg{ruri=Uri, opts=[stateless|ROpts]}, Opts),
    case nksip_request:is_local_route(Req1) of
        true -> 
            ?notice(AppId, CallId,
                    "Stateless proxy tried to stateless proxy a request to itself", []),
            loop_detected;
        false ->
            ?debug(AppId, CallId, "Proxy stateless ~p", [Method]),
            case Method of
                'ACK' -> nksip_dialog_proxy:request(Req1);
                _ -> ok
            end,
            Req2 = nksip_transport_uac:add_via(Req1),
            case nksip_transport_uac:send_request(Req2) of
                {ok, _} ->  
                    ?debug(AppId, CallId, "stateless proxy routing ~p to ~s", 
                                        [Method, nksip_unparse:uri(Uri)]);
                error -> 
                    ?notice(AppId, CallId, "stateless proxy could not route "
                                     "~p to ~s", [ Method, nksip_unparse:uri(Uri)])
            end,
            ignore
    end.
    

%% @private Called from nksip_transport_uac when a request 
%% is received by a stateless proxy
-spec response_stateless(nksip:response()) -> 
    ok.

response_stateless(#sipmsg{sipapp_id=AppId, call_id=CallId, vias=[_|RestVia]}=Response) 
                    when RestVia=/=[] ->
    case nksip_transport_uas:send_response(Response#sipmsg{vias=RestVia}) of
        {ok, _} -> ?debug(AppId, CallId, "stateless proxy sent response", []);
        error -> ?notice(AppId, CallId, "stateless proxy could not send response", [])
    end;

response_stateless(#sipmsg{sipapp_id=AppId, call_id=CallId}) ->
    ?notice(AppId, CallId, "stateless proxy could not send response: no Via", []).



%%====================================================================
%% Internal 
%%====================================================================


%% @private
-spec check_forwards(nksip:request()) ->
    ok | {reply, nksip:sipreply()}.

check_forwards(#sipmsg{forwards=Forwards, method=Method}) ->
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
-spec preprocess(nksip:request(), nksip_lib:proplist()) ->
    nksip:request().

preprocess(#sipmsg{forwards=Forwards, routes=Routes, headers=Headers}=Req, Opts) ->
    Routes1 = case lists:member(remove_routes, Opts) of
        true -> [];
        false -> Routes
    end,
    Headers1 = case lists:member(remove_headers, Opts) of
        true -> [];
        false -> Headers
    end,
    Req#sipmsg{
        forwards = Forwards - 1, 
        headers = nksip_lib:get_value(headers, Opts, []) ++ Headers1, 
        routes = nksip_parse:uris(nksip_lib:get_value(route, Opts, [])) ++ Routes1
    }.


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



