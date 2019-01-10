%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Carlos Gonzalez Florido.  All Rights Reserved.
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
-include_lib("nkserver/include/nkserver.hrl").

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
                    [#nkconn{protocol=nksip_protocol, transp=udp, ip=RIp, port=RPort}];
                <<>> ->
                    [#nkconn{protocol=nksip_protocol, transp=udp, ip=RIp, port=ViaPort}];
                MAddr ->
                    [#uri{scheme=sip, domain=MAddr, port=ViaPort}]   
            end;
        _ ->
            % Stateless proxy will remove the socket, but current will be used
            UriOpt = {<<"transport">>, nklib_util:to_binary(ViaTransp)},
            [
                NkPort,
                #uri{scheme=sip, domain=ViaDomain, port=ViaPort, opts=[UriOpt]}
            ]
    end,
    RouteBranch = nklib_util:get_binary(<<"branch">>, ViaOpts),
    GlobalId = nksip_config:get_config(global_id),
    RouteHash = <<"NkQ", (nklib_util:hash({GlobalId, SrvId, RouteBranch}))/binary>>,
    ?CALL_SRV(SrvId, nksip_debug, [SrvId, CallId, {send_response, Method, Code}]),
    Msg = make_msg_fun(RouteHash, Resp, Opts),
    ?CALL_DEBUG("UAS sending to ~p", [TranspSpec]),
    Return = nksip_util:send(SrvId, TranspSpec, Msg, Opts),
    ?CALL_SRV(SrvId, nksip_transport_uas_sent, [Resp]),
    Return.


%% @doc Resends a previously sent response to the same ip, port and protocol.
-spec resend_response(Resp::nksip:response(), nksip:optslist()) ->
    {ok, nksip:response()} | {error, term()}.

resend_response(#sipmsg{class={resp, Code, _}, nkport=#nkport{}=NkPort}=Resp, Opts) ->
    #sipmsg{ srv_id=SrvId, cseq={_, Method}, call_id=CallId} = Resp,
    Msg = fun(FunNkPort) -> Resp#sipmsg{nkport=FunNkPort} end,
    Return = nksip_util:send(SrvId, [NkPort], Msg, Opts),
     ?CALL_SRV(SrvId, nksip_debug, [SrvId, CallId, {sent_response, Method, Code}]),
    Return;

resend_response(Resp, Opts) ->
    ?CALL_LOG(info, "Called resend_response/2 without transport", []),
    send_response(Resp, Opts).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec make_msg_fun(binary(), nksip:response(), nksip:optslist()) ->
    function().

make_msg_fun(RouteHash, Resp, Opts) ->
    fun(NkPort) ->
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
        ?CALL_DEBUG("UAS listenhost is ~s", [ListenHost]),
        Scheme = case Transp==tls andalso lists:member(secure, Opts) of
            true ->
                sips;
            _ ->
                sip
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
            #sdp{} = SDP ->
                nksip_sdp:update_ip(SDP, ListenHost);
            _ ->
                Body
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


