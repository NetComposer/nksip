%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Request sending functions as UAC.
%%
%% In case of using a SIP URI as destination, is is possible to include
%% custom headers: `"<sip:host;method=REGISTER?contact=*&expires=10>"'
%%
-module(nksip_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").


-export([options/3, options/2, register/3, invite/3, invite/2, ack/2, bye/2, cancel/2]).
-export([info/2, update/2, subscribe/2, subscribe/3, notify/2]).
-export([message/3, message/2, refer/3, refer/2, publish/3, publish/2]).
-export([request/3, request/2, refresh/2]).
-export([stun/3]).
-export_type([uac_result/0, uac_ack_result/0, uac_cancel_result/0,
              req_option/0, resp_options/0]).


%% ===================================================================
%% Types
%% ===================================================================


-type uac_result() ::
    {ok, nksip:sip_code(), nksip:resp_options()} | {async, nksip:handle()} | {error, term()}.

-type uac_ack_result() ::
    ok | async | {error, term()}.

-type uac_cancel_result() ::
    ok | {error, term()}.

-type name() :: atom() | list() | binary().

-type value() :: atom() | list() | binary() | integer().


-type req_option() ::

    % Automatic header generation (replace existing headers)
    user_agent |
    supported |
    allow |
    accept |
    allow_event |
    contact |

    % Special parameters
    to_as_from |
    {body, value()} |
    {cseq_num, value()} |
    {min_cseq, value()} |
    {no_100, true} |
    {get_meta, list()} |
    {user, list()} |
    {local_host, auto|binary()} |
    {local_host6, auto|binary()} |
    {callback, fun()} |
    {reg_id, pos_integer()} |
    {record_flow, value()} |
    {route_flow, value()} |

    % Register options
    unregister_all |
    unregister |

    % Subscription
    {subscription_state, term()} |
    {refer_to, binary()} |

    % Publish
    {sip_if_match, binary()} |

    no_dialog |
    stateless_via |

    % Header manipulation
    {call_id, value()} |
    {from, value()} |
    {to, value()} |
    {content_type, value()} |
    {require, value()} |
    {supported, value()} |
    {expires, value()} |
    {contact, value()} |
    {route, value()} |
    {reason, value()} |
    {event, value()} |
    % Generic headers
    {add, name(), value()} |
    {replace, name(), value()} |
    {insert, name(), value()}.


-type resp_options() ::
    #{

    }.




%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an out-of-dialog OPTIONS request.
-spec options(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

options(SrvId, Uri, Opts) ->
    Opts2 = [supported, allow, allow_event | Opts],
    send(SrvId, 'OPTIONS', Uri, Opts2).


%% @doc Sends an in-dialog OPTIONS request.
-spec options(nksip:handle(), [req_option()]) ->
    uac_result().

options(Handle, Opts) ->
    Opts1 = [supported, allow, allow_event | Opts],
    send_dialog('OPTIONS', Handle, Opts1).


%% @doc Sends a REGISTER request.
-spec register(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

register(SrvId, Uri, Opts) ->
    Opts2 = [to_as_from, supported, allow, allow_event | Opts],
    send(SrvId, 'REGISTER', Uri, Opts2).


%% @doc Sends an out-of-dialog INVITE request.
-spec invite(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

invite(SrvId, Uri, Opts) ->
    Opts1 = [contact, supported, allow, allow_event | Opts],
    send(SrvId, 'INVITE', Uri, Opts1).


%% @doc Sends an in-dialog INVITE request.
-spec invite(nksip:handle(), [req_option()]) ->
    uac_result().

invite(Handle, Opts) ->
    Opts1 = [supported, allow, allow_event | Opts],
    send_dialog('INVITE', Handle, Opts1).



%% @doc Sends an ACK after a successful INVITE response.
-spec ack(nksip:handle(), [req_option()]) ->
    uac_ack_result().

ack(Handle, Opts) ->
    send_dialog('ACK', Handle, Opts).


%% @doc Sends an BYE for a current dialog, terminating the session.
-spec bye(nksip:handle(), [req_option()]) ->
    uac_result().

bye(Handle, Opts) ->
    send_dialog('BYE', Handle, Opts).


%% @doc Sends an <i>INFO</i> for a current dialog.
-spec info(nksip:handle(), [req_option()]) ->
    uac_result().

info(Handle, Opts) ->
    send_dialog('INFO', Handle, Opts).


%% @doc Sends an <i>CANCEL</i> for a currently ongoing <i>INVITE</i> request.
-spec cancel(nksip:handle(), [req_option()]) ->
    uac_cancel_result().

cancel(Handle, Opts) ->
    send_cancel(Handle, Opts).


%% @doc Sends a UPDATE on a currently ongoing dialog.
-spec update(nksip:handle(), [req_option()]) ->
    uac_result().

update(Handle, Opts) ->
    Opts1 = [supported, accept, allow | Opts],
    send_dialog('UPDATE', Handle, Opts1).



%% @doc Sends an out-of-dialog SUBSCRIBE request.
-spec subscribe(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

subscribe(SrvId, Uri, Opts) ->
    case lists:keymember(event, 1, Opts) of
        true ->
            Opts1 = [contact, supported, allow, allow_event | Opts],
            send(SrvId, 'SUBSCRIBE', Uri, Opts1);
        false ->
            {error, invalid_event}
    end.


%% @doc Sends an in-dialog or in-subscription SUBSCRIBE request.
-spec subscribe(nksip:handle(), [req_option()]) ->
    uac_result().

subscribe(Handle, Opts) ->
    Opts1 = [supported, allow, allow_event | Opts],
    send_dialog('SUBSCRIBE', Handle, Opts1).



%% @doc Sends an NOTIFY for a current server subscription.
-spec notify(nksip:handle(), [req_option()]) ->
    uac_result().

notify(Handle, Opts) ->
    Opts1 = case lists:keymember(subscription_state, 1, Opts) of
        true ->
            Opts;
        false ->
            [{subscription_state, active}|Opts]
    end,
    send_dialog('NOTIFY', Handle, Opts1).


%% @doc Sends an out-of-dialog MESSAGE request.
-spec message(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

message(SrvId, Uri, Opts) ->
    Opts1 = case lists:keymember(expires, 1, Opts) of
        true ->
            [date|Opts];
        _ ->
            Opts
    end,
    send(SrvId, 'MESSAGE', Uri, Opts1).


%% @doc Sends an in-dialog MESSAGE request.
-spec message(nksip:handle(), [req_option()]) ->
    uac_result().

message(Handle, Opts) ->
    Opts1 = case lists:keymember(expires, 1, Opts) of
        true ->
            [date|Opts];
        _ ->
            Opts
    end,
    send_dialog('MESSAGE', Handle, Opts1).



%% @doc Sends an <i>REFER</i> for a remote party
-spec refer(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

refer(SrvId, Uri, Opts) ->
    case nklib_util:get_binary(refer_to, Opts) of
        <<>> ->
            {error, invalid_refer_to};
        ReferTo ->
            Opts1 = [{insert, "refer-to", ReferTo} | nklib_util:delete(Opts, refer_to)],
            send(SrvId, 'REFER', Uri, Opts1)
    end.


-spec refer(nksip:handle(), [req_option()]) ->
    uac_result() |  {error, invalid_refer_to}.

refer(Handle, Opts) ->
    case nklib_util:get_binary(refer_to, Opts) of
        <<>> ->
            {error, invalid_refer_to};
        ReferTo ->
            Opts1 = [{insert, "refer-to", ReferTo} | nklib_util:delete(Opts, refer_to)],
            send_dialog('REFER', Handle, Opts1)
    end.


%% @doc Sends an out-of-dialog PUBLISH request.
-spec publish(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

publish(SrvId, Uri, Opts) ->
    Opts1 = [supported, allow, allow_event | Opts],
    send(SrvId, 'PUBLISH', Uri, Opts1).


%% @doc Sends an in-dialog PUBLISH request.
-spec publish(nksip:handle(), [req_option()]) ->
    uac_result().

publish(Handle, Opts) ->
    Opts1 = [supported, allow, allow_event | Opts],
    send_dialog('PUBLISH', Handle, Opts1).



%% @doc Sends an out-of-dialog request constructed from a SIP-Uri
-spec request(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    uac_result().

request(SrvId, Dest, Opts) ->
    send(SrvId, undefined, Dest, Opts).


%% @doc Sends an in-dialog request constructed from a SIP-Uri
-spec request(nksip:handle(), [req_option()]) ->
    uac_result().

request(Handle, Opts) ->
    send_dialog(undefined, Handle, Opts).



%% @doc Sends a update on a currently ongoing dialog using INVITE.
%%
%% This function sends a in-dialog INVITE, using the same current
%% parameters of the dialog, only to refresh it. The current local SDP version
%% will be incremented before sending it.
%%
%% Available options are the same as {@link reinvite/2} and also:
%% <ul>
%%  <li>`active': activate the medias on SDP (sending `a=sendrecv')</li>
%%  <li>`inactive': deactivate the medias on SDP (sending `a=inactive')</li>
%%  <li>`hold': activate the medias on SDP (sending `a=sendonly')</li>
%% </ul>
%%
-spec refresh(nksip:handle(), [req_option()]) ->
    uac_result().

refresh(Handle, Opts) ->
    Body1 = case nklib_util:get_value(body, Opts) of
        undefined ->
            case nksip_dialog:get_meta(invite_local_sdp, Handle) of
                {ok, #sdp{} = SDP} ->
                    SDP;
                _ ->
                    <<>>
            end;
        Body ->
            Body
    end,
    Op = case lists:member(active, Opts) of
        true ->
            sendrecv;
        false ->
            case lists:member(inactive, Opts) of
                true ->
                    inactive;
                false ->
                    case lists:member(hold, Opts) of
                        true ->
                            sendonly;
                        false ->
                            none
                    end
            end
    end,
    Body2 = case Body1 of
        #sdp{} when Op /= none ->
            nksip_sdp:update(Body1, Op);
        #sdp{} ->
            nksip_sdp:increment(Body1);
        _ ->
            Body1
    end,
    Opts2 = nklib_util:delete(Opts, [body, active, inactive, hold]),
    invite(Handle, [{body, Body2}|Opts2]).



%% @doc Sends a <i>STUN</i> binding request.
%%
%% Use this function to send a STUN binding request to a remote STUN or
%% STUN-enabled SIP server, in order to get our external ip and port.
%% If the remote server is a standard STUN server, use port 3478
%% (i.e. `sip:stunserver.org:3478'). If it is a STUN server embedded into a SIP UDP
%% server, use a standard SIP uri.
%%
-spec stun(nkserver:id(), nksip:user_uri(), [req_option()]) ->
    {ok, {LocalIp, LocalPort}, {RemoteIp, RemotePort}} | {error, term()}
    when LocalIp :: inet:ip_address(), LocalPort :: inet:port_number(),
         RemoteIp :: inet:ip_address(), RemotePort :: inet:port_number().

stun(SrvId, UriSpec, _Opts) ->
    case nkpacket_resolve:resolve(UriSpec) of
        {ok, [#nkconn{protocol=nksip_protocol, ip=Ip}|_]=Conns} ->
            ListenOpts = #{class=>{nksip, SrvId}, ip=>Ip},
            case nkpacket:get_listening(nksip_protocol, udp, ListenOpts) of
                [NkPort|_] ->
                    {ok, {_, _, LocIp, LocPort}} = nkpacket:get_local(NkPort),
                    case stun_send(Conns, NkPort#nkport.pid) of
                        {ok, RemIp, RemPort} ->
                            {ok, {LocIp, LocPort}, {RemIp, RemPort}};
                        error ->
                            {error, service_unavailable}
                    end;
                [] ->
                    {error, no_listening_transport}
            end;
        _ ->
            {error, invalid_uri}
    end.


%% @private
stun_send([], _Pid) ->
    error;

stun_send([#nkconn{transp=udp, ip=Ip, port=Port}|Rest], Pid) ->
    case nkpacket_transport_udp:send_stun_sync(Pid, Ip, Port, 30000) of
        {ok, StunIp, StunPort} ->
            {ok, StunIp, StunPort};
        error ->
            stun_send(Rest, Pid)
    end;

stun_send([_|Rest], Pid) ->
    stun_send(Rest, Pid).




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec send(nkserver:id(), nksip:method(),    nksip:user_uri(), [req_option()]) ->
    uac_result() | {error, term()}.

send(SrvId, Method, Uri, Opts) ->
    case whereis(SrvId) of
        Pid when is_pid(Pid) ->
            CallId = case lists:keyfind(call_id, 1, Opts) of
                {call_id, CallId0} ->
                    nklib_util:to_binary(CallId0);
                false ->
                    nklib_util:luid()
            end,
            nksip_call:send(SrvId, CallId, Method, Uri, Opts);
        undefined ->
            {error, service_not_started}
    end.



%% @private
-spec send_dialog(nksip:method(), nksip:handle(), [req_option()]) ->
    uac_result() | uac_ack_result() | {error, term()}.

send_dialog(Method, Handle, Opts) ->
    case nksip_dialog:get_handle(Handle) of
        {ok, DlgHandle} ->
            Opts1 = case Handle of
                <<$U, $_, _/binary>>=SubsHandle ->
                    [{subscription, SubsHandle}|Opts];
                _ ->
                    Opts
            end,
            {SrvId, DialogId, CallId} = nksip_dialog_lib:parse_handle(DlgHandle),
            case whereis(SrvId) of
                Pid when is_pid(Pid) ->
                    nksip_call:send_dialog(SrvId, CallId, Method, DialogId, Opts1);
                undefined ->
                    {error, service_not_started}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @private
-spec send_cancel(nksip:handle(), [req_option()]) ->
    uac_ack_result().

send_cancel(Handle, Opts) ->
    case nksip_sipmsg:parse_handle(Handle) of
        {req, SrvId, ReqId, CallId} ->
            nksip_call:send_cancel(SrvId, CallId, ReqId, Opts);
        _ ->
            {error, invalid_request}
    end.


%%%% @private
%%to_bin(Term) when is_binary(Term) -> Term;
%%to_bin(Term) -> nklib_util:to_binary(Term).
