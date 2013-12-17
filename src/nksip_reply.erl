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
%%   <tr><td>`{ringing, Body}'</td><td>180</td><td></td></tr>
%%   <tr><td>`session_progress'</td><td>183</td><td></td></tr>
%%   <tr><td>`{session_progress, Body}'</td><td>183</td><td></td></tr>
%%   <tr><td>`rel_ringing'</td><td>180</td>
%%       <td><i>Reliable responses</i> will be used</td></tr>
%%   <tr><td>`{rel_ringing, Body}'</td><td>180</td>
%%       <td><i>Reliable responses</i> will be used</td></tr>
%%   <tr><td>`rel_session_progress'</td><td>183</td>
%%       <td><i>Reliable responses</i> will be used</td></tr>
%%   <tr><td>`{rel_session_progress, Body}'</td>
%%        <td>183</td><td><i>Reliable responses</i> will be used</td></tr>
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
%%   <tr><td>`accepted'</td><td>202</td><td></td></tr>
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
%%   <tr><td>`conditional_request_failed</td><td>412</td><td></td></tr>
%%   <tr><td>`too_large'</td><td>413</td><td></td></tr>
%%   <tr><td>`{unsupported_media_type, Types}'</td><td>415</td>
%%       <td>Generates a new `Accept' header using `Types'</td></tr>
%%   <tr><td>`{unsupported_media_encoding, Types}'</td><td>415</td>
%%       <td>Generates a new `Accept-Encoding' header using `Types'</td></tr>
%%   <tr><td>`unsupported_uri_scheme'</td><td>416</td><td></td></tr>
%%   <tr><td>`{bad_extension, Extensions}'</td><td>420</td>
%%       <td>Generates a new `Unsupported' header using `Extensions'</td></tr>
%%   <tr><td>`{extension_required, Extension}'</td><td>421</td>
%%       <td>Generates a new `Require' header using `Extension'</td></tr>
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
%%   <tr><td>`bad_event'</td><td>489</td><td></td></tr>
%%   <tr><td>`request_pending'</td><td>491</td><td></td></tr>
%%   <tr><td>`internal'</td><td>500</td><td></td></tr>
%%   <tr><td>`{internal, Text}'</td><td>500</td>
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
%%  <li>`{reason_phrase, Text::binary()}': changes the default response line to `Text'.</li>
%%  <li>`{make_www_auth, Realm::from|binary()}': a <i>WWW-Authenticate</i>
%%       header will be generated for this `Realm' (see 
%%       {@link nksip_auth:make_response/2}).</li>
%%  <li>`{make_proxy_auth, Realm::from|binary()}': a <i>Proxy-Authenticate</i> will be 
%%       generated for this `Realm'.</li>
%%  <li>`{expires, non_neg_integer()': generates a <i>Event</i> header.</li>
%%  <li><code>{reason, {@link nksip:error_reason()}}</code>: 
%%       generates a <i>Reason</i> header.</li>
%%  <li><code>{service_route, {@link nksip:user_uri()}}</code>: 
%%       generates a <i>Service-Route</i> header, only for 2xx to REGISTER</li>
%% </ul>

-module(nksip_reply).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([reply/3, reqreply/1]).

-export_type([sipreply/0]).


%% ===================================================================
%% Types
%% ===================================================================

-type sipreply() ::
    ringing | {ringing, nksip:body()} | 
    session_progress | {session_progress, nksip:body()} |
    rel_ringing | {rel_ringing, nksip:body()} | 
    rel_session_progress | {rel_session_progress, nksip:body()} |
    ok | {ok, [nksip:header()]} | {ok, [nksip:header()], nksip:body()} | 
    {ok, [nksip:header()], nksip:body(), nksip_lib:proplist()} | 
    answer | {answer, [nksip:header()]} | {answer, [nksip:header()], nksip:body()} | 
    {answer, [nksip:header()], nksip:body(), nksip_lib:proplist()} | 
    accepted | 
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
    conditional_request_failed |
    too_large |
    {unsupported_media_type, Types::binary()} | 
    {unsupported_media_encoding, Types::binary()} |
    unsupported_uri_scheme | 
    {bad_extension, Exts::binary()} |
    {extension_required, Exts::binary} |
    {interval_too_brief, Min::binary()} |
    temporarily_unavailable |
    no_transaction |
    loop_detected | 
    too_many_hops |
    ambiguous |
    busy |
    request_terminated |
    {not_acceptable, Reason::binary()} |
    bad_event |
    request_pending |
    internal | {internal, Text::binary()} |
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

%% @doc Generates a new SIP response and send options using helper replies.
%% Currently recognized replies are described in this module.
%% See {@link nksip_uas_lib:response/5}.
-spec reply(nksip:request(), nksip:sipreply()|#reqreply{}, nksip_lib:proplist()) -> 
    {nksip:response(), nksip_lib:proplist()}.

reply(Req, #reqreply{}=ReqReply, AppOpts) ->
    #sipmsg{app_id=AppId, call_id=CallId} = Req,
    #reqreply{code=Code, headers=Headers, body=Body, opts=Opts} = ReqReply,
    case nksip_lib:get_value(contact, Opts, []) of
        [] ->
            response(Req, Code, Headers, Body, Opts, AppOpts);
        ContactSpec ->
            case nksip_parse:uris(ContactSpec) of
                error -> 
                    ?warning(AppId, CallId, "UAS returned invalid contact: ~p", 
                            [ContactSpec]),
                    Opts1 = [{reason_phrase, <<"Invalid SipApp Response">>}],
                    response(Req, 500, [], <<>>, Opts1, AppOpts);
                Contacts ->
                    Opts1 = [{contact, Contacts}],
                    response(Req, Code, Headers, Body, Opts1, AppOpts)
            end
    end;

reply(#sipmsg{app_id=AppId, call_id=CallId}=Req, SipReply, AppOpts) -> 
    case nksip_reply:reqreply(SipReply) of
        #reqreply{} = ReqReply -> 
            ok;
        error -> 
            ?warning(AppId, CallId, "Invalid sipreply: ~p, ~p", 
                            [SipReply, erlang:get_stacktrace()]),
            ReqReply = reqreply({internal, <<"Invalid SipApp Response">>})
    end,
    reply(Req, ReqReply, AppOpts).


%% @private Generates an `#reqreply{}' from an `user_sipreply()' like 
%% `ringing', `invalid_Req', etc. (see {@link //nksip})
-spec reqreply(sipreply()|#reqreply{}) ->
    #reqreply{} | error.

reqreply(#reqreply{}=Reply) ->
    Reply;
reqreply(ringing) ->
    #reqreply{code=180};
reqreply({ringing, Body}) ->
    #reqreply{code=180, body=Body};
reqreply(rel_ringing) ->
    #reqreply{code=180, opts=[make_100rel]};
reqreply({rel_ringing, Body}) ->
    #reqreply{code=180, body=Body, opts=[make_100rel]};
reqreply(session_progress) ->
    #reqreply{code=183};
reqreply({session_progress, Body}) ->
    #reqreply{code=183, body=Body};
reqreply(rel_session_progress) ->
    #reqreply{code=183, opts=[make_100rel]};
reqreply({rel_session_progress, Body}) ->
    #reqreply{code=183, body=Body, opts=[make_100rel]};
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
reqreply(accepted) ->
    #reqreply{code=202};
reqreply({redirect, RawContacts}) ->
    case nksip_parse:uris(RawContacts) of
        error -> error;
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
reqreply(conditional_request_failed) ->
    #reqreply{code=412};
reqreply(too_large) ->
    #reqreply{code=413};
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
reqreply({extension_required, Exts}) -> 
    #reqreply{code=421, opts=[{require, Exts}]};
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
reqreply(bad_event) ->
    #reqreply{code=489};
reqreply(request_pending) ->
    #reqreply{code=491};
reqreply(internal) ->
    #reqreply{code=500};
reqreply({internal, Text}) ->
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
    #reqreply{code=Code, opts=[{reason_phrase, Text}]};
reqreply({Code, Headers}) when is_integer(Code), is_list(Headers) ->
    #reqreply{code=Code, headers=Headers};
reqreply({Code, Headers, Body}) when is_integer(Code), is_list(Headers) ->
    #reqreply{code=Code, headers=Headers, body=Body};
reqreply({Code, Headers, Body, Opts}) when is_integer(Code), is_list(Headers), 
    is_list(Opts) ->
    #reqreply{code=Code, headers=Headers, body=Body, opts=Opts};
reqreply(_Other) ->
    error.




%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec helper_debug(#reqreply{}, binary()) ->
    #reqreply{}.

helper_debug(#reqreply{opts=Opts}=SipReply, Text) ->
    SipReply#reqreply{opts=[{reason_phrase, Text}, make_date|Opts]}.


%% @private
-spec response(nksip:request(), nksip:response_code(), [nksip:header()], 
                nksip:body(), nksip_lib:proplist(), nksip_lib:proplist()) -> 
    {nksip:response(), nksip_lib:proplist()}.

response(Req, Code, Headers, Body, Opts, AppOpts) ->
    case nksip_uas_lib:response(Req, Code, Headers, Body, Opts, AppOpts) of
        {ok, Resp, RespOpts} ->
            {Resp, RespOpts};
        {error, Error} ->
            lager:error("Error procesing response {~p,~p,~p,~p}: ~p",
                        [Code, Headers, Body, Opts, Error]),
            case nksip_uas_lib:response(Req, 500, [], <<>>, [], AppOpts) of
                {ok, Resp, RespOpts} -> {Resp, RespOpts};
                {error, Error} -> error(Error)
            end
    end.
