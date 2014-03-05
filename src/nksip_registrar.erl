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

%% @doc NkSIP Registrar Server.
%%
%% This module implements a full registrar implementation according to RFC3261. 
%% "Path" is also supported according to RFC3327.
%% By default, it uses the RAM-only built-in store, but any SipApp can implement 
%% {@link nksip_sipapp:registrar_store/3} callback use any external database.
%% Each started SipApp maintains its fully independent set of registrations.
%%
%% When a new REGISTER request arrives at a SipApp, and if you order to `process' 
%% the request in {@link nksip_sipapp:route/6} callback, NkSIP will try to call 
%% {@link nksip_sipapp:register/3} callback if it is defined. 
%% If it is not defined, but `registrar' option was present in the SipApp's 
%% startup config, NkSIP will process the request automatically. 
%% It will check if `From' and `To' headers differ, and call {@link request/1} if 
%% everything is ok. 
%% If you implement {@link nksip_sipapp:register/3} to customize the registration 
%% process you should call {@link request/1} directly.
%%
%% Use {@link find/4} or {@link qfind/4} to search for a specific registration's 
%% contacts, and {@link is_registered/1} to check if the `Request-URI' of a 
%% specific request is registered.

-module(nksip_registrar).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([find/2, find/4, qfind/2, qfind/4, get_info/4, delete/4, clear/1]).
-export([is_registered/1, request/1]).
-export([internal_get_all/0, internal_clear/0, internal_print_all/0]).

-export_type([reg_contact/0, index/0]).

-define(TIMEOUT, 15000).


%% ===================================================================
%% Types and records
%% ===================================================================

-type reg_contact() :: #reg_contact{}.

-type index() :: 
    {
        Scheme::sip|sips,
        Proto::nksip:protocol(), 
        User::binary(),
        Domain::binary(), 
        Port::inet:port_number()
    } 
    |
    {ob, Instance::binary(), RegId::binary()}.

% -type reg_info() :: 
%     {
%         Index::index(), 
%         Uri::nksip:uri(), 
%         Expire::nksip_lib:timestamp(), 
%         Q::float()
%     }.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Gets all current registered contacts for an AOR.
-spec find(nksip:app_id(), AOR::nksip:aor()) ->
    [nksip:uri()].

find(AppId, {Scheme, User, Domain}) ->
    find(AppId, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR.
-spec find(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [nksip:uri()].

find(AppId, Scheme, User, Domain) ->
    [make_contact(Reg) || Reg <- get_info(AppId, Scheme, User, Domain)].


%% @private Gets all current stored info for an AOR.
-spec get_info(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [#reg_contact{}].

get_info(AppId, Scheme, User, Domain) ->
    AOR = {Scheme, nksip_lib:to_binary(User), nksip_lib:to_binary(Domain)},
    case catch callback_get(AppId, AOR) of
        {ok, RegContacts} -> RegContacts;
        _ -> []
    end.


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nksip:app_id(), AOR::nksip:aor()) ->
    nksip:uri_set().

qfind(AppId, {Scheme, User, Domain}) ->
    qfind(AppId, Scheme, User, Domain).


%% @doc Gets all current registered contacts for an AOR, aggregated on Q values.
%% You can use this function to generate a parallel and/o serial proxy request.
-spec qfind(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    nksip:uri_set().

qfind(AppId, Scheme, User, Domain) ->
    All = [
        {1/Q, Updated, make_contact(Reg)} || 
        #reg_contact{q=Q, updated=Updated} = Reg 
        <- get_info(AppId, Scheme, User, Domain)
    ],
    do_qfind(lists:sort(All), []).



%% @doc Deletes all registered contacts for an AOR (<i>Address-Of-Record</i>).
-spec delete(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    ok | not_found | callback_error.

delete(AppId, Scheme, User, Domain) ->
    AOR = {
        nksip_parse:scheme(Scheme), 
        nksip_lib:to_binary(User), 
        nksip_lib:to_binary(Domain)
    },
    case callback(AppId, {del, AOR}) of
        ok -> ok;
        not_found -> not_found;
        _ -> callback_error
    end.


%% @doc Finds if a request has a <i>From</i> that has been already registered
%% from the same transport, ip and port, or have a registered <i>Contact</i>
%% having the same received transport, ip and port.
-spec is_registered(Req::nksip:request()) ->
    boolean().

is_registered(#sipmsg{class={req, 'REGISTER'}}) ->
    false;

is_registered(#sipmsg{
                app_id = AppId, 
                from = #uri{scheme=Scheme, user=User, domain=Domain},
                transport=Transport
            }) ->
    case catch callback_get(AppId, {Scheme, User, Domain}) of
        {ok, Regs} -> is_registered(Regs, Transport);
        _ -> false
    end.


%% @doc Process a REGISTER request. 
%% Can return:
%% <ul>
%%  <li>`unsupported_uri_scheme': if R-RUI scheme is not `sip' or `sips'.</li>
%%  <li>`invalid_request': if the request is not valid for any reason.</li>
%%  <li>`interval_too_brief': if <i>Expires</i> is lower than the minimum configured
%%       registration time (defined in `registrar_min_time' global parameter).</li>
%% </ul>
%%
%% If <i>Expires</i> is 0, the indicated <i>Contact</i> will be unregistered.
%% If <i>Contact</i> header is `*', all previous contacts will be unregistered.
%%
%% The requested <i>Contact</i> will replace a previous registration if it has 
%% the same `reg-id' and `+sip_instace' values, or has the same transport scheme,
%% protocol, user, domain and port.
%%
%% If the request is successful, a 200-code `nksip:sipreply()' is returned,
%% including one or more <i>Contact</i> headers (for all of the current registered
%% contacts), <i>Date</i> and <i>Allow</i> headers.
-spec request(nksip:request()) ->
    nksip:sipreply().

request(Req) ->
    try
        {ObProc, Req1} = check_outbound(Req),
        process(Req1, ObProc),
        #sipmsg{app_id=AppId, to=#uri{scheme=Scheme, user=ToUser, domain=ToDomain}} = Req,
        {ok, Regs} = callback_get(AppId, {Scheme, ToUser, ToDomain}),
        Contacts1 = [Contact || #reg_contact{contact=Contact} <- Regs],
        ObReq = case 
            ObProc==true andalso [true || #reg_contact{index={ob, _, _}} <- Regs] 
        of
            [_|_] -> [{require, <<"outbound">>}];
            _ -> []
        end,
        {ok, [], <<>>, 
            [{contact, Contacts1}, make_date, make_allow, make_supported | ObReq]}
    catch
        throw:Throw -> Throw
    end.
 

%% @doc Clear all stored records by a SipApp's core.
-spec clear(nksip:app_id()) -> 
    ok | callback_error.

clear(AppId) -> 
    case callback(AppId, del_all) of
        ok -> ok;
        _ -> callback_error
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec do_qfind([{float(), float(), nksip:uri()}], list()) ->
    [[nksip:uri()]].

do_qfind([{Q, _, Contact}|Rest], [{Q, CList}|Acc]) ->
    do_qfind(Rest, [{Q, [Contact|CList]}|Acc]);

do_qfind([{Q, _, Contact}|Rest], Acc) ->
    do_qfind(Rest, [{Q, [Contact]}|Acc]);

do_qfind([], Acc) ->
    [CList || {_Q, CList} <- Acc].


%% @private
-spec is_registered([nksip:uri()], nksip_transport:transport()) ->
    boolean().

is_registered([], _) ->
    false;

is_registered([
                #reg_contact{
                    transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}}
                | _ ], 
                #transport{proto=Proto, remote_ip=Ip, remote_port=Port}) ->
    true;

% If a TCP es registered, the transport source port is probably going to be 
% different then the registered, so it is not going to work.
% When outbound is implemented this will be reworked 
is_registered([
                #reg_contact{contact=Contact}|R], 
                #transport{proto=Proto, remote_ip=Ip, remote_port=Port}=Transport) ->
    case nksip_parse:transport(Contact) of
        {Proto, Domain, Port} -> 
            case nksip_lib:to_ip(Domain) of
                {ok, Ip} -> true;
                _ -> is_registered(R, Transport)
            end;
        _ ->
            is_registered(R, Transport)
    end.


%% @private
-spec check_outbound(nksip:request()) ->
    {true|false|undefined, nksip:request()}.

check_outbound(Req) ->
    #sipmsg{app_id=AppId, vias=Vias, transport=Transp} = Req,
    {ok, _, AppOpts, _} = nksip_sipapp_srv:get_opts(AppId),
    AppSupp = nksip_lib:get_value(supported, AppOpts, ?SUPPORTED),
    case 
        lists:member(<<"outbound">>, AppSupp) andalso
        nksip_sipmsg:supported(Req, <<"outbound">>)
    of
        true when length(Vias) > 1 ->       % We are not the first host
            case nksip_sipmsg:header(Req, <<"Path">>, uris) of
                error ->
                    throw({invalid_request, <<"Invalid Path">>});
                Paths ->
                    case lists:reverse(Paths) of
                        [#uri{opts=PathOpts}|_] -> 
                            {lists:member(<<"ob">>, PathOpts), Req};
                        _ -> 
                            {false, Req}
                    end
            end;
        true ->
            #transport{
                proto = Proto, 
                listen_ip = ListenIp, 
                listen_port = ListenPort,
                remote_ip = RemoteIp,
                remote_port = RemotePort
            } = Transp,
            case nksip_transport:get_connected(AppId, Proto, RemoteIp, RemotePort) of
                [{_, Pid}|_] ->
                    Flow = base64:encode(term_to_binary(Pid)),
                    Host = nksip_transport:get_listenhost(ListenIp, AppOpts),
                    Path = nksip_transport:make_route(sip, Proto, Host, ListenPort, 
                                                      <<"NkF", Flow/binary>>, 
                                                      [<<"lr">>]),
                    Headers1 = nksip_headers:update(Req, 
                                                [{before_single, <<"Path">>, Path}]),
                    Req1 = Req#sipmsg{headers=Headers1},
                    {true, Req1};
                [] ->
                    {false, Req}
            end;
        false ->
            {unsupported, Req}
    end.


%% @private
-spec process(nksip:request(), true|false|unsupported) ->
    ok.

process(Req, ObProc) ->
    #sipmsg{to=#uri{scheme=Scheme}, contacts=Contacts} = Req,
    if
        Scheme==sip; Scheme==sips -> ok;
        true -> throw(unsupported_uri_scheme)
    end,
    Default = case nksip_sipmsg:field(Req, parsed_expires) of
        D0 when is_integer(D0) -> D0;
        _ -> nksip_config:get(registrar_default_time)
    end,
    Long = nksip_lib:l_timestamp(),
    Times = {
        nksip_config:get(registrar_min_time), 
        nksip_config:get(registrar_max_time),
        Default,
        Long div 1000000,
        Long
    },
    case Contacts of
        [] -> ok;
        [#uri{domain=(<<"*">>)}] when Default==0 -> del_all(Req);
        _ -> update(Req, Times, ObProc)
    end.


%% @private
-spec update(nksip:request(), {integer(), integer(), integer(), integer(), integer()}, 
             true|false|unsupported) ->
    ok.

update(Req, Times, ObProc) ->
    #sipmsg{
        app_id = AppId, 
        to = #uri{scheme=Scheme, user=ToUser, domain=ToDomain},
        contacts = Contacts,
        call_id = CallId, 
        cseq = CSeq,
        transport = Transp
    } = Req,
    Path = case nksip_sipmsg:header(Req, <<"Path">>, uris) of
        error -> throw({invalid_request, "Invalid Path"});
        Path0 -> Path0
    end,
    {_, _, _, Now, LongNow} = Times,
    Base = #reg_contact{
        call_id = CallId, 
        cseq = CSeq,
        updated = LongNow,
        transport = Transp,
        path = Path
    },
    RegContacts = gen_regcontacts(Contacts, Base, Times, ObProc, []),
    case 
        [true || #reg_contact{index={ob, _, _}, expire=Exp} <- RegContacts, Exp>0] 
    of
        [_, _|_] -> throw({invalid_request, "Several 'reg-id' Options"});
        _ -> ok
    end,
    AOR = {Scheme, ToUser, ToDomain},
    {ok, Regs} = callback_get(AppId, AOR),
    Contacts1 = [
        RegContact ||
        #reg_contact{expire=Exp} = RegContact <- Regs, 
        Exp > Now
    ],
    case update_regcontacts(RegContacts, Now, Contacts1) of
        [] -> 
            case callback(AppId, {del, AOR}) of
                ok -> ok;
                not_found -> ok;
                _ -> throw({internal_error, "Error calling registrar 'del' callback"})
            end;
        Contacts2 -> 
            GlobalExpire = lists:max([Exp-Now||#reg_contact{expire=Exp} <- Contacts2]),
            % Set a minimum expiration check of 5 secs
            case callback(AppId, {put, AOR, Contacts2, max(GlobalExpire, 5)}) of
                ok -> ok;
                _ -> throw({internal_error, "Error calling registrar 'put' callback"})
            end
    end,
    ok.


%% @private Extracts from each contact a index, uri, expire time and q
-spec gen_regcontacts([#uri{}], reg_contact(), 
                      {integer(), integer(), integer(), integer(), integer()}, 
                      true|false|unsupported, [reg_contact()]) ->
    [reg_contact()].

gen_regcontacts([Contact|Rest], Base, Times, ObProc, Acc) ->
    #uri{scheme=Scheme, user=User, domain=Domain, ext_opts=Opts} = Contact,
    {Min, Max, Default, Now, _LongNow} = Times,
    case Domain of
        <<"*">> -> throw(invalid_request);
        _ -> ok
    end,
    UriExp = case nksip_lib:get_list(<<"expires">>, Opts) of
        [] ->
            Default;
        Exp1List ->
            case catch list_to_integer(Exp1List) of
                ExpInt when is_integer(ExpInt) -> ExpInt;
                _ -> Default
            end
    end,
    Expires = if
        UriExp==0 -> 0;
        UriExp>0, UriExp<3600, UriExp<Min -> throw({interval_too_brief, Min});
        UriExp>Max -> Max;
        true -> UriExp
    end,
    Q = case nksip_lib:get_list(<<"q">>, Opts) of
        [] -> 
            1.0;
        Q0 ->
            case catch list_to_float(Q0) of
                Q1 when is_float(Q1), Q1 > 0 -> 
                    Q1;
                _ -> 
                    case catch list_to_integer(Q0) of
                        Q2 when is_integer(Q2), Q2 > 0 -> Q2 * 1.0;
                        _ -> 1.0
                    end
            end
    end,
    ExpireBin = list_to_binary(integer_to_list(Expires)),
    Opts1 = nksip_lib:store_value(<<"expires">>, ExpireBin, Opts),
    {Proto, Domain, Port} = nksip_parse:transport(Contact),
    Instance = nksip_lib:get_value(<<"+sip.instance">>, Opts),
    RegId = case nksip_lib:get_value(<<"reg-id">>, Opts) of
        undefined -> undefined;
        _ when ObProc==unsupported -> undefined;
        _ when ObProc==false -> throw(first_hop_lacks_outbound);
        _ when Instance==undefined -> undefined;
        RegId0 -> RegId0
    end,
    % TODO: If Instance and no reg_id -> creation of gruu
    Index = case RegId of
        undefined -> {Scheme, Proto, User, Domain, Port};
        _ -> {ob, Instance, RegId}
    end,
    RegContact = Base#reg_contact{
        index = Index,
        contact = Contact#uri{ext_opts=Opts1},
        expire = Now + Expires, 
        q = Q
    },
    gen_regcontacts(Rest, Base, Times, ObProc, [RegContact|Acc]);

gen_regcontacts([], _Base, _Times, _ObProc, Acc) ->
    Acc.


%% @private
-spec update_regcontacts([reg_contact()], nksip_lib:timestamp(), [reg_contact()]) ->
    [reg_contact()].

update_regcontacts([RegContact|Rest], Now, Acc) ->
    % A new registration will overwite an old Contact if it has the same index
    #reg_contact{index=Index, expire=Expire, cseq=CSeq, call_id=CallId} = RegContact,
    Acc1 = case lists:keytake(Index, #reg_contact.index, Acc) of
        false when Expire==Now ->
            Acc;
        false ->
            [RegContact|Acc];
        {value, #reg_contact{call_id=CallId, cseq=OldCSeq}, _} when OldCSeq >= CSeq -> 
            throw({invalid_request, "Rejected Old CSeq"});
        {value, _, Acc0} when Expire==Now ->
            Acc0;
        {value, _, Acc0} ->
            [RegContact|Acc0]
    end,
    update_regcontacts(Rest, Now, Acc1);
        
update_regcontacts([], _Now, Acc) ->
    lists:reverse(lists:keysort(#reg_contact.updated, Acc)).


%% @private Generates a contact value including Path
make_contact(#reg_contact{contact=Contact, path=[]}) ->
    Contact;
make_contact(#reg_contact{contact=Contact, path=Path}) ->
    #uri{headers=Headers} = Contact,
    Route1 = nksip_unparse:uri(Path),
    Routes2 = list_to_binary(http_uri:encode(binary_to_list(Route1))),
    Headers1 = [{<<"Route">>, Routes2}|Headers],
    Contact#uri{headers=Headers1}.


%% @private
-spec del_all(nksip:request()) ->
    ok | not_found.

del_all(Req) ->
    #sipmsg{
        app_id = AppId,
        to = #uri{scheme=Scheme, user=ToUser, domain=ToDomain},
        call_id = CallId, 
        cseq = CSeq
    } = Req,
    AOR = {Scheme, ToUser, ToDomain},
    {ok, RegContacts} = callback_get(AppId, AOR),
    lists:foreach(
        fun(#reg_contact{call_id=CCallId, cseq=CCSeq}) ->
            if
                CallId /= CCallId -> ok;
                CSeq > CCSeq -> ok;
                true -> throw({invalid_request, "Rejected Old CSeq"})
            end
        end,
        RegContacts),
    case callback(AppId, {del, AOR}) of
        ok -> ok;
        not_found -> not_found;
        _ -> throw({internal_error, "Error calling registrar 'del' callback"})
    end.


%% @private
callback_get(AppId, AOR) -> 
    case callback(AppId, {get, AOR}) of
        List when is_list(List) ->
            lists:foreach(
                fun(Term) ->
                    case Term of
                        #reg_contact{} -> 
                            ok;
                        _ -> 
                            Msg = "Invalid return in registrar 'get' callback",
                            throw({internal_error, Msg})
                    end
                end, List),
            {ok, List};
        _ -> 
            throw({internal_error, "Error calling registrar 'get' callback"})
    end.


%% @private 
-spec callback(nksip:app_id(), term()) ->
    term() | error.

callback(AppId, Op) -> 
    case nksip_sipapp_srv:get_module(AppId) of
        {ok, Module, _Pid} ->
            case 
                nksip_sipapp_srv:sipapp_call_wait(AppId, Module, 
                                                  registrar_store, [Op], [Op], 
                                                  ?TIMEOUT)
            of
                not_exported -> 
                    {reply, Reply, none} = 
                        nksip_sipapp:registrar_store(AppId, Op, none),
                    Reply;
                {reply, Reply} -> 
                    Reply;
                _ -> 
                    error
            end;
        {error, not_found} ->
            error
    end.


%% ===================================================================
%% Utilities available only using internal store
%% ===================================================================


%% @private Get all current registrations. Use it with care.
-spec internal_get_all() ->
    [{nksip:aor(), [{App::nksip:app_id(), URI::nksip:uri(),
                     Remaining::integer(), Q::float()}]}].

internal_get_all() ->
    Now = nksip_lib:timestamp(),
    [
        {
            AOR, 
            [
                {AppId, C, Exp-Now, Q} || #reg_contact{contact=C, expire=Exp, q=Q} 
                <- nksip_store:get({nksip_registrar, AppId, AOR}, [])
            ]
        }
        || {AppId, AOR} <- internal_all()
    ].


%% @private
internal_print_all() ->
    Print = fun({{Scheme, User, Domain}, Regs}) ->
        ?P("\n--- ~p:~s@~s ---", [Scheme, User, Domain]),
        lists:foreach(
            fun({AppId, Contact, Remaining, Q}) ->
                ?P("    ~p: ~s, ~p, ~p", 
                   [AppId, nksip_unparse:uri(Contact), Remaining, Q])
            end, Regs)
    end,
    lists:foreach(Print, internal_get_all()),
    ?P("\n").


%% @private Clear all stored records for all SipApps, only with buil-in database
%% Returns the number of deleted items.
-spec internal_clear() -> 
    integer().

internal_clear() ->
    Fun = fun(AppId, AOR, _Val, Acc) ->
        nksip_store:del({nksip_registrar, AppId, AOR}),
        Acc+1
    end,
    internal_fold(Fun, 0).


%% @private
internal_all() -> 
    internal_fold(fun(AppId, AOR, _Value, Acc) -> [{AppId, AOR}|Acc] end, []).


%% @private
internal_fold(Fun, Acc0) when is_function(Fun, 4) ->
    FoldFun = fun(Key, Value, Acc) ->
        case Key of
            {nksip_registrar, AppId, AOR} -> Fun(AppId, AOR, Value, Acc);
            _ -> Acc
        end
    end,
    nksip_store:fold(FoldFun, Acc0).





