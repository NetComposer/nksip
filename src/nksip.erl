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
-export([get/3, get/4, put/4, del/3]).
-export([call/2, call/3, cast/2, reply/2, get_pid/1, get_port/3]).

-include("nksip.hrl").

-export_type([app_id/0, id/0, request/0, response/0, transport/0, sipreply/0]).
-export_type([uri/0, user_uri/0, header/0, header_value/0]).
-export_type([scheme/0, protocol/0, method/0, response_code/0, via/0]).
-export_type([call_id/0, cseq/0, tag/0, body/0, uri_set/0, aor/0]).
-export_type([dialog/0, invite/0, subscription/0, token/0, error_reason/0]).



%% ===================================================================
%% Types
%% ===================================================================

% Util types
-type name() :: binary() | string() | atom().
-type value() :: binary() | string() | token() | atom() | integer().


%% Unique Id of each started SipApp
-type app_id() :: term().

%% External request, response, dialog or event id
-type id() :: binary().

%% Parsed SIP Request
-type request() :: #sipmsg{}.

%% Parsed SIP Response
-type response() :: #sipmsg{}.

%% User's response to a request
-type sipreply() :: nksip_reply:sipreply().

%% Transport
-type transport() :: #transport{}.

%% Parsed SIP Uri
-type uri() :: #uri{}.

%% User specified uri
-type user_uri() :: string() | binary() | uri().

%% Parsed SIP Via
-type via() :: #via{}.

%% Token
-type token() :: {name(), [{name(), value()}]}.

%% SIP Generic Header Value
-type header_value() :: value() | uri() | via() | [value() | uri() | via()].

%% SIP Generic Header
-type header() :: {name(), header_value()}.

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


%% SIP Message's Call-ID
-type call_id() :: binary().

%% SIP Message's CSeq
-type cseq() :: pos_integer().

%% Tag in From and To headers
-type tag() :: binary().

%% SIP Message body
-type body() :: binary() | string() | nksip_sdp:sdp() | term().

%% Uri Set used to order proxies
-type uri_set() :: nksip:user_uri() | [nksip:user_uri() | [nksip:user_uri()]].

%% Address of Record
-type aor() :: {Scheme::scheme(), User::binary(), Domain::binary()}.

%% Dialog
-type dialog() :: #dialog{}.

%% Dialog
-type subscription() :: #subscription{}.

%% Dialog
-type invite() :: #invite{}.

%% Reason
-type error_reason() :: 
    {sip|q850, pos_integer()} |
    {sip|q850, pos_integer(), string()|binary()}.


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
%%          <td>NkSIP will try to <i>REGISTER</i> the SipApp with this registrar server
%%          or servers (i.e. "sips:sip2sip.info,sips:other.com"). <br/> 
%%          If the SipApp supports outbound (RFC5626), a new reg_id will be generated 
%%          for each one, a flow will be stablished, and,
%%          if the remote party also supports outbound, keep alive messages will be
%%          sent over each flow.
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
%%          <td>`supported'</td>
%%          <td>`string()|binary()'</td>
%%          <td>`"100rel"'</td>
%%          <td>If present, these tokens will be used in Supported headers instead of
%%          the default supported list, for example
%%          "my_token1, mytoken2, 100rel".</td>
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
%%          option `accept' is used</td>
%%      </tr>
%%  </table>
%%
%% <br/>
-spec start(app_id(), atom(), term(), nksip_lib:optslist()) -> 
	ok | {error, term()}.

start(AppId, Module, Args, Opts) ->
    try
        Opts1 = parse_opts(Opts, []),
        nksip_sup:start_core(AppId, Module, Args, Opts1)
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


%% @doc Gets a value from SipApp's store
-spec get(nksip:app_id(), term(), sync|async) ->
    {ok, term()} | not_found | error.

get(AppId, Key, Sync) ->
    nksip_sipapp_srv:get(AppId, Key, Sync).


%% @doc Gets a value from SipApp's store, using a default if not found
-spec get(nksip:app_id(), term(), term(), sync|async) ->
    {ok, term()} | error.

get(AppId, Key, Default, Sync) ->
    case get(AppId, Key, Sync) of
        not_found -> {ok, Default};
        {ok, Value} -> {ok, Value};
        error -> error
    end.


%% @doc Inserts a value in SipApp's store
-spec put(nksip:app_id(), term(), term(), sync|async) ->
    ok | error.

put(AppId, Key, Value, Sync) ->
    nksip_sipapp_srv:put(AppId, Key, Value, Sync).


%% @doc Deletes a value from SipApp's store
-spec del(nksip:app_id(), term(), sync|async) ->
    ok | error.

del(AppId, Key, Sync) ->
    nksip_sipapp_srv:del(AppId, Key, Sync).


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
    nksip_sipapp_srv:get_pid(Id).


%% @doc Gets SipApp's first listening port on this transport protocol.
-spec get_port(app_id(), protocol(), ipv4|ipv6) -> 
    inet:port_number() | not_found.

get_port(AppId, Proto, Class) ->
    case nksip_transport:get_listening(AppId, Proto, Class) of
        [{#transport{listen_port=Port}, _Pid}|_] -> Port;
        _ -> not_found
    end.



%% ===================================================================
%% Private
%% ===================================================================


parse_transports([], Acc) ->
    lists:reverse(Acc);

parse_transports([Transport|Rest], Acc) ->
    case Transport of
        {Scheme, Ip, Port} -> TOpts = [];
        {Scheme, Ip, Port, TOpts} when is_list(TOpts) -> ok;
        _ -> Scheme=Ip=Port=TOpts=throw(invalid_transport)
    end,
    case 
        (Scheme==udp orelse Scheme==tcp orelse 
         Scheme==tls orelse Scheme==sctp orelse
         Scheme==ws  orelse Scheme==wss)
    of
        true -> ok;
        false -> throw(invalid_transport)
    end,
    Ip1 = case Ip of
        all ->
            {0,0,0,0};
        all6 ->
            {0,0,0,0,0,0,0,0};
        _ when is_tuple(Ip) ->
            case catch inet_parse:ntoa(Ip) of
                {error, _} -> throw(invalid_transport);
                {'EXIT', _} -> throw(invalid_transport);
                _ -> Ip
            end;
        _ ->
            case catch nksip_lib:to_ip(Ip) of
                {ok, PIp} -> PIp;
                _ -> throw(invalid_transport)
            end
    end,
    Port1 = case Port of
        any -> 0;
        _ when is_integer(Port), Port >= 0 -> Port;
        _ -> throw(invalid_transport)
    end,
    parse_transports(Rest, [{Scheme, Ip1, Port1, TOpts}|Acc]).


parse_opts([], Opts) ->
    Opts;

parse_opts([Term|Rest], Opts) ->
    Opts1 = case Term of

        % Startup options
        {transports, Transports} ->
            [{transports, parse_transports(Transports, [])}|Opts];
        {certfile, File} ->
            [{certfile, nksip_lib:to_list(File)}|Opts];
        {keyfile, File} ->
            [{keyfile, nksip_lib:to_list(File)}|Opts];
        {register, Register} ->
            case nksip_parse:uris(Register) of
                error -> throw(invalid_register);
                Uris -> [{register, Uris}|Opts]
            end;
        {register_expires, Expires} when is_integer(Expires), Expires>0 ->
            [{register_expires, Expires}|Opts];
        registrar ->
            [registrar|Opts];
        {supported, Supported} ->
            case nksip_parse:tokens(Supported) of
                error -> throw({invalid, supported});
                Tokens -> [{supported, [T||{T, _}<-Tokens]}|Opts]
            end;
        {allow, Allow} ->
            case nksip_parse:tokens(Allow) of
                error -> throw({invalid, allow});
                Tokens -> [{allow, [A||{A, _}<-Tokens]}|Opts]
            end;
        {accept, Accept} ->
            case nksip_parse:tokens(Accept) of
                error -> throw({invalid, accept});
                Tokens -> [{accept, [A||{A, _}<-Tokens]}|Opts]
            end;
        {events, Event} ->
            case nksip_parse:tokens(Event) of
                error -> throw({invalid, events});
                Tokens -> [{events, [T||{T, _}<-Tokens]}|Opts]
            end;
        
        % Default headers and options
        {from, From} ->
            case nksip_parse:uris(From) of
                [Uri] -> [{from, Uri}|Opts];
                _ -> throw({invalid, from}) 
            end;
        {route, Route} ->
            case nksip_parse:uris(Route) of
                error -> throw({invalid, route});
                Uris -> [{route, Uris}|Opts]
            end;
        {pass, Pass} ->
            [{pass, Pass}|Opts];
        {local_host, Host} ->
            [{local_host, nksip_lib:to_host(Host)}|Opts];
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    [{local_host6, nksip_lib:to_host(HostIp6, true)}|Opts];
                error -> 
                    [{local_host6, nksip_lib:to_binary(Host)}|Opts]
            end;
        no_100 ->
            [no_100|Opts];

        % Unknown options
        {Name, Value} ->
            case nksip_config:parse_config(Name, Value) of
                {ok, Value1} -> [{Name, Value1}|Opts];
                {error, _Error} -> throw({invalid, Name})
            end;
        Name ->
            throw({invalid, Name})
    end,
    parse_opts(Rest, Opts1).