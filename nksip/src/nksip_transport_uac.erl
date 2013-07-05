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

%% @doc UAC Transport Layer

-module(nksip_transport_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([add_via/1, send_request/1, resend_request/1]).

-include("nksip.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new request.
-spec send_request(nksip:request()) -> 
    {ok, nksip:request()} | error.

send_request(Request) ->
    #sipmsg{sipapp_id=AppId, method=Method, ruri=RUri, routes=Routes} = Request,
    case Routes of
        [] -> 
            DestUri = RUri1 = RUri,
            Routes1 = [];
        [#uri{opts=RouteOpts}=TopRoute|RestRoutes] ->
            case lists:member(lr, RouteOpts) of
                true ->     
                    DestUri = TopRoute#uri{
                        scheme = case RUri#uri.scheme of
                            sips -> sips;
                            _ -> TopRoute#uri.scheme
                        end
                    },
                    RUri1 = RUri,
                    Routes1 = [TopRoute|RestRoutes];
                false ->
                    DestUri = RUri1 = TopRoute#uri{
                        scheme = case RUri#uri.scheme of
                            sips -> sips;
                            _ -> TopRoute#uri.scheme
                        end
                    },
                    Routes1 = RestRoutes ++ [nksip_parse:uri2ruri(RUri)]
            end
    end,
    MakeRequestFun = make_request_fun(Request#sipmsg{ruri=RUri1, routes=Routes1}),  
    nksip_trace:insert(Request, {uac_out_request, Method}),
    case nksip_transport:send(AppId, [DestUri], MakeRequestFun) of
        {ok, SentReq} -> 
            {ok, SentReq};
        error ->
            nksip_trace:insert(Request, uac_out_request_error),
            error
    end.


%% @doc Resend an already sent request to the same ip, port and transport.
-spec resend_request(nksip:request()) -> 
    {ok, nksip:request()} | error.

resend_request(#sipmsg{sipapp_id=AppId, transport=Transport}=Request) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port} = Transport,
    MakeRequest = fun(_) -> Request end,
    nksip_transport:send(AppId, [{Proto, Ip, Port}], MakeRequest).
        


%% ===================================================================
%% Private
%% ===================================================================

%% @private
-spec add_via(nksip:request()) -> nksip:request().

add_via(#sipmsg{sipapp_id=AppId, ruri=RUri, vias=Vias, opts=Opts}=Request) ->
    GlobalId = nksip_config:get(global_id),
    IsStateless = lists:member(stateless, Opts),
    case Vias of
        [Via|_] when IsStateless ->
            % If it is a stateless proxy, generates the new Branch as a hash
            % of the main NkSIP's id and the old branch. It generates also 
            % a nksip tag to detect the response correctly
            Base = case nksip_lib:get_binary(branch, Via#via.opts) of
                <<"z9hG4bK", OBranch/binary>> ->
                    {AppId, OBranch};
                _ ->
                    #sipmsg{from_tag=FromTag, to_tag=ToTag, call_id=CallId, 
                                cseq=CSeq} = Request,
                    % Any of these will change in every transaction
                    {AppId, Via, ToTag, FromTag, CallId, CSeq, RUri}
            end,
            Branch = nksip_lib:hash(Base),
            NkSip = nksip_lib:hash({Branch, GlobalId, stateless});
        _ ->
            % Generate a brand new Branch
            Branch = nksip_lib:uid(),
            NkSip = nksip_lib:hash({Branch, GlobalId})
    end,
    ViaOpts = [rport, {branch, <<"z9hG4bK",Branch/binary>>}, {nksip, NkSip}],
    Request#sipmsg{vias=[#via{opts=ViaOpts}|Vias]}.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec make_request_fun(nksip:request()) ->
    function().

make_request_fun(#sipmsg{
                    sipapp_id = AppId, 
                    method = Method, 
                    ruri = RUri, 
                    from = From, 
                    vias = [Via|RestVias],
                    routes = Routes, 
                    contacts = Contacts, 
                    headers = Headers, 
                    body = Body, 
                    opts = Opts
                } = Request) ->
    GlobalId = nksip_config:get(global_id),
    RouteBranch = case RestVias of
        [#via{opts=RBOpts}|_] -> nksip_lib:get_binary(branch, RBOpts);
        _ -> <<>>
    end,
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
        % The user hash is used when the Record-Route is sent back from the UAS
        % to notice it is ours, and change it to the destination transport
        % (see nksip_transport_uas:send_response/1)
        % The nksip tag is used to confirm it is ours and to check if a strict router
        % has used it as Request Uri (see nksip_uas:strict_router/1)
        RecordRoute = case lists:member(record_route, Opts) of
            true when Method =/= 'REGISTER' -> 
                Hash = nksip_lib:hash({GlobalId, AppId, RouteBranch}),
                #uri{
                    scheme = sip,
                    user = <<"NkQ", Hash/binary>>,
                    domain = ListenHost,
                    port = ListenPort,
                    opts = if
                        Proto=:=udp -> [lr];
                        true -> [lr, {transport, Proto}] 
                    end
                };
            _ ->
                []
        end,
        Contacts1 = case lists:member(make_contact, Opts) of
            true ->
                [#uri{
                    scheme = case Proto of tls -> sips; _ -> sip end,
                    user = From#uri.user,
                    domain = ListenHost,
                    port = ListenPort,
                    opts = if
                        Proto=:=tls; Proto=:=udp -> []; 
                        true -> [{transport, Proto}] 
                    end
                }|Contacts];
            false ->
                Contacts
        end,
        Via1 = Via#via{proto=Proto, domain=ListenHost, port=ListenPort},
        Headers1 = nksip_headers:update(Headers, 
                                    [{before_multi, <<"Record-Route">>, RecordRoute}]),
        Body1 = case Body of 
            #sdp{} = SDP -> nksip_sdp:update_ip(SDP, ListenHost);
            _ -> Body
        end,
        Request#sipmsg{
            transport = Transport,
            ruri = nksip_parse:uri2ruri(RUri),
            vias = [Via1|RestVias],
            routes = Routes,
            contacts = Contacts1,
            headers = Headers1,
            body = Body1
        }
    end.









