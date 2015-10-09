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

%% @doc UAS Transport Layer
-module(nksip_call_uas_transp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_response/2, resend_response/2]).
    
-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Sends a new `Response'.
-spec send_response(nksip:response(), nksip:optslist()) ->
    {ok, nksip:response()} | error.

send_response(#sipmsg{class={resp, Code, _Reason}}=Resp, Opts) ->
    #sipmsg{
        app_id = AppId, 
        call_id = CallId,
        vias = [Via|_],
        cseq = {_, Method},
        transport = Transp
    } = Resp,
    #via{proto=ViaProto, domain=ViaDomain, port=ViaPort, opts=ViaOpts} = Via,
    #transport{proto=RProto, remote_ip=RIp, remote_port=RPort, resource=Res} = Transp,
    % {ok, RIp} = nklib_util:to_ip(nklib_util:get_value(<<"received">>, ViaOpts)),
    ViaRPort = lists:keymember(<<"rport">>, 1, ViaOpts),
    TranspSpec = case RProto of
        'udp' ->
            case nklib_util:get_binary(<<"maddr">>, ViaOpts) of
                <<>> when ViaRPort -> [{udp, RIp, RPort, <<>>}];
                <<>> -> [{udp, RIp, ViaPort, <<>>}];
                MAddr -> [#uri{scheme=sip, domain=MAddr, port=ViaPort}]   
            end;
        _ ->
            UriOpt = {<<"transport">>, nklib_util:to_binary(ViaProto)},
            [
                {current, {RProto, RIp, RPort, Res}}, 
                #uri{scheme=sip, domain=ViaDomain, port=ViaPort, opts=[UriOpt]}
            ]
    end,
    RouteBranch = nklib_util:get_binary(<<"branch">>, ViaOpts),
    GlobalId = nksip_config_cache:global_id(),
    RouteHash = <<"NkQ", (nklib_util:hash({GlobalId, AppId, RouteBranch}))/binary>>,
    MakeRespFun = make_response_fun(RouteHash, Resp, Opts),
    AppId:nks_debug(AppId, CallId, {send_response, Method, Code}),
    Return = nksip_transport:send(AppId, TranspSpec, MakeRespFun, Opts),
    AppId:nks_transport_uas_sent(Resp),
    Return.


%% @doc Resends a previously sent response to the same ip, port and protocol.
-spec resend_response(Resp::nksip:response(), nksip:optslist()) ->
    {ok, nksip:response()} | error.

resend_response(#sipmsg{class={resp, Code, _}, 
                        transport=#transport{}=Transport}=Resp, Opts) ->
    #sipmsg{app_id=AppId, cseq={_, Method}, call_id=CallId} = Resp,
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port, resource=Res} = Transport,
    MakeResp = fun(_) -> Resp end,
    TranspSpec = [{current, {Proto, Ip, Port, Res}}],
    Return = nksip_transport:send(AppId, TranspSpec, MakeResp, Opts),
    AppId:nks_debug(AppId, CallId, {sent_response, Method, Code}),
    Return;

resend_response(Resp, Opts) ->
    ?call_info("Called resend_response/2 without transport", []),
    send_response(Resp, Opts).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec make_response_fun(binary(), nksip:response(), nksip:optslist()) ->
    function().

make_response_fun(RouteHash, Resp, Opts) ->
    #sipmsg{
        app_id = AppId,
        to = {To, _},
        headers = Headers,
        contacts = Contacts, 
        body = Body
    }= Resp,
    fun(#transport{
                    proto = Proto, 
                    listen_ip = ListenIp, 
                    listen_port = ListenPort
                } = Transport) ->
        ListenHost = nksip_transport:get_listenhost(AppId, ListenIp, Opts),
        % ?call_debug("UAS listenhost is ~s", [ListenHost]),
        Scheme = case Proto==tls andalso lists:member(secure, Opts) of
            true -> sips;
            _ -> sip
        end,
        Contacts1 = case Contacts==[] andalso lists:member(contact, Opts) of
            true ->
                [nksip_transport:make_route(Scheme, Proto, ListenHost, 
                                            ListenPort, To#uri.user, [])];
            false ->
                Contacts
        end,
        UpdateRoutes = fun(#uri{user=User}=Route) ->
            case User of
                RouteHash ->
                    nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
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
            transport = Transport, 
            % vias = [Via#via{opts=ViaOpts}|ViaR],
            contacts = Contacts1,
            headers = Headers1, 
            body = Body1
        }
    end.


