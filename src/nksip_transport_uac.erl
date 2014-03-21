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
    % AppOpts = nksip_sipapp_srv:get_opts(AppId),
    ?debug(AppId, "UAC send opts: ~p", [Opts]),
    try
        case Routes of
            [] -> 
                DestUri = RUri1 = RUri,
                Routes1 = [];
            [#uri{opts=RouteOpts}=TopRoute|RestRoutes] ->
                case lists:member(<<"lr">>, RouteOpts) of
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
                        CRUri = RUri#uri{headers=[], ext_opts=[], ext_headers=[]},
                        Routes1 = RestRoutes ++ [CRUri]
                end
        end,
        Req1 = Req#sipmsg{ruri=RUri1, routes=Routes1},
        MakeReqFun = make_request_fun(Req1, DestUri, GlobalId, Opts),  
        nksip_trace:insert(Req, {uac_out_request, Method}),
        Dests = case nksip_lib:get_value(route_flow, Opts) of
            {Transp, Pid} -> 
                [{flow, {Pid, Transp}}, DestUri];
            undefined -> 
                [DestUri]
        end,
        case nksip_transport:send(AppId, Dests, MakeReqFun, Opts) of
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
-spec make_request_fun(nksip:request(), nksip:uri(), binary(), nksip_lib:proplist()) ->
    function().

make_request_fun(Req, Dest, GlobalId, Opts) ->
    #sipmsg{
        class = {req, Method},
        app_id = AppId, 
        ruri = RUri, 
        call_id = CallId,
        from = {From, _},
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
        case nksip_lib:get_value(record_flow, Opts) of
            FlowPid when is_pid(FlowPid) -> FlowOb = false;
            {FlowPid, ob} -> FlowOb = true;
            undefined -> FlowPid = FlowOb = false
        end,
        RouteUser = case FlowPid of
            false -> 
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
        Path = case lists:member(path, Opts) of
            true when Method=='REGISTER' ->
                case RouteUser of
                    <<"NkQ", _/binary>> ->
                        nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
                                                   RouteUser, [<<"lr">>]);
                    <<"NkF", _/binary>> ->
                        PathOpts = case FlowOb of
                            true -> [<<"lr">>, <<"ob">>];
                            false -> [<<"lr">>]
                        end,
                        nksip_transport:make_route(sip, Proto, ListenHost, ListenPort,
                                                   RouteUser, PathOpts)
                end;
            _ ->
                []
        end,
        Contacts1 = case Contacts==[] andalso lists:member(contact, Opts) of
            true ->
                Contact0 = nksip_transport:make_route(Scheme, Proto, ListenHost, 
                                                     ListenPort, From#uri.user, []),
                [nksip_outbound:make_contact(Req, Contact0, Opts)];
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
                        #sipmsg{from={_, FromTag}, to={_, ToTag}, call_id=CallId, 
                                    cseq={CSeq, _}} = Req,
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
                                    {before_multi, <<"record-route">>, RecordRoute},
                                    {before_multi, <<"path">>, Path}]),
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


