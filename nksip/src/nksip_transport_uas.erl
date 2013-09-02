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

-export([send_response/2, send_response/1, resend_response/1]).
    
-include("nksip.hrl").


%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new `Response'.
-spec send_response(nksip:request(), nksip:sipreply()) ->
    {ok, nksip:response()} | error.

send_response(Request, SipReply) ->
    send_response(nksip_reply:reply(Request, SipReply)).


%% @doc Sends a new `Response'.
-spec send_response(Resp::nksip:response()) ->
    {ok, nksip:response()} | error.

send_response(#sipmsg{
                app_id = AppId, 
                vias = [Via|_],
                start = Start,
                cseq_method = Method,
                response = Code
            } = Resp) ->
    #via{proto=Proto, domain=Domain, port=Port, opts=Opts} = Via,
    {ok, RIp} = nksip_lib:to_ip(nksip_lib:get_value(received, Opts)),
    RPort = nksip_lib:get_integer(rport, Opts),
    TranspSpec = case Proto of
        'udp' ->
            case nksip_lib:get_binary(maddr, Opts) of
                <<>> when RPort=:=0 -> [{udp, RIp, Port}];
                <<>> -> [{udp, RIp, RPort}];
                MAddr -> [#uri{domain=MAddr, port=Port}]   
            end;
        _ ->
            [
                {current, {Proto, RIp, RPort}}, 
                #uri{domain=Domain, port=Port, opts=[{transport, Proto}]}
            ]
    end,
    GlobalId = nksip_config:get(global_id),
    RouteBranch = nksip_lib:get_binary(branch, Opts),
    RouteHash = <<"NkQ", (nksip_lib:hash({GlobalId, AppId, RouteBranch}))/binary>>,
    MakeRespFun = make_response_fun(RouteHash, Resp),
    nksip_trace:insert(Resp, {send_response, Method, Code}),
    Return = nksip_transport:send(AppId, TranspSpec, MakeRespFun),
    Elapsed = nksip_lib:l_timestamp()-Start,
    nksip_stats:uas_response(Elapsed),
    Return.


%% @doc Resends a previously sent response to the same ip, port and protocol.
-spec resend_response(Resp::nksip:response()) ->
    {ok, nksip:response()} | error.

resend_response(#sipmsg{app_id=AppId, response=Code, cseq_method=Method, 
                        transport=Transport}=Resp) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    MakeResp = fun(_) -> Resp end,
    Return = nksip_transport:send(AppId, [{current, {Proto, Ip, Port}}], MakeResp),
    nksip_trace:insert(Resp, {sent_response, Method, Code}),
    Return.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec make_response_fun(binary(), nksip:response()) ->
    function().

make_response_fun(RouteHash, 
            #sipmsg{
                vias = [#via{proto=ViaProto, opts=ViaOpts}=Via|ViaR], 
                to = To, 
                headers = Headers,
                contacts = Contacts, 
                body = Body, 
                opts = Opts
            }= Resp) ->
    fun(#transport{
                    proto = Proto, 
                    listen_ip = ListenIp, 
                    listen_port = ListenPort
                } = Transport) ->
        ListenHost = case nksip_lib:get_value(local_host, Opts, auto) of
            auto when ListenIp =:= {0,0,0,0} -> 
                nksip_lib:to_binary(nksip_transport:main_ip());
            auto -> 
                nksip_lib:to_binary(ListenIp);
            Host -> 
                nksip_lib:to_binary(Host)
        end,
        Contacts1 = case lists:member(make_contact, Opts) of
            true ->
                [#uri{
                    scheme = case Proto of tls -> sips; _ -> sip end,
                    user = To#uri.user,
                    domain = ListenHost,
                    port = ListenPort,
                    opts = if 
                        Proto=:=tls; Proto=:=udp -> []; true -> [{transport, Proto}]
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
                            Proto=:=udp -> [lr];
                            true -> [lr, {transport, Proto}] 
                        end
                    };
                _ ->
                    Route
            end
        end,
        Routes = lists:map(UpdateRoutes, 
                                nksip_sipmsg:header(Resp, <<"Record-Route">>, uris)),
        Headers1 = nksip_headers:update(Headers, [
                                        {multi, <<"Record-Route">>, Routes}]),
        Body1 = case Body of
            #sdp{} = SDP -> nksip_sdp:update_ip(SDP, ListenHost);
            _ -> Body
        end,
        ViaOpts1 = lists:keydelete(nksip_transport, 1, ViaOpts), 
        Resp#sipmsg{
            transport = Transport, 
            vias = [Via#via{opts=ViaOpts1}|ViaR],
            contacts = Contacts1,
            headers = Headers1, 
            body = Body1
        }
    end.


