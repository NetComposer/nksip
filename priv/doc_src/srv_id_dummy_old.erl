%% @doc Dummy Implementation of compiled 
%%
%% == Header 1 ==
%%
%% This is where we tell about this module. 
%%
%% @end



-module(srv_id_dummy_old).

-export([cache_sip_allow/0]).

-compile([export_all]).

terminate(AB, B1) ->
    nkservice_callbacks:terminate(A1, B1).

sip_update(A1, B1) ->
    nksip_callbacks:sip_update(A1, B1).

sip_subscribe(A1, B1) ->
    nksip_callbacks:sip_subscribe(A1, B1).

sip_session_update(A1, B1, C1) ->
    nksip_callbacks:sip_session_update(A1, B1, C1).

sip_route(A2, B2, C2, D2, E2) ->
    case nksip_tutorial_server_callbacks:sip_route(A2, B2,
						   C2, D2, E2)
	of
      continue ->
	  [A1, B1, C1, D1, E1] = [A2, B2, C2, D2, E2],
	  nksip_callbacks:sip_route(A1, B1, C1, D1, E1);
      {continue, [A1, B1, C1, D1, E1]} ->
	  nksip_callbacks:sip_route(A1, B1, C1, D1, E1);
      Other -> Other
    end.

sip_resubscribe(A1, B1) ->
    nksip_callbacks:sip_resubscribe(A1, B1).

sip_reinvite(A1, B1) ->
    nksip_callbacks:sip_reinvite(A1, B1).

sip_registrar_store(A1, B1) ->
    nksip_registrar_callbacks:sip_registrar_store(A1, B1).

sip_register(A1, B1) ->
    nksip_callbacks:sip_register(A1, B1).

sip_refer(A1, B1) -> nksip_callbacks:sip_refer(A1, B1).

sip_publish(A1, B1) ->
    nksip_callbacks:sip_publish(A1, B1).

sip_options(A1, B1) ->
    nksip_callbacks:sip_options(A1, B1).

sip_notify(A1, B1) ->
    nksip_callbacks:sip_notify(A1, B1).

sip_message(A1, B1) ->
    nksip_callbacks:sip_message(A1, B1).

sip_invite(A1, B1) ->
    nksip_callbacks:sip_invite(A1, B1).

sip_info(A1, B1) -> nksip_callbacks:sip_info(A1, B1).

sip_get_user_pass(A2, B2, C2, D2) ->
    case
      nksip_tutorial_server_callbacks:sip_get_user_pass(A2,
							B2, C2, D2)
	of
      continue ->
	  [A1, B1, C1, D1] = [A2, B2, C2, D2],
	  nksip_callbacks:sip_get_user_pass(A1, B1, C1, D1);
      {continue, [A1, B1, C1, D1]} ->
	  nksip_callbacks:sip_get_user_pass(A1, B1, C1, D1);
      Other -> Other
    end.

sip_dialog_update(A1, B1, C1) ->
    nksip_callbacks:sip_dialog_update(A1, B1, C1).

sip_cancel(A1, B1, C1) ->
    nksip_callbacks:sip_cancel(A1, B1, C1).

sip_bye(A1, B1) -> nksip_callbacks:sip_bye(A1, B1).

sip_authorize(A2, B2, C2) ->
    case nksip_tutorial_server_callbacks:sip_authorize(A2,
						       B2, C2)
	of
      continue ->
	  [A1, B1, C1] = [A2, B2, C2],
	  nksip_callbacks:sip_authorize(A1, B1, C1);
      {continue, [A1, B1, C1]} ->
	  nksip_callbacks:sip_authorize(A1, B1, C1);
      Other -> Other
    end.

sip_ack(A1, B1) -> nksip_callbacks:sip_ack(A1, B1).

plugin_stop(A1) -> nkservice_callbacks:plugin_stop(A1).

plugin_start(A1) ->
    nkservice_callbacks:plugin_start(A1).

nks_sip_uas_timer(A1, B1, C1) ->
    nksip_callbacks:nks_sip_uas_timer(A1, B1, C1).

nks_sip_uas_sent_reply(A1) ->
    nksip_callbacks:nks_sip_uas_sent_reply(A1).

nks_sip_uas_send_reply(A1, B1, C1) ->
    nksip_callbacks:nks_sip_uas_send_reply(A1, B1, C1).

nks_sip_uas_process(A1, B1) ->
    nksip_callbacks:nks_sip_uas_process(A1, B1).

nks_sip_uas_method(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_uas_method(A1, B1, C1, D1).

nks_sip_uas_dialog_response(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_uas_dialog_response(A1, B1, C1,
						D1).

nks_sip_uac_response(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_uac_response(A1, B1, C1, D1).

nks_sip_uac_reply(A1, B1, C1) ->
    nksip_callbacks:nks_sip_uac_reply(A1, B1, C1).

nks_sip_uac_proxy_opts(A1, B1) ->
    nksip_callbacks:nks_sip_uac_proxy_opts(A1, B1).

nks_sip_uac_pre_response(A1, B1, C1) ->
    nksip_callbacks:nks_sip_uac_pre_response(A1, B1, C1).

nks_sip_uac_pre_request(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_uac_pre_request(A1, B1, C1, D1).

nks_sip_transport_uas_sent(A1) ->
    nksip_callbacks:nks_sip_transport_uas_sent(A1).

nks_sip_transport_uac_headers(A1, B1, C1, D1, E1, F1) ->
    nksip_callbacks:nks_sip_transport_uac_headers(A1, B1,
						  C1, D1, E1, F1).

nks_sip_route(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_route(A1, B1, C1, D1).

nks_sip_registrar_update_regcontact(A1, B1, C1, D1) ->
    nksip_registrar_callbacks:nks_sip_registrar_update_regcontact(A1,
								  B1, C1, D1).

nks_sip_registrar_request_reply(A1, B1, C1) ->
    nksip_registrar_callbacks:nks_sip_registrar_request_reply(A1,
							      B1, C1).

nks_sip_registrar_request_opts(A1, B1) ->
    nksip_registrar_callbacks:nks_sip_registrar_request_opts(A1,
							     B1).

nks_sip_registrar_get_index(A1, B1) ->
    nksip_registrar_callbacks:nks_sip_registrar_get_index(A1,
							  B1).

nks_sip_parse_uas_opt(A1, B1, C1) ->
    nksip_callbacks:nks_sip_parse_uas_opt(A1, B1, C1).

nks_sip_parse_uac_opts(A1, B1) ->
    nksip_callbacks:nks_sip_parse_uac_opts(A1, B1).

nks_sip_method(A2, B2) ->
    case nksip_registrar_callbacks:nks_sip_method(A2, B2) of
      continue ->
	  [A1, B1] = [A2, B2],
	  nksip_callbacks:nks_sip_method(A1, B1);
      {continue, [A1, B1]} ->
	  nksip_callbacks:nks_sip_method(A1, B1);
      Other -> Other
    end.

nks_sip_make_uac_dialog(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_make_uac_dialog(A1, B1, C1, D1).

nks_sip_dialog_update(A1, B1, C1) ->
    nksip_callbacks:nks_sip_dialog_update(A1, B1, C1).

nks_sip_debug(A1, B1, C1) ->
    nksip_callbacks:nks_sip_debug(A1, B1, C1).

nks_sip_connection_sent(A1, B1) ->
    nksip_callbacks:nks_sip_connection_sent(A1, B1).

nks_sip_connection_recv(A1, B1, C1, D1) ->
    nksip_callbacks:nks_sip_connection_recv(A1, B1, C1, D1).

nks_sip_call(A1, B1, C1) ->
    nksip_callbacks:nks_sip_call(A1, B1, C1).

nks_sip_authorize_data(A2, B2, C2) ->
    case
      nksip_registrar_callbacks:nks_sip_authorize_data(A2, B2,
						       C2)
	of
      continue ->
	  [A1, B1, C1] = [A2, B2, C2],
	  nksip_callbacks:nks_sip_authorize_data(A1, B1, C1);
      {continue, [A1, B1, C1]} ->
	  nksip_callbacks:nks_sip_authorize_data(A1, B1, C1);
      Other -> Other
    end.

init(A2, B2) ->
    case nksip_tutorial_server_callbacks:init(A2, B2) of
      ok ->
	  [A1, B1] = [A2, B2], nkservice_callbacks:init(A1, B1);
      {ok, B1} ->
	  [A1] = [A2], nkservice_callbacks:init(A1, B1);
      Other -> Other
    end.

handle_info(A2, B2) ->
    case nksip_callbacks:handle_info(A2, B2) of
      continue ->
	  [A1, B1] = [A2, B2],
	  nkservice_callbacks:handle_info(A1, B1);
      {continue, [A1, B1]} ->
	  nkservice_callbacks:handle_info(A1, B1);
      Other -> Other
    end.

handle_cast(A2, B2) ->
    case nksip_callbacks:handle_cast(A2, B2) of
      continue ->
	  [A1, B1] = [A2, B2],
	  nkservice_callbacks:handle_cast(A1, B1);
      {continue, [A1, B1]} ->
	  nkservice_callbacks:handle_cast(A1, B1);
      Other -> Other
    end.

handle_call(A3, B3, C3) ->
    case nksip_tutorial_server_callbacks:handle_call(A3, B3,
						     C3)
	of
      continue ->
	  [A2, B2, C2] = [A3, B3, C3],
	  case nksip_callbacks:handle_call(A2, B2, C2) of
	    continue ->
		[A1, B1, C1] = [A2, B2, C2],
		nkservice_callbacks:handle_call(A1, B1, C1);
	    {continue, [A1, B1, C1]} ->
		nkservice_callbacks:handle_call(A1, B1, C1);
	    Other -> Other
	  end;
      {continue, [A2, B2, C2]} ->
	  case nksip_callbacks:handle_call(A2, B2, C2) of
	    continue ->
		[A1, B1, C1] = [A2, B2, C2],
		nkservice_callbacks:handle_call(A1, B1, C1);
	    {continue, [A1, B1, C1]} ->
		nkservice_callbacks:handle_call(A1, B1, C1);
	    Other -> Other
	  end;
      Other -> Other
    end.

foo(A1, B1) -> nksip_callbacks:foo(A1, B1).

code_change(A1, B1, C1) ->
    nkservice_callbacks:code_change(A1, B1, C1).

uuid() ->
    <<97, 55, 102, 101, 102, 51, 48, 54, 45, 50, 56, 51, 53,
      45, 97, 57, 54, 53, 45, 56, 98, 52, 98, 45, 50, 56, 99,
      102, 101, 57, 49, 57, 50, 100, 101, 98>>.

spec() ->
    {map,
     <<131, 116, 0, 0, 0, 30, 100, 0, 8, 99, 97, 108, 108,
       98, 97, 99, 107, 100, 0, 31, 110, 107, 115, 105, 112,
       95, 116, 117, 116, 111, 114, 105, 97, 108, 95, 115, 101,
       114, 118, 101, 114, 95, 99, 97, 108, 108, 98, 97, 99,
       107, 115, 100, 0, 5, 99, 108, 97, 115, 115, 100, 0, 5,
       110, 107, 115, 105, 112, 100, 0, 2, 105, 100, 100, 0, 7,
       97, 114, 109, 101, 106, 108, 55, 100, 0, 9, 108, 111,
       103, 95, 108, 101, 118, 101, 108, 97, 6, 100, 0, 4, 110,
       97, 109, 101, 100, 0, 6, 115, 101, 114, 118, 101, 114,
       100, 0, 7, 112, 108, 117, 103, 105, 110, 115, 108, 0, 0,
       0, 3, 100, 0, 5, 110, 107, 115, 105, 112, 100, 0, 15,
       110, 107, 115, 105, 112, 95, 114, 101, 103, 105, 115,
       116, 114, 97, 114, 100, 0, 31, 110, 107, 115, 105, 112,
       95, 116, 117, 116, 111, 114, 105, 97, 108, 95, 115, 101,
       114, 118, 101, 114, 95, 99, 97, 108, 108, 98, 97, 99,
       107, 115, 106, 100, 0, 10, 115, 105, 112, 95, 97, 99,
       99, 101, 112, 116, 100, 0, 9, 117, 110, 100, 101, 102,
       105, 110, 101, 100, 100, 0, 9, 115, 105, 112, 95, 97,
       108, 108, 111, 119, 108, 0, 0, 0, 12, 109, 0, 0, 0, 8,
       82, 69, 71, 73, 83, 84, 69, 82, 109, 0, 0, 0, 6, 73, 78,
       86, 73, 84, 69, 109, 0, 0, 0, 3, 65, 67, 75, 109, 0, 0,
       0, 6, 67, 65, 78, 67, 69, 76, 109, 0, 0, 0, 3, 66, 89,
       69, 109, 0, 0, 0, 7, 79, 80, 84, 73, 79, 78, 83, 109, 0,
       0, 0, 4, 73, 78, 70, 79, 109, 0, 0, 0, 6, 85, 80, 68,
       65, 84, 69, 109, 0, 0, 0, 9, 83, 85, 66, 83, 67, 82, 73,
       66, 69, 109, 0, 0, 0, 6, 78, 79, 84, 73, 70, 89, 109, 0,
       0, 0, 5, 82, 69, 70, 69, 82, 109, 0, 0, 0, 7, 77, 69,
       83, 83, 65, 71, 69, 106, 100, 0, 9, 115, 105, 112, 95,
       100, 101, 98, 117, 103, 100, 0, 5, 102, 97, 108, 115,
       101, 100, 0, 18, 115, 105, 112, 95, 100, 105, 97, 108,
       111, 103, 95, 116, 105, 109, 101, 111, 117, 116, 98, 0,
       0, 7, 8, 100, 0, 17, 115, 105, 112, 95, 101, 118, 101,
       110, 116, 95, 101, 120, 112, 105, 114, 101, 115, 97, 60,
       100, 0, 24, 115, 105, 112, 95, 101, 118, 101, 110, 116,
       95, 101, 120, 112, 105, 114, 101, 115, 95, 111, 102,
       102, 115, 101, 116, 97, 5, 100, 0, 10, 115, 105, 112,
       95, 101, 118, 101, 110, 116, 115, 106, 100, 0, 8, 115,
       105, 112, 95, 102, 114, 111, 109, 100, 0, 9, 117, 110,
       100, 101, 102, 105, 110, 101, 100, 100, 0, 14, 115, 105,
       112, 95, 108, 111, 99, 97, 108, 95, 104, 111, 115, 116,
       109, 0, 0, 0, 9, 108, 111, 99, 97, 108, 104, 111, 115,
       116, 100, 0, 15, 115, 105, 112, 95, 108, 111, 99, 97,
       108, 95, 104, 111, 115, 116, 54, 100, 0, 4, 97, 117,
       116, 111, 100, 0, 13, 115, 105, 112, 95, 109, 97, 120,
       95, 99, 97, 108, 108, 115, 98, 0, 1, 134, 160, 100, 0,
       10, 115, 105, 112, 95, 110, 111, 95, 49, 48, 48, 100, 0,
       5, 102, 97, 108, 115, 101, 100, 0, 17, 115, 105, 112,
       95, 110, 111, 110, 99, 101, 95, 116, 105, 109, 101, 111,
       117, 116, 97, 30, 100, 0, 26, 115, 105, 112, 95, 114,
       101, 103, 105, 115, 116, 114, 97, 114, 95, 100, 101,
       102, 97, 117, 108, 116, 95, 116, 105, 109, 101, 98, 0,
       0, 14, 16, 100, 0, 22, 115, 105, 112, 95, 114, 101, 103,
       105, 115, 116, 114, 97, 114, 95, 109, 97, 120, 95, 116,
       105, 109, 101, 98, 0, 1, 81, 128, 100, 0, 22, 115, 105,
       112, 95, 114, 101, 103, 105, 115, 116, 114, 97, 114, 95,
       109, 105, 110, 95, 116, 105, 109, 101, 97, 60, 100, 0,
       9, 115, 105, 112, 95, 114, 111, 117, 116, 101, 106, 100,
       0, 13, 115, 105, 112, 95, 115, 117, 112, 112, 111, 114,
       116, 101, 100, 108, 0, 0, 0, 1, 109, 0, 0, 0, 4, 112,
       97, 116, 104, 106, 100, 0, 11, 115, 105, 112, 95, 116,
       105, 109, 101, 114, 95, 99, 97, 180, 100, 0, 12, 115,
       105, 112, 95, 116, 105, 109, 101, 114, 95, 116, 49, 98,
       0, 0, 1, 244, 100, 0, 12, 115, 105, 112, 95, 116, 105,
       109, 101, 114, 95, 116, 50, 98, 0, 0, 15, 160, 100, 0,
       12, 115, 105, 112, 95, 116, 105, 109, 101, 114, 95, 116,
       52, 98, 0, 0, 19, 136, 100, 0, 17, 115, 105, 112, 95,
       116, 114, 97, 110, 115, 95, 116, 105, 109, 101, 111,
       117, 116, 98, 0, 0, 3, 132, 100, 0, 10, 116, 114, 97,
       110, 115, 112, 111, 114, 116, 115, 108, 0, 0, 0, 2, 104,
       2, 108, 0, 0, 0, 1, 104, 4, 100, 0, 14, 110, 107, 115,
       105, 112, 95, 112, 114, 111, 116, 111, 99, 111, 108,
       100, 0, 3, 117, 100, 112, 104, 4, 97, 0, 97, 0, 97, 0,
       97, 0, 98, 0, 0, 19, 196, 106, 116, 0, 0, 0, 5, 100, 0,
       12, 114, 101, 115, 111, 108, 118, 101, 95, 116, 121,
       112, 101, 100, 0, 6, 108, 105, 115, 116, 101, 110, 100,
       0, 6, 115, 114, 118, 95, 105, 100, 104, 2, 100, 0, 5,
       110, 107, 115, 105, 112, 100, 0, 7, 97, 114, 109, 101,
       106, 108, 55, 100, 0, 14, 117, 100, 112, 95, 115, 116,
       97, 114, 116, 115, 95, 116, 99, 112, 100, 0, 4, 116,
       114, 117, 101, 100, 0, 14, 117, 100, 112, 95, 115, 116,
       117, 110, 95, 114, 101, 112, 108, 121, 100, 0, 4, 116,
       114, 117, 101, 100, 0, 11, 117, 100, 112, 95, 115, 116,
       117, 110, 95, 116, 49, 98, 0, 0, 1, 244, 104, 2, 108, 0,
       0, 0, 1, 104, 4, 100, 0, 14, 110, 107, 115, 105, 112,
       95, 112, 114, 111, 116, 111, 99, 111, 108, 100, 0, 3,
       116, 108, 115, 104, 4, 97, 0, 97, 0, 97, 0, 97, 0, 98,
       0, 0, 19, 197, 106, 116, 0, 0, 0, 2, 100, 0, 12, 114,
       101, 115, 111, 108, 118, 101, 95, 116, 121, 112, 101,
       100, 0, 6, 108, 105, 115, 116, 101, 110, 100, 0, 6, 115,
       114, 118, 95, 105, 100, 104, 2, 100, 0, 5, 110, 107,
       115, 105, 112, 100, 0, 7, 97, 114, 109, 101, 106, 108,
       55, 106>>}.

plugins() ->
    [nksip, nksip_registrar,
     nksip_tutorial_server_callbacks].

name() -> server.

class() -> nksip.

callback() -> nksip_tutorial_server_callbacks.

cache_sip_trans_timeout() -> 900.

cache_sip_times() ->
    {call_timers, 500, 4000, 5000, 180, 900, 1800}.

cache_sip_supported() -> [<<112, 97, 116, 104>>].

cache_sip_route() -> [].

cache_sip_registrar_time() ->
    {nksip_registrar_time, 60, 86400, 3600, undefined,
     undefined}.

cache_sip_nonce_timeout() -> 30.

cache_sip_no_100() -> false.

cache_sip_max_calls() -> 100000.

cache_sip_local_host6() -> auto.

cache_sip_local_host() ->
    <<108, 111, 99, 97, 108, 104, 111, 115, 116>>.

cache_sip_from() -> undefined.

cache_sip_events() -> [].

cache_sip_event_expires_offset() -> 5.

cache_sip_event_expires() -> 60.

cache_sip_dialog_timeout() -> 1800.

cache_sip_debug() -> false.

%% @doc cache_sip_allow returns SIP Allow method list  
%%
%% Example:
%
% ```b3finlv:cache_sip_allow().
% [<<"INVITE">>,<<"ACK">>,<<"CANCEL">>,<<"BYE">>,
%  <<"OPTIONS">>,<<"INFO">>,<<"UPDATE">>,<<"SUBSCRIBE">>,
%  <<"NOTIFY">>,<<"REFER">>,<<"MESSAGE">>]'''

-spec cache_sip_allow() -> Result when
    Request :: list_of_sip_methods_supported_see_notes.

cache_sip_allow() ->
    [<<82, 69, 71, 73, 83, 84, 69, 82>>,
     <<73, 78, 86, 73, 84, 69>>, <<65, 67, 75>>,
     <<67, 65, 78, 67, 69, 76>>, <<66, 89, 69>>,
     <<79, 80, 84, 73, 79, 78, 83>>, <<73, 78, 70, 79>>,
     <<85, 80, 68, 65, 84, 69>>,
     <<83, 85, 66, 83, 67, 82, 73, 66, 69>>,
     <<78, 79, 84, 73, 70, 89>>, <<82, 69, 70, 69, 82>>,
     <<77, 69, 83, 83, 65, 71, 69>>].

cache_sip_accept() -> undefined.

cache_log_level() -> 6.

