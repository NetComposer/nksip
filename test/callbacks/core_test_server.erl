-module(core_test_server).

%% Include nkserver macros
%% -include_lib("nkserver/include/nkserver_module.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-include_lib("nkserver/include/nkserver_module.hrl").

-export([config/1]).
-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5, sip_invite/2, sip_reinvite/2,
         sip_cancel/3, sip_bye/2, sip_info/2, sip_ack/2, sip_options/2, sip_dialog_update/3,
         sip_session_update/3]).

%%%%%%%%%%%%%%%%%%%%%%%  CallBacks (servers and clients) %%%%%%%%%%%%%%%%%%%%%


config(Opts) ->
    Opts#{
        sip_from => "\"NkSIP Basic SUITE Test Server\" <sip:server@nksip>",
        sip_local_host => "127.0.0.1",
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>",
        plugins => [nksip_registrar]
    }.



sip_get_user_pass(User, Realm, _Req, _Call) ->
    case {User, Realm} of
        {<<"core_test_client1">>, <<"nksip">>} -> <<"1234">>;
        {<<"core_test_client2">>, <<"nksip">>} -> <<"4321">>;
        _ -> false
    end.

sip_authorize(Auth, Req, _Call) ->
    case nksip_sipmsg:header(<<"x-nk-auth">>, Req) of
        [<<"true">>] ->
            case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
                true ->
                    ok;
                false ->
                    case nklib_util:get_value({digest, <<"nksip">>}, Auth) of
                        true -> ok;
                        false -> forbidden;
                        undefined -> {proxy_authenticate, <<"nksip">>}
                    end
            end;
        _ ->
            ok
    end.

sip_route(Scheme, User, Domain, Req, _Call) ->
    send_reply(Req, route),
    Opts = [
        record_route,
        {add, "x-nk-id", ?MODULE}
    ],
    case lists:member(Domain, [<<"127.0.0.1">>, <<"nksip">>]) of
        true when User =:= <<>> ->
            process;
        true when Domain =:= <<"nksip">> ->
            case nksip_registrar:find(?MODULE, Scheme, User, Domain) of
                [] ->
                    % lager:notice("E: ~p, ~p, ~p", [Scheme, User, Domain]),
                    {reply, temporarily_unavailable};
                UriList ->
                 {proxy, UriList, Opts}
            end;
        true ->
            % It is for 127.0.0.1 domain, route
            {proxy, ruri, Opts};
        false ->
            {proxy, ruri, Opts}
    end.


sip_invite(Req, _Call) ->
    send_reply(Req, invite),
    case nksip_sipmsg:header(<<"x-nk-op">>, Req) of
        [<<"wait">>] ->
            {ok, ReqId} = nksip_request:get_handle(Req),
            lager:error("Next error about a looped_process is expected"),
            {error, looped_process} = nksip_request:reply(ringing, ReqId),
            spawn(
                fun() ->
                    nksip_request:reply(ringing, ReqId),
                    timer:sleep(1000),
                    nksip_request:reply(ok, ReqId)
                end),
            noreply;
        _ ->
            {reply, {answer, nksip_sipmsg:get_meta(body, Req)}}
    end.


sip_reinvite(Req, _Call) ->
    send_reply(Req, reinvite),
    {reply, {answer, nksip_sipmsg:get_meta(body, Req)}}.


sip_cancel(InvReq, Req, _Call) ->
    {ok, 'INVITE'} = nksip_request:method(InvReq),
    send_reply(Req, cancel),
    ok.


sip_bye(Req, _Call) ->
    send_reply(Req, bye),
    {reply, ok}.


sip_info(Req, _Call) ->
    send_reply(Req, info),
    {reply, ok}.


sip_ack(Req, _Call) ->
    send_reply(Req, ack),
    ok.


sip_options(Req, _Call) ->
    send_reply(Req, options),
    SrvId = nksip_sipmsg:get_meta(srv_id, Req),
    Ids = nksip_sipmsg:header(<<"x-nk-id">>, Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    Reply = {ok, [{add, "x-nk-id", [nklib_util:to_binary(SrvId)|Ids]}]},
    spawn(fun() -> nksip_request:reply(Reply, ReqId) end),
    noreply.


sip_dialog_update(State, Dialog, _Call) ->
    case State of
        start -> send_reply(Dialog, dialog_start);
        stop -> send_reply(Dialog, dialog_stop);
        _ -> ok
    end.


sip_session_update(State, Dialog, _Call) ->
    case State of
        {start, _, _} -> send_reply(Dialog, session_start);
        stop -> send_reply(Dialog, session_stop);
        _ -> ok
    end.



%%%%%%%%%%% Util %%%%%%%%%%%%%%%%%%%%


send_reply(Elem, Msg) ->
    App = case Elem of
        #sipmsg{} -> nksip_sipmsg:get_meta(srv_id, Elem);
        #dialog{} -> nksip_dialog_lib:get_meta(srv_id, Elem)
    end,
    case nkserver:get(App, inline_test) of
        {Ref, Pid} -> Pid ! {Ref, {App, Msg}};
        _ -> ok
    end.





