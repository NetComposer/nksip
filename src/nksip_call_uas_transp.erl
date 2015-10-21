%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc UAS Transport Layer
-module(nksip_call_uas_transp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_response/2, resend_response/2]).
    
-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends a new `Response'.
-spec send_response(nksip:response(), nksip:optslist()) ->
    {ok, nksip:response()} | {error, term()}.

send_response(#sipmsg{class={resp, Code, _Reason}}=Resp, Opts) ->
    #sipmsg{
        srv_id = SrvId, 
        call_id = CallId,
        vias = [Via|_],
        cseq = {_, Method},
        nkport = NkPort
    } = Resp,
    #via{transp=ViaTransp, domain=ViaDomain, port=ViaPort, opts=ViaOpts} = Via,
    #nkport{transp=RTransp, remote_ip=RIp, remote_port=RPort} = NkPort,
    % {ok, RIp} = nklib_util:to_ip(nklib_util:get_value(<<"received">>, ViaOpts)),
    ViaRPort = lists:keymember(<<"rport">>, 1, ViaOpts),
    TranspSpec = case RTransp of
        udp ->
            case nklib_util:get_binary(<<"maddr">>, ViaOpts) of
                <<>> when ViaRPort -> 
                    [{nksip_protocol, udp, RIp, RPort}];
                <<>> -> 
                    [{nksip_protocol, RIp, ViaPort}];
                MAddr -> 
                    [#uri{scheme=sip, domain=MAddr, port=ViaPort}]   
            end;
        _ ->
            % We cannot use NkPort here, because it used also in stateless
            % proxies, they erase the socket.
            UriOpt = {<<"transport">>, nklib_util:to_binary(ViaTransp)},
            [
                {current, {nksip_protocol, RTransp, RIp, RPort}},
                #uri{scheme=sip, domain=ViaDomain, port=ViaPort, opts=[UriOpt]}
            ]
    end,
    RouteBranch = nklib_util:get_binary(<<"branch">>, ViaOpts),
    GlobalId = nksip_config_cache:global_id(),
    RouteHash = <<"NkQ", (nklib_util:hash({GlobalId, SrvId, RouteBranch}))/binary>>,
    PreFun = make_pre_fun(RouteHash, Opts),
    SrvId:nks_sip_debug(SrvId, CallId, {send_response, Method, Code}),
    Return = nksip_util:send(SrvId, TranspSpec, Resp, PreFun, Opts),
    SrvId:nks_sip_transport_uas_sent(Resp),
    Return.


%% @doc Resends a previously sent response to the same ip, port and protocol.
-spec resend_response(Resp::nksip:response(), nksip:optslist()) ->
    {ok, nksip:response()} | {error, term()}.

resend_response(#sipmsg{class={resp, Code, _}, nkport=#nkport{}=NkPort}=Resp, Opts) ->
    #sipmsg{srv_id=SrvId, cseq={_, Method}, call_id=CallId} = Resp,
    Return = nksip_util:send(SrvId, [NkPort], Resp, none, Opts),
    SrvId:nks_sip_debug(SrvId, CallId, {sent_response, Method, Code}),
    Return;

resend_response(Resp, Opts) ->
    ?call_info("Called resend_response/2 without transport", []),
    send_response(Resp, Opts).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec make_pre_fun(binary(), nksip:optslist()) ->
    function().

make_pre_fun(RouteHash, Opts) ->
    fun(Resp, NkPort) ->
        #sipmsg{
            srv_id = SrvId,
            to = {To, _},
            headers = Headers,
            contacts = Contacts, 
            body = Body
        }= Resp,
        #nkport{
            transp = Transp, 
            listen_ip = ListenIp, 
            listen_port = ListenPort
        } = NkPort,
        ListenHost = nksip_util:get_listenhost(SrvId, ListenIp, Opts),
        % ?call_debug("UAS listenhost is ~s", [ListenHost]),
        Scheme = case Transp==tls andalso lists:member(secure, Opts) of
            true -> sips;
            _ -> sip
        end,
        Contacts1 = case Contacts==[] andalso lists:member(contact, Opts) of
            true ->
                [nksip_util:make_route(Scheme, Transp, ListenHost, 
                                            ListenPort, To#uri.user, [])];
            false ->
                Contacts
        end,
        UpdateRoutes = fun(#uri{user=User}=Route) ->
            case User of
                RouteHash ->
                    nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                               <<"NkS">>, [<<"lr">>]);
                _ ->
                    Route
            end
        end,
        RRs = nksip_sipmsg:header(<<"record-route">>, Resp, uris),
        Routes = lists:map(UpdateRoutes, RRs),
        Headers1 = nksip_headers:update(Headers, [
                                        {multi, <<"record-route">>, Routes}]),
        Body1 = case Body of
            #sdp{} = SDP -> nksip_sdp:update_ip(SDP, ListenHost);
            _ -> Body
        end,
        % ViaOpts1 = lists:keydelete(<<"nksip_transport">>, 1, ViaOpts), 
        Resp#sipmsg{
            nkport = NkPort, 
            % vias = [Via#via{opts=ViaOpts}|ViaR],
            contacts = Contacts1,
            headers = Headers1, 
            body = Body1
        }
    end.


