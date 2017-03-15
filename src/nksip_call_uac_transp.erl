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

%% @doc UAC Transport Layer
-module(nksip_call_uac_transp).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([send_request/2, resend_request/2, add_headers/6]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
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
        srv_id = SrvId, 
        call_id = CallId, 
        class = {req, Method}, 
        ruri = RUri, 
        routes = Routes
    } = Req,
    ?call_debug("UAC send opts: ~p", [Opts]),
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
    SrvId:nks_sip_debug(SrvId, CallId, {uac_out_request, Method}),
    Dests = case nklib_util:get_value(route_flow, Opts) of
        #nkport{}=Flow -> 
            [Flow, DestUri];
        undefined ->
            case nklib_util:get_value(outbound_proxy, Opts) of
                undefined -> [DestUri];
                OutboundProxy -> [OutboundProxy]
            end
    end,
    Req1 = Req#sipmsg{ruri=RUri1, routes=Routes1},
    PreFun = make_pre_fun(DestUri, Opts),  
    case nksip_util:send(SrvId, Dests, Req1, PreFun, Opts) of
        {ok, SentReq} -> 
            {ok, SentReq};
        {error, Error} ->
            SrvId:nks_sip_debug(SrvId, CallId, {uac_out_request_error, Error}),
            {error, service_unavailable}
    end.


%% @doc Resend an already sent request to the same ip, port and transport.
-spec resend_request(nksip:request(), nksip:optslist()) -> 
    {ok, nksip:request()} | error.

resend_request(#sipmsg{srv_id=SrvId, nkport=NkPort}=Req, Opts) ->
    nksip_util:send(SrvId, [NkPort], Req, none, Opts).
        


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec make_pre_fun(nksip:uri(), nklib:optslist()) ->
    function().

make_pre_fun(Dest, Opts) ->
    #uri{scheme=Scheme} = Dest,     % RUri or first route
    fun(Req, NkPort) ->
        #sipmsg{
            srv_id = SrvId, 
            ruri = RUri, 
            call_id = CallId,
            vias = Vias,
            routes = Routes, 
            body = Body
        } = Req,
        #nkport{
            transp = Transp, 
            listen_ip = ListenIp, 
            listen_port = ListenPort
        } = NkPort,
        ListenHost = nksip_util:get_listenhost(SrvId, ListenIp, Opts),
        ?call_debug("UAC listenhost is ~s", [ListenHost]),
        {ok, Req1} = 
            SrvId:nks_sip_transport_uac_headers(Req, Opts, Scheme, 
                                             Transp, ListenHost, ListenPort),
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
        Via1 = #via{
            transp = Transp, 
            domain = ListenHost, 
            port = ListenPort, 
            opts = [<<"rport">>, {<<"branch">>, Branch}]
        },
        Body1 = case Body of 
            #sdp{} = SDP -> nksip_sdp:update_ip(SDP, ListenHost);
            _ -> Body
        end,
        Req1#sipmsg{
            nkport = NkPort,
            ruri = RUri#uri{ext_opts=[], ext_headers=[]},
            vias = [Via1|Vias],
            routes = Routes,
            body = Body1
        }
    end.


%% @private
-spec add_headers(nksip:request(), nksip:optslist(), nksip:scheme(),
                  nkpacket:transport(), binary(), inet:port_number()) ->
    nksip:request().

add_headers(Req, Opts, Scheme, Transp, ListenHost, ListenPort) ->
    #sipmsg{
        class = {req, Method},
        srv_id = SrvId, 
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
