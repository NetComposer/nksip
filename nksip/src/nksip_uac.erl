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

%% @doc Request sending functions.
%%
%% The functions in this module are used to send requests to remote parties as a UAC.
%%
%% All mandatory SIP methods all supported: <i>OPTIONS</i>, <i>REGISTER</i>, 
%% <i>INVITE</i>, <i>ACK</i>, <i>BYE</i> and <i>CANCEL</i>. 
%% Future versions will address all currently defined SIP methods: 
%% <i>SUBSCRIBE</i>, <i>NOTIFY</i>, <i>MESSAGE</i>, <i>UPDATE</i>, 
%% <i>REFER</i> and <i>PUBLISH</i>.
%%
%% Your SipApp can send any of these requests calling the corresponding functions in 
%% this module. If there is no error, the request will be sent, and when a response 
%% is received most functions will return `{ok, Code}'. 
%% In case you need to access the full response (to get headers, body, etc.), 
%% you can use the option `full_response' and the response would then be 
%% `{reply, Response}'. 
%% You can now use the functions in {@link nksip_response} to extract 
%% relevant information from the response like body or headers.
%% If there is a local error processing the request most functions will return 
%% `{error, Error}'. 
%%
%% These functions are called <i>synchronously</i> by default. 
%% They will block until a final (2xx-6xx) response (or a timeout) is received. 
%% You can also call them <i>asynchronously</i>, and the call will return immediately. 
%% NkSIP will then send the received response to an user defined callback function, 
%% (`respfun' option) which will be called as many times as provisional 
%% (1xx) responses are received, and once again for the final response. 
%% In case of <i>INVITE</i>, a `CancelId' value is returned to be able to 
%% <i>CANCEL</i> the request.

-module(nksip_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([options/3, options/2, register/3, invite/3, ack/2, reinvite/2, 
            bye/2, cancel/2, refresh/2, stun/3]).
-export([send_request/4, send_request/2]).


-type nodialog_errors() ::  invalid_uri | invalid_from | invalid_to |
                            invalid_route | invalid_contact | invalid_cseq |
                            sipapp_not_found | too_many_calls.

-type dialog_errors() :: invalid_dialog | unknown_dialog | 
                         sipapp_not_found | too_many_calls.


-define(UAC_DEFAULT_TIMEOUT, 60000).



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
%% NkSIP will start a new client transaction to process the request and its responses.
%% The recognized options are:<br/>
%%  
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`async'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, the call will return inmediatly as `async'.
%%          Use `respfun' to receive responses. If not present, 
%%          the call will block until a final response is received or an error
%%          is detected (like a timeout).</td>
%%      </tr>
%%      <tr>
%%          <td>`respfun'</td>
%%          <td>`fun/1'</td>
%%          <td></td>
%%          <td>If defined, it will be called for every provisional response (101-199) as 
%%          `{ok, Code}' (or `{reply, Response}' if `full_response' option is used). 
%%          For `async' requests, it will be called also for errors and for the 
%%          final response (as `{ok, Code}', `{reply, Response}' or `{error, Error}').
%%          See also `full_request'.</td>
%%      </tr>
%%      <tr>
%%          <td>`full_response'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present NkSIP will return `{reply, Response}' instead of 
%%          `{ok, Code}' in sync requests. `respfun' function will be called also
%%           this way for async requests.</td>
%%      </tr>
%%      <tr>
%%          <td>`full_request'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present NkSIP will call the function defined is `respfun' also for
%%          each generated request (once sent), as `{request, Request}'.
%%          Several requests can be generated in case of automatic authentication 
%%          response.</td>
%%      </tr>
%%      <tr>
%%          <td>`timeout'</td>
%%          <td>`integer()'</td>
%%          <td>30000</td>
%%          <td>Time to wait for the final response in case of sync request.</td>
%%      </tr>
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
%%          we used here: <i>From</i>, <i>To</i>, <i>Via</i>, <i>Call-Id</i>, 
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
%% NkSIP has an automatic remote <i>pinging</i> feature that can be activated 
%% on any SipApp (see {@link nksip_sipapp_auto:start_ping/5}).
%%
-spec options(nksip:app_id(), nksip:user_uri(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, nodialog_errors()}.

options(AppId, Uri, Opts) ->
    send_request(AppId, 'OPTIONS', Uri, Opts).


%% @private Sends a in-dialog OPTIONS request
-spec options(nksip_dialog:spec(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, dialog_errors()}.

options(DialogSpec, Opts) ->
    send_dialog(DialogSpec, 'OPTIONS', Opts).


%% @doc Sends a REGISTER request.
%%
%% This function is used to send a new REGISTER request to any registrar server,
%% to register a new `Contact', delete a current registration or get the list of 
%% current registered contacts from the registrar.
%%
%% The recognized options and responses are the same as {@link options/3}, and also:
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
%% should have the same `Call-Id' and an incremented `CSeq' headers. 
%% The default value for `contact' parameter would be `auto' in this case.
%%
%% NkSIP offers also an automatic SipApp registration facility 
%% (see {@link nksip:start/4}).
-spec register(nksip:app_id(), nksip:user_uri(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, nodialog_errors()}.

register(AppId, Uri, Opts) ->
    case lists:member(unregister_all, Opts) of
        true ->
            Contact = {contact, <<"*">>},
            Expires = 0;
        false ->
            Contact = [], 
            case lists:member(unregister, Opts) of
                true ->
                    Expires = 0;
                false ->
                    Expires = case nksip_lib:get_integer(expires, Opts, -1) of
                        Exp0 when Exp0 >= 0 -> Exp0;
                        _ -> undefined
                    end
            end
    end,
    Opts1 = case Expires of
        undefined -> 
            Opts;
        _ -> 
            Headers1 = nksip_lib:get_value(headers, Opts, []),
            Headers2 = nksip_headers:update(Headers1, [{single, <<"Expires">>, Expires}]),
            lists:keystore(headers, 1, Opts, {headers, Headers2})
    end,
    Opts2 = lists:flatten(Opts1++[Contact, {to, as_from}]),
    send_request(AppId, 'REGISTER', Uri, Opts2).


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
%% <b>You must then call {@link ack/2} immediately</b>, offering an 
%% SDP body if you haven't done it in the INVITE request.
%%
%% The dialog is destroyed when a BYE is sent or received, or a 408 <i>Timeout</i> 
%% or 481 <i>Call Does Not Exist</i> response is received. If a secondary 2xx response is
%% received (usually because a proxy server has forked the request) NkSIP will 
%% automatically acknowledge it and send BYE. 
%% If a 3xx-6xx response is received instead of a 2xx response, the <i>early dialog</i> 
%% is destroyed. You should not call {@link ack/2} in this case, 
%% as NkSIP will do it for you automatically.
%%
%% After a dialog has being established, you can send new INVITE requests
%% (called <i>reINVITEs</i>) <i>inside</i> this dialog, 
%% calling {@link reinvite/2}.
%%
%% The recognized options and responses are the same as {@link options/3}, but
%% if not `full_response' is used, the response will also include the `DialogId'; the 
%% `respfun' function will also be called as `{ok, Code, DialogId}' or `{reply, Resp}'.
%% If `async' is used, the response would be `{async, CancelId}'. You can use this
%% `CancelId' to <i>CANCEL</i> the request using {@link cancel/2}.
%%
%% Aditional options are:
%%
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`expires'</td>
%%          <td>`integer()'</td>
%%          <td></td>
%%          <td>If included it will generate a `Expires' header</td>
%%      </tr>
%% </table>
%%
%% A `make_contact' option will be automatically added if no contact is defined.
%%
%% If `Expires' header is used, NkSIP will CANCEL the request if no final response 
%% has been received in this period in seconds. The default value for `contact' parameter 
%% would be `auto' in this case.
%%
-spec invite(nksip:app_id(), nksip:user_uri(), nksip_lib:proplist()) ->
    {ok, nksip:response_code(), nksip:dialog_id()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, nodialog_errors()}.

invite(AppId, Uri, Opts) ->
    Expires = nksip_lib:get_integer(expires, Opts, 0), 
    Headers1 = nksip_lib:get_value(headers, Opts, []),
    Opts1 = if
        is_integer(Expires), Expires > 0 ->
            Headers2 = nksip_headers:update(Headers1, [{single, <<"Expires">>, Expires}]),
            lists:keystore(headers, 1, Opts, {headers, Headers2});
        true ->
            Opts
    end,
    Opts2 = [make_supported, make_accept, make_allow  | Opts1],
    send_request(AppId, 'INVITE', Uri, Opts2).


%% @doc Sends an <i>ACK</i> after a successful <i>INVITE</i> response.
%%
%% After sending an INVITE or reINVITE and receiving a successfully (2xx) response, 
%% you must call this function immediately to send the mandatory ACK request. 
%% NkSIP won't send it for you automatically in case of a successful response, 
%% because you may want to include a SDP body if you didn't do it in the INVITE request.
%%
%% To speciy the dialog you should use the `DialogId' or `Response' from 
%% the return of the {@link invite/3} call or use {@link nksip_sipapp:dialog_update/3}
%% callback function. Valid options are defined in {@link options/3}, but, 
%% as an in-dialog request, options `from', `to', `call_id', `cseq' and `route' 
%% should not used.
%%
%% For sync requests, it will return `ok' if the request could be sent, 
%% (or `{ok, AckRequest}' if `full_request' option is present) or
%% `{error, Error}' if an error is detected. For async requests, it will return `async', 
%% and if `respfun' is provided, it will be called as `ok', `{ok, AckRequest}' or 
%% `{error, Error}'.
%%
-spec ack(nksip_dialog:spec(), nksip_lib:proplist()) ->
    ok | {ok, nksip:request()} | async | {error, dialog_errors()}.

ack(DialogSpec, Opts) ->
    send_dialog(DialogSpec, 'ACK', Opts).


%% @doc Sends a in-dialog <i>INVITE</i> (commonly called reINVITE) for a 
%% currently ongoing dialog.
%%
%% The options and responses are the same as for {@link invite/3}, but in case of
%% `async' requests no `CancelId' is returned. As an in-dialog request,
%% options `from', `to', `call_id', `cseq' and `route' should not used.
%%
%% A `make_contact' option will be automatically added if no contact is defined.
%%
%% You can send a new INVITE during an existing dialog, to refresh it or to 
%% change its <i>Contact</i> address or SDP media parameters. You will need 
%% the `DialogId' of the dialog. You can get it from the `dialog_start/2' callback
%% or the return value of the first {@link invite/3}.
%%
%% If you receive a successful (2xx) response you <b>must call {@link ack/2} 
%% inmediatly</b>, offering an SDP body if you haven't done so in the reINVITE request.
%% If you receive any other response you must not call {@link ack/2}. 
%%
%% If a 491 response is received, it usually means that the remote party is 
%% starting another reINVITE transaction right now. You should call 
%% {@link nksip_response:wait_491()} and try again.
%%
-spec reinvite(nksip_dialog:spec(), nksip_lib:proplist()) ->
    {ok, nksip:response_code(), nksip:dialog_id()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, dialog_errors()}.

reinvite(DialogSpec, Opts) ->
    Opts1 = [make_accept, make_supported | Opts],
    send_dialog(DialogSpec, 'INVITE', Opts1).


%% @doc Sends an <i>BYE</i> for a current dialog.
%%
%% Sends a BYE request and terminates the dialog and the session.

%% You need to know the `DialogId' of the dialog. You can get from the return of
%% the initial {@link invite/3}, or using {@link nksip_sipapp:dialog_update/3}
%% callback function.
%%
%% Valid options are defined in {@link options/3}, but, as an in-dialog request,
%% options `from', `to', `call_id', `cseq' and `route' should not used.
%%
-spec bye(nksip_dialog:spec(), nksip_lib:proplist()) -> 
    {ok, nksip:response_code()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, dialog_errors()}.

bye(DialogSpec, Opts) ->
    send_dialog(DialogSpec, 'BYE', Opts).


%% @doc Sends an <i>CANCEL</i> for a currently ongoing <i>INVITE</i> request.
%%
%% You can use this function to send a CANCEL requests to abort a currently 
%% <i>calling</i> INVITE request, using the `CancelId' obtained when calling 
%% {@link invite/3} <i>asynchronously</i>. 
%% The CANCEL request will eventually be received at the remote end, and, 
%% if it hasn't yet answered the matching INVITE request, 
%% it will finish it with a 487 code. 
%%
%% The options and responses are the same as for {@link options/3}, but you should not
%% use any options modifying the request as `from', `to', `call_id', `cseq', `route', etc.
%%
-spec cancel(nksip:request_id(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {reply, nksip:response()} | 
    async | {error, Error}
    when Error :: unknown_request | invalid_request | sipapp_not_found | too_many_calls.

cancel(ReqId, Opts) ->
    nksip_call_router:cancel(ReqId, Opts).

%% @doc Sends a update on a currently ongoing dialog using reINVITE.
%%
%% This function sends a in-dialog reINVITE, using the same current
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
-spec refresh(nksip_dialog:spec(), nksip_lib:proplist()) ->
    {ok, nksip:response_code(), nksip:dialog_id()} | {reply, nksip:response()} | 
    {async, nksip:request_id()} | {error, dialog_errors()}.

refresh(DialogSpec, Opts) ->
    Body1 = case nksip_lib:get_value(body, Opts) of
        undefined ->
            case nksip_dialog:field(DialogSpec, local_sdp) of
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
        #sdp{} when Op =/= none -> nksip_sdp:update(Body1, Op);
        #sdp{} -> nksip_sdp:increment(Body1);
        _ -> Body1
    end,
    Opts2 = nksip_lib:delete(Opts, [body, active, inactive, hold]),
    reinvite(DialogSpec, [{body, Body2}|Opts2]).


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
    when LocalIp :: inet:ip4_address(), LocalPort :: inet:port_number(),
         RemoteIp :: inet:ip4_address(), RemotePort :: inet:port_number(),
         Error :: unknown_core | invalid_uri | no_host | network_error.

stun(AppId, UriSpec, _Opts) ->
    case nksip_transport:get_listening(AppId, udp) of
        [] -> 
            {error, unknown_core};
        [{#transport{listen_ip=LIp, listen_port=LPort}, Pid}|_] ->
            case nksip_parse:uris(UriSpec) of
                [] -> 
                    {error, invalid_uri};
                [Uri|_] ->
                    Transp = nksip_transport:resolve(Uri),
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
                    end
            end
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send_request(nksip:app_id(), nksip:method(), nksip:user_uri(), 
                    nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {ok, nksip:response_code(), nksip_dialog:id()} |
    ok  | {ok, nksip:request()} | {reply, nksip:response()} |
    {async, nksip:request_id()} | {error, nodialog_errors()}.
    
send_request(AppId, Method, Uri, Opts) ->
    case nksip_uac_lib:make(AppId, Method, Uri, Opts) of
        {ok, Request} -> send_request(Request, Opts);
        {error, Error} -> {error, Error}
    end.


%% @private
-spec send_request(nksip:request(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {ok, nksip:response_code(), nksip_dialog:id()} |
    ok  | {ok, nksip:request()} | {reply, nksip:response()} |
    {async, nksip:request_id()} | {error, nodialog_errors()}.

send_request(#sipmsg{method=Method}=Req, Opts) ->
    case lists:member(async, Opts) of
        true ->
            case nksip_call_router:send(Req) of
                {ok, ReqId} -> {async, ReqId};
                {error, Error} -> {error, Error}
            end;
        false ->
            Ref = make_ref(),
            Pid = self(),
            UserFun = nksip_lib:get_value(respfun, Opts),
            Fun = fun(Reply) ->
                case Reply of
                    {ok, Code} -> ok;
                    {ok, Code, _DialogId} -> ok;
                    {reply, #sipmsg{response=Code}} -> ok;
                    {request, _} -> Code = 0;
                    _ -> Code = 999
                end,
                case Code < 200 of
                    true when is_function(UserFun, 1) -> UserFun(Reply);
                    true -> ok;
                    false -> Pid ! {Ref, Reply}
                end
            end,
            ReqOpts1 = [{respfun, Fun}|Req#sipmsg.opts],
            case nksip_call_router:send(Req#sipmsg{opts=ReqOpts1}) of
                {ok, _ReqId} ->
                    case nksip_lib:get_integer(timeout, Opts) of
                        Timeout when is_integer(Timeout), Timeout > 0 -> ok;
                        _ -> Timeout = ?UAC_DEFAULT_TIMEOUT
                    end,
                    receive
                        {Ref, Reply} -> Reply
                    after Timeout ->
                        case Method of
                            'ACK' ->
                                {error, network_error};
                            _ ->
                                case lists:member(full_response, Opts) of
                                    true ->  
                                        {reply, nksip_reply:reply(Req, 408)};
                                    false when Method=:='INVITE' ->
                                        {ok, 408, <<>>};
                                    false -> 
                                        {ok, 408}
                                end
                        end
                    end;
                {error, Error} ->
                    {error, Error}
            end
    end.


%% @private
-spec send_dialog(nksip_dialog:spec(), nksip:method(), nksip_lib:proplist()) ->
    {ok, nksip:response_code()} | {ok, nksip:response_code(), nksip_dialog:id()} |
    ok  | {ok, nksip:request()} | {reply, nksip:response()} |
    {async, nksip:request_id()} | {error, dialog_errors()}.

send_dialog(DialogSpec, Method, Opts) ->
    case nksip_call_router:make_dialog(DialogSpec, Method, Opts) of
        {ok, {AppId, RUri, Opts1}} ->
            send_request(AppId, Method, RUri, Opts1);  
        {error, Error} -> 
            {error, Error}
    end.
