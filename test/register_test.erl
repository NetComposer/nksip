%% -------------------------------------------------------------------
%%
%% register_test: Register Test Suite
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

-module(register_test).
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").

-include_lib("eunit/include/eunit.hrl").
-include("../include/nksip.hrl").
-include("../plugins/include/nksip_registrar.hrl").

-compile([export_all]).
-define(RECV(T), receive T -> T after 1000 -> error(recv) end).

register_test_() ->
    {setup, spawn, 
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            fun register1/0, 
            fun register2/0
        ]
    }.


start() ->
    tests_util:start_nksip(),

    {ok, _} = nksip:start(server1, [
        {callback, ?MODULE},
        {from, "sip:server1@nksip"},
        {plugins, [nksip_registrar]},
        {transports, "sip:all:5060, <sip:all:5061;transport=tls>"},
        {supported, "100rel,timer,path"},        % No outbound
        {sip_registrar_min_time, 60}
    ]),

    {ok, _} = nksip:start(client1, [
        {callback, ?MODULE},
        {from, "sip:client1@nksip"},
        {local_host, "127.0.0.1"},
        {transports, ["<sip:all:5070>", "<sip:all:5071;transport=tls>"]},
        {supported, "100rel,timer,path"}        % No outbound
    ]),

    {ok, _} = nksip:start(client2, [
        {callback, ?MODULE},
        {from, "sip:client2@nksip"}]),

    tests_util:log(),
    ?debugFmt("Starting ~p", [?MODULE]).

stop() ->
    ok = nksip:stop(server1),
    ok = nksip:stop(client1),
    ok = nksip:stop(client2).


register1() ->
    Spec = nkservice_server:get_spec(server1),
    Min = maps:get(sip_registrar_min_time, Spec),
    MinB = nklib_util:to_binary(Min),
    Max = maps:get(sip_registrar_max_time, Spec),
    MaxB = nklib_util:to_binary(Max),
    Def = maps:get(sip_registrar_default_time, Spec),
    DefB = nklib_util:to_binary(Def),
    
    % Method not allowed
    {ok, 405, []} = nksip_uac:register(client2, "sip:127.0.0.1:5070", []),

    {ok, 200, Values1} = nksip_uac:register(client1, "sip:127.0.0.1", 
                            [unregister_all, {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),
    
    Ref = make_ref(),
    Self = self(),

    CB = fun(Term) ->
        case Term of
            ({req, Req1, _Call}) ->
                FCallId1 = nksip_sipmsg:meta(call_id, Req1),
                {ok, FCSeq1} = nksip_request:meta(cseq_num, Req1),
                Self ! {Ref, {cb1_1, FCallId1, FCSeq1}};
            ({resp, 200, Resp1, _Call}) ->
                {ok, [FContact1]} = nksip_response:header(<<"contact">>, Resp1),
                Self ! {Ref, {cb1_2, FContact1}}
        end
    end,
    {async, _} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [async, {callback, CB}, contact, get_request]),
    {_, {_, CallId, CSeq}} = ?RECV({Ref, {cb1_1, CallId_0, CSeq_0}}),
    {_, {_, Contact}} = ?RECV({Ref, {cb1_2, Contact_0}}),

    Name = <<"client1">>,
    [#uri{
        user = Name, 
        domain = Domain, 
        port = Port,
        ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, DefB}]
    }] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),
    UUID = nksip:get_uuid(client1),
    C1_UUID = <<$", UUID/binary, $">>,
    MakeContact = fun(Exp) ->
        list_to_binary([
            "<sip:", Name, "@", Domain, ":", nklib_util:to_binary(Port),
            ">;+sip.instance=", C1_UUID, ";expires=", Exp])
        end,

    Contact = MakeContact(DefB),

    {ok, 400, Values3} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq}, contact,
                                     {meta, [reason_phrase]}]),
    [{reason_phrase, <<"Rejected Old CSeq">>}] = Values3,

    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, contact]),

    {ok, 400, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                    [{call_id, CallId}, {cseq_num, CSeq+1}, 
                                     unregister_all]),
    Opts3 = [{expires, Min-1}, contact, {meta, [<<"min-expires">>]}],
    {ok, 423, Values4} = nksip_uac:register(client1, "sip:127.0.0.1", Opts3),
    [{_, [MinB]}] = Values4,
    
    Opts4 = [{expires, Max+1}, contact, {meta, [<<"contact">>]}],
    {ok, 200, Values5} = nksip_uac:register(client1, "sip:127.0.0.1", Opts4),
    [{_, [Contact5]}] = Values5,
    Contact5 = MakeContact(MaxB),
    [#uri{user=Name, domain=Domain, port=Port, 
         ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, MaxB}]}] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    Opts5 = [{expires, Min}, contact, {meta, [<<"contact">>]}],
    ExpB = nklib_util:to_binary(Min),
    {ok, 200, Values6} = nksip_uac:register(client1, "sip:127.0.0.1", Opts5),
    [{_, [Contact6]}] = Values6,
    Contact6 = MakeContact(ExpB),
    [#uri{user=Name, domain=Domain, port=Port, 
          ext_opts=[{<<"+sip.instance">>, _}, {<<"expires">>, ExpB}]}] = 
        nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    {ok, Registrar} = nkservice_server:find(server1),
    Expire = nklib_util:timestamp()+Min,
    [#reg_contact{
            contact = #uri{
                user = <<"client1">>, domain=Domain, port=Port, 
                ext_opts=[{<<"+sip.instance">>, C1_UUID}, {<<"expires">>, ExpB}]}, 
            expire = Expire,
            q = 1.0
    }] = nksip_registrar_lib:get_info(Registrar, sip, <<"client1">>, <<"nksip">>),



    % true = lists:member(Reg1, nksip_registrar_util:get_all()),

    % Simulate a request coming at the server from 127.0.0.1:Port, 
    % From is sip:client1@nksip,
    Request1 = #sipmsg{
                srv_id = element(2, nkservice_server:find(server1)), 
                from = {#uri{scheme=sip, user= <<"client1">>, domain= <<"nksip">>}, <<>>},
                nkport = #nkport{
                                transp = udp, 
                                remote_ip = {127,0,0,1}, 
                                remote_port=Port}},

    true = nksip_registrar:is_registered(Request1),

    {ok, Ip} = nklib_util:to_ip(Domain),
    
    % Now coming from the Contact's registered address
    Request2 = Request1#sipmsg{nkport=(Request1#sipmsg.nkport)
                                                #nkport{remote_ip=Ip}},
    true = nksip_registrar:is_registered(Request2),

    ok = nksip_registrar:delete(server1, sip, <<"client1">>, <<"nksip">>),
    not_found  = nksip_registrar:delete(server1, sip, <<"client1">>, <<"nksip">>),
    ok.


register2() ->
    nksip_registrar_util:clear(),

    Opts1 = [contact, {expires, 300}],
    FromS = {from, <<"sips:client1@nksip">>},

    {ok, 200, Values1} = nksip_uac:register(client1, "sip:127.0.0.1", 
                            [unregister_all, {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values1,
    [] = nksip_registrar:find(server1, sip, <<"client1">>, <<"nksip">>),

    {ok, 200, Values2} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                            [FromS, unregister_all, 
                                             {meta, [<<"contact">>]}]),
    [{<<"contact">>, []}] = Values2,
    [] = nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, 
                                            "<sip:127.0.0.1;transport=tcp>", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, 
                                            "<sip:127.0.0.1;transport=tls>", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, "sips:127.0.0.1", Opts1),
    {ok, 200, []} = nksip_uac:register(client1, "sip:127.0.0.1", 
                    [{contact, "tel:123456"}, {expires, 300}]),

    UUID1 = nksip:get_uuid(client1),
    QUUID1 = <<$", UUID1/binary, $">>,

    % Now we register a different AOR (with sips)
    % ManualContact = <<"<sips:client1@127.0.0.1:5071>;+sip.instance=", QUUID1/binary>>,
    ManualContact = <<"<sips:client1@127.0.0.1:5071>">>,
    {ok, 200, Values3} = nksip_uac:register(client1, "sips:127.0.0.1", 
                        [{contact, ManualContact}, {from, "sips:client1@nksip"},
                         {meta, [<<"contact">>]}, {expires, 300}]),
    [{<<"contact">>, Contact3}] = Values3,
    Contact3Uris = nklib_parse:uris(Contact3),

    {ok, 200, Values4} = nksip_uac:register(client1, "sip:127.0.0.1", 
                                            [{meta,[contacts]}]),
    [{contacts, Contacts4}] = Values4, 
    [
        #uri{scheme=sip, port=5070, opts=[], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5070, opts=[{<<"transport">>, <<"tcp">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sip, port=5071, opts=[{<<"transport">>, <<"tls">>}], 
             ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=sips, port=5071, opts=[],
            ext_opts=[{<<"+sip.instance">>, QUUID1}, {<<"expires">>, <<"300">>}]},
        #uri{scheme=tel, domain=(<<"123456">>), opts=[], 
             ext_opts=[{<<"expires">>, <<"300">>}]}
    ]  = lists:sort(Contacts4),

    [#uri{scheme=sips, port=5071, opts=[], ext_opts=[{<<"expires">>, <<"300">>}]}] = 
        Contact3Uris,
    [#uri{scheme=sips, user = <<"client1">>, domain=_Domain, port = 5071}] =
        nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    Contact = <<"<sips:client1@127.0.0.1:5071>;expires=0">>,
    {ok, 200, []} = nksip_uac:register(client1, "sips:127.0.0.1", 
                                        [{contact, Contact}, {from, "sips:client1@nksip"},
                                         {expires, 300}]),
    [] = nksip_registrar:find(server1, sips, <<"client1">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client2, 
                                        "sip:127.0.0.1", [unregister_all]),
    [] = nksip_registrar:find(server1, sip, <<"client2">>, <<"nksip">>),

    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{local_host, "aaa"}, contact]),
    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{contact, "<sip:bbb>;q=2.1;expires=180, <sips:ccc>;q=3"}]),
    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", 
                                [{contact, <<"<sip:ddd:444;transport=tcp>;q=2.1">>}]),
    [
        [
            #uri{user = <<"client2">>, domain = <<"aaa">>, ext_opts = ExtOpts1}
        ],
        [
            #uri{user= <<>>, domain = <<"ddd">>,port = 444,
                opts = [{<<"transport">>,<<"tcp">>}],
               ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"3600">>}]},
             #uri{user = <<>>, domain = <<"bbb">>, port = 0,
                opts = [], ext_opts = [{<<"q">>,<<"2.1">>},{<<"expires">>,<<"180">>}]}
        ],
        [
            #uri{user = <<>>, domain = <<"ccc">>, port = 0, 
                opts = [], ext_opts = [{<<"q">>,<<"3">>},{<<"expires">>,<<"3600">>}]}
        ]
    ] = nksip_registrar:qfind(server1, sip, <<"client2">>, <<"nksip">>),
    true = lists:member({<<"expires">>,<<"3600">>}, ExtOpts1),

    {ok, 200, []} = nksip_uac:register(client2, "sip:127.0.0.1", [unregister_all]),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


init(#{name:=Id}, State) ->
    ok = nkservice_server:put(Id, domains, [<<"nksip">>, <<"127.0.0.1">>, <<"[::1]">>]),
    {ok, State}.


sip_route(Scheme, User, Domain, Req, _Call) ->
    case nksip_request:srv_name(Req) of
        {ok, server1} ->
            Opts = [record_route, {insert, "x-nk-server", server1}],
            Domains = nkservice_server:get(server1, domains),
            case lists:member(Domain, Domains) of
                true when User =:= <<>> ->
                    process;
                true when Domain =:= <<"nksip">> ->
                    case nksip_registrar:find(server1, Scheme, User, Domain) of
                        [] -> {reply, temporarily_unavailable};
                        UriList -> {proxy, UriList, Opts}
                    end;
                _ ->
                    {proxy, ruri, Opts}
            end;
        {ok, _} ->
            process
    end.
