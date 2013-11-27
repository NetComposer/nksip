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

%% @doc Request sending functions as UAC.
%%
%% The functions in this module are used to send requests to remote parties as a UAC.
%%
%% All mandatory SIP methods all supported: <i>OPTIONS</i>, <i>REGISTER</i>, 
%% <i>INVITE</i>, <i>ACK</i>, <i>BYE</i> and <i>CANCEL</i>. 
%% The following optional methods are also supported: <i>INFO</i>.
%% Future versions will address all currently defined SIP methods: 
%% <i>SUBSCRIBE</i>, <i>NOTIFY</i>, <i>MESSAGE</i>, <i>UPDATE</i>, 
%% <i>REFER</i> and <i>PUBLISH</i>.
%%
%% By default, most functions will block util a final response is received
%% or a an error is produced before sending the request, 
%% returning `{ok, Code, Values}' or `{error, Error}'.
%% 
%% `Values' can include some metadata about the response. Use the option `fields' to
%% select which metadatas you want to receive. For request-generating methods
%% (only <i>INVITE</i> currently) the first value is allways the dialog's id
%% of the response: `{dialog_id, DialogId}'.
%% You can use the functions in {@link nksip_dialog} to get additional information.
%%
%% You can define a callback function using option `callback', and it will be called
%% for every received provisional response as `{ok, Code, Values}'.
%%
%% You can also call most of these functions <i>asynchronously</i> using
%% the `async' option, and the call will return immediately (before trying to send
%% the request) instead of blocking.
%% You should use the callback function to receive provisional responses, 
%% final response and errors.
%%
%% Methods <i>OPTIONS</i>, <i>REGISTER</i> and <i>INVITE</i> can be
%% sent outside or inside a dialog. <i>ACK</i>, <i>BYE</i> and <i>INFO</i> 
%% can only be sent inside a dialog, and <i>CANCEL</i> can only be sent outside a dialog.
%%
%% Common options for most functions (outside or inside dialog) are:<br/>
%%  
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`fields'</td>
%%          <td><code>[{@link nksip_response:field()}]</code></td>
%%          <td>`[]'</td>
%%          <td>Use it to select which specific fields from the response are
%%          returned. See {@link nksip_response:field()} for the complete list of
%%          supported fields. For <i>INVITE</i> requests, the first field is 
%%          always the dialog's id of the response.</td>
%%      </tr>
%%      <tr>
%%          <td>`async'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, the call will return inmediatly as `{async, ReqId}', or
%%          `{error, Error}' if an error is produced before sending the request.
%%          `ReqId' can be used with the functions in {@link nksip_request} to get
%%          information about the request (the request may not be sent yet, so
%%          the information about transport may not be present).</td>
%%      </tr>
%%      <tr>
%%          <td>`callback'</td>
%%          <td>`fun/1'</td>
%%          <td></td>
%%          <td>If defined, it will be called for every received provisional response
%%          as `{ok, Code, Values}'. For `async' requests, it is called also 
%%          for the final response and, if an error is produced before sending 
%%          the request, as `{error, Error}'.</td>
%%      </tr>
%%      <tr>
%%          <td>`contact'</td>
%%          <td>{@link nksip:user_uri()}</td>
%%          <td></td>
%%          <td>If defined, one or several <i>Contact</i> headers will be inserted in
%%          the request.</td>
%%      </tr>
%%      <tr>
%%          <td>`make_contact'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, a <i>Contact</i> header will be automatically generated.</td>
%%      </tr>
%%      <tr>
%%          <td>`content_type'</td>
%%          <td>`binary()'</td>
%%          <td></td>
%%          <td>If defined, a <i>Content-Type</i> headers will be inserted</td>
%%      </tr>
%%      <tr>
%%          <td>`headers'</td>
%%          <td><code>[{@link nksip:header()}]</code></td>
%%          <td>[]</td>
%%          <td>List of headers to add to the request. The following headers should not
%%          we used here: <i>From</i>, <i>To</i>, <i>Via</i>, <i>Call-ID</i>, 
%%          <i>CSeq</i>, <i>Forwards</i>, <i>User-Agent</i>, <i>Content-Type</i>, 
%%          <i>Route</i>, <i>Contact</i>.</td>
%%      </tr>
%%      <tr>
%%          <td>`body'</td>
%%          <td><code>{@link nksip:body()}</code></td>
%%          <td>`<<>>'</td>
%%          <td>Body to use. If it is a `nksip_sdp:sdp()', a <i>Content-Type</i> 
%%          header will be generated.</td>
%%      </tr>
%%      <tr>
%%          <td>`local_host'</td>
%%          <td>`auto|string()|binary()'</td>
%%          <td>SipApp's config</td>
%%          <td>See {@link start/4}</td>
%%      </tr>
%% </table>
%%
%% Options available for most methods only when sent outside a dialog are:
%%
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`from'</td>
%%          <td>{@link nksip:user_uri()}</td>
%%          <td>SipApp's config</td>
%%          <td><i>From</i> to use in the request.</td>
%%      </tr>
%%      <tr>
%%          <td>`to'</td>
%%          <td>{@link nksip:user_uri()}`|as_from'</td>
%%          <td>`Uri'</td>
%%          <td><i>To</i> to use in the request.</td>
%%      </tr>
%%      <tr>
%%          <td>`user_agent'</td>
%%          <td>`string()|binary()'</td>
%%          <td>"NkSIP (version)"</td>
%%          <td><i>User-Agent</i> header to use in the request.</td>
%%      </tr>
%%      <tr>
%%          <td>`call_id'</td>
%%          <td>{@link nksip:call_id()}</td>
%%          <td>(automatic)</td>
%%          <td>If defined, will be used instead of a newly generated one
%%          (use {@link nksip_lib:luid/0})</td>
%%      </tr>
%%      <tr>
%%          <td>`cseq'</td>
%%          <td>{@link nksip:cseq()}</td>
%%          <td>(automatic)</td>
%%          <td>If defined, will be used instead of a newly generated one
%%          (use {@link nksip_lib:cseq/0})</td>
%%      </tr>
%%      <tr>
%%          <td>`route'</td>
%%          <td>{@link nksip:user_uri()}</td>
%%          <td>SipApp's config</td>
%%          <td>If defined, one or several <i>Route</i> headers will be inserted in
%%          the request.</td>
%%      </tr>
%% </table>
%%
%%
%% Look at the specification for each function to find supported options

-module(nksip_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([options/3, register/3, invite/3, ack/3, bye/3, info/3, cancel/2]).
-export([refresh/3, stun/3]).
-export_type([result/0, ack_result/0, error/0, cancel_error/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type dialog_spec() :: 
    nksip_dialog:id() | nksip_request:id() | nksip_response:id().

-type opt() ::  
    dialog_opt() |
    {from, nksip:user_uri()} | {to, nksip:user_uri()} | {user_agent, binary()} |
    {call_id, binary()} | {cseq, nksip:cseq()} | {route, nksip:user_uri()}.

-type dialog_opt() ::  
    {fields, [nksip_response:field()]} | async | {callback, function()} | 
    get_response | get_request | 
    {contact, nksip:user_uri()} | make_contact | {content_type, binary()} | 
    {headers, [nksip:header()]} | {body, nksip:body()} | {local_host, auto|binary()}.

-type register_opt() ::
    {expires, non_neg_integer()} | unregister | unregister_all.

-type invite_opt() ::
    {expires, pos_integer()}.

-type result() ::  
    {async, nksip_request:id()} | {ok, nksip:response_code(), nksip_lib:proplist()} | 
    {resp, nksip:response()}.
    
-type ack_result() ::
    ok | async.

-type error() :: 
    invalid_uri | invalid_from | invalid_to | invalid_route |
    invalid_contact | invalid_cseq | invalid_content_type |
    unknown_dialog | request_pending | network_error | 
    nksip_call_router:sync_error().

-type cancel_error() :: 
    unknown_request | nksip_call_router:sync_error().



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends an OPTIONS request.
%%
%% OPTIONS requests are usually sent to get the current set of SIP features 
%% and codecs the remote party supports, and to detect if it is <i>up</i>, 
%% it has failed or it is not responding requests for any reason. 
%% It can also be used to measure the remote party response time. 
%%
%% When `Dest' if an <i>SIP Uri</i> the request will be sent outside any dialog.
%% If it is a dialog specification, it will be sent inside that dialog.
%% Recognized options are described in {@link opt()} when sent outside any dialog,
%% and {@link dialog_opt()} when sent inside a dialog.
%%
%% NkSIP has an automatic remote <i>pinging</i> feature that can be activated 
%% on any SipApp (see {@link nksip_sipapp_auto:start_ping/5}).
%%
-spec options(nksip:app_id(), nksip:user_uri()|dialog_spec(), [opt()|dialog_opt()]) ->
    result() | {error, error()}.

options(AppId, Dest, Opts) ->
    send_any(AppId, 'OPTIONS', Dest, Opts).


%% @doc Sends a REGISTER request.
%%
%% This function is used to send a new REGISTER request to any registrar server,
%% to register a new `Contact', delete a current registration or get the list of 
%% current registered contacts from the registrar.
%%
%% When `Dest' if an <i>SIP Uri</i> the request will be sent outside any dialog.
%% If it is a dialog specification, it will be sent inside that dialog.
%% Recognized options are described in {@link opt()} when sent outside any dialog,
%% and {@link dialog_opt()} when sent inside a dialog.
%%
%% Additional recognized options are defined in {@link register_opt()}:
%%  
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`expires'</td>
%%          <td>`integer()'</td>
%%          <td></td>
%%          <td>If defined it will generate a <i>Expires</i> header</td>
%%      </tr>
%%      <tr>
%%          <td>`unregister'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, unregisters the contact (sets <i>Expires</i> to 0)</td>
%%      </tr>
%%      <tr>
%%          <td>`unregister_all'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, unregisters all registered contacts for this user (sets
%%              <i>Contact</i> to <i>*</i> and <i>Expires</i> to 0)</td>
%%      </tr>
%% </table>
%% 
%% You will usually want to include a `make_contact' option to generate a valid
%% <i>Contact</i> header.
%%
%% Keep in mind that, once you send a REGISTER requests, following refreshers
%% should have the same `Call-ID' and an incremented `CSeq' headers. 
%% The default value for `contact' parameter would be `auto' in this case.
%%
%% NkSIP offers also an automatic SipApp registration facility 
%% (see {@link nksip:start/4}).
-spec register(nksip:app_id(), nksip:user_uri()|dialog_spec(), 
               [opt()|dialog_opt()|register_opt()]) ->
    result() | {error, error()}.

register(AppId, Dest, Opts) ->
    case lists:member(unregister_all, Opts) of
        true ->
            Contact = {contact, <<"*">>},
            Expires = 0;
        false ->
            Contact = [], 
            case lists:member(unregister, Opts) of
                true -> Expires = 0;
                false -> Expires = same
            end
    end,
    Opts1 = case Expires of
        same -> Opts;
        _ -> [{expires, Expires}|Opts]
    end,
    Opts2 = lists:flatten(Opts1++[Contact, {to, as_from}]),
    send_any(AppId, 'REGISTER', Dest, Opts2).


%% @doc Sends an INVITE request.
%%
%% This functions sends a new session invitation to another endpoint or proxy. 
%% When the first provisional response from the remote party is received
%% (as 180 <i>Ringing</i>) a new dialog will be started, and the corresponding callback
%% {@link nksip_sipapp:dialog_update/3} in the callback module will be called. 
%% If this response has also a valid SDP body, a new session will be associated 
%% with the dialog and the corresponding callback {@link nksip_sipapp:session_update/3}
%% will also be called.
%%
%% When the first 2xx response is received, the dialog is confirmed. 
%% <b>You must then call {@link ack/3} immediately</b>, offering an 
%% SDP body if you haven't done it in the INVITE request.
%%
%% The dialog is destroyed when a BYE is sent or received, or a 408 <i>Timeout</i> 
%% or 481 <i>Call Does Not Exist</i> response is received. 
%% If a secondary 2xx response is received (usually because a proxy server 
%% has forked the request) NkSIP will automatically acknowledge it and send BYE. 
%% If a 3xx-6xx response is received instead of a 2xx response, the <i>early dialog</i> 
%% is destroyed. You should not call {@link ack/2} in this case, 
%% as NkSIP will do it for you automatically.
%%
%% After a dialog has being established, you can send new INVITE requests
%% (called <i>reINVITEs</i>) <i>inside</i> this dialog.
%%
%% When `Dest' if an <i>SIP Uri</i> the request will be sent outside any dialog.
%% If it is a dialog specification, it will be sent inside that dialog.
%% Recognized options are described in {@link opt()} when sent outside any dialog,
%% and {@link dialog_opt()} when sent inside a dialog.
%%
%% Additional recognized options are defined in {@link invite_opts()}:
%%
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`expires'</td>
%%          <td>`integer()'</td>
%%          <td></td>
%%          <td>If included it will generate a `Expires' header</td>
%%      </tr>
%%      <tr>
%%          <td>`require_100rel</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, a <i>Require: 100rel</i> will be generated, and the other
%%          party must then send reliable provisional responses.</td>
%%      </tr>
%%      <tr>
%%          <td>`prack'</td>
%%          <td><code>`fun/2'</code></td>
%%          <td></td>
%%          <td>If included, this function will be called when the original INVITE
%%          when a reliable provisional response has been received, and before 
%%          sending the corresponding PRACK.
%%          It will be called as `{RemoteSDP, Response}' where 
%%          RemoteSDP :: <<>> | {@link nksip_sdp:sdp()} and Response :: {@link nksip:response()}.
%%          If RemoteSDP is a SDP, it is an offer and you must supply an answer as 
%%          function return. If it is <<>>, you can return <<>> or send a new offer.
%%          If this option is not included, PRACKs will be sent with no body.
%%      </tr>
%%      <tr>
%%          <td>`require_100rel</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, a <i>Require: 100rel</i> will be generated, and the other
%%          party must then send reliable provisional responses.</td>
%%      </tr>
%% </table>
%%
%% A `make_contact' option will be automatically added if no contact is defined.
%%
%% If `Expires' header is used, NkSIP will CANCEL the request if no final response 
%% has been received in this period in seconds. The default value for `contact' parameter 
%% would be `auto' in this case.
%%
%% If you want to be able to <i>CANCEL</i> the request, you should use the `async'
%% option.
%%
%% If a 491 response is received, it usually means that the remote party is 
%% starting another reINVITE transaction right now. You should call 
%% {@link nksip_response:wait_491()} and try again.
%%
-spec invite(nksip:app_id(), nksip:user_uri()|dialog_spec(), 
             [opt()|dialog_opt()|invite_opt()]) ->
    result() | {error, error()}.

invite(AppId, Dest, Opts) ->
    Opts1 = [make_supported, make_accept, make_allow | Opts],
    send_any(AppId, 'INVITE', Dest, Opts1).



%% @doc Sends an <i>ACK</i> after a successful <i>INVITE</i> response.
%%
%% After sending an INVITE and receiving a successfully (2xx) response, 
%% you must call this function immediately to send the mandatory ACK request. 
%% NkSIP won't send it for you automatically in case of a successful response, 
%% because you may want to include a SDP body if you didn't do it in the INVITE request.
%%
%% To specify the dialog you should use the dialog's id from 
%% the return of the {@link invite/3} call or using
%% {@link nksip_sipapp:dialog_update/3} callback function. 
%% Valid options are `fields', `callback', `async', `content_type', `headers' and 
%% `body'.
%%
%% For sync requests, it will return `ok' if the request could be sent or
%% `{error, Error}' if an error is detected. For async requests, it will return 
%% `async'. If a callback is defined, it will be called as `ok' or `{error, Error}'.    
%%
-spec ack(nksip:app_id(), dialog_spec(), [dialog_opt()]) ->
    ack_result() | {error, error()}.

ack(AppId, DialogSpec, Opts) ->
    send_dialog(AppId, 'ACK', DialogSpec, Opts).


%% @doc Sends an <i>BYE</i> for a current dialog, terminating the session.
%%
%% You need to know the dialog's id of the dialog you want to hang up.
%% You can get it from the return of the initial {@link invite/3}, or using 
%% {@link nksip_sipapp:dialog_update/3} callback function.
%%
%% Valid options are defined in {@link dialog_opt()}.
%%
-spec bye(nksip:app_id(), dialog_spec(), [dialog_opt()]) -> 
    result() | {error, error()}.

bye(AppId, DialogSpec, Opts) ->
    send_dialog(AppId, 'BYE', DialogSpec, Opts).


%% @doc Sends an <i>INFO</i> for a current dialog.
%%
%% Sends an INFO request. Doesn't change the state of the current session.
%% You need to know the dialog's id. You can get it from the return of the initial 
%% {@link invite/3}, or using {@link nksip_sipapp:dialog_update/3} callback function.
%%
%% Valid options are defined in {@link dialog_opt()}.
%%
-spec info(nksip:app_id(), dialog_spec(), [dialog_opt()]) -> 
    result() | {error, error()}.

info(AppId, DialogSpec, Opts) ->
    send_dialog(AppId, 'INFO', DialogSpec, Opts).


%% @doc Sends an <i>CANCEL</i> for a currently ongoing <i>INVITE</i> request.
%%
%% You can use this function to send a CANCEL requests to abort a currently 
%% <i>calling</i> INVITE request, using the `ReqId' obtained when calling 
%% {@link invite/3} <i>asynchronously</i>. 
%% The CANCEL request will eventually be received at the remote end, and, 
%% if it hasn't yet answered the matching INVITE request, 
%% it will finish it with a 487 code. 
%%
%% This call is always asychronous. It returns a soon as the request is
%% received and the cancelling INVITE is found.
%%
-spec cancel(nksip:app_id(), nksip_request:id()) ->
    ok | {error, cancel_error()}.

cancel(AppId, ReqId) ->
    nksip_call:cancel(AppId, ReqId).


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
-spec refresh(nksip:app_id(), dialog_spec(), [dialog_opt()]) ->
    result() | {error, error()}.

refresh(AppId, DialogSpec, Opts) ->
    Body1 = case nksip_lib:get_value(body, Opts) of
        undefined ->
            case nksip_dialog:field(AppId, DialogSpec, local_sdp) of
                #sdp{} = SDP -> SDP;
                _ -> <<>>
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
                        true -> sendonly;
                        false -> none
                    end
            end
    end,
    Body2 = case Body1 of
        #sdp{} when Op /= none -> nksip_sdp:update(Body1, Op);
        #sdp{} -> nksip_sdp:increment(Body1);
        _ -> Body1
    end,
    Opts2 = nksip_lib:delete(Opts, [body, active, inactive, hold]),
    invite(AppId, DialogSpec, [{body, Body2}|Opts2]).


%% @doc Sends a <i>STUN</i> binding request.
%%
%% Use this function to send a STUN binding request to a remote STUN or 
%% STUN-enabled SIP server, in order to get our remote ip and port.
%% If the remote server is a standard STUN server, use port 3478 
%% (i.e. `sip:stunserver.org:3478'). If it is a STUN server embedded into a SIP UDP
%% server, use a standard SIP uri.
%%
-spec stun(nksip:app_id(), nksip:user_uri(), nksip_lib:proplist()) ->
    {ok, {LocalIp, LocalPort}, {RemoteIp, RemotePort}} | {error, Error}
    when LocalIp :: inet:ip_address(), LocalPort :: inet:port_number(),
         RemoteIp :: inet:ip_address(), RemotePort :: inet:port_number(),
         Error :: unknown_core | invalid_uri | no_host | network_error.

stun(AppId, UriSpec, _Opts) ->
    case nksip_transport:get_listening(AppId, udp, ipv4) of
        [] -> 
            {error, unknown_core};
        [{#transport{listen_ip=LIp, listen_port=LPort}, Pid}|_] ->
            case nksip_parse:uris(UriSpec) of
                [Uri] ->
                    Transp = nksip_dns:resolve(Uri),
                    case nksip_lib:extract(Transp, udp) of
                        [{udp, Ip, Port}|_] -> 
                            case nksip_transport_udp:send_stun(Pid, Ip, Port) of
                                {ok, SIp, SPort} ->
                                    {ok, {LIp, LPort}, {SIp, SPort}};
                                error ->
                                    {error, network_error}
                            end;
                        _ ->
                            {error, no_host}
                    end;
                _ ->
                    {error, invalid_uri}
            end
    end.


%% ===================================================================
%% Internal
%% ===================================================================

-spec send_any(nksip:app_id(), nksip:method(), nksip:user_uri()|dialog_spec(), 
               nksip_lib:proplist()) ->
    result() | ack_result() | {error, error()}.

send_any(AppId, Method, UriOrDialog, Opts) ->
    case UriOrDialog of
        <<Class, $_, _/binary>> when Class==$R; Class==$S; Class==$D ->
            send_dialog(AppId, Method, UriOrDialog, Opts);
        UserUri ->
            nksip_call:send(AppId, Method, UserUri, Opts)
    end.


%% @private
-spec send_dialog(nksip:app_id(), nksip:method(), dialog_spec(), 
                  nksip_lib:proplist()) ->
    result() | ack_result() | {error, error()}.

send_dialog(AppId, Method, <<Class, $_, _/binary>>=Id, Opts)
            when Class==$R; Class==$S; Class==$D ->
    case nksip_dialog:id(AppId, Id) of
        <<>> -> {error, unknown_dialog};
        DialogId -> nksip_call:send_dialog(AppId, DialogId, Method, Opts)
    end.

