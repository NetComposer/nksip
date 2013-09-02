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

%% @doc User Response generation functions.
%%
%% This module offers helper functions to easy the generation of common SIP responses.
%% Currently the following replies are recognized:
%%
%% <table border="1">
%%   <tr><th>Response</th><th>Code</th><th>Comments</th></tr>
%%   <tr><td>`ringing'</td><td>180</td><td></td></tr>
%%   <tr><td>`session_progress'</td><td>183</td><td></td></tr>
%%   <tr><td>`ok'</td><td>200</td><td></td></tr>
%%   <tr><td>`{ok, [Header]}'</td><td>200</td>
%%       <td>Response will include provided headers</td></tr>
%%   <tr><td>`{ok, [Header] Body}'</td><td>200</td>
%%       <td>Response will include provided headers and body</td></tr>
%%   <tr><td>`{ok, [Header] Body, Options}'</td><td>200</td>
%%       <td>Response will include provided headers and body, allows options</td></tr>
%%   <tr><td>`answer'</td><td>200</td><td></td></tr>
%%   <tr><td>`{answer, [Header]}'</td><td>200</td>
%%       <td>Response will include provided headers</td></tr>
%%   <tr><td>`{answer, [Header] Body}'</td><td>200</td>
%%       <td>Response will include provided headers and body</td></tr>
%%   <tr><td>`{answer, [Header] Body, Options}'</td><td>200</td>
%%       <td>Response will include provided headers and body allows options</td></tr>
%%   <tr><td>`{redirect, [Contact]}'</td><td>300</td>
%%       <td>Generates `Contact' headers</td></tr>
%%   <tr><td>`{redirect_permanent, Contact}'</td><td>301</td>
%%       <td>Generates a `Contact' header</td></tr>
%%   <tr><td>`{redirect_temporary, Contact}'</td><td>302</td>
%%       <td>Generates a `Contact' header</td></tr>
%%   <tr><td>`invalid_request'</td><td>400</td><td></td></tr>
%%   <tr><td>`{invalid_request, Text}'</td><td>400</td>
%%       <td>`Text' will be used in SIP reason line</td></tr>
%%   <tr><td>`authenticate'</td><td>401</td>
%%        <td>Generates a new `WWW-Authenticate' header, using current `From' domain 
%%            as `Realm'</td></tr>
%%   <tr><td>`{authenticate, Realm}'</td><td>401</td>
%%       <td>Generates a valid new `WWW-Authenticate' header, using `Realm'</td></tr>
%%   <tr><td>`forbidden'</td><td>403</td><td></td></tr>
%%   <tr><td>`{forbidden, Text}'</td><td>403</td>
%%       <td>`Text' will be used in SIP reason line</td></tr>
%%   <tr><td>`not_found'</td><td>404</td><td></td></tr>
%%   <tr><td>`{not_found, Text}'</td><td>404</td>
%%       <td>`Text' will be used in SIP reason line</td></tr>
%%   <tr><td>`{method_not_allowed, Methods}'</td><td>405</td>
%%       <td>Generates an `Allow' header using `Methods'</td></tr>
%%   <tr><td>`proxy_authenticate'</td><td>407</td>
%%       <td>Generates a valid new `Proxy-Authenticate' header, using current `From' 
%%           domain as `Realm'</td></tr>
%%   <tr><td>`{proxy_authenticate, Realm}'</td>
%%       <td>407</td><td>Generates a valid new `Proxy-Authenticate' header, 
%%                       using `Realm'</td></tr>
%%   <tr><td>`timeout'</td><td>408</td><td></td></tr>
%%   <tr><td>`{timeout, Text}'</td><td>408</td>
%%       <td>`Text' will be used in SIP reason line</td></tr>
%%   <tr><td>`{unsupported_media_type, Types}'</td><td>415</td>
%%       <td>Generates a new `Accept' header using `Types'</td></tr>
%%   <tr><td>`{unsupported_media_encoding, Types}'</td><td>415</td>
%%       <td>Generates a new `Accept-Encoding' header using `Types'</td></tr>
%%   <tr><td>`unsupported_uri_scheme'</td><td>416</td><td></td></tr>
%%   <tr><td>`{bad_extension, Extensions}'</td><td>420</td>
%%       <td>Generates a new `Unsupported' header using `Extensions'</td></tr>
%%   <tr><td>`{interval_too_brief, Time}'</td><td>423</td>
%%        <td>Generates a new `Min-Expires' header using `Time'</td></tr>
%%   <tr><td>`temporarily_unavailable'</td><td>480</td><td></td></tr>
%%   <tr><td>`no_transaction'</td><td>481</td><td></td></tr>
%%   <tr><td>`loop_detected'</td><td>482</td><td></td></tr>
%%   <tr><td>`too_many_hops'</td><td>483</td><td></td></tr>
%%   <tr><td>`ambiguous'</td><td>485</td><td></td></tr>
%%   <tr><td>`busy'</td><td>486</td><td></td></tr>
%%   <tr><td>`request_terminated'</td><td>487</td><td></td></tr>
%%   <tr><td>`{not_acceptable, Reason}'</td><td>488</td>
%%       <td>Generates a new `Warning' header using `Reason'</td></tr>
%%   <tr><td>`request_pending'</td><td>491</td><td></td></tr>
%%   <tr><td>`internal_error'</td><td>500</td><td></td></tr>
%%   <tr><td>`{internal_error, Text}'</td><td>500</td>
%%       <td>Text will be used in SIP first line</td></tr>
%%   <tr><td>`busy_eveywhere'</td><td>600</td><td></td></tr>
%%   <tr><td>`decline'</td><td>603</td><td></td></tr>
%%   <tr><td>`Code'</td><td>`Code'</td><td></td></tr>
%%   <tr><td>`{Code, [Header]}'</td><td>`Code'</td>
%%        <td>Will include headers in the response</td></tr>
%%   <tr><td>`{Code, [Header], Body}'</td><td>`Code'</td>
%%        <td>Will include headers and body in response</td></tr>
%%   <tr><td>`{Code, [Header], Body, Options}'</td><td>`Code'</td>
%%       <td>Will include headers and body in response, using options</td></tr>
%% </table> 
%% <br/>
%% With the following types:
%% <table border="1">
%%   <tr><th>Parameter</th><th>Type</th></tr>
%%   <tr><td>`Code'</td><td>{@link nksip:response_code()}</td></tr>
%%   <tr><td>`Header'</td><td>{@link nksip:header()}</td></tr>
%%   <tr><td>`Body'</td><td>{@link nksip:body()}</td></tr>
%%   <tr><td>`Options'</td><td>{@link nksip_lib:proplist()}</td></tr>
%%   <tr><td>`Text'</td><td>`binary()'</td></tr>
%%   <tr><td>`Realm'</td><td>`binary()'</td></tr>
%%   <tr><td>`Methods'</td><td>`binary()'</td></tr>
%%   <tr><td>`Types'</td><td>`binary()'</td></tr>
%%   <tr><td>`Extensions'</td><td>`binary()'</td></tr>
%%   <tr><td>`Min'</td><td>`binary()'</td></tr>
%% </table> 
%% <br/>
%% Some previous replies allow including options. The recognized options are:
%% <ul>
%%  <li>`make_allow': if present generates an <i>Allow</i> header.</li>
%%  <li>`make_supported': if present generates a <i>Supported</i> header.</li>
%%  <li>`make_accept': if present generates an <i>Accept</i> header.</li>
%%  <li>`make_date': if present generates a <i>Date</i> header.</li>
%%  <li>`make_contact': if present generates a <i>Contact</i> header.</li>
%%  <li>`{local_host, Host::binary()}': uses this Host instead of the default one for 
%%      <i>Contact</i>, <i>Record-Route</i>, etc.</li>
%%  <li>`{contact, [nksip:user_uri()]}': adds one or more `Contact' headers.</li>
%%  <li>`{reason, Text::binary()}': changes the default response line to `Text'.</li>
%%  <li>`{make_www_auth, Realm::from|binary()}': a <i>WWW-Authenticate</i>
%%       header will be generated for this `Realm' (see 
%%       {@link nksip_auth:make_response/2}).</li>
%%  <li>`{make_proxy_auth, Realm::from|binary()}': a <i>Proxy-Authenticate</i> will be 
%%       generated for this `Realm'.</li>
%% </ul>

-module(nksip_reply).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([reply/2, error/2, error/3, reqreply/1]).

-export_type([sipreply/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type sipreply() ::
    ringing | session_progress | 
    ok | {ok, [nksip:header()]} | {ok, [nksip:header()], nksip:body()} | 
    {ok, [nksip:header()], nksip:body(), nksip_lib:proplist()} | 
    answer | {answer, [nksip:header()]} | {answer, [nksip:header()], nksip:body()} | 
    {answer, [nksip:header()], nksip:body(), nksip_lib:proplist()} | 
    {redirect, [nksip:user_uri()]} | 
    {redirect_permanent, nksip:user_uri()} | 
    {redirect_temporary, nksip:user_uri()} |
    invalid_request | {invalid_request, Text::binary()} | 
    authenticate | {authenticate, Realm::binary()} |
    forbidden | {forbidden, Text::binary()} |
    not_found | {not_found, Text::binary()} |
    {method_not_allowed, Methods::binary()} |
    proxy_authenticate | {proxy_authenticate, Realm::binary()} |
    timeout | {timeout, Text::binary()} | 
    {unsupported_media_type, Types::binary()} | 
    {unsupported_media_encoding, Types::binary()} |
    unsupported_uri_scheme | 
    {bad_extension, Exts::binary()} |
    {interval_too_brief, Min::binary()} |
    temporarily_unavailable |
    no_transaction |
    loop_detected | 
    too_many_hops |
    ambiguous |
    busy |
    request_terminated |
    {not_acceptable, Reason::binary()} |
    request_pending |
    internal_error | {internal_error, Text::binary()} |
    service_unavailable |
    busy_eveywhere |
    decline |
    nksip:response_code() | 
    {nksip:response_code(), binary()} | 
    {nksip:response_code(), [nksip:header()]} | 
    {nksip:response_code(), [nksip:header()], nksip:body()} | 
    {nksip:response_code(), [nksip:header()], nksip:body(), nksip_lib:proplist()}.


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Generates a new SIP response using helper replies.
%% Currently recognized replies are describes {@link nksip_reply. here}.
%%
%% A <i>Timestamp</i> header will be added if it was present in `Request' and 
%% response code is 100. A <i>To</i> tag will be set if parameter 
%% `{to_tag, Tag}' is present in the request's options.
%% If the response is for an INVITE request, options `make_allow', `make_supported'
%% and `make_contact' will be added automatically, and (if code is 101-299) all
%% <i>Record-Route</i> headers from the request will be copied in the response.
-spec reply(nksip:request(), nksip:sipreply()|#reqreply{}) -> 
    nksip:response().

reply(#sipmsg{app_id=AppId, call_id=CallId}=Req, 
            #reqreply{code=Code, headers=Headers, body=Body, opts=Opts}) ->
    case nksip_lib:get_value(contact, Opts, []) of
        [] ->
            nksip_uas_lib:response(Req, Code, Headers, Body, Opts);
        ContactSpec ->
            case nksip_parse:uris(ContactSpec) of
                [] -> 
                    ?warning(AppId, CallId, "UAS returned invalid contact: ~p", 
                            [ContactSpec]),
                    error(Req, 500, <<"Invalid SipApp Response">>);
                Contacts ->
                    Opts1 = [{contact, Contacts}|Opts],
                    nksip_uas_lib:response(Req, Code, Headers, Body, Opts1)
            end
    end;

reply(#sipmsg{app_id=AppId, call_id=CallId}=Req, SipReply) -> 
    case nksip_reply:reqreply(SipReply) of
        #reqreply{} = SipReply1 -> 
            ok;
        error -> 
            ?warning(AppId, CallId, "Invalid sipreply: ~p, ~p", 
                            [SipReply, erlang:get_stacktrace()]),
            SipReply1 = reqreply({internal_error, <<"Invalid Response">>})
    end,
    reply(Req, SipReply1).


%% @private Generates an `#reqreply{}' from an `user_sipreply()' like 
%% `ringing', `invalid_Req', etc. (see {@link //nksip})
-spec reqreply(sipreply()|#reqreply{}) ->
    #reqreply{} | error.

reqreply(#reqreply{}=Reply) ->
    Reply;
reqreply(ringing) ->
    #reqreply{code=180};
reqreply(session_progress) ->
    #reqreply{code=183};
reqreply(ok) ->
    #reqreply{code=200};
reqreply({ok, Headers}) ->
    #reqreply{code=200, headers=Headers};
reqreply({ok, Headers, Body}) ->
    #reqreply{code=200, headers=Headers, body=Body};
reqreply({ok, Headers, Body, Opts}) ->
    #reqreply{code=200, headers=Headers, body=Body, opts=Opts};
reqreply(answer) ->
    #reqreply{code=200};
reqreply({answer, Headers}) ->
    #reqreply{code=200, headers=Headers};
reqreply({answer, Headers, Body}) ->
    #reqreply{code=200, headers=Headers, body=Body};
reqreply({answer, Headers, Body, Opts}) ->
    #reqreply{code=200, headers=Headers, body=Body, opts=Opts};
reqreply({redirect, RawContacts}) ->
    case nksip_parse:uris(RawContacts) of
        [] -> error;
        Contacts -> #reqreply{code=300, opts=[{contact, Contacts}]}
    end;
reqreply({redirect_permanent, RawContact}) ->
    case nksip_parse:uris(RawContact) of
        [Contact] -> #reqreply{code=301, opts=[{contact, [Contact]}]};
        _ -> error
    end;
reqreply({redirect_temporary, RawContact}) ->
    case nksip_parse:uris(RawContact) of
        [Contact] -> #reqreply{code=302, opts=[{contact, [Contact]}]};
        _ -> error
    end;
reqreply(invalid_request) ->
    #reqreply{code=400};
reqreply({invalid_request, Text}) ->
    helper_debug(#reqreply{code=400}, Text);
reqreply(authenticate) ->
    #reqreply{code=401, opts=[make_allow, {make_www_auth, from}]};
reqreply({authenticate, Realm}) ->
    #reqreply{code=401, opts=[make_allow, {make_www_auth, Realm}]};
reqreply(forbidden) ->
    #reqreply{code=403};
reqreply({forbidden, Text}) -> 
    helper_debug(#reqreply{code=403}, Text);
reqreply(not_found) -> 
    #reqreply{code=404};
reqreply({not_found, Text}) -> 
    helper_debug(#reqreply{code=404}, Text);
reqreply({method_not_allowed, Methods}) -> 
    Methods1 = nksip_lib:to_binary(Methods), 
    #reqreply{
        code = 405, 
        headers = nksip_headers:new([{single, <<"Allow">>, Methods1}])
    };
reqreply(proxy_authenticate) ->
    #reqreply{code=407, opts=[make_allow, {make_proxy_auth, from}]};
reqreply({proxy_authenticate, Realm}) ->
    #reqreply{code=407, opts=[make_allow, {make_proxy_auth, Realm}]};
reqreply(timeout) ->
    #reqreply{code=408};
reqreply({timeout, Text}) ->
    helper_debug(#reqreply{code=408}, Text);
reqreply({unsupported_media_type, Types}) ->
    Types1 = nksip_lib:to_binary(Types), 
    #reqreply{
        code=415, 
        headers = nksip_headers:new([{single, <<"Accept">>, Types1}])
    };
reqreply({unsupported_media_encoding, Types}) ->
    Types1 = nksip_lib:to_binary(Types),    
    #reqreply{
        code = 415, 
        headers = nksip_headers:new([{single, <<"Accept-Encoding">>, Types1}])
    };
reqreply(unsupported_uri_scheme) -> 
    #reqreply{code=416};
reqreply({bad_extension, Exts}) -> 
    Exts1 = nksip_lib:to_binary(Exts),  
    #reqreply{
        code = 420, 
        headers = nksip_headers:new([{single, <<"Unsupported">>, Exts1}])
    };
reqreply({interval_too_brief, Min}) ->
    Min1 = nksip_lib:to_binary(Min),    
    #reqreply{
        code = 423, 
        headers = nksip_headers:new([{single, <<"Min-Expires">>, Min1}])
    };
reqreply(temporarily_unavailable) ->
    #reqreply{code=480};
reqreply(no_transaction) ->
    #reqreply{code=481};
reqreply(loop_detected) ->
    #reqreply{code=482};
reqreply(too_many_hops) -> 
    #reqreply{code=483};
reqreply(ambiguous) ->
    #reqreply{code=485};
reqreply(busy) ->
    #reqreply{code=486};
reqreply(request_terminated) ->
    #reqreply{code=487};
reqreply({not_acceptable, Reason}) ->
    #reqreply{code=488, headers=[{<<"Warning">>, nksip_lib:to_binary(Reason)}]};
reqreply(request_pending) ->
    #reqreply{code=491};
reqreply(internal_error) ->
    #reqreply{code=500};
reqreply({internal_error, Text}) ->
    helper_debug(#reqreply{code=500}, Text);
reqreply(service_unavailable) ->
    #reqreply{code=503};
reqreply({service_unavailable, Text}) ->
    helper_debug(#reqreply{code=503}, Text);
reqreply(busy_eveywhere) ->
    #reqreply{code=600};
reqreply(decline) ->
    #reqreply{code=603};
reqreply(Code) when is_integer(Code) ->
    #reqreply{code=Code};
reqreply({Code, Text}) when is_integer(Code), is_binary(Text) ->
    #reqreply{code=Code, opts=[{reason, Text}]};
reqreply({Code, Headers}) when is_integer(Code), is_list(Headers) ->
    #reqreply{code=Code, headers=Headers};
reqreply({Code, Headers, Body}) when is_integer(Code), is_list(Headers) ->
    #reqreply{code=Code, headers=Headers, body=Body};
reqreply({Code, Headers, Body, Opts}) when is_integer(Code), is_list(Headers), 
    is_list(Opts) ->
    #reqreply{code=Code, headers=Headers, body=Body, opts=Opts};
reqreply(_Other) ->
    error.



%% @private Generares a new `Response' for a `Request' with `ResponseCode', representing
%% an error. A <i>Date</i> header will be generated.
-spec error(nksip:request(), nksip:response_code()) -> 
    nksip:response().

error(Req, RespCode) ->
    reply(Req, #reqreply{code=RespCode, opts=[make_date]}).


%% @private Generares a new `Response' for a `Request' with `ResponseCode', representing
%% an error, and changing the SIP response description text to `Debug'.  
%% A <i>Date</i> header will be generated.
-spec error(nksip:request(), nksip:response_code(), string() | binary()) -> 
    nksip:response().

error(Req, RespCode, Debug) ->
    reply(Req, #reqreply{code=RespCode, opts=[{reason, Debug}, make_date]}).




%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec helper_debug(#reqreply{}, binary()) ->
    #reqreply{}.

helper_debug(#reqreply{opts=Opts}=SipReply, Text) ->
    SipReply#reqreply{opts=[{reason, Text}, make_date|Opts]}.


