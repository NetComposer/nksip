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

%% @doc NkSIP Registrar Server Plugin
-module(nksip_registrar_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").
-include("nksip_registrar.hrl").

-export([find/2, find/4, qfind/4, is_registered/2, request/1]).
-export([parse_config/3, get_info/4]).
-export([store_get/2, store_del/2, store_del_all/1]).
-export_type([reg_contact/0, index/0]).

-define(AES_IV, <<"12345678abcdefgh">>).


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



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec parse_config(PluginConfig, Unknown, Config) ->
    {ok, Unknown, Config} | {error, term()}
    when PluginConfig::nksip:optslist(), Unknown::nksip:optslist(), 
         Config::nksip:optslist().

parse_config([], Unknown, Config) ->
    {ok, Unknown, Config};

parse_config([Term|Rest], Unknown, Config) ->
    Op = case Term of
        {nksip_registrar_default_time, Secs} ->
            case is_integer(Secs) andalso Secs>=5 of
                true -> update;
                false -> error
            end;
        {nksip_registrar_min_time, Secs} ->
            case is_integer(Secs) andalso Secs>=1 of
                true -> update;
                false -> error
            end;
        {nksip_registrar_max_time, Secs} ->
            case is_integer(Secs) andalso Secs>=60 of
                true -> update;
                false -> error
            end;
        _ ->
            unknown
    end,
    case Op of
        update ->
            Key = element(1, Term),
            Val = element(2, Term),
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        error ->
            {error, {invalid_config, element(1, Term)}};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.


%% @private
-spec find(nksip:app_id(), nksip:uri()) ->
    [nksip:uri()].

find(AppId, #uri{scheme=Scheme, user=User, domain=Domain, opts=Opts}) ->
    case lists:member(<<"gr">>, Opts) of
        true -> 
            % It is probably a tmp GRUU
            case catch decrypt(User) of
                Tmp when is_binary(Tmp) ->
                    {{Scheme1, User1, Domain1}, InstId, Pos} = binary_to_term(Tmp),
                    [
                        make_contact(Reg) 
                        || #reg_contact{instance_id=InstId1, min_tmp_pos=Min}=Reg 
                        <- get_info(AppId, Scheme1, User1, Domain1), 
                        InstId1==InstId, Pos>=Min
                    ];
                _ ->
                    ?notice(AppId, <<>>, 
                            "private GRUU not recognized: ~p", [User]),
                    find(AppId, Scheme, User, Domain)
            end;
        false ->
            case nksip_lib:get_value(<<"gr">>, Opts) of
                undefined -> 
                    find(AppId, Scheme, User, Domain);
                InstId ->
                    [
                        make_contact(Reg) 
                        || #reg_contact{instance_id=InstId1}=Reg 
                        <- get_info(AppId, Scheme, User, Domain), 
                        InstId1==InstId
                    ]
            end
    end.


%% @doc Gets all current registered contacts for an AOR.
-spec find(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [nksip:uri()].

find(AppId, Scheme, User, Domain) ->
    [make_contact(Reg) || Reg <- get_info(AppId, Scheme, User, Domain)].



%% @private
-spec qfind(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    nksip:uri_set().

qfind(AppId, Scheme, User, Domain) ->
    All = [
        {1/Q, Updated, make_contact(Reg)} || 
        #reg_contact{q=Q, updated=Updated} = Reg 
        <- get_info(AppId, Scheme, User, Domain)
    ],
    qfind_iter(lists:sort(All), []).


%% @private
-spec qfind_iter([{float(), float(), nksip:uri()}], list()) ->
    [[nksip:uri()]].

qfind_iter([{Q, _, Contact}|Rest], [{Q, CList}|Acc]) ->
    qfind_iter(Rest, [{Q, [Contact|CList]}|Acc]);

qfind_iter([{Q, _, Contact}|Rest], Acc) ->
    qfind_iter(Rest, [{Q, [Contact]}|Acc]);

qfind_iter([], Acc) ->
    [CList || {_Q, CList} <- Acc].



%% @private Gets all current stored info for an AOR.
-spec get_info(nksip:app_id(), nksip:scheme(), binary(), binary()) ->
    [#reg_contact{}].

get_info(AppId, Scheme, User, Domain) ->
    AOR = {Scheme, nksip_lib:to_binary(User), nksip_lib:to_binary(Domain)},
    case catch store_get(AppId, AOR) of
        {ok, RegContacts} -> RegContacts;
        _ -> []
    end.



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
-spec request(nksip:request()) ->
    nksip:sipreply().

request(#sipmsg{app_id=AppId, to={To, _}}=Req) ->
    try
        % case lists:member(nksip_outbound, AppId:config_plugins()) of
        %     true ->
                case nksip_outbound:registrar(Req) of
                    {true, Req1} -> Opts1 = [{outbound, true}];
                    {false, Req1} -> Opts1 = [{outbound, false}];
                    no_outbound -> Req1 = Req, Opts1 = [];
                    {error, OutError} -> Req1 = Opts1 = throw(OutError)
            %     end;
            % false ->
            %     Req1 = Req,
            %     Opts1 = [] 
        end,
        case 
            lists:member(<<"gruu">>, AppId:config_supported()) andalso 
            nksip_sipmsg:supported(<<"gruu">>, Req)
        of
            true -> Opts2 = [{gruu, true}|Opts1];
            false -> Opts2 = Opts1
        end,
        process(Req1, Opts2),
        {ok, Regs} = store_get(AppId, aor(To)),
        Contacts1 = [Contact || #reg_contact{contact=Contact} <- Regs],
        ObReq = case 
            lists:member({outbound, true}, Opts2) andalso
            [true || #reg_contact{index={ob, _, _}} <- Regs] 
        of
            [_|_] -> [{require, <<"outbound">>}];
            _ -> []
        end,
        {ok, [{contact, Contacts1}, date, allow, supported | ObReq]}
    catch
        throw:Throw -> Throw
    end.


%% @private
-spec process(nksip:request(), nksip:optslist()) ->
    ok.

process(Req, Opts) ->
    #sipmsg{app_id=AppId, to={#uri{scheme=Scheme}, _}, contacts=Contacts} = Req,
    if
        Scheme==sip; Scheme==sips -> ok;
        true -> throw(unsupported_uri_scheme)
    end,
    Config = nksip_sipapp_srv:config(AppId),
    DefTime = nksip_lib:get_value(nksip_registrar_default_time, Config),
    Default = case nksip_sipmsg:meta(expires, Req) of
        D0 when is_integer(D0) -> D0;
        _ -> DefTime
    end,
    TimeLong = nksip_lib:l_timestamp(),
    Times = #nksip_registrar_time{
        min = nksip_lib:get_value(nksip_registrar_min_time, Config),
        max = nksip_lib:get_value(nksip_registrar_max_time, Config),
        default = Default,
        time = TimeLong div 1000000,
        time_long = TimeLong
    },
    case Contacts of
        [] -> ok;
        [#uri{domain=(<<"*">>)}] when Default==0 -> del_all(Req);
        _ -> update(Req, Times, Opts)
    end.



%% @private
-spec update(nksip:request(), #nksip_registrar_time{}, nksip:optslist()) ->
    ok.

update(Req, Times, Opts) ->
    #sipmsg{app_id=AppId, to={To, _}, contacts=Contacts} = Req,
    #nksip_registrar_time{default=Default, time=Now} = Times,
    check_several_reg_id(Contacts, Default, false),
    Path = case nksip_sipmsg:header(<<"path">>, Req, uris) of
        error -> throw({invalid_request, "Invalid Path"});
        Path0 -> Path0
    end,
    AOR = aor(To),
    {ok, Regs} = store_get(AppId, AOR),
    RegContacts0 = [
        RegContact ||
        #reg_contact{expire=Exp} = RegContact <- Regs, 
        Exp > Now
    ],
    RegContacts = update_regcontacts(Contacts, Req, Times, Path, Opts, RegContacts0),
    case RegContacts of
        [] -> 
            case store_del(AppId, AOR) of
                ok -> ok;
                not_found -> ok;
                _ -> throw({internal_error, "Error calling registrar 'del' callback"})
            end;
        _ -> 
            GlobalExpire = lists:max([Exp-Now||#reg_contact{expire=Exp} <- RegContacts]),
            % Set a minimum expiration check of 5 secs
            case store_put(AppId, AOR, RegContacts, max(GlobalExpire, 5)) of
                ok -> ok;
                _ -> throw({internal_error, "Error calling registrar 'put' callback"})
            end
    end,
    ok.


%% @private Extracts from each contact a index, uri, expire time and q
-spec update_regcontacts([#uri{}], nksip:request(), #nksip_registrar_time{}, 
                         [nksip:uri()], nksip:optslist(), [#reg_contact{}]) ->
    [#reg_contact{}].

update_regcontacts([Contact|Rest], Req, Times, Path, Opts, Acc) ->
    #uri{scheme=Scheme, user=User, domain=Domain, ext_opts=ExtOpts} = Contact,
    #sipmsg{to={To, _}, call_id=CallId, cseq={CSeq, _}, transport=Transp} = Req,
    update_checks(Contact, Req),
    #nksip_registrar_time{
        min = Min,
        max = Max,
        default = Default,
        time = Now,
        time_long = LongNow
    } = Times,
    UriExp = case nksip_lib:get_list(<<"expires">>, ExtOpts) of
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
    Q = case nksip_lib:get_list(<<"q">>, ExtOpts) of
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
    ExtOpts1 = nksip_lib:store_value(<<"expires">>, ExpireBin, ExtOpts),
    InstId = case nksip_lib:get_value(<<"+sip.instance">>, ExtOpts) of
        undefined -> <<>>;
        Inst0 -> nksip_lib:hash(Inst0)
    end,
    Outbo = nksip_lib:get_value(outbound, Opts),
    RegId = case nksip_lib:get_value(<<"reg-id">>, ExtOpts) of
        undefined -> <<>>;
        _ when Outbo == undefined -> <<>>;
        _ when Outbo == false -> throw(first_hop_lacks_outbound);
        _ when InstId == <<>> -> <<>>;
        RegId0 -> RegId0
    end,
    Index = case RegId of
        <<>> -> 
            {Proto, Domain, Port} = nksip_parse:transport(Contact),
            {Scheme, Proto, User, Domain, Port};
        _ -> 
            {ob, InstId, RegId}
    end,

    % Find if this contact was already registered under the AOR
    {Base, Acc1} = case lists:keytake(Index, #reg_contact.index, Acc) of
        false when Expires==0 ->
            {undefined, Acc};
        false ->
            {#reg_contact{min_tmp_pos=0, next_tmp_pos=0, meta=[]}, Acc};
        {value, #reg_contact{call_id=CallId, cseq=OldCSeq}, _} when OldCSeq >= CSeq -> 
            throw({invalid_request, "Rejected Old CSeq"});
        {value, _, Acc0} when Expires==0 ->
            {undefined, Acc0};
        {value, #reg_contact{call_id=CallId}=Base0, Acc0} ->
            {Base0, Acc0};
        {value, #reg_contact{next_tmp_pos=Next0}=Base0, Acc0} ->
            % We have changed the Call-ID for this AOR and index, invalidate all
            % temporary GRUUs
            {Base0#reg_contact{min_tmp_pos=Next0}, Acc0}
    end,
    Acc2 = case Base of
        undefined ->
            Acc1;
        #reg_contact{next_tmp_pos=Next} ->
            ExtOpts2 = case 
                InstId /= <<>> andalso RegId == <<>> andalso 
                Expires>0 andalso lists:member({gruu, true}, Opts)
            of
                true ->
                    case Scheme of
                        sip -> ok;
                        _ -> throw({forbidden, "Invalid Contact"})
                    end,
                    {AORScheme, AORUser, AORDomain} = aor(To),
                    PubUri = #uri{
                        scheme = AORScheme, 
                        user = AORUser, 
                        domain = AORDomain,
                        opts = [{<<"gr">>, InstId}]
                    },
                    Pub = list_to_binary([$", nksip_unparse:ruri(PubUri), $"]),
                    GOpts1 = nksip_lib:store_value(<<"pub-gruu">>, Pub, ExtOpts1),
                    TmpBin = term_to_binary({aor(To), InstId, Next}),
                    TmpGr = encrypt(TmpBin),
                    TmpUri = PubUri#uri{user=TmpGr, opts=[<<"gr">>]},
                    Tmp = list_to_binary([$", nksip_unparse:ruri(TmpUri), $"]),
                    nksip_lib:store_value(<<"temp-gruu">>, Tmp, GOpts1);
                false ->
                    ExtOpts1
            end,
            RegContact = Base#reg_contact{
                index = Index,
                contact = Contact#uri{ext_opts=ExtOpts2},
                updated = LongNow,
                expire = Now + Expires, 
                q = Q,
                call_id = CallId,
                cseq = CSeq,
                transport = Transp,
                path = Path,
                instance_id = InstId,
                reg_id = RegId,
                next_tmp_pos = Next+1
            },
            [RegContact|Acc1]
    end,
    update_regcontacts(Rest, Req, Times, Path, Opts, Acc2);

update_regcontacts([], _Req, _Times, _Path, _Opts, Acc) ->
    lists:reverse(lists:keysort(#reg_contact.updated, Acc)).


%% @private
update_checks(Contact, Req) ->
    #uri{scheme=Scheme, user=User, domain=Domain, opts=Opts} = Contact,
    #sipmsg{to={To, _}} = Req,
    case Domain of
        <<"*">> -> throw(invalid_request);
        _ -> ok
    end,
    case aor(To) of
        {Scheme, User, Domain} -> throw({forbidden, "Invalid Contact"});
        _ -> ok
    end,
    case lists:member(<<"gr">>, Opts) of
        true ->
            case catch decrypt(User) of
                LoopTmp when is_binary(LoopTmp) ->
                    {{LScheme, LUser, LDomain}, _, _} = binary_to_term(LoopTmp),
                    case aor(To) of
                        {LScheme, LUser, LDomain} -> 
                            throw({forbidden, "Invalid Contact"});
                        _ -> 
                            ok
                    end;
                _ ->
                    ok
            end;
        false ->
            ok
    end.


%% @private
check_several_reg_id([], _Expires, _Found) ->
    ok;

check_several_reg_id([#uri{ext_opts=Opts}|Rest], Default, Found) ->
    case nksip_lib:get_value(<<"reg-id">>, Opts) of
        undefined -> 
            check_several_reg_id(Rest, Default, Found);
        _ ->
            Expires = case nksip_lib:get_list(<<"expires">>, Opts) of
                [] ->
                    Default;
                Expires0 ->
                    case catch list_to_integer(Expires0) of
                        Expires1 when is_integer(Expires1) -> Expires1;
                        _ -> Default
                    end
            end,
            case Expires of
                0 -> 
                    check_several_reg_id(Rest, Default, Found);
                _ when Found ->
                    throw({invalid_request, "Several 'reg-id' Options"});
                _ ->
                    check_several_reg_id(Rest, Default, true)
            end
    end.


%% @private
aor(#uri{scheme=Scheme, user=User, domain=Domain}) ->
    {Scheme, User, Domain}.


%% @private Generates a contact value including Path
make_contact(#reg_contact{contact=Contact, path=[]}) ->
    Contact;
make_contact(#reg_contact{contact=Contact, path=Path}) ->
    #uri{headers=Headers} = Contact,
    Route1 = nksip_unparse:uri(Path),
    Routes2 = list_to_binary(http_uri:encode(binary_to_list(Route1))),
    Headers1 = [{<<"route">>, Routes2}|Headers],
    Contact#uri{headers=Headers1, ext_opts=[], ext_headers=[]}.


%% @private
-spec del_all(nksip:request()) ->
    ok | not_found.

del_all(Req) ->
    #sipmsg{app_id=AppId, to={To, _}, call_id=CallId, cseq={CSeq, _}} = Req,
    AOR = aor(To),
    {ok, RegContacts} = store_get(AppId, AOR),
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
store_get(AppId, AOR) -> 
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
store_put(AppId, AOR, RegContacts, Time) ->
    callback(AppId, {put, AOR, RegContacts, Time}).


%% @private
store_del(AppId, AOR) ->
    case callback(AppId, {del, AOR}) of
        ok -> ok;
        not_found -> not_found;
        _ -> callback_error
    end.


%% @private
store_del_all(AppId) ->
    callback(AppId, del_all).


%% @private 
-spec callback(nksip:app_id(), term()) ->
    term() | error.

callback(AppId, Op) -> 
    case AppId:nkcb_call(sip_registrar_store, [Op, AppId], AppId) of
        {ok, Reply} -> Reply;
        _ -> error
    end.


%% @private
encrypt(Bin) ->
    <<Key:16/binary, _/binary>> = nksip_config_cache:global_id(),
    base64:encode(crypto:aes_cfb_128_encrypt(Key, ?AES_IV, Bin)).


%% @private
decrypt(Bin) ->
    <<Key:16/binary, _/binary>> = nksip_config_cache:global_id(),
    crypto:aes_cfb_128_decrypt(Key, ?AES_IV, base64:decode(Bin)).



