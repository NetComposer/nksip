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

%% @doc Authentication management module.

-module(nksip_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([get_authentication/1, realms/1, make_ha1/3, make_request/3]).
-export([check_digest/1, make_response/2]).

-include("nksip.hrl").

-define(RESP_WWW, (<<"WWW-Authenticate">>)).
-define(RESP_PROXY, (<<"Proxy-Authenticate">>)).
-define(REQ_WWW,  (<<"Authorization">>)).
-define(REQ_PROXY,  (<<"Proxy-Authorization">>)).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Extracts all the realms present in <i>WWW-Authenticate</i> or
%% <i>Proxy-Authenticate</i> headers from a response
-spec realms(Response::nksip:response()) ->
    [Realm::binary()].

realms(#sipmsg{headers=Headers}) ->
    realms(Headers, []).

realms([{Name, Value}|Rest], Acc) ->
    if
        Name=:=?RESP_WWW; Name=:=?RESP_PROXY ->
            case parse_header(Value) of
                error -> realms(Rest, Acc);
                AuthData -> realms(Rest, [nksip_lib:get_value(realm, AuthData)|Acc])
            end;
        true ->
            realms(Rest, Acc)
    end;
realms([], Acc) ->
    lists:usort(Acc).


%% @doc Generates a password hash to use in NkSIP authentication.
%% In order to avoid storing the user's passwords in clear text, you can generate 
%% a `hash' (fom `User', `Pass' and `Realm') and store and use it in
%% {@link nksip_sipapp:get_user_pass/4} instead of the real password.
-spec make_ha1(binary()|string(), binary()|string(), binary()|string()) -> 
    binary().

make_ha1(User, Pass, Realm) ->
    % <<"HA1!">> is a custom header to be detected as a ha1 hash
    <<"HA1!", (crypto:md5(list_to_binary([User, $:, Realm, $:, Pass])))/binary>>.


%% @doc Extracts digest authentication information from a incoming request.
%% The response can include:
%% <ul>
%%    <li>`{{digest, Realm}, true}': there is at least one valid user authenticated
%%        with this `Realm'.</li>
%%    <li>`{{digest, Realm}, false}': there is at least one user offering 
%%        an authentication header for this `Realm', but all of them have
%%        failed the authentication.</li>
%% </ul>
%%
-spec get_authentication(nksip:request()) -> [Authorized] when
    Authorized :: {digest, Realm::binary(), true|false}.

get_authentication(Req) ->
    Fun = fun({Ok, _User, Realm}, Acc) ->
        case lists:keyfind(Realm, 1, Acc) of
            false when Ok -> [{Realm, true}|Acc];
            false -> [{Realm, false}|Acc];
            {Realm, true} -> Acc;
            {Realm, false} when Ok -> lists:keystore(Realm, 1, Acc, {Realm, true});
            {Realm, false} -> Acc
        end
    end,
    [{{digest, Realm}, Ok} || {Realm, Ok} <- lists:foldl(Fun, [], check_digest(Req))].


%% @doc Adds an <i>Authorization</i> or <i>Proxy-Authorization</i> header 
%% and updates <i>CSeq</i> of a request after receiving a 401 or 407 response.
%% CSeq must be updated after calling this function.
%%
%% Recognized options are pass, user, cnonce and nc
-spec make_request(Req::nksip:request(), Resp::nksip:response(), nksip_lib:proplist()) ->
    {ok, nksip:request()} | {error, Error}
    when Error :: invalid_auth_header | unknown_nonce | no_pass.

make_request(Req, #sipmsg{headers=RespHeaders}, Opts) ->
    #sipmsg{
        ruri = RUri, 
        method = Method, 
        from = #uri{user=User}, 
        headers=ReqHeaders
    } = Req,
    try
        ReqAuthHeaders = nksip_lib:extract(ReqHeaders, [?REQ_WWW, ?REQ_PROXY]),
        ReqNOnces = [nksip_lib:get_value(nonce, parse_header(ReqAuthHeader)) 
                        || {_, ReqAuthHeader} <- ReqAuthHeaders],
        RespAuthHeaders = nksip_lib:extract(RespHeaders, [?RESP_WWW, ?RESP_PROXY]),
        case RespAuthHeaders of
            [{RespName, RespData}] -> ok;
            _ -> RespName = RespData = throw(invalid_auth_header)
        end,
        case parse_header(RespData) of
            error -> AuthHeaderData = throw(invalid_auth_header);
            AuthHeaderData -> ok
        end,
        RespNOnce = nksip_lib:get_value(nonce, AuthHeaderData),
        case lists:member(RespNOnce, ReqNOnces) of
            true -> throw(unknown_nonce);
            false -> ok
        end,
        case get_passes(Opts, []) of
            [] -> 
                Opts1 = throw(no_pass);
            Passes ->
                Opts1 = [
                    {method, Method}, 
                    {ruri, RUri}, 
                    {user, nksip_lib:get_binary(user, Opts, User)}, 
                    {passes, Passes} 
                    | Opts
                ]
        end,
        case make_auth_request(AuthHeaderData, Opts1) of
            error -> 
                throw(invalid_auth_header);
            {ok, ReqData} ->
                ReqName = case RespName of
                    ?RESP_WWW -> ?REQ_WWW;
                    ?RESP_PROXY -> ?REQ_PROXY
                end,
                ReqHeaders1 = [{ReqName, ReqData}|ReqHeaders],
                {ok, Req#sipmsg{headers=ReqHeaders1}}
        end
    catch
        throw:Error -> {error, Error}
    end.


%% @doc Generates a <i>WWW-Authenticate</i> or <i>Proxy-Authenticate</i> header
%% in response to a `Request'. 
%% Use this function to answer to a request with a 401 or 407 response.
%%
%% A new `nonce' will be generated to be used by the client in its response, 
%% but will expire after the time configured in global parameter `once_timeout'.
%%
-spec make_response(binary(), nksip:request()) ->
    binary().

make_response(Realm, Req) ->
    #sipmsg{
        app_id = AppId, 
        call_id = CallId,
        transport=#transport{remote_ip=Ip, remote_port=Port}
    } = Req,
    Nonce = nksip_lib:luid(),
    Timeout = nksip_config:get(nonce_timeout),
    put_nonce(AppId, CallId, Nonce, {Ip, Port}, Timeout),
    Opaque = nksip_lib:hash(AppId),
    list_to_binary([
        "Digest realm=\"", Realm, "\", nonce=\"", Nonce, "\", "
        "algorithm=MD5, qop=\"auth\", opaque=\"", Opaque, "\""
    ]).




%% ===================================================================
%% Private
%% ===================================================================


%% @private Finds auth headers in request, and for each one extracts user and 
%% realm, calling `get_user_pass/4' callback to check if it is correct.
%% For each user and realm having a correct password returns `{true, User, Realm}',
%% and `{false, User, Realm}' for each one having an incorrect password.
-spec check_digest(Req::nksip:request()) ->
    [{boolean(), User::binary(), Realm::binary()}].

check_digest(#sipmsg{headers=Headers}=Req) ->
    check_digest(Headers, Req, []).


%% @private
check_digest([], _Req, Acc) ->
    Acc;

check_digest([{Name, Data}|Rest], #sipmsg{app_id=AppId}=Req, Acc) 
                when Name=:=?REQ_WWW; Name=:=?REQ_PROXY ->
    case parse_header(Data) of
        error ->
            check_digest(Rest, Req, Acc);
        AuthData ->
            Resp = nksip_lib:get_value(response, AuthData),
            User = nksip_lib:get_binary(username, AuthData),
            Realm = nksip_lib:get_binary(realm, AuthData),
            Result = case 
                nksip_sipapp_srv:sipapp_call_sync(AppId, get_user_pass, [User, Realm]) 
            of
                true -> true;
                false -> false;
                Pass -> check_auth_header(AuthData, Resp, User, Realm, Pass, Req)
            end,
            case Result of
                true ->
                    check_digest(Rest, Req, [{true, User, Realm}|Acc]);
                false ->
                    check_digest(Rest, Req, [{false, User, Realm}|Acc]);
                not_found ->
                    check_digest(Rest, Req, Acc)
            end
    end;
    
check_digest([_|Rest], Req, Acc) ->
    check_digest(Rest, Req, Acc).



%% @private Generates a Authorization or Proxy-Authorization header
-spec make_auth_request(nksip_lib:proplist(), nksip_lib:proplist()) ->
    {ok, binary()} | error.

make_auth_request(AuthHeaderData, UserOpts) ->
    QOP = nksip_lib:get_value(qop, AuthHeaderData, []),
    Algorithm = nksip_lib:get_value(algorithm, AuthHeaderData, 'MD5'),
    case Algorithm=:='MD5' andalso (QOP=:=[] orelse lists:member(auth, QOP)) of
        true ->
            case nksip_lib:get_binary(cnonce, UserOpts) of
                <<>> -> CNonce = nksip_lib:luid();
                CNonce -> ok
            end,
            Nonce = nksip_lib:get_binary(nonce, AuthHeaderData, <<>>),  
            Nc = nksip_lib:msg("~8.16.0B", [nksip_lib:get_integer(nc, UserOpts, 1)]),
            Realm = nksip_lib:get_binary(realm, AuthHeaderData, <<>>),
            Passes = nksip_lib:get_value(passes, UserOpts, []),
            User = nksip_lib:get_binary(user, UserOpts),
            case get_pass(Passes, Realm, <<>>) of
                <<"HA1!", HA1/binary>> -> _Pass = <<"hash">>;
                _Pass -> <<"HA1!", HA1/binary>> = make_ha1(User, _Pass, Realm)
            end,
            Uri = nksip_unparse:uri(nksip_lib:get_value(ruri, UserOpts)),
            Method1 = case nksip_lib:get_value(method, UserOpts) of
                'ACK' -> 'INVITE';
                Method -> Method
            end,
            Resp = make_auth_response(QOP, Method1, Uri, HA1, Nonce, CNonce, Nc),
            % ?P("AUTH REQUEST: ~p, ~p, ~p: ~p", [User, _Pass, Realm, Resp]),
            % ?P("AUTH REQUEST: ~p, ~p, ~p, ~p, ~p, ~p, ~p", 
            %               [QOP,  Method1, Uri, HA1, Nonce, CNonce, Nc]),
            Raw = [
                "Digest username=\"", User, "\", realm=\"", Realm, 
                "\", nonce=\"", Nonce, "\", uri=\"", Uri, "\", response=\"", Resp, 
                "\", algorithm=MD5",
                case QOP of
                    [] -> [];
                    _ -> [", qop=auth, cnonce=\"", CNonce, "\", nc=", Nc]
                end,
                case nksip_lib:get_value(opaque, AuthHeaderData) of
                    undefined -> [];
                    Opaque -> [", opaque=\"", Opaque, "\""]
                end
            ],
            {ok, list_to_binary(Raw)};
        false ->
            error
    end.


%% @private
-spec check_auth_header(nksip_lib:proplist(), binary(), binary(), binary(), 
                            binary(), nksip:request()) -> 
    true | false | not_found.

check_auth_header(AuthHeader, Resp, User, Realm, Pass, Req) ->
    #sipmsg{
        app_id = AppId,
        call_id = CallId,
        method = Method,
        transport = #transport{remote_ip=Ip, remote_port=Port}
    } = Req,
    case
        nksip_lib:get_value(scheme, AuthHeader) =/= digest orelse
        nksip_lib:get_value(qop, AuthHeader) =/= [auth] orelse
        nksip_lib:get_value(algorithm, AuthHeader, 'MD5') =/= 'MD5'
    of
        true ->
            ?notice(AppId, "received invalid parameters in Authorization Header: ~p", 
                    [AuthHeader]),
            not_found;
        false ->
            % Should we check the uri in the authdata matches the ruri of the request?
            Uri = nksip_lib:get_value(uri, AuthHeader),
            Nonce = nksip_lib:get_value(nonce, AuthHeader),
            Found = get_nonce(AppId, CallId, Nonce),
            if
                Found=:=not_found ->
                    Opaque = nksip_lib:get_value(opaque, AuthHeader),
                    case nksip_lib:hash(AppId) of
                        Opaque -> ?notice(AppId, "received invalid nonce", []);
                        _ -> ok
                    end,
                    not_found;
                Method=:='ACK' orelse Found=:={Ip, Port} ->
                    CNonce = nksip_lib:get_value(cnonce, AuthHeader),
                    Nc = nksip_lib:get_value(nc, AuthHeader),
                    case nksip_lib:to_binary(Pass) of
                        <<"HA1!", HA1/binary>> -> ok;
                        _ -> <<"HA1!", HA1/binary>> = make_ha1(User, Pass, Realm)
                    end,
                    QOP = [auth],
                    Method1 = case Method of
                        'ACK' -> 'INVITE';
                        _ -> Method
                    end,
                    ValidResp = make_auth_response(QOP, Method1, Uri, HA1, 
                                                        Nonce, CNonce, Nc),
                    % ?P("AUTH RESP: ~p, ~p, ~p: ~p vs ~p", 
                    %       [User, Pass, Realm, Resp, ValidResp]),
                    % ?P("AUTH RESP: ~p, ~p, ~p, ~p, ~p, ~p, ~p", 
                    %       [QOP, Method1, Uri, HA1, Nonce, CNonce, Nc]),
                    Resp =:= ValidResp;
                true ->
                    ?warning(AppId, "received nonce from different Ip or Port", []),
                    false
            end
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_passes([], Acc) ->
    lists:reverse(Acc);

get_passes([Opt|Rest], Acc) ->
    Acc1 = case Opt of
        {passes, PassList} -> PassList++Acc;
        {pass, {P, R}} -> [{nksip_lib:to_binary(P), nksip_lib:to_binary(R)}|Acc];
        {pass, P} -> [{nksip_lib:to_binary(P), <<>>}|Acc];
        _ -> Acc
    end,
    get_passes(Rest, Acc1).

%% @private Generates a standard SIP Digest Response
-spec make_auth_response([atom()], nksip:method(), binary(), binary(), 
                            binary(), binary(), binary()) -> binary().

make_auth_response(QOP, Method, BinUri, HA1bin, Nonce, CNonce, Nc) ->
    HA1 = nksip_lib:hex(HA1bin),
    HA2_base = <<(nksip_lib:to_binary(Method))/binary, ":", BinUri/binary>>,
    HA2 = nksip_lib:hex(crypto:md5(HA2_base)),
    case QOP of
        [] ->
            nksip_lib:hex(crypto:md5(list_to_binary([HA1, $:, Nonce, $:, HA2])));
        _ ->    
            case lists:member(auth, QOP) of
                true ->
                    nksip_lib:hex(crypto:md5(list_to_binary(
                        [HA1, $:, Nonce, $:, Nc, $:, CNonce, ":auth:", HA2])));
                _ ->
                    <<>>
            end 
    end.


%% @private Parses an WWW-Authenticate or Proxy-Authenticate header
-spec parse_header(binary()) -> 
    [nksip_lib:proplist()] | error.

parse_header(Header) ->
    try
        [{Scheme0}|Rest] = lists:flatten(nksip_lib:tokenize(Header, equal)),
        Scheme = case string:to_lower(Scheme0) of
            "digest" -> digest;
            "basic" -> basic;
            SchOther -> list_to_binary(SchOther)
        end,
        [{scheme, Scheme}|parse_header_auth(Rest, [])]
    catch
        _:_ -> error
    end.


%% @private
-spec parse_header_auth([term()], [term()]) -> 
    nksip_lib:proplist().

parse_header_auth([{Key0}, $=, {Val0}|Rest], Acc) ->
    Val = string:strip(Val0, both, $"),
    Term = case string:to_lower(Key0) of
        "realm" -> {realm, list_to_binary(string:to_lower(Val))};
        "nonce" -> {nonce, list_to_binary(Val)};
        "opaque" -> {opaque, list_to_binary(Val)};
        "username" -> {username, list_to_binary(Val)};
        "uri" -> {uri, list_to_binary(Val)};
        "response" -> {response, list_to_binary(Val)};
        "cnonce" -> {cnonce, list_to_binary(Val)};
        "nc" -> {nc, list_to_binary(Val)};
        "algorithm" -> 
            {algorithm, 
                case string:to_lower(Val) of
                    "md5" -> 'MD5';
                    A0 -> list_to_binary(A0) 
                end};
        "qop" -> 
            QOP = [
                case string:to_lower(QOPToken) of
                    "auth" -> auth;
                    "auth-int" -> 'auth-int';
                    _ -> list_to_binary(QOPToken)
                end
                || [{QOPToken}] <- nksip_lib:tokenize(Val, none)
            ],
            {qop, QOP};
        Other ->
            {list_to_binary(Other), list_to_binary(Val)}
    end,
    parse_header_auth(Rest, [Term|Acc]);
parse_header_auth([_|Rest], Acc) ->
    parse_header_auth(Rest, Acc);
parse_header_auth([], Acc) ->
    Acc.


%% @private Extracts password from user options.
%% The first matching realm is used, otherwise first password without realm
-spec get_pass([{binary(), binary()}], binary(), binary()) ->   Pass::binary().
get_pass([], _Realm, FirstPass) -> FirstPass;
get_pass([{FirstPass, <<>>}|Rest], Realm, <<>>) -> get_pass(Rest, Realm, FirstPass);
get_pass([{Pass, Realm}|_], Realm, _FirstPass) -> Pass;
get_pass([_|Rest], Realm, FirstPass) -> get_pass(Rest, Realm, FirstPass).


% @private
get_nonce(AppId, CallId, Nonce) ->
    nksip_store:get({nksip_auth_nonce, AppId, CallId, Nonce}).

%% @private
put_nonce(AppId, CallId, Nonce, Term, Timeout) ->
    nksip_store:put({nksip_auth_nonce, AppId, CallId, Nonce}, Term,
                    [{ttl, Timeout}]).



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ha1_test() ->
    HA1 = <<132,147,251,197,59,165,130,251,76,4,76,69,107,220,64,235>>,
    ?assertMatch(<<"HA1!", HA1/binary>>, make_ha1("user", "pass", "realm")),
    ?assertMatch(
        <<"194370e184088fb011b140d770936009">>,
        make_auth_response([], 'INVITE', <<"test@test.com">>, HA1, 
                            <<"gfedcba">>, <<"abcdefg">>, 1)),
    ?assertMatch(
        <<"788a70e3b5d371dc5f9dee5e59bb80cd">>,
        make_auth_response([other, auth], 'INVITE', <<"test@test.com">>, HA1, 
                            <<"gfedcba">>, <<"abcdefg">>, 1)),
    ?assertMatch(<<>>, make_auth_response([other], 'INVITE', <<"any">>, HA1, <<"any">>,
                 <<"any">>, 1)).

-endif.



