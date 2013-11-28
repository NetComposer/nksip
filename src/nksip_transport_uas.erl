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

-module(nksip_transport_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_response/3, resend_response/3]).
    
-include("nksip.hrl").


%% ===================================================================
%% Public
%% ===================================================================


-type send_opt() :: {local_host, auto|binary()} | make_contact | secure.

%% @doc Sends a new `Response'.
-spec send_response(nksip:response(), binary(), [send_opt()]) ->
    {ok, nksip:response()} | error.

send_response(#sipmsg{class={resp, Code, _Reason}}=Resp, GlobalId, Opts) ->
    #sipmsg{
        app_id = AppId, 
        vias = [Via|_],
        start = Start,
        cseq_method = Method
    } = Resp,
    #via{proto=Proto, domain=Domain, port=Port, opts=ViaOpts} = Via,
    {ok, RIp} = nksip_lib:to_ip(nksip_lib:get_value(<<"received">>, ViaOpts)),
    RPort = nksip_lib:get_integer(<<"rport">>, ViaOpts),
    TranspSpec = case Proto of
        'udp' ->
            case nksip_lib:get_binary(<<"maddr">>, ViaOpts) of
                <<>> when RPort==0 -> [{udp, RIp, Port}];
                <<>> -> [{udp, RIp, RPort}];
                MAddr -> [#uri{domain=MAddr, port=Port}]   
            end;
        _ ->
            UriOpt = {<<"transport">>, nksip_lib:to_binary(Proto)},
            [
                {current, {Proto, RIp, RPort}}, 
                #uri{domain=Domain, port=Port, opts=[UriOpt]}
            ]
    end,
    RouteBranch = nksip_lib:get_binary(<<"branch">>, ViaOpts),
    RouteHash = <<"NkQ", (nksip_lib:hash({GlobalId, AppId, RouteBranch}))/binary>>,
    MakeRespFun = make_response_fun(RouteHash, Resp, Opts),
    nksip_trace:insert(Resp, {send_response, Method, Code}),
    Return = nksip_transport:send(AppId, TranspSpec, MakeRespFun, Opts),
    Elapsed = nksip_lib:l_timestamp()-Start,
    nksip_stats:uas_response(Elapsed),
    Return.


%% @doc Resends a previously sent response to the same ip, port and protocol.
-spec resend_response(Resp::nksip:response(), binary(), nksip_lib:proplist()) ->
    {ok, nksip:response()} | error.

resend_response(#sipmsg{class={resp, Code, _}, app_id=AppId, cseq_method=Method, 
                        transport=#transport{}=Transport}=Resp, _GlobalId, Opts) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    MakeResp = fun(_) -> Resp end,
    Return = nksip_transport:send(AppId, [{current, {Proto, Ip, Port}}], MakeResp, Opts),
    nksip_trace:insert(Resp, {sent_response, Method, Code}),
    Return;

resend_response(#sipmsg{app_id=AppId, call_id=CallId}=Resp, GlobalId, Opts) ->
    ?info(AppId, CallId, "Called resend_response/2 without transport\n", []),
    send_response(Resp, GlobalId, Opts).



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
%% Recognizes options local_host, make_contact
-spec make_response_fun(binary(), nksip:response(), nksip_lib:proplist()) ->
    function().

make_response_fun(RouteHash, Resp, Opts) ->
    #sipmsg{
        app_id = AppId,
        call_id = CallId,
        % vias = [#via{opts=ViaOpts}|ViaR],
        to = To, 
        headers = Headers,
        contacts = Contacts, 
        body = Body
    }= Resp,
    fun(#transport{
                    proto = Proto, 
                    listen_ip = ListenIp, 
                    listen_port = ListenPort
                } = Transport) ->
        ListenHost = case size(ListenIp) of
            4 ->
                case nksip_lib:get_value(local_host, Opts, auto) of
                    auto when ListenIp == {0,0,0,0} -> 
                        nksip_lib:to_host(nksip_transport:main_ip());
                    auto -> 
                        nksip_lib:to_host(ListenIp);
                    Host -> 
                        Host
                end;
            8 ->
                case nksip_lib:get_value(local_host6, Opts, auto) of
                    auto when ListenIp == {0,0,0,0,0,0,0,0} -> 
                        nksip_lib:to_host(nksip_transport:main_ip6(), true);
                    auto -> 
                        nksip_lib:to_host(ListenIp, true);
                    Host -> 
                        Host
                end
        end,
        ?debug(AppId, CallId, "UAS listenhost is ~s", [ListenHost]),
        Scheme = case Proto==tls andalso lists:member(secure, Opts) of
            true -> sips;
            _ -> sip
        end,
        Contacts1 = case lists:member(make_contact, Opts) of
            true ->
                [#uri{
                    scheme = Scheme,
                    user = To#uri.user,
                    domain = ListenHost,
                    port = ListenPort,
                    opts = case Proto of 
                        tls when Scheme==sips -> [];
                        udp when Scheme==sip -> [];
                        _ -> [{<<"transport">>, nksip_lib:to_binary(Proto)}]
                    end}|Contacts];
            false ->
                Contacts
        end,
        UpdateRoutes = fun(#uri{user=User}=Route) ->
            case User of
                RouteHash ->
                    Route#uri{
                        user = <<"NkS">>,
                        scheme = sip,
                        domain = ListenHost,
                        port = ListenPort,
                        opts = if
                            Proto==udp -> 
                                [<<"lr">>];
                            true -> 
                                [
                                    <<"lr">>, 
                                    {<<"transport">>, nksip_lib:to_binary(Proto)}
                                ] 
                        end
                    };
                _ ->
                    Route
            end
        end,
        RRs = nksip_sipmsg:header(Resp, <<"Record-Route">>, uris),
        Routes = lists:map(UpdateRoutes, RRs),
        Headers1 = nksip_headers:update(Headers, [
                                        {multi, <<"Record-Route">>, Routes}]),
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


