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

%% @doc <i>SipApps</i> management module.
%%
%% This module allows to manage <i>NkSIP application instances</i> or <b>SipApps</b>. 
%% NkSIP can start any number of SipApps, each one listening on one or several sets of 
%% ip, port and transport (UDP, TCP, TLS or SCTP currently).
%%
%% To register a SipApp, you must first create a <i>callback module</i> using 
%% behaviour {@link nksip_sipapp} (you can also use the <i>default callback module</i>
%% included with NkSIP, defined in the same  `nksip_sipapp' module).
%% This behaviour is very similar to OTP standard `gen_server' behaviour, but 
%% the only mandatory callback function is {@link nksip_sipapp:init/1}. 
%% The callback module can also implement a number of 
%% optional callbacks functions, have a look at {@link nksip_sipapp} to find 
%% the currently available callbacks and default implementation for each of 
%% these functions.
%%
%% Once defined the callback module, call {@link start/4} to start the SipApp. 
%% NkSIP will call `init/1' inmediatly, setting up the inital application's state.
%%
%% From this moment on, you can start sending requests using the functions in 
%% {@link nksip_uac}. When a incoming request is received in our SipApp 
%% (sent from another SIP endpoint or proxy), NkSIP starts a process to manage it. 
%% This process starts calling specific functions in the SipApp's callback module
%% as explained in {@link nksip_sipapp}.
%%
%% Should the SipApp process stop due to an error, it will be automatically restarted 
%% by its supervisor, but the Erlang application's state would be lost like a standard
%% `gen_server'.
%%
%% Please notice that it is not necessary to tell NkSIP which kind of SIP element 
%% your SipApp is implementing. For every request, depending on the return of 
%% the call to your {@link nksip_sipapp:route/6} callback function 
%% NkSIP will act as an endpoint, B2BUA or proxy, request by request. 
%%
-module(nksip).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, stop/1, stop_all/0, get_all/0]).
-export([call/2, call/3, cast/2, reply/2, get_pid/1, get_port/3]).

-include("nksip.hrl").

-export_type([app_id/0, request/0, response/0, sipreply/0]).
-export_type([uri/0, user_uri/0]).
-export_type([header/0, scheme/0, protocol/0, method/0, response_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

%% Unique Id of each started SipApp
-type app_id() :: term().

%% Parsed SIP Request
-type request() :: #sipmsg{}.

%% Parsed SIP Response
-type response() :: #sipmsg{}.

%% User's response to a request
-type sipreply() :: nksip_reply:sipreply().

%% Parsed SIP Uri
-type uri() :: #uri{}.

%% User specified uri
-type user_uri() :: string() | binary() | uri().

%% SIP Generic Header
-type header() :: {binary(), binary() | atom() | integer()}.

%% Recognized transport schemes
-type protocol() :: udp | tcp | tls | sctp | ws | wss | binary().

%% Recognized SIP schemes
-type scheme() :: sip | sips | tel | mailto | binary().

%% SIP Method
-type method() :: 'INVITE' | 'ACK' | 'CANCEL' | 'BYE' | 'REGISTER' | 'OPTIONS' |
                  'SUBSCRIBE' | 'NOTIFY' | 'PUBLISH' | 'REFER' | 'MESSAGE' |
                  'INFO' | 'PRACK' | 'UPDATE' | binary().

%% SIP Response's Code
-type response_code() :: 100..699.

%% Parsed SIP Via
-type via() :: #via{}.

%% SIP Message's Call-ID
-type call_id() :: binary().

%% SIP Message's CSeq
-type cseq() :: pos_integer().

%% Tag in From and To headers
-type tag() :: binary().

%% SIP Message body
-type body() :: binary() | nksip_sdp:sdp().

%% Uri Set used to order proxies
-type uri_set() :: nksip:user_uri() | [nksip:user_uri() | [nksip:user_uri()]].

%% Address of Record
-type aor() :: {Scheme::scheme(), User::binary(), Domain::binary()}.

%% Dialog
-type dialog() :: #dialog{}.

%% Dialog
-type subscription() :: #subscription{}.

%% Token
-type token() :: {Name::binary(), [Key::binary() | {Key::binary(), Value::binary()}]}.

%% Reason
-type error_reason() :: {sip|q850, pos_integer(), string()|binary()}.


%% ===================================================================
%% Public functions
%% ===================================================================

%% @doc Starts a new SipApp.
%% A <b>SipApp</b> is a SIP application started by NkSIP, listening on one or several
%% sets of transport protocol, IP and port of the host. You must supply an `AppId' 
%% for the SipApp, a <i>callbacke</i> `Module' with {@link nksip_sipapp} behaviour, 
%% an `Args' for calling `init/1' and a set of `Options'
%%
%% The recognized options are:<br/><br/>
%% <table border="1">
%%      <tr><th>Key</th><th>Type</th><th>Default</th><th>Description</th></tr>
%%      <tr>
%%          <td>`from'</td>
%%          <td>{@link user_uri()}</td>
%%          <td>`"NkSIP App <sip:user@nksip>"'</td>
%%          <td>Default <i>From</i> to use in the requests.</td>
%%      </tr>
%%      <tr>
%%          <td>`pass'</td>
%%          <td>`Pass | {Pass, Realm} | [Pass | {Pass, Realm}]'<br/>
%%              `Pass::binary(), Realm::binary()'</td>
%%          <td></td>
%%          <td>Passwords to use in case of receiving an <i>authenticate</i> response
%%          using {@link nksip_uac} functions.<br/>
%%          The first password matching the response's realm will be used, 
%%          or the first without any realm if none matches. <br/>
%%          A hash of the password can be used instead 
%%          (see {@link nksip_auth:make_ha1/3}).</td>
%%      </tr>
%%      <tr>
%%          <td>`register'</td>
%%          <td>{@link user_uri()}</td>
%%          <td></td>
%%          <td>NkSIP will try to <i>REGISTER</i> the SipApp with this registrar server, 
%%          (i.e. "sips:sip2sip.info"). <br/> 
%%          See {@link nksip_sipapp_auto:get_registers/1}
%%          and {@link nksip_sipapp:register_update/3}.</td>
%%      </tr>
%%      <tr>
%%          <td>`register_expires'</td>
%%          <td>`integer()'</td> 
%%          <td>`300'</td>
%%          <td>In case of register, registration interval (secs).</td>
%%      </tr>
%%      <tr>
%%          <td>`transports'</td>
%%          <td>
%%              `[{Proto, Ip, Port}]'<br/>
%%              <code>Proto::{@link protocol()}</code><br/>
%%              `Ip::inet:ip_address()|string()|binary()|any|any6'<br/>
%%              `Port::inet:port_number()|all'
%%          </td>
%%          <td>`[{udp, any, all}, {tls, any, all}]'</td>
%%          <td>The SipApp can start any number of transports. 
%%          If an UDP transport is started, a TCP transport on the same IP and port
%%          will be started automatically.<br/>
%%          Use `any' to use <i>all</i> available IPv4 addresses and 
%%          `any6' for all IPv6 addresses, and `all' to use
%%          any available port.</td>
%%      </tr>
%%      <tr>
%%          <td>`listeners'</td>
%%          <td>`integer()'</td>
%%          <td>`1'</td>
%%          <td>Number of pre-started listeners for TCP and TLS
%%          (see <a href="http://ninenines.eu/docs/en/ranch/HEAD/guide/introduction">Ranch's</a> documentation).</td>
%%      </tr>
%%      <tr>
%%          <td>`certfile'</td>
%%          <td>`string()'</td>
%%          <td>`"(privdir)/cert.pem"'</td>
%%          <td> Path to the certificate file for TLS.</td>
%%      </tr>
%%      <tr>
%%          <td>`keyfile'</td>
%%          <td>`string()'</td>
%%          <td>`"(privdir)/key.pem"'</td>
%%          <td>Path to the key file for TLS.</td>
%%      </tr>
%%      <tr>
%%          <td>`route'</td>
%%          <td>{@link user_uri()}</td>
%%          <td></td>
%%          <td> Route (outbound proxy) to use. Generates one or more `Route' headers
%%              in every request, for example `<sip:1.2.3.4;lr>, <sip:abcd;lr>' 
%%              (you will usually append the `lr' option to use <i>loose routing</i>).
%%          </td>
%%      </tr>
%%      <tr>
%%          <td>`local_host'</td>
%%          <td>`auto|string()|binary()'</td>
%%          <td>`auto'</td>
%%          <td>Default host or IP to use in headers like `Via', `Contact' and 
%%          `Record-Route'.<br/>
%%          If set to `auto' NkSIP will use the IP of the
%%          transport selected in every case. If that transport is listening on all
%%          addresses NkSIP will try to find the best IP using the first 
%%          valid IP among the network interfaces `ethX' and 'enX',
%%          or localhost if none is found.</td>
%%      </tr>
%%      <tr>
%%          <td>`local_host6'</td>
%%          <td>`auto|string()|binary()'</td>
%%          <td>`auto'</td>
%%          <td>Default host or IP to use in headers like `Via', `Contact' and 
%%          `Record-Route' for IPv6 transports.<br/>
%%          See `local_host' option.</td>
%%      </tr>
%%      <tr>
%%          <td>`registrar'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, allows the automatic processing <i>REGISTER</i> requests, 
%%          even if no `register/3' callback  is defined, using 
%%          {@link nksip_sipapp:register/3}.<br/>
%%          The word <i>REGISTER</i> will also be present in all <i>Allow</i> headers.
%%          </td>
%%      </tr>
%%      <tr>
%%          <td>`no_100'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, forbids the generation of automatic `100-type' responses
%%          for INVITE requests.</td>
%%      </tr>
%%      <tr>
%%          <td>`require_100rel'</td>
%%          <td></td>
%%          <td></td>
%%          <td>If present, all <i>INVITE</i> requests will have 'require_100rel' option 
%%          activated.</td>
%%      </tr>
%%      <tr>
%%          <td>`supported'</td>
%%          <td>`string()|binary()'</td>
%%          <td>`"100rel"'</td>
%%          <td>If present, these tokens will be used in Supported headers instead of
%%          the default supported list (only '100rel' currently), for example
%%          "my_token1;opt1, mytoken2, 100rel".</td>
%%      </tr>
%%      <tr>
%%          <td>`event'</td>
%%          <td>`string()|binary()'</td>
%%          <td>`""'</td>
%%          <td>Lists the Event Packages this SipApp supports.</td>
%%      </tr>
%%      <tr>
%%          <td>`accept'</td>
%%          <td>`string()|binary()'</td>
%%          <td>`"*/*"'</td>
%%          <td>If defined, this value will be used instead of default when 
%%          option `make_accept' is used</td>
%%      </tr>
%%  </table>
%%
%% <br/>
-spec start(app_id(), atom(), term(), nksip_lib:proplist()) -> 
	ok | {error, Error} 
    when Error :: invalid_from | invalid_transport | invalid_register | invalid_route |
                  invalid_supported | invalid_accept | invalid_event | invalid_reason |
                  no_matching_tcp | could_not_start_udp | could_not_start_tcp |
                  could_not_start_tls | could_not_start_sctp.

start(AppId, Module, Args, Opts) ->
    try
        Transports = [
            case Transport of
                {Scheme, Ip, Port} 
                    when (Scheme==udp orelse Scheme==tcp orelse 
                          Scheme==tls orelse Scheme==sctp) ->
                    Ip1 = case Ip of
                        any -> 
                            {0,0,0,0};
                        any6 ->
                            {0,0,0,0,0,0,0,0};
                        _ when is_tuple(Ip) ->
                            case catch inet_parse:ntoa(Ip) of
                                {error, _} -> throw(invalid_transport);
                                {'EXIT', _} -> throw(invalid_transport);
                                _ -> Ip
                            end;
                        _ ->
                            case nksip_lib:to_ip(Ip) of
                                {ok, PIp} -> PIp;
                                error -> throw(invalid_transport)
                            end
                    end,
                    Port1 = case Port of
                        all -> 0;
                        _ when is_integer(Port), Port >= 0 -> Port;
                        _ -> throw(invalid_transport)
                    end,
                    {Scheme, Ip1, Port1};
                _ ->
                    throw(invalid_transport)
            end
            || Transport <- proplists:get_all_values(transport, Opts)
        ],
        DefFrom = "\"NkSIP App\" <sip:user@nksip>",
        DefCertFile = filename:join(code:priv_dir(nksip), "cert.pem"),
        DefKeyFile = filename:join(code:priv_dir(nksip), "key.pem"),
        CoreOpts = [
            case nksip_parse:uris(nksip_lib:get_value(from, Opts, DefFrom)) of
                [From] -> {from, From};
                _ -> throw(invalid_from) 
            end,
            nksip_lib:extract(Opts, pass),
            case Transports of
                [] -> {transports, [{udp, {0,0,0,0}, 0}, {tls, {0,0,0,0}, 0}]};
                _ -> {transports, Transports}
            end,
            case nksip_lib:get_value(listeners, Opts) of
                Listeners when is_integer(Listeners), Listeners > 0 -> 
                    {listeners, Listeners};
                _ -> 
                    []
            end,
            {certfile, nksip_lib:get_list(certfile, Opts, DefCertFile)},
            {keyfile, nksip_lib:get_list(keyfile, Opts, DefKeyFile)},
            case nksip_lib:get_value(register, Opts) of
                undefined ->
                    [];
                RegSpec ->
                    case nksip_parse:uris(RegSpec) of
                        [RegUri] ->
                            case nksip_lib:get_value(register_expires, Opts, 300) of
                                RegExpires when is_integer(RegExpires) ->
                                    [
                                        {register, RegUri}, 
                                        {register_expires, RegExpires}
                                    ];
                                _ ->
                                    {register, RegUri}
                            end;
                        _ ->
                            throw(invalid_register)
                    end
            end,
            case nksip_lib:get_value(route, Opts, false) of
                false -> 
                    [];
                RouteSpec -> 
                    case nksip_parse:uris(RouteSpec) of
                        error -> throw(invalid_route);
                        RouteUris -> {route, RouteUris}
                    end
            end,
            case nksip_lib:get_value(local_host, Opts, auto) of
                auto -> [];
                Host -> {local_host, nksip_lib:to_host(Host)}
            end,
            case nksip_lib:get_value(local_host6, Opts, auto) of
                auto -> 
                    [];
                Host6 -> 
                    case nksip_lib:to_ip(Host6) of
                        {ok, HostIp6} -> 
                            % Ensure it is enclosed in `[]'
                            {local_host6, nksip_lib:to_host(HostIp6, true)};
                        error -> 
                            {local_host6, nksip_lib:to_binary(Host6)}
                    end
            end,
            case lists:member(registrar, Opts) of
                true -> registrar;
                _ -> []
            end,
            case lists:member(no_100, Opts) of
                true -> no_100;
                _ -> []
            end,
            case lists:member(require_100rel, Opts) of
                true -> require_100rel;
                _ -> []
            end,
            case nksip_lib:get_value(supported, Opts) of
                undefined -> 
                    [];
                SupList ->
                    case nksip_parse:tokens(SupList) of
                        error -> throw(invalid_supported);
                        Supported -> {supported, Supported}
                    end
            end,
            case nksip_lib:get_value(accept, Opts) of
                undefined -> 
                    [];
                AcceptList ->
                    case nksip_parse:tokens(AcceptList) of
                        error -> throw(invalid_accept);
                        Accept -> {accept, Accept}
                    end
            end,
            case proplists:get_all_values(event, Opts) of
                [] -> 
                    [];
                PkgList ->
                    case nksip_parse:tokens(PkgList) of
                        error -> throw(invalid_event);
                        Events -> {event, [T||{T, _}<-Events]}
                    end
            end
        ],
        nksip_sup:start_core(AppId, Module, Args, lists:flatten(CoreOpts))
    catch
        throw:Throw -> {error, Throw}
    end.


%% @doc Stops a started SipApp, stopping any registered transports.
-spec stop(app_id()) -> 
    ok | error.

stop(AppId) ->
    case nksip_sup:stop_core(AppId) of
        ok ->
            nksip_registrar:clear(AppId),
            ok;
        error ->
            error
    end.


%% @doc Stops all started SipApps.
-spec stop_all() -> 
    ok.

stop_all() ->
    lists:foreach(fun(AppId) -> stop(AppId) end, get_all()).
    

%% @doc Gets the `AppIds' of all started SipApps.
-spec get_all() ->
    [AppId::app_id()].

get_all() ->
    [AppId || {AppId, _Pid} <- nksip_proc:values(nksip_sipapps)].


%% @doc Sends a response from a synchronous callback function.
%% Eequivalent to `gen_server:reply/2'.
-spec reply({reference(), pid()} | {fsm, reference(), pid()}, term()) -> 
    term().

reply(From, Reply) ->
    nksip_sipapp_srv:reply(From, Reply).


%% @doc Sends a synchronous message to the SipApp's process, 
%% similar to `gen_server:call/2'.
%% The SipApp's callback module must implement `handle_call/3'.
-spec call(app_id(), term()) ->
    any().

call(AppId, Msg) ->
    call(AppId, Msg, 5000).


%% @doc Sends a synchronous message to the SipApp's process with a timeout, 
%% similar to `gen_server:call/3'.
%% The SipApp's callback module must implement `handle_call/3'.
-spec call(app_id(), term(), infinity|pos_integer()) ->
    any().

call(AppId, Msg, Timeout) ->
    case get_pid(AppId) of
        not_found -> error(core_not_found);
        Pid -> gen_server:call(Pid, Msg, Timeout)
    end.


%% @doc Sends an asynchronous message to the SipApp's process, 
%% similar to `gen_server:cast/2'.
%% The SipApp's callback module must implement `handle_cast/2'.
-spec cast(app_id(), term()) ->
    ok.

cast(AppId, Msg) ->
    case get_pid(AppId) of
        not_found -> error(core_not_found);
        Pid -> gen_server:cast(Pid, Msg)
    end.


%% @doc Gets the SipApp's process `pid()'.
-spec get_pid(app_id()) -> 
    pid() | not_found.

get_pid(Id) ->
    case nksip_proc:whereis_name({nksip_sipapp, Id}) of
        undefined -> not_found;
        Pid -> Pid
    end.


%% @doc Gets SipApp's first listening port on this transport protocol.
-spec get_port(app_id(), protocol(), ipv4|ipv6) -> 
    inet:port_number() | not_found.

get_port(AppId, Proto, Class) ->
    case nksip_transport:get_listening(AppId, Proto, Class) of
        [{#transport{listen_port=Port}, _Pid}|_] -> Port;
        _ -> not_found
    end.




