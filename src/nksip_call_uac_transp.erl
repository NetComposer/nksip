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

%% @doc UAC Transport Layer
-module(nksip_call_uac_transp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_request/2, resend_request/2, add_headers/6]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("nkservice/include/nkservice.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Sends a new request.
-spec send_request(nksip:request(), nksip:optslist()) -> 
    {ok, nksip:request()} | {error, nksip:sipreply()}.

send_request(Req, Opts) ->
    #sipmsg{
        srv = SrvId,
        package = PkgId,
        call_id = CallId, 
        class = {req, Method}, 
        ruri = RUri, 
        routes = Routes
    } = Req,
    ?CALL_DEBUG("UAC send opts: ~p", [Opts]),
    {DestUri2, RUri2, Routes2} = case Routes of
        [] -> 
            {RUri, RUri, []};
        [#uri{opts=RouteOpts}=TopRoute|RestRoutes] ->
            case lists:member(<<"lr">>, RouteOpts) of
                true ->     
                    DestUri = TopRoute#uri{
                        scheme = case RUri#uri.scheme of
                            sips ->
                                sips;
                            _ ->
                                TopRoute#uri.scheme
                        end
                    },
                    %{DestUri, RUri, [TopRoute|RestRoutes]};
                    {DestUri, RUri, Routes};
                false ->
                    DestUri = TopRoute#uri{
                        scheme = case RUri#uri.scheme of
                            sips ->
                                sips;
                            _ ->
                                TopRoute#uri.scheme
                        end
                    },
                    CRUri = RUri#uri{headers=[], ext_opts=[], ext_headers=[]},
                    {DestUri, DestUri, RestRoutes ++ [CRUri]}
            end
    end,
    ?CALL_SRV(SrvId, nksip_debug, [SrvId, CallId, {uac_out_request, Method}]),
    Destinations = case nklib_util:get_value(route_flow, Opts) of
        #nkport{}=Flow -> 
            [Flow, DestUri2];
        undefined -> 
            [DestUri2]
    end,
    Req2 = Req#sipmsg{ruri=RUri2, routes=Routes2},
    #uri{scheme=Scheme} = DestUri2,
    PreFun = make_pre_fun(Scheme, Opts),
    %
    % - if no route is set, message is sent directly to RUri, and
    %   ruri and routes is not updated in request
    % - if a "loose" (lr) route is first, message is sent to that route,
    %   ruri and routes are not updated
    % - if a non-loose route is first, message is sent to that route,
    %   ruri is changed to that route, it's extracted from route list and
    %   original ruri is appended to the end
    %
    case nksip_util:send(SrvId, PkgId, Destinations, Req2, PreFun, Opts) of
        {ok, SentReq} -> 
            {ok, SentReq};
        {error, Error} ->
            ?CALL_SRV(SrvId, nksip_debug, [SrvId, CallId, {uac_out_request_error, Error}]),
            {error, service_unavailable}
    end.


%% @doc Resend an already sent request to the same ip, port and transport.
-spec resend_request(nksip:request(), nksip:optslist()) -> 
    {ok, nksip:request()} | error.

resend_request(#sipmsg{srv=SrvId, package=PkgId, nkport=NkPort}=Req, Opts) ->
    nksip_util:send(SrvId, PkgId, [NkPort], Req, none, Opts).
        


%% ===================================================================
%% Internal
%% ===================================================================


%% @private Updates the request based on selected transport
%% - Generates Record-Route, Path and Contact (calling add_headers/6)
%% - Adds nkport
%% - Adds Via
%% - Updates the IP in SDP in case it is "auto.nksip" to the local IP

-spec make_pre_fun(nksip:scheme(), [nksip_uac:req_option()]) ->
    function().

make_pre_fun(Scheme, Opts) ->
    fun(Req, NkPort) ->
        #sipmsg{
            srv = SrvId,
            package = PkgId,
            ruri = RUri, 
            call_id = CallId,
            vias = Vias,
            body = Body
        } = Req,
        #nkport{
            transp = Transp, 
            listen_ip = ListenIp, 
            listen_port = ListenPort
        } = NkPort,
        ListenHost = nksip_util:get_listenhost(SrvId, PkgId, ListenIp, Opts),
        ?CALL_DEBUG("UAC listenhost is ~s", [ListenHost]),
        {ok, Req2} =
            ?CALL_SRV(SrvId, nksip_transport_uac_headers,
                     [Req, Opts, Scheme,Transp, ListenHost, ListenPort]),
        IsStateless = lists:member(stateless_via, Opts),
        GlobalId = nksip_config_cache:global_id(),
        Branch = case Vias of
            [Via0|_] when IsStateless ->
                % If it is a stateless proxy, generates the new Branch as a hash
                % of the main NkSIP's id and the old branch. It generates also 
                % a nksip tag to detect the response correctly
                Base = case nklib_util:get_binary(<<"branch">>, Via0#via.opts) of
                    <<"z9hG4bK", OBranch/binary>> ->
                        {SrvId, OBranch};
                    _ ->
                        #sipmsg{from={_, FromTag}, to={_, ToTag}, call_id=CallId, 
                                    cseq={CSeq, _}} = Req,
                        % Any of these will change in every transaction
                        {SrvId, Via0, ToTag, FromTag, CallId, CSeq, RUri}
                end,
                BaseBranch = nklib_util:hash(Base),
                NkSIP = nklib_util:hash({BaseBranch, GlobalId, stateless}),
                <<"z9hG4bK", BaseBranch/binary, $-, NkSIP/binary>>;
            _ ->
                % Generate a brand new Branch
                BaseBranch = nklib_util:uid(),
                NkSIP = nklib_util:hash({BaseBranch, GlobalId}),
                <<"z9hG4bK", BaseBranch/binary, $-, NkSIP/binary>>
        end,
        Via2 = #via{
            transp = Transp, 
            domain = ListenHost, 
            port = ListenPort, 
            opts = [<<"rport">>, {<<"branch">>, Branch}]
        },
        Body2 = case Body of
            #sdp{} = SDP ->
                nksip_sdp:update_ip(SDP, ListenHost);
            _ ->
                Body
        end,
        Req2#sipmsg{
            nkport = NkPort,
            ruri = RUri#uri{ext_opts=[], ext_headers=[]},
            vias = [Via2|Vias],
            body = Body2
        }
    end.


%% @private Generates Record-Route, Path and Contact
-spec add_headers(nksip:request(), nksip:optslist(), nksip:scheme(),
                  nkpacket:transport(), binary(), inet:port_number()) ->
    nksip:request().

add_headers(Req, Opts, Scheme, Transp, ListenHost, ListenPort) ->
    #sipmsg{
        class = {req, Method},
        srv = SrvId,
        from = {From, _},
        vias = Vias,
        contacts = Contacts,
        headers = Headers
    } = Req,    
    GlobalId = nksip_config_cache:global_id(),
    RouteBranch = case Vias of
        [#via{opts=RBOpts}|_] -> 
            nklib_util:get_binary(<<"branch">>, RBOpts);
        _ -> 
            <<>>
    end,
    RouteHash = nklib_util:hash({GlobalId, SrvId, RouteBranch}),
    RouteUser = <<"NkQ", RouteHash/binary>>,
    RecordRoute = case lists:member(record_route, Opts) of
        true when Method=='INVITE'; Method=='SUBSCRIBE'; Method=='NOTIFY';
                  Method=='REFER' -> 
            nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                       RouteUser, [<<"lr">>]);
        _ ->
            []
    end,
    Path = case lists:member(path, Opts) of
        true when Method=='REGISTER' ->
            nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                       RouteUser, [<<"lr">>]);
        _ ->
            []
    end,
    Contacts1 = case Contacts==[] andalso lists:member(contact, Opts) of
        true ->
            Contact = nksip_util:make_route(Scheme, Transp, ListenHost,
                                                 ListenPort, From#uri.user, []),
            #uri{ext_opts=CExtOpts} = Contact,
            UUID = nksip:get_uuid(SrvId),
            CExtOpts1 = [{<<"+sip.instance">>, <<$", UUID/binary, $">>}|CExtOpts],
            [Contact#uri{ext_opts=CExtOpts1}];
        false ->
            Contacts
    end,    
    Headers1 = nksip_headers:update(Headers, [
        {before_multi, <<"record-route">>, RecordRoute},
        {before_multi, <<"path">>, Path}]),
    Req#sipmsg{headers=Headers1, contacts=Contacts1}.
