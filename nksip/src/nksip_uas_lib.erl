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

%% @doc UAS Process helper functions
%% Look at {@link make}
-module(nksip_uas_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([preprocess/1, response/5]).
-include("nksip.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Preprocess an incoming request.
%% Returns `ignore' if the request is an ACK directed to us, or `{ok, nksip:request()}'
%% in any other case. If performs the following actions:
%% <ul>
%%  <li>Adds rport, received and transport options to Via.</li>
%%  <li>Generates a To Tag candidate.</li>
%%  <li>Extracts the authorized digest users.</li>
%%  <li>Performs strict routing processing.</li>
%%  <li>Updates the request if maddr is present.</li>
%%  <li>Removes first route if it is poiting to us.</li>
%% </ul>
-spec preprocess(nksip:request()) ->
    {ok, nksip:request()} | ignore.

preprocess(#sipmsg{sipapp_id=AppId, call_id=CallId, method=Method, to_tag=ToTag, 
                   transport=Transport, vias=[Via|ViaR], opts=Opts}=Request) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    ViaOpts1 = [{received, nksip_lib:to_binary(Ip)}|Via#via.opts],
    % For UDP, we honor de rport option
    % For connection transports, we force inclusion of remote port to reuse the same
    % connection
    ViaOpts2 = case lists:member(rport, ViaOpts1) of
        false when Proto=:=udp -> ViaOpts1;
        _ -> [{rport, Port} | ViaOpts1 -- [rport]]
    end,
    Via1 = Via#via{opts=ViaOpts2},
    GlobalId = nksip_config:get(global_id),
    Branch = nksip_lib:get_binary(branch, ViaOpts2),
    Opts1 = case ToTag of
        <<>> -> [{to_tag, nksip_lib:hash({GlobalId, Branch})}|Opts];
        _ -> Opts
    end,
    case Method=:='ACK' andalso nksip_lib:hash({GlobalId, Branch})=:=ToTag of
        true -> 
            % We have generated the response this ACK is based on
            ?debug(AppId, CallId, "UAS absorbed own ACK", []),
            ignore;
        false ->
            Request1 = Request#sipmsg{
                vias = [Via1|ViaR],
                auth = nksip_auth:get_authentication(Request),
                opts = Opts1
            },
            {ok, preprocess_route(Request1)}
    end.




%% ===================================================================
%% Internal
%% ===================================================================

%% @doc Generates a new `Response' based on a received `Request'.
-spec response(nksip:request(), nksip:response_code(), [nksip:header()], 
                nksip:body(), nksip_lib:proplist()) -> 
    nksip:response().

response(Req, Code, Headers, Body, Opts) ->
    #sipmsg{
        sipapp_id = AppId, 
        method = Method, 
        from = #uri{domain=FromDomain}, 
        to = To, 
        to_tag = ToTag, 
        headers = ReqHeaders, 
        opts = ReqOpts              % local_host, to_tag
    } = Req, 
    Contacts = nksip_lib:get_value(contact, Opts, []),
    Opts1 = 
        case Method of 
            'INVITE' when Code > 100, Contacts =:= [] ->
                [make_allow, make_supported, make_contact | Opts];
            'INVITE' when Code > 100 ->
                [make_allow, make_supported | Opts];
            _ -> 
                Opts
        end 
        ++
        case nksip_lib:get_value(local_host, ReqOpts) of
            undefined -> [];
            LocalHost -> [{local_host, LocalHost}]
        end,
    HeaderOps = [
        case Code of
            100 ->
                case nksip_parse:header_integers(<<"Timestamp">>, Req) of
                    [Time] -> {single, <<"Timestamp">>, Time};
                    _ -> none
                end;
            _ ->
                none
        end,
        case nksip_lib:get_value(make_www_auth, Opts1) of
            undefined -> none;
            from -> 
                {multi, <<"WWW-Authenticate">>, 
                    nksip_auth:make_response(FromDomain, Req)};
            Realm -> 
                {multi, <<"WWW-Authenticate">>, 
                    nksip_auth:make_response(Realm, Req)}
        end,
        case nksip_lib:get_value(make_proxy_auth, Opts1) of
            undefined -> none;
            from -> 
                {multi, <<"Proxy-Authenticate">>,
                    nksip_auth:make_response(FromDomain, Req)};
            Realm -> 
                {multi, <<"Proxy-Authenticate">>,
                    nksip_auth:make_response(Realm, Req)}
        end,
        case lists:member(make_allow, Opts1) of
            true -> {default_single, <<"Allow">>, nksip_sipapp_srv:allowed(AppId)};
            false -> none
        end,
        case lists:member(make_supported, Opts1) of
            true -> {default_single, <<"Supported">>, ?SUPPORTED};
            false -> none
        end,
        case lists:member(make_accept, Opts1) of
            true -> {default_single, <<"Accept">>, ?ACCEPT};
            false -> none
        end,
        case lists:member(make_date, Opts1) of
            true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                httpd_util:rfc1123_date())};
            false -> none
        end,
        if
            Method =:= 'INVITE', Code > 100, Code < 300 ->
                {multi, <<"Record-Route">>, 
                        proplists:get_all_values(<<"Record-Route">>, ReqHeaders)};
            true ->
                none
        end
    ],
    Headers1 = nksip_headers:update(Headers, HeaderOps),
    % If to_tag is present in Opts1, it takes priority. Used by proxy server
    % when it generates a 408 response after a remote party has already sent a 
    % response
    case nksip_lib:get_binary(to_tag, Opts1) of
        <<>> when Code < 101 ->
            ToTag1 = <<>>,
            ToOpts1 = lists:keydelete(tag, 1, To#uri.ext_opts),
            To1 = To#uri{ext_opts=ToOpts1};
        <<>> ->
            % UAS generated to_tag
            case nksip_lib:get_binary(to_tag, ReqOpts) of
                <<>> ->
                    ToTag1 = ToTag,
                    To1 = To;
                ToTag1 ->
                    To1 = To#uri{ext_opts=[{tag, ToTag1}|To#uri.ext_opts]}
            end;
        ToTag1 ->
            ToOpts1 = lists:keydelete(tag, 1, To#uri.ext_opts),
            To1 = To#uri{ext_opts=[{tag, ToTag1}|ToOpts1]}
    end,
    ContentType = case Body of 
        #sdp{} -> [{<<"application/sdp">>, []}]; 
        _ -> [] 
    end,
    MsgOpts = [make_contact, local_host, reason, stateless],
    Req#sipmsg{
        class = response,
        response = Code,
        to = To1,
        forwards = 70,
        cseq_method = Method,
        routes = [],
        contacts = Contacts,
        headers = Headers1,
        content_type = ContentType,
        body = Body,
        to_tag = ToTag1,
        opts = nksip_lib:extract(Opts1, MsgOpts)
    }.



%% @private Process RFC3261 16.4
-spec preprocess_route(nksip:request()) ->
    nksip:request().

preprocess_route(Request) ->
    Request1 = strict_router(Request),
    Request2 = ruri_has_maddr(Request1),
    remove_local_route(Request2).



% @private If the Request-URI has a value we have placed on a Record-Route header, 
% change it to the last Route header and remove it. This gets back the original 
% RUri "stored" at the end of the Route header when proxing through a strict router
% This could happen if
% - in a previous request, we added a Record-Route header with our ip
% - the response generated a dialog
% - a new in-dialog request has arrived from a strict router, that copied our Record-Route
%   in the ruri
strict_router(#sipmsg{sipapp_id=AppId, ruri=RUri, call_id=CallId, 
                      routes=Routes}=Request) ->
    case 
        nksip_lib:get_value(nksip, RUri#uri.opts) =/= undefined 
        andalso nksip_transport:is_local(AppId, RUri) of
    true ->
        case lists:reverse(Routes) of
            [] ->
                Request;
            [RUri1|RestRoutes] ->
                ?notice(AppId, CallId, 
                        "recovering RURI from strict router request", []),
                Request#sipmsg{ruri=RUri1, routes=lists:reverse(RestRoutes)}
        end;
    false ->
        Request
    end.    


% @private If RUri has a maddr address that corresponds to a local ip and has the 
% same transport class and local port than the transport, change the Ruri to
% this address, default port and no transport parameter
ruri_has_maddr(#sipmsg{
                    sipapp_id = AppId, 
                    ruri = RUri, 
                    transport=#transport{proto=Proto, local_port=LPort}
                } = Request) ->
    case nksip_lib:get_binary(maddr, RUri#uri.opts) of
        <<>> ->
            Request;
        MAddr -> 
            case nksip_transport:is_local(AppId, RUri#uri{domain=MAddr}) of
                true ->
                    case nksip_parse:transport(RUri) of
                        {Proto, _, LPort} ->
                            RUri1 = RUri#uri{
                                port = 0,
                                opts = nksip_lib:delete(RUri#uri.opts, [maddr,transport])
                            },
                            Request#sipmsg{ruri=RUri1};
                        _ ->
                            Request
                    end;
                false ->
                    Request
            end
    end.


%% @private Remove top route if reached
remove_local_route(#sipmsg{sipapp_id=AppId, routes=Routes}=Request) ->
    case Routes of
        [] ->
            Request;
        [Route|RestRoutes] ->
            case nksip_transport:is_local(AppId, Route) of
                true -> Request#sipmsg{routes=RestRoutes};
                false -> Request
            end
    end.


