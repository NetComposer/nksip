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

-export([send_request/3, resend_request/2]).

-include("nksip.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new request.
-spec send_request(nksip:request(), binary(), nksip_lib:proplist()) -> 
    {ok, nksip:request()} | {error, nksip:sipreply()}.

send_request(Req, GlobalId, Opts) ->
    #sipmsg{app_id=AppId, class={req, Method}, ruri=RUri, routes=Routes} = Req,
    try
        case nksip_parse:extract_uri_routes(RUri) of
            {UriRoutes, RUri1} -> Routes1 = Routes++UriRoutes; 
            error -> RUri1 = Routes1 = throw({internal_error, "Bad Uri"})
        end,
        Opts1 = outbound_opts(Req, Opts),
        {Routes2, Opts2, Flow} = remove_local_routes(Req, Opts1, Routes1, undefined),
        case Routes2 of
            [] -> 
                DestUri = RUri2 = RUri1,
                Routes3 = [];
            [#uri{opts=RouteOpts}=TopRoute|RestRoutes] ->
                case lists:member(<<"lr">>, RouteOpts) of
                    true ->     
                        DestUri = TopRoute#uri{
                            scheme = case RUri1#uri.scheme of
                                sips -> sips;
                                _ -> TopRoute#uri.scheme
                            end
                        },
                        RUri2 = RUri1,
                        Routes3 = [TopRoute|RestRoutes];
                    false ->
                        DestUri = RUri2 = TopRoute#uri{
                            scheme = case RUri1#uri.scheme of
                                sips -> sips;
                                _ -> TopRoute#uri.scheme
                            end
                        },
                        CRUri = RUri1#uri{headers=[], ext_opts=[], ext_headers=[]},
                        Routes3 = RestRoutes ++ [CRUri]
                end
        end,
        Req1 = Req#sipmsg{ruri=RUri2, routes=Routes3},
        MakeReqFun = make_request_fun(Req1, DestUri, GlobalId, Opts2),  
        nksip_trace:insert(Req, {uac_out_request, Method}),
        Dests = case Flow of
            {Pid, Transp} -> [{flow, {Pid, Transp}}, DestUri];
            _ -> [DestUri]
        end,
        case nksip_transport:send(AppId, Dests, MakeReqFun, Opts2) of
            {ok, SentReq} -> 
                {ok, SentReq};
            error ->
                nksip_trace:insert(Req, uac_out_request_error),
                {error, service_unavailable}
        end
    catch
        throw:Throw -> {error, Throw}
    end.


%% @doc Resend an already sent request to the same ip, port and transport.
-spec resend_request(nksip:request(), nksip_lib:proplist()) -> 
    {ok, nksip:request()} | error.

resend_request(#sipmsg{app_id=AppId, transport=Transport}=Req, Opts) ->
    #transport{proto=Proto, remote_ip=Ip, remote_port=Port, resource=Res} = Transport,
    MakeReq = fun(_) -> Req end,
    nksip_transport:send(AppId, [{Proto, Ip, Port, Res}], MakeReq, Opts).
        


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec outbound_opts(nksip:request(), nksip_lib:proplist()) ->
    nksip_lib:proplist().

outbound_opts(Req, Opts) ->
    #sipmsg{
        app_id = AppId,
        class = {req, Method}, 
        vias = Vias, 
        transport = Transp, 
        contacts = Contacts
    } = Req,
    case Method=='REGISTER' andalso lists:member(make_path, Opts) of     
        true ->
            case nksip_sipmsg:supported(Req, <<"path">>) of
                true ->
                    Supported = nksip_lib:get_value(supported, Opts, ?SUPPORTED),
                    case Contacts of
                        [#uri{ext_opts=ContactOpts}] ->
                            case 
                                lists:member(<<"outbound">>, Supported) andalso
                                lists:keymember(<<"reg-id">>, 1, ContactOpts) andalso
                                length(Vias)==1
                            of
                                true ->
                                    case Transp of
                                        #transport{
                                            proto = Proto, 
                                            remote_ip = Ip, 
                                            remote_port = Port,
                                            resource = Res
                                        } ->
                                            case 
                                                nksip_transport:get_connected(
                                                            AppId, Proto, Ip, Port, Res)
                                            of
                                                [{_, Pid}|_] -> [{store_flow, Pid}|Opts];
                                                _ -> Opts
                                            end;
                                        _ ->
                                            Opts
                                    end;
                                false ->
                                    Opts
                            end;
                        _ ->
                            Opts
                    end;
                false -> 
                    throw({extension_required, <<"path">>})
            end;
        false ->
            Opts
    end.


%% @private 
-spec remove_local_routes(nksip:request(), nksip_lib:proplist(), [#uri{}], 
                          undefined | {pid(), nksip:transport()}) ->
    {[#uri{}], nksip_lib:proplist(), undefined | {pid(), nksip:transport()}}.

remove_local_routes(_Req, Opts, [], Flow) ->
    {[], Opts, Flow};

remove_local_routes(Req, Opts, [Route|RestRoutes], Flow) ->
    #sipmsg{app_id=AppId, class={req, Method}, to_tag=ToTag} = Req,
    case nksip_transport:is_local(AppId, Route) of
        true -> 
            case Route of
                #uri{user = <<"NkF", Token/binary>>, opts=RouteOpts} 
                    when Flow==undefined ->
                    case catch binary_to_term(base64:decode(Token)) of
                        Pid when is_pid(Pid) ->
                            case nksip_connection:get_transport(Pid) of
                                {ok, Transp} -> 
                                    Opts1 = case 
                                        lists:member(<<"ob">>, RouteOpts) andalso
                                        (Method=='INVITE' orelse Method=='SUBSCRIBE' 
                                            orelse Method=='NOTIFY') 
                                        andalso ToTag == <<>>
                                    of
                                        true -> [record_route, {store_flow, Pid}|Opts];
                                        false -> Opts
                                    end,
                                    remove_local_routes(Req, Opts1, 
                                                        RestRoutes, {Pid, Transp});
                                _ ->
                                    throw(flow_failed)
                            end;
                        _ ->
                            ?notice(AppId, "Received invalid flow token", []),
                            throw(forbidden)
                    end;
                _ ->
                    remove_local_routes(Req, Opts, RestRoutes, Flow)
            end;
        false -> 
            {[Route|RestRoutes], Opts, Flow}
    end.


%% @private
-spec make_request_fun(nksip:request(), nksip:uri(), binary(), nksip_lib:proplist()) ->
    function().

make_request_fun(Req, Dest, GlobalId, Opts) ->
    #sipmsg{
        class = {req, Method},
        app_id = AppId, 
        ruri = RUri, 
        call_id = CallId,
        vias = Vias,
        routes = Routes, 
        contacts = Contacts, 
        headers = Headers, 
        body = Body
    } = Req,
    #uri{scheme=Scheme} = Dest,     % RUri or first route
    fun(Transp) ->
        #transport{
            proto = Proto, 
            listen_ip = ListenIp, 
            listen_port = ListenPort
        } = Transp,
        ListenHost = nksip_transport:get_listenhost(ListenIp, Opts),
        ?debug(AppId, CallId, "UAC listenhost is ~s", [ListenHost]),
        RouteBranch = case Vias of
            [#via{opts=RBOpts}|_] -> nksip_lib:get_binary(<<"branch">>, RBOpts);
            _ -> <<>>
        end,
        % The user hash is used when the Record-Route is sent back from the UAS
        % to notice it is ours, and change it to the destination transport
        % (see nksip_transport_uas:send_response/2)
        % The nksip tag is used to confirm it is ours and to check if a strict router
        % has used it as Request Uri (see nksip_uas:strict_router/1)
      

        RouteUser = case nksip_lib:get_value(store_flow, Opts) of
            undefined -> 
                RouteHash = nksip_lib:hash({GlobalId, AppId, RouteBranch}),
                <<"NkQ", RouteHash/binary>>;
            FlowPid -> 
                FlowToken = base64:encode(term_to_binary(FlowPid)),
                <<"NkF", FlowToken/binary>>
        end,
        RecordRoute = case lists:member(record_route, Opts) of
            true when Method/='REGISTER' -> 
                nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
                                           RouteUser, [<<"lr">>]);
            _ ->
                []
        end,
        Path = case lists:member(make_path, Opts) of
            true when Method=='REGISTER' ->
                case RouteUser of
                    <<"NkQ", _/binary>> ->
                        nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
                                                   RouteUser, [<<"lr">>]);
                    <<"NkF", _/binary>> ->
                        nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
                                                   RouteUser, [<<"lr">>, <<"ob">>])
                end;
            false ->
                []
        end,
        Contacts1 = case lists:member(make_contact, Opts) of
            true ->
                Contact = make_contact(Req, Scheme, Proto, ListenHost, ListenPort, Opts),
                [Contact|Contacts];
            false ->
                Contacts
        end,
        IsStateless = lists:member(stateless_via, Opts),
        Branch = case Vias of
            [Via0|_] when IsStateless ->
                % If it is a stateless proxy, generates the new Branch as a hash
                % of the main NkSIP's id and the old branch. It generates also 
                % a nksip tag to detect the response correctly
                Base = case nksip_lib:get_binary(<<"branch">>, Via0#via.opts) of
                    <<"z9hG4bK", OBranch/binary>> ->
                        {AppId, OBranch};
                    _ ->
                        #sipmsg{from_tag=FromTag, to_tag=ToTag, call_id=CallId, 
                                    cseq=CSeq} = Req,
                        % Any of these will change in every transaction
                        {AppId, Via0, ToTag, FromTag, CallId, CSeq, RUri}
                end,
                BaseBranch = nksip_lib:hash(Base),
                NkSip = nksip_lib:hash({BaseBranch, GlobalId, stateless}),
                <<"z9hG4bK", BaseBranch/binary, $-, NkSip/binary>>;
            _ ->
                % Generate a brand new Branch
                BaseBranch = nksip_lib:uid(),
                NkSip = nksip_lib:hash({BaseBranch, GlobalId}),
                <<"z9hG4bK", BaseBranch/binary, $-, NkSip/binary>>
        end,
        Via1 = #via{
            proto = Proto, 
            domain = ListenHost, 
            port = ListenPort, 
            opts = [<<"rport">>, {<<"branch">>, Branch}]
        },
        Headers1 = nksip_headers:update(Headers, [
                                    {before_multi, <<"Record-Route">>, RecordRoute},
                                    {before_multi, <<"Path">>, Path}]),
        Body1 = case Body of 
            #sdp{} = SDP -> nksip_sdp:update_ip(SDP, ListenHost);
            _ -> Body
        end,
        Req#sipmsg{
            transport = Transp,
            ruri = RUri#uri{ext_opts=[], ext_headers=[]},
            vias = [Via1|Vias],
            routes = Routes,
            contacts = Contacts1,
            headers = Headers1,
            body = Body1
        }
    end.



% %% @private
% make_route(GlobalId, AppId, Branch, ListenHost, ListenPort, Proto) ->
%     Hash = nksip_lib:hash({GlobalId, AppId, Branch}),
%     #uri{
%         scheme = sip,
%         user = <<"NkQ", Hash/binary>>,
%         domain = ListenHost,
%         port = ListenPort,
%         opts = case Proto of
%             udp -> [<<"lr">>];
%             _ -> [<<"lr">>, {<<"transport">>, nksip_lib:to_binary(Proto)}] 
%         end
%     }.


%% @private
make_contact(Req, Scheme, Proto, ListenHost, ListenPort, Opts) ->
    #sipmsg{app_id=AppId, from=From, class={req, Method}} = Req,
    OB = nksip_sipmsg:supported(Req, <<"outbound">>),
    UriOpts = case OB of
        true -> [<<"ob">>];
        false -> []
    end,
    Contact = nksip_transport:make_route(Scheme, Proto, ListenHost, ListenPort,
                                         From#uri.user, UriOpts),
    case OB of
        true ->
            {ok, UUID} = nksip_sipapp_srv:get_uuid(AppId),
            ExtOpts = [
                {<<"+sip.instance">>, <<$", UUID/binary, $">>} | 
                case 
                    Method=='REGISTER' andalso nksip_lib:get_integer(reg_id, Opts)
                of
                    RegId when is_integer(RegId), RegId>0 -> 
                        [{<<"reg-id">>, nksip_lib:to_binary(RegId)}];
                    _ ->
                        []
                end
            ],
            Contact#uri{ext_opts=ExtOpts};
        false ->
           Contact
    end.



