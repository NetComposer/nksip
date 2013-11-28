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

%% @doc SipApp callback behaviour and callbacks default implementation.
%%
%% All of the available functions you can implement in your callback module are described 
%% here, along with the default implementation of each one.
%%
%% Every <b>SipApp</b> must define a <i>callback module</i>, using this module's behaviour. 
%% This behaviour works in a very similar way to any standard Erlang `gen_server''s 
%% callback module, but only {@link init/1} is mandatory.
%%
%% Depending on the phase of the request processing, different functions will be called. 
%% Some of these calls expect an answer from the SipApp to continue the processing, 
%% and some others are called to inform the SipApp about a specific event and don't 
%% expect any answer. As in `gen_server', the current SipApp state (created in the call
%% to `init/1') will be sent in every call, and can be updated by the SipApp
%% implementation in every function return.
%%
%% Except for `init/1', all defined functions belong
%% to one of two groups: <i>expected answer</i> functions and 
%% <i>no expected answer</i> functions.
%%
%% The supported return values for <i>expected answer functions</i> are:
%% ```
%%   call_reply() :: 
%%       {noreply, State} | {noreply, State, Timeout} | 
%%       {reply, Reply, State} | {reply, Reply, State, Timeout} | 
%%       {stop, Reason, State} | {stop, Reason, Reply, State}
%%       when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term()
%% '''     
%%
%% The function is expected to return `State' as new SipApp user's state and a `Reply', 
%% whose meaning is specific to each function and it is described bellow. 
%% If a `Timeout' is defined the SipApp process will receive a `timeout' message 
%% after the indicated milliseconds period (you must implement {@link handle_info/2}
%% to receive it). 
%% If the function returns `stop' the SipApp will be stopped. 
%% If the function does not want to return a reply just know, it must return 
%% `{noreply, State}' and call {@link nksip:reply/2} later on, 
%% possibly from a different spawned process.
%%
%% The supported return values for <i>no expected answer functions</i> are:
%% ```
%%   call_noreply() :: 
%%       {noreply, State} | {noreply, State, Timeout} | 
%%       {stop, Reason, State} 
%%       when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term()
%% '''     
%%
%% Some of the callback functions allow the SipApp to send a response back
%% to the calling party. See the available responses in {@link nksip_reply}.
%%
%% The usual call order is the following:
%% <ol>
%%  <li>When starting the SipApp, {@link init/1} is called to initialize the 
%%      application state.</li>
%%  <li>When a request is received having an <i>Authorization</i> or 
%%      <i>Proxy-Authorization</i> header, {@link get_user_pass/3} is called to check
%%      the user's password.</li>
%%  <li>NkSIP calls {@link authorize/4} to check is the request should be
%%      authorized.</li>
%%  <li>If authorized, it calls {@link route/6} to decide what to do with the 
%%      request: reply, route or process locally.</li>
%%  <li>If the request is going to be processed locally, {@link invite/3},
%%      {@link options/3}, {@link register/3} or {@link bye/3} are called,
%%      and the user must send a reply. 
%%      If the request is a valid <i>CANCEL</i>, belonging to an active <i>INVITE</i>
%%      transaction, the INVITE is cancelled and {@link cancel/2} is called.</li>
%%  <li>After sending a successful response to an <i>INVITE</i> request,
%%      the other party will send an <i>ACK</i> and {@link ack/3} will be called.</li>
%%  <li>If the request creates or modifies a dialog and/or a SDP session, 
%%      {@link dialog_update/3} and/or {@link session_update/3} are called.</li>
%%  <li>If the remote party sends an in-dialog invite (a <i>reINVITE</i>),
%%      NkSIP will call {@link reinvite/3}.</li>
%%  <li>If the user has set up an automatic ping or registration, 
%%      {@link ping_update/3} or {@link register_update/3} are called on each
%%      status change.</li>
%%  <li>When the SipApp is stopped, {@link terminate/2} is called.</li>
%% </ol>
%%
%%
%% It is <b>very important</b> to notice that, as in using normal `gen_server', 
%% there is a single SipApp core process, so you must not spend a long time in any of 
%% the callback functions. If you do so, new requests arriving at your SipApp will be 
%% blocked and the other party will start to send retransmissions. As no transaction 
%% has been created yet, NkSIP will see them as new requests that will be also blocked, 
%% and so on.
%%
%% If the expected processing time of any of your callback functions is high 
%% (more than a few milliseconds), you must spawn a new process, return `{noreply, ...}' 
%% and do any time-consuming work there. If the called function spawning the process is 
%% in the expected answer group, it must call {@link nksip:reply/2} from the spawned 
%% process when a reply is available. 
%% Launching new processes in Erlang is a very cheap operation, 
%% so in case of doubt follow this recommendation.
%%
%% Many of the callback functions receive a `RequesId' ({@link nksip_request:id()}) 
%% object as first parameter, representing a pointer to the actual request. You can
%% use the helper funcions in {@link nksip_request} to extract any information from it,
%% and, it it is liked to a dialog, the functions in {@link nksip_dialog}.
%%
%% <b>Inline functions</b>
%%
%% NkSIP offers another option for defining callback functions. Most of them have
%% an <i>inline</i> form. If defined, it will be called instead of the <i>normal</i> form.
%%
%% Inline functions have the same name of normal functions, but they don't have the
%% `State' parameter. They are called in-process, inside the call processing process and
%% not from the SipApp's process like the normal functions.
%%
%% Inline functions are much quicker, but they can't modify the SipApp state. 
%% They received a full {@link nksip:request()} object instead of a request's id, 
%% so they must use the functions in {@link nksip_sipmsg} instead of 
%% {@link nksip_request}.
%% See `inline_test' for an example of use

-module(nksip_sipapp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/1, get_user_pass/3, authorize/4, route/6, invite/3, reinvite/3, cancel/2, 
         ack/3, bye/3, options/3, register/3, info/3, prack/3, update/3]).
-export([ping_update/3, register_update/3, dialog_update/3, session_update/3]).
-export([handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-include("nksip.hrl").


%% ===================================================================
%% Types
%% ===================================================================



-type init_return() :: 
    {ok, State::term()} | {ok, State::term(), Timeout::timeout()} |
    {stop, Reason::term()}.

-type call_reply(RetType) :: 
    {reply, Reply::RetType, State::term()} | 
    {reply, Reply::RetType, State::term(), Timeout::timeout()} |
    {noreply, State::term()} | 
    {noreply, State::term(), Timeout::timeout()} |
    {stop, Reason::term(), Reply::RetType, State::term()} | 
    {stop, Reason::term(), State::term()}.
                   
-type call_noreply() :: 
    {noreply, State::term()} |
    {noreply, State::term(), Timeout::timeout()} |
    {stop, Reason::term(), State::term()}.


%% ===================================================================
%% Callbacks
%% ===================================================================

-callback init(Args :: term()) ->
    init_return().


%% ===================================================================
%% Default callback implementations
%% ==================================================================

%% @doc SipApp initialization.
%% This callback function is called when the SipApp is launched using 
%% {@link nksip:start/4}.
%% If `{ok, State}' or `{ok, State, Timeout}' is returned the SipApp is started with
%% this initial state. If a `Timeout' is provided (in milliseconds) a 
%% `timeout' message will be sent to the process 
%% (you will need to implement {@link handle_info/2} to receive it).
%% If `{stop, Reason}' is returned the SipApp will not start. 
%%
-spec init(Args::term()) ->
    init_return().

init([]) ->
    {ok, {}}.


%% @doc Called when the SipApp is stopped.
-spec terminate(Reason::term(), State::term()) ->
    ok.

terminate(_Reason, _State) ->
    ok.


%% @doc Called to check a user password for a realm.
%% When a request is received containing a `Authorization' or `Proxy-Authorization' 
%% header, this function is called by NkSIP including the header's `User' and `Realm', 
%% to check if the authorization data in the header corresponds to the user's password.
%%
%% You should normally reply with the user's password (if you have it for this user 
%% and realm). NkSIP will use the password and the digest information in the header 
%% to check if it is valid, offering this information in the call to 
%% {@link authorize/4}. 
%%
%% You can also reply `true' if you want to accept any request from this user 
%% without checking any password, or `false' if you don't have a password for this user 
%% or want her blocked.
%%
%% If you don't want to store <i>clear-text</i> passwords of your users, 
%% you can use {@link nksip_auth:make_ha1/3} to generate a <i>hash</i> of the password 
%% for an user and a realm, and store only this hash instead of the real password. 
%% Later on you can reply here with the hash instead of the real password.
%%
%% If you don't define this function, NkSIP will reply with password `<<>>' 
%% if user is `anonymous', and `false' for any other user.  
%%
-spec get_user_pass(User::binary(), Realm::binary(), State::term()) ->
    {reply, Reply, NewState}
    when Reply :: true | false | binary(), NewState :: term().

get_user_pass(<<"anonymous">>, _, State) ->
    {reply, <<>>, State};
get_user_pass(_User, _Realm, State) ->
    {reply, false, State}.



%% @doc Called for every incoming request to be authorized or not.
%%
%% If `ok' is replied the request is authorized and the 
%% request processing continues. If `authenticate' is replied, the request will be 
%% rejected (statelessly) with a 401 <i>Unauthorized</i>. 
%% The other party will usually send the request again, this time with an 
%% `Authorization' header. If you reply `proxy_authenticate', it is rejected 
%% with a 407 <i>Proxy Authentication Rejected</i> response and the other party 
%% will include a `Proxy-Authorization' header.
%%
%% You can use the tags included in `AuthList' in order to decide to authenticate
%% or not the request.  AuthList includes the following tags:
%% <ul>
%%    <li>`dialog': the request is in-dialog and coming from the same ip and port
%%        than the last request for an existing dialog.</li>
%%    <li>`register': the request comes from the same ip, port and transport of a 
%%        currently valid registration (and the method is not <i>REGISTER</i>).</li>
%%    <li>`{{digest, Realm}, true}': there is at least one valid user authenticated
%%        (has a correct password) with this Realm.</li>
%%    <li>`{{digest, Realm}, false}': there is at least one user offering an 
%%        authentication header for this Realm, but all of them 
%%        have failed the authentication (no password was valid). </li>
%% </ul>
%%
%% You will usually want to combine these strategies. Typically you will first 
%% check using SIP digest authentication, and, in case of faillure, you can use 
%% previous registration and/or dialog authentication. 
%% If you don't define this function all requests will be authenticated.
%%
-spec authorize(AuthList, ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(ok | authenticate | proxy_authenticate | forbidden)
    when AuthList :: [dialog|register|{{digest, Realm::binary}, boolean()}].

authorize(_AuthList, _ReqId, _From, State) ->
    {reply, ok, State}.


%% @doc This function is called by NkSIP for every new request, to check if it must be 
%% proxied, processed locally or replied immediately. For convenience, the scheme, user
%% and domain parts of the <i>Request-Uri</i> are included.
%%
%% If we want to <b>act as a proxy</b> and route the request, and we are not responsible 
%% for `Domain' we must return `proxy' or `{proxy, ruri, ProxyOpts}'. 
%% We must not return an `UriSet' in this case. 
%% NkSIP will then make additional checks to the request (like inspecting the 
%% `Proxy-Require' header) and will route it statefully to the same `Request-URI' 
%% contained in the request.
%%
%% If we are the resposible proxy for `Domain' we can provide a new list 
%% of URIs to route the request to. NkSIP will use <b><i>serial</i> and/or 
%% <i>parallel</i> forking</b> depending on the format of `UriSet'. 
%% If `UriSet' is a simple Erlang array of binaries representing uris, NkSIP will try 
%% each one serially. If any of the elements of the arrary is in turn a new array 
%% of binaries, it will fork them in parallel. 
%% For example, for  ```[ <<"sip:aaa">>, [<<"sip:bbb">>, <<"sip:ccc">>], <<"sip:ddd">>]'''
%% NkSIP will first forward the request to `aaa'. If it does not receive a successful 
%% (2xx) response, it will try `bbb' and `cccc' in parallel. 
%% If no 2xx is received again, `ddd' will be tried. See {@link nksip_registrar}
%% to find out how to get the registered contacts for this `Request-Uri'.
%%
%% Available options for `ProxyOpts' are:
%% <ul>
%%  <li>`stateless': Use it if you want to proxy the request <i>statelessly</i>. 
%%       Only one URL is allowed in `UriSet' in this case.</li>
%%  <li>`record_route': NkSIP will insert a <i>Record-Route</i> header before sending 
%%      the request, so that following request inside the dialog will be routed 
%%      to this proxy.</li>
%%  <li>`follow_redirects': If any 3xx response is received, the received contacts
%%      will be inserted in the list of uris to try.</li>
%%  <li><code>{route, {@link nksip:user_uri()}}</code>: 
%%      NkSIP will insert theses routes as <i>Route</i> headers
%%      in the request, before any other existing `Route' header.
%%      The request would then be sent to the first <i>Route</i>.</li>
%%  <li><code>{headers, [{@link nksip:header()}]}</code>: 
%%      Inserts these headers before any existing header.</li>
%%  <li>`remove_routes': Removes any previous <i>Route</i> header in the request.
%%      A proxy should not usually do this. Use it with care.</li>
%%  <li>`remove_headers': Remove previous non-vital headers in the request. 
%%      You can use modify the headers and include them with using `{headers, Headers}'. 
%%      A proxy should not usually do this. Use it with care.</li>
%% </ul>
%% 
%% If we want to <b>act as an endpoint or B2BUA</b> and answer to the request 
%% from this SipApp, we must return `process' or `{process, ProcessOpts}'. 
%% NkSIP will then make additional checks to the request (like inspecting 
%% `Require' header), start a new transaction and call the function corresponding 
%% to the method in the request (like `invite/3', `options/3', etc.)
%%
%% Available options for `ProcessOpts' are:
%% <ul>
%%  <li>`stateless': Use it if you want to process this request <i>statelessly</i>. 
%%       No transaction will be started.</li>
%% <li><code>{headers, [{@link nksip:header()}]}</code>: 
%%     Insert these headers before any existing header, before calling the next 
%%     callback function.</li>
%% </ul>
%%
%% We can also <b>send a reply immediately</b>, replying `{response, Response}', 
%% `{response, Response, ResponseOpts}' or simply `Response'. See {@link nksip_reply} 
%% to find the recognized response values. The typical reason to reply a response here 
%% is to send <b>redirect</b> or an error like `not_found', `ambiguous', 
%% `method_not_allowed' or any other. If the form `{response, Response}' or 
%% `{response, Response, ResponseOpts}' is used the response is sent statefully, 
%% and a new transaction will be started, unless `stateless' is present in `ResponseOpts'.
%% If simply `Response' is used no transaction will be started. 
%% The only recognized option in `ResponseOpts' is `stateless'.
%%
%% If route/3 is not defined the default reply would be `process'.
%%
-type route_reply() ::
    proxy | {proxy, ruri | nksip:uri_set()} | 
    {proxy, ruri | nksip:uri_set(), nksip_lib:proplist()} | 
    process | {process, nksip_lib:proplist()} |
    {response, nksip:sipreply()} | 
    {response, nksip:sipreply(), nksip_lib:proplist()}.

-spec route(Scheme::nksip:scheme(), User::binary(), Domain::binary(), 
            ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(route_reply()).

route(_Scheme, _User, _Domain, _ReqId, _From, State) ->
    {reply, process, State}.


%% @doc This function is called by NkSIP to process a new INVITE request as an endpoint.
%% Before replying a final response, you will usually call 
%% {@link nksip_request:reply/3} to send a provisional response like 
%% `ringing' (which would send a 180 <i>Ringing</i> reply).
%%
%% If a quick response (like `busy') is not going to be sent immediately 
%% (which is typical for INVITE requests, as the user would normally need to accept 
%% the call) you must return `{noreply, NewState}' and spawn a new process, 
%% calling {@link nksip:reply/2} from the new process, in order to avoid 
%% blocking the SipApp process.
%%
%% You can access the body of the request by calling {@link nksip_request:body/2}. 
%% INVITE requests will usually have a SDP body. If this is the case, and the 
%% `Content-Type' header contains `application/sdp', NkSIP will decode the SDP and 
%% `nksip_request:body/2' will return a {@link nksip_sdp:sdp()} object you can manage 
%% with the functions in {@link nksip_sdp}. 
%% If it is not recognized it would return a binary, or `<<>>' if it is missing.
%%
%% You must then answer the request. The possible responses are defined in 
%% {@link nksip_reply}.
%% If a successful (2xx) response is sent, you should include a new generated SDP body
%% in the response. A new dialog will then start. 
%% The remote party should then send an ACK request immediately.
%% If none is received, NkSIP will automatically stop the dialog.
%%
-spec invite(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

invite(_ReqId, _From, State) ->
    {reply, decline, State}.


%% @doc This function is called when a new in-dialog INVITE request is received.
%% The guidelines in {@link invite/4} are valid, but you shouldn't send provisional
%% responses, but a final response inmediatly.
%% 
%% If the dialog's target or the SDP session parameters are updated by the request or
%% its response, {@link dialog_update/3} and/or {@link session_update/3} would be
%% called.
%%
-spec reinvite(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

reinvite(_ReqId, _From, State) ->
    {reply, decline, State}.


%% @doc Called when a pending INVITE request is cancelled.
%% When a CANCEL request is received by NkSIP, it will check if it belongs to an 
%% existing INVITE transaction. If not, a 481 <i>Call/Transaction does not exist</i> 
%% will be automatically replied.
%%
%% If it belongs to an existing INVITE transaction, NkSIP replies 200 <i>OK</i> to the
%% CANCEL request. If the matching INVITE transaction has not yet replied a
%% final response, NkSIP replies it with a 487 (Request Terminated) and this function
%% is called. If a final response has already beeing replied, it has no effect.
%%
-spec cancel(ReqId::nksip_request:id(), State::term()) ->
    call_noreply().

cancel(_ReqId, State) ->
    {noreply, State}.


%% @doc Called when a valid ACK request is received.
%%
%% This function is called by NkSIP when a new valid in-dialog ACK request has to
%% be processed locally.
%% You don't usually need to implement this callback. One possible reason to do it is 
%% to receive the SDP body from the other party in case it was not present in the INVITE
%% (you can also get it from the {@link session_update/3} callback).
%%
-spec ack(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(ok).

ack(_ReqId, _From, State) ->
    {reply, ok, State}.


%% @doc Called when a valid BYE request is received.
%% When a BYE request is received, NkSIP will automatically response 481 
%% <i>Call/Transaction does not exist</i> if it doesn't belong to a current dialog.
%% If it does, NkSIP stops the dialog and this callback functions is called.
%% You won't usually need to implement this function, but in case you do, you
%% should reply `ok' to send a 200 response back.
%%
-spec bye(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

bye(_ReqId, _From, State) ->
    {reply, ok, State}.


%% @doc Called when a valid INFO request is received.
%% When an INFO request is received, NkSIP will automatically response 481
%% <i>Call/Transaction does not exist</i> if it doesn't belong to a current dialog.
%% If it does, NkSIP this callback functions is called.
%% If implementing this function, you should reply `ok' to send a 200 response back.
%%
-spec info(ReqId::nksip_request:id(), From::from(), State::term()) ->
  call_reply(nksip:sipreply()).

info(_ReqId, _From, State) ->
  {reply, ok, State}.


%% @doc Called when a OPTIONS request is received.
%% This function is called by NkSIP to process a new incoming OPTIONS request as 
%% an endpoint. If not defined, NkSIP will reply with a 200 <i>OK</i> response, 
%% including automatically generated `Allow', `Accept' and `Supported' headers.
%%
%% NkSIP will not send any body in its automatic response. This is ok for proxies. 
%% If you are implementing an endpoint or B2BUA, you should implement this function 
%% and include in your response a SDP body representing your supported list of codecs, 
%% and also `Allow', `Accept' and `Supported' headers.
%%
-spec options(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

options(_ReqId, _From, State) ->
    Reply = {ok, [], <<>>, [make_contact, make_allow, make_accept, make_supported]},
    {reply, Reply, State}.


%% @doc This function is called by NkSIP to process a new incoming REGISTER request. 
%% If it is not defined, but `registrar' option was present in the SipApp's 
%% startup config, NkSIP will process the request. 
%% It will NOT check if <i>From</i> and <i>To</i> headers contains the same URI,
%% or if the registered domain is valid or not. If you need to check this,
%% implement this function returning `register' if everything is ok.
%% See {@link nksip_registrar} for other possible response codes defined in the SIP 
%% standard registration process.
%%
%% If this function is not defined, and no `registrar' option is found, 
%% a 405 <i>Method not allowed</i> would be replied. 
%%
%% You should define this function in case you are implementing a registrar server 
%% and need a specific REGISTER processing 
%% (for example to add some headers to the response).
%%
-spec register(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

register(_ReqId, _From, State) ->
    %% NOTE: In this default implementation, State contains the SipApp options.
    %% If you implement this function, State will contain your own state.
    Reply = case lists:member(registrar, State) of
        true -> register;
        false -> {method_not_allowed, ?ALLOW}
    end,
    {reply, Reply, State}.


%% @doc Called when a valid PRACK request is received.
%%
%% This function is called by NkSIP when a new valid in-dialog PRACK request has to
%% be processed locally, in response to a sent reliable provisional response
%% You don't usually need to implement this callback. One possible reason to do it is 
%% to receive the SDP body from the other party in case it was not present in the INVITE
%% (you can also get it from the {@link session_update/3} callback).
%%
-spec prack(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(ok).

prack(_ReqId, _From, State) ->
    {reply, ok, State}.


%% @doc Called when a valid UPDATE request is received.
%% When a UPDATE request is received, NkSIP will automatically response 481 
%% <i>Call/Transaction does not exist</i> if it doesn't belong to a current dialog.
%% If it does, this function is called. The requiest will probably have a
%% SDP body. If a `ok' is replied, a SDP answer is inclued, the session may change
%% (and the corresponding callback function will be called). 
%% If other non 2xx response is replied (like decline) the media is not changed.
%%
-spec update(ReqId::nksip_request:id(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

update(_ReqId, _From, State) ->
    {reply, decline, State}.


%% @doc Called when a dialog has changed its state.
%%
%% A new dialog will be created when you send an INVITE request 
%% (using {@link nksip_uac:invite/3}) and a successful (101-299) response is received, 
%% or after an INVITE is received and the call to `invite/3' callback replies 
%% with a successful response. If the response is provisional (101-199) the dialog 
%% will be marked as temporary or <i>early</i>, waiting for the final response 
%% to be confirmed or deleted.
%%
%% The dialog is destroyed when a valid in-dialog BYE request is sent or received 
%% (and for many other reasons, see {@link nksip_dialog:stop_reason()}). 
%%
%% Once the dialog is established, some in-dialog methods (like INVITE) can update the
%% `target' of the dialog. 
%%
%% NkSIP will call this function every time a dialog is created, its target is updated
%% or it is destroyed.
%%
-spec dialog_update(DialogId::nksip_dialog:id(), DialogStatus, State::term()) ->
    call_noreply()
    when DialogStatus :: start | target_update | {status, nksip_dialog:status()} |
                         {stop, nksip_dialog:stop_reason()}.
    
dialog_update(_DialogId, _Status, State) ->
    {noreply, State}.


%% @doc Called when a dialog has updated its SDP session parameters.
%% When NkSIP detects that, inside an existing dialog, both parties have agreed on 
%% a specific SDP defined session, it will call this function.
%% You can use the functions in {@link nksip_sdp} to process the SDP data.
%%
%% This function will be also called after each new successful SDP negotiation.
%%
-spec session_update(DialogId::nksip_dialog:id(), SessionStatus, State::term()) ->
    call_noreply()
    when SessionStatus :: {start, Local, Remote} | {update, Local, Remote} | stop,
                          Local::nksip_sdp:sdp(), Remote::nksip_sdp:sdp().

session_update(_DialogId, _Status, State) ->
    {noreply, State}.



%% @doc Called when the status of an automatic ping configuration changes.
%% See {@link nksip_sipapp_auto:start_ping/5}.
-spec ping_update(PingId::term(), OK::boolean(), State::term()) ->
    call_noreply().

ping_update(_PingId, _OK, State) ->
    {noreply, State}.


%% @doc Called when the status of an automatic registration configuration changes.
%% See {@link nksip_sipapp_auto:start_register/5}.
-spec register_update(RegId::term(), OK::boolean(), State::term()) ->
    call_noreply().

register_update(_RegId, _OK, State) ->
    {noreply, State}.


%% @doc Called when a direct call to the SipApp process is made using 
%% {@link nksip:call/2} or {@link nksip:call/3}.
handle_call(_Msg, _From, State) ->
    {error, unexpected_call, State}.


%% @doc Called when a direct cast to the SipApp process is made using 
%% {@link nksip:cast/2}.
handle_cast(_Msg, State) ->
    {error, unexpected_cast, State}.


%% @doc Called when the SipApp process receives an unknown message.
handle_info(_Msg, State) ->
    {noreply, State}.









