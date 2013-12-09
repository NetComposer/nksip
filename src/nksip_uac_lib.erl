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

%% @doc UAC process helper functions
-module(nksip_uac_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([make/5, make_cancel/1, make_ack/2, make_ack/1, is_stateless/2]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
-spec make(nksip:app_id(), nksip:method(), nksip:user_uri(), 
           nksip_lib:proplist(), nksip_lib:proplist()) ->    
    {ok, nksip:request(), nksip_lib:proplist()} | {error, Error} when
    Error :: invalid_uri | invalid_from | invalid_to | invalid_route |
             invalid_contact | invalid_cseq | invalid_content_type |
             invalid_require | invalid_accept | invalid_event.

make(AppId, Method, Uri, Opts, AppOpts) ->
    FullOpts = Opts++AppOpts,
    try
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uris(nksip_lib:get_value(from, FullOpts)) of
            [From] -> ok;
            _ -> From = throw(invalid_from) 
        end,
        case nksip_lib:get_value(to, FullOpts) of
            undefined -> 
                To = RUri#uri{port=0, opts=[], 
                                headers=[], ext_opts=[], ext_headers=[]};
            as_from -> 
                To = From;
            ToOther -> 
                case nksip_parse:uris(ToOther) of
                    [To] -> ok;
                    _ -> To = throw(invalid_to) 
                end
        end,
        case nksip_lib:get_value(route, FullOpts, []) of
            [] ->
                Routes = [];
            RouteSpec ->
                case nksip_parse:uris(RouteSpec) of
                    error -> Routes = throw(invalid_route);
                    Routes -> ok
                end
        end,
        case nksip_lib:get_value(contact, FullOpts, []) of
            [] ->
                Contacts = [];
            ContactSpec ->
                case nksip_parse:uris(ContactSpec) of
                    error -> Contacts = throw(invalid_contact);
                    Contacts -> ok
                end
        end,
        case nksip_lib:get_binary(call_id, Opts) of
            <<>> -> CallId = nksip_lib:luid();
            CallId -> ok
        end,
        CSeq = case nksip_lib:get_value(cseq, Opts) of
            undefined -> nksip_config:cseq();
            UCSeq when is_integer(UCSeq), UCSeq > 0 -> UCSeq;
            _ -> throw(invalid_cseq)
        end,
        CSeq1 = case nksip_lib:get_integer(min_cseq, Opts) of
            MinCSeq when MinCSeq > CSeq -> MinCSeq;
            _ -> CSeq
        end,
        case nksip_lib:get_value(<<"tag">>, From#uri.ext_opts) of
            undefined -> 
                FromTag = nksip_lib:uid(),
                FromOpts = [{<<"tag">>, FromTag}|From#uri.ext_opts];
            FromTag -> 
                FromOpts = From#uri.ext_opts
        end,
        case nksip_lib:get_binary(user_agent, FullOpts) of
            <<>> -> UserAgent = <<"NkSIP ", ?VERSION>>;
            UserAgent -> ok
        end,
        Headers = 
                proplists:get_all_values(pre_headers, FullOpts) ++
                nksip_lib:get_value(headers, FullOpts, []) ++
                proplists:get_all_values(post_headers, FullOpts),
        Body = nksip_lib:get_value(body, Opts, <<>>),
        Headers1 = nksip_headers:update(Headers, [
            {default_single, <<"User-Agent">>, UserAgent},
            case lists:member(make_allow, FullOpts) of
                true -> 
                    Allow = case lists:member(registrar, AppOpts) of
                        true -> <<(?ALLOW)/binary, ", REGISTER">>;
                        false -> ?ALLOW
                    end,
                    {default_single, <<"Allow">>, Allow};
                false -> 
                    []
            end,
            case lists:member(make_allow_event, FullOpts) of
                true -> 
                    case nksip_lib:get_value(event, AppOpts) of
                        undefined ->
                            [];
                        Events ->
                            AllowEvents = nksip_lib:bjoin(Events),
                            {default_single, <<"Allow-Event">>, AllowEvents}
                    end;
                false -> 
                    []
            end,
            case lists:member(make_accept, Opts) of
                true -> 
                    Accept = case nksip_lib:get_value(accept, FullOpts) of
                        undefined when Method=='INVITE'; Method=='UPDATE'; 
                                       Method=='PRACK' -> 
                            [{<<"application/sdp">>, []}];
                        undefined ->
                            ?ACCEPT;
                        AcceptList ->
                            case nksip_parse:tokens(AcceptList) of
                                error -> throw(invalid_accept);
                                AcceptTokens -> AcceptTokens
                            end
                    end,
                    {default_single, <<"Accept">>, nksip_unparse:tokens(Accept)};
                false -> 
                    []
            end,
            case lists:member(make_date, FullOpts) of
                true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                    httpd_util:rfc1123_date())};
                false -> []
            end
        ]),
        ContentType = case nksip_lib:get_binary(content_type, Opts) of
            <<>> when is_record(Body, sdp) -> 
                {<<"application/sdp">>, []};
            <<>> when not is_binary(Body) -> 
                {<<"application/nksip.ebf.base64">>, []};
            <<>> -> 
                undefined;
            ContentTypeSpec -> 
                case nksip_parse:tokens(ContentTypeSpec) of
                    [ContentTypeToken] -> ContentTypeToken;
                    error -> throw(invalid_content_type)
                end
        end,
        Require0 = case nksip_lib:get_value(require, Opts) of
            undefined -> 
                [];
            ReqOpts ->
                case nksip_parse:tokens(ReqOpts) of
                    error -> throw(invalid_require);
                    ReqTokens0 -> ReqTokens0
                end
        end,
        Require = case 
            Method=='INVITE' andalso lists:member(require_100rel, FullOpts) 
        of
            true -> 
                case lists:keymember(<<"100rel">>, 1, Require0) of
                    true -> Require0;
                    false -> [{<<"100rel">>, []}|Require0]
                end;
            false -> 
                Require0
        end,
        Supported = case lists:member(make_supported, FullOpts) of
            true -> nksip_lib:get_value(supported, AppOpts, ?SUPPORTED);
            false -> []
        end,
        Expires = case nksip_lib:get_integer(expires, Opts, -1) of
            Exp when is_integer(Exp), Exp>=0 -> Exp;
            _ -> undefined
        end,
        Event = case nksip_lib:get_value(event, Opts) of
            undefined ->
                undefined;
            EventData ->
                case nksip_parse:tokens(EventData) of
                    [EventToken] -> EventToken;
                    _ -> throw(invalid_event)
                end
        end,
        RUri1 = nksip_parse:uri2ruri(RUri),
        Req = #sipmsg{
            id = nksip_sipmsg:make_id(req, CallId),
            class = {req, nksip_parse:method(Method)},
            app_id = AppId,
            ruri = RUri1,
            vias = [],
            from = From#uri{ext_opts=FromOpts},
            to = To,
            call_id = CallId,
            cseq = CSeq1,
            cseq_method = Method,
            forwards = 70,
            routes = Routes,
            contacts = Contacts,
            expires = Expires,
            headers = Headers1,
            content_type = ContentType,
            require = Require,
            supported = Supported,
            event = Event,
            body = Body,
            from_tag = FromTag,
            to_tag = nksip_lib:get_binary(<<"tag">>, To#uri.ext_opts),
            to_tag_candidate = <<>>,
            transport = #transport{},
            start = nksip_lib:l_timestamp()
        },
        Opts1 = [
            nksip_lib:extract(Opts, pass),
            case lists:member(make_contact, Opts) of
                true -> make_contact;
                false when Method=='INVITE', Contacts==[] -> make_contact;
                false when Method=='SUBSCRIBE', Contacts==[] -> make_contact;
                _ -> []
            end,
            case lists:member(record_route, Opts) of
                true  -> record_route;
                _ -> []
            end,
            case nksip_lib:get_value(local_host, Opts, auto) of
                auto -> [];
                Host -> {local_host, nksip_lib:to_host(Host)}
            end,
            case nksip_lib:get_value(local_host6, Opts, auto) of
                auto -> 
                    [];
                Host6 -> 
                    case nksip_lib:to_ip(Host6) of
                        {ok, HostIp6} -> 
                            % Ensure it is enclosed in `[]'
                            {local_host6, nksip_lib:to_host(HostIp6, true)};
                        error -> 
                            {local_host6, nksip_lib:to_binary(Host6)}
                    end
            end,            
            case nksip_lib:get_value(fields, Opts) of
                undefined -> [];
                Fields -> {fields, Fields}
            end,
            case lists:member(async, Opts) of
                true -> async;
                false -> []
            end,
            case nksip_lib:get_value(callback, Opts) of
                Callback when is_function(Callback, 1) -> {callback, Callback};
                _ -> []
            end,
            case nksip_lib:get_value(prack, Opts) of
                PrAck when is_function(PrAck, 2) -> {prack, PrAck};
                _ -> []
            end,
            case lists:member(get_request, Opts) of
                true -> get_request;
                false -> []
            end,
            case lists:member(get_response, Opts) of
                true -> get_response;
                false -> []
            end
        ],
        {ok, Req, lists:flatten(Opts1)}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request()) ->
    nksip:request().

make_cancel(#sipmsg{class={req, _}, call_id=CallId, vias=[Via|_], headers=Hds}=Req) ->
    Req#sipmsg{
        class = {req, 'CANCEL'},
        id = nksip_sipmsg:make_id(req, CallId),
        cseq_method = 'CANCEL',
        forwards = 70,
        vias = [Via],
        headers = nksip_lib:extract(Hds, <<"Route">>),
        contacts = [],
        content_type = undefined,
        require = [],
        supported = [],
        expires = undefined,
        event = undefined,
        body = <<>>
    }.


%% @doc Generates an <i>ACK</i> request from an <i>INVITE</i> request and a response
-spec make_ack(nksip:request(), nksip:response()) ->
    nksip:request().

make_ack(Req, #sipmsg{to=To, to_tag=ToTag}) ->
    make_ack(Req#sipmsg{to=To, to_tag=ToTag}).


%% @private
-spec make_ack(nksip:request()) ->
    nksip:request().

make_ack(#sipmsg{vias=[Via|_], call_id=CallId}=Req) ->
    Req#sipmsg{
        class = {req, 'ACK'},
        id = nksip_sipmsg:make_id(req, CallId),
        vias = [Via],
        cseq_method = 'ACK',
        forwards = 70,
        routes = [],
        contacts = [],
        headers = [],
        content_type = undefined,
        require = [],
        supported = [],
        expires = undefined,
        event = undefined,
        body = <<>>
    }.


%% @doc Checks if a response is a stateless response
-spec is_stateless(nksip:response(), binary()) ->
    boolean().

is_stateless(Resp, GlobalId) ->
    #sipmsg{vias=[#via{opts=Opts}|_]} = Resp,
    case nksip_lib:get_binary(<<"branch">>, Opts) of
        <<"z9hG4bK", Branch/binary>> ->
            case binary:split(Branch, <<"-">>) of
                [BaseBranch, NkSip] ->
                    case nksip_lib:hash({BaseBranch, GlobalId, stateless}) of
                        NkSip -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.


