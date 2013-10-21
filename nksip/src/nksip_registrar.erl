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
%% Currently only RAM back-end storage is supported, so all registrations will be lost 
%% in case of a NkSIP application restart. 
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

-export([get_all/0, find/2, find/4, qfind/2, qfind/4, get_info/4, delete/4]).
-export([is_registered/1, clear/0, clear/1, print_all/0]).
-export([request/1]).


%% ===================================================================
%% Types and records
%% ===================================================================

-type index() :: {
                    Scheme::sip|sips,
                    Proto::nksip:protocol(), 
                    User::binary(),
                    Domain::binary(), 
                    Port::inet:port_number()
                } |
                {instance, Instance::binary(), RegId::binary()}.

-record(reg_contact, {
    index :: index(),
    contact :: nksip:uri(), 
    updated :: nksip_lib:l_timestamp(),
    expire :: nksip_lib:timestamp(),
    q :: float(),  
    call_id :: nksip:call_id(),
    cseq :: nksip:cseq(),
    transport :: nksip_transport:transport()
}).


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
    [Contact || #reg_contact{contact=Contact} <- get_info(AppId, Scheme, User, Domain)].


%% @private Gets all current stored info for an AOR.
-spec get_info(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [#reg_contact{}].

get_info(AppId, Scheme, User, Domain) ->
    AOR = {Scheme, nksip_lib:to_binary(User), nksip_lib:to_binary(Domain)},
    get(AppId, AOR).


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
        {1/Q, Updated, Contact} || 
        #reg_contact{q=Q, updated=Updated, contact=Contact} 
        <- get_info(AppId, Scheme, User, Domain)
    ],
    do_qfind(lists:sort(All), []).



%% @doc Deletes all registered contacts for an AOR (<i>Address-Of-Record</i>).
-spec delete(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    ok | not_found.

delete(AppId, Scheme, User, Domain) ->
    AOR = {
        nksip_parse:scheme(Scheme), 
        nksip_lib:to_binary(User), 
        nksip_lib:to_binary(Domain)
    },
    del(AppId, AOR).


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
    Regs = get(AppId, {Scheme, User, Domain}),
    is_registered(Regs, Transport).


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

request(Request) ->
    try
        process(Request)
    catch
        throw:Throw -> Throw
    end.
 

%% @doc Clear all stored records for all SipApps.
%% Returns the number of deleted items.
-spec clear() -> integer().

clear() ->
    clear('$nk_any').


%% @doc Clear all stored records by a SipApp's core.
%% Returns the number of deleted items.
-spec clear(nksip:app_id()) -> integer().

clear(AppId) -> 
    Fun = fun(Id, AOR, _Val, Acc) ->
        if
            AppId=:='$nk_any'; AppId=:=Id -> del(Id, AOR), Acc+1;
            true -> Acc
        end
    end,
    fold(Fun, 0).


%% @private Get all current registrations. Use it with care.
-spec get_all() ->
    [{nksip:aor(), [{App::nksip:app_id(), URI::nksip:uri(),
                     Remaining::integer(), Q::float()}]}].

get_all() ->
    Now = nksip_lib:timestamp(),
    [
        {
            {Scheme, User, Domain}, 
            [
                {AppId, C, Exp-Now, Q} || #reg_contact{contact=C, expire=Exp, q=Q} 
                <- get(AppId, {Scheme, User, Domain})
            ]
        }
        || {AppId, {Scheme, User, Domain}} <- all()
    ].


% @private
print_all() ->
    Print = fun({{Scheme, User, Domain}, Regs}) ->
        ?P("\n--- ~p:~s@~s ---", [Scheme, User, Domain]),
        lists:foreach(
            fun({AppId, Contact, Remaining, Q}) ->
                ?P("    ~p: ~s, ~p, ~p", 
                   [AppId, nksip_unparse:uri(Contact), Remaining, Q])
            end, Regs)
    end,
    lists:foreach(Print, get_all()),
    ?P("\n").


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
-spec process(nksip:request()) ->
    nksip:sipreply().

process(#sipmsg{
            app_id = AppId, 
            to = #uri{scheme=Scheme, user=ToUser, domain=ToDomain},
            contacts = Contacts
        }=Req) ->
    if
        Scheme=:=sip; Scheme=:=sips -> ok;
        true -> throw(unsupported_uri_scheme)
    end,
    AOR = {Scheme, ToUser, ToDomain},
    Expires = case nksip_sipmsg:header(Req, <<"Expires">>, integers) of
        [T|_] when is_integer(T) -> T;
        _ -> nksip_config:get(registrar_default_time)
    end,
    case Contacts of
        [] -> ok;
        [#uri{domain=(<<"*">>)}] -> del_all(AppId, AOR, Req);
        _ -> update(Req, AOR, Contacts, Expires)
    end,
    NewContacts = [Contact || #reg_contact{contact=Contact} <- get(AppId, AOR)],
    {ok, [], <<>>, [{contact, NewContacts}, make_date, make_allow]}.


%% @private
-spec update(nksip:request(), nksip:aor(), [nksip:uri()], integer()) ->
    ok | no_return().

update(#sipmsg{app_id=AppId}=Req, AOR, Contacts, Default) ->
    Min = nksip_config:get(registrar_min_time),
    Max = nksip_config:get(registrar_max_time),
    Now = nksip_lib:timestamp(),
    Updates = make_updates(Min, Max, Default, Now, Contacts, []),
    OldContacts = [
        RegContact ||
        #reg_contact{expire=Exp} = RegContact <- get(AppId, AOR), Exp > Now],
    case update_iter(Updates, Req, OldContacts) of
        [] -> 
            del(AppId, AOR);
        NewContacts -> 
            GroupExp0 = lists:max([CExp-Now||#reg_contact{expire=CExp} <- NewContacts]),
            GroupExp1 = max(GroupExp0, 5),
            put(AppId, AOR, NewContacts, GroupExp1)
    end,
    ok.


% @private
-spec make_updates(integer(), integer(), integer(), nksip_lib:timestamp(), [#uri{}], 
                    [{index(), nksip:uri(), nksip_lib:timestamp(), float()}]) ->
    [{index(), nksip:uri(), nksip_lib:timestamp(), float()}].               

make_updates(Min, Max, Default, Now,
                [#uri{scheme=Scheme, user=User, ext_opts=Opts}=Contact|Rest], 
                Acc) ->
    Exp1 = case nksip_lib:get_list(expires, Opts) of
        [] ->
            Default;
        Exp1List ->
            case catch list_to_integer(Exp1List) of
                ExpInt when is_integer(ExpInt) -> ExpInt;
                _ -> Default
            end
    end,
    Exp2 = if
        Exp1 > 0, Exp1 < 3600, Exp1 < Min -> throw({interval_too_brief, Min});
        Exp1 > Max -> Max;
        true -> Exp1
    end,
    ExpTime = if 
        Exp2 =:= 0 -> 0; 
        true -> Now+Exp2 
    end,
    Q = case nksip_lib:get_list(q, Opts) of
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
    Opts1 = lists:keystore(expires, 1, Opts, 
                {expires, list_to_binary(integer_to_list(Exp2))}),
    {Proto, Domain, Port} = nksip_parse:transport(Contact),
    Index = case nksip_lib:get_value('reg-id', Opts) of
        undefined ->
            {Scheme, Proto, User, Domain, Port};
        RegId ->
            case nksip_lib:get_value('+sip.instance', Opts) of
                undefined -> {Scheme, Proto, User, Domain, Port};
                SipInstance -> {instance, SipInstance, RegId}
            end
    end,
    Update = {Index, Contact#uri{ext_opts=Opts1}, ExpTime, Q},
    make_updates(Min, Max, Default, Now, Rest, [Update|Acc]);

make_updates(_Min, _Max, _Default, _Now, [], Acc) ->
    Acc.

update_iter([], _, Acc) ->
    lists:reverse(lists:keysort(#reg_contact.updated, Acc));

update_iter([{Index, Contact, ExpTime, Q}|Rest], 
            #sipmsg{transport=Transport, call_id=CallId, cseq=CSeq}=Req, Acc) ->
    RegContact = #reg_contact{
        index = Index,
        contact = Contact,
        updated = nksip_lib:l_timestamp(),
        expire = ExpTime, 
        q = Q, 
        call_id = CallId, 
        cseq = CSeq,
        transport = Transport
    },
    % A new registration will overwite an old Contact if it has the same index
    NewAcc = case lists:keytake(Index, #reg_contact.index, Acc) of
        false when ExpTime=:=0 ->
            Acc;
        false ->
            [RegContact|Acc];
        {value, #reg_contact{call_id=CallId, cseq=OldCSeq}, _} when OldCSeq >= CSeq -> 
            throw({invalid_request, "Rejected Old CSeq"});
        {value, _, Acc0} when ExpTime =:= 0 ->
            Acc0;
        {value, _, Acc0} ->
            [RegContact|Acc0]
    end,
    update_iter(Rest, Req, NewAcc).
        

%% @private
-spec del_all(nksip:app_id(), nksip:aor(), nksip:request()) ->
    ok | no_return().

del_all(AppId, AOR, #sipmsg{call_id=CallId, cseq=CSeq}) ->
    lists:foreach(
        fun(#reg_contact{call_id=CCallId, cseq=CCSeq}) ->
            if
                CallId =/= CCallId -> ok;
                CSeq > CCSeq -> ok;
                true -> throw({invalid_request, "Rejected Old CSeq"})
            end
        end,
        get(AppId, AOR)),
    del(AppId, AOR).



%% @private
get(AppId, AOR) -> 
    nksip_store:get({nksip_registrar, AppId, AOR}, []).

%% @private
all() -> 
    fold(fun(AppId, AOR, _Value, Acc) -> [{AppId, AOR}|Acc] end, []).

%% @private
put(AppId, AOR, Contacts, TTL) ->
    nksip_store:put({nksip_registrar, AppId, AOR}, Contacts, [{ttl, TTL}]).

%% @private
del(AppId, AOR) -> 
    nksip_store:del({nksip_registrar, AppId, AOR}).


fold(Fun, Acc0) when is_function(Fun, 4) ->
    FoldFun = fun(Key, Value, Acc) ->
        case Key of
            {nksip_registrar, AppId, AOR} -> Fun(AppId, AOR, Value, Acc);
            _ -> Acc
        end
    end,
    nksip_store:fold(FoldFun, Acc0).






