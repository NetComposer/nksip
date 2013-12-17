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

-export([send_any/4, send_dialog/4]).
-export([make/5, make_cancel/2, make_ack/2, make_ack/1, is_stateless/2]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


-spec send_any(nksip:app_id(), nksip:method(), 
               nksip:user_uri() | nksip_dialog:spec() | nksip_subscription:id(),
               nksip_lib:proplist()) ->
    nksip_uac:result() | nksip_uac:ack_result() | {error, nksip_uac:error()}.

send_any(AppId, Method, UriOrDialog, Opts) ->
    case UriOrDialog of
        <<Class, $_, _/binary>> when Class==$R; Class==$S; Class==$D; Class==$U ->
            send_dialog(AppId, Method, UriOrDialog, Opts);
        UserUri ->
            nksip_call:send(AppId, Method, UserUri, Opts)
    end.


%% @private
-spec send_dialog(nksip:app_id(), nksip:method(), 
                  nksip_dialog:spec() | nksip_subscription:id(),
                  nksip_lib:proplist()) ->
    nksip_uac:result() | nksip_uac:ack_result() | {error, nksip_uac:error()}.

send_dialog(AppId, Method, <<Class, $_, _/binary>>=Id, Opts)
            when Class==$R; Class==$S; Class==$D; Class==$U ->
    case nksip_dialog:id(AppId, Id) of
        <<>> -> 
            {error, unknown_dialog};
        DialogId when Class==$U ->
            nksip_call:send_dialog(AppId, DialogId, Method, [{subscription_id, Id}|Opts]);
        DialogId ->
            nksip_call:send_dialog(AppId, DialogId, Method, Opts)
    end.


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
-spec make(nksip:app_id(), nksip:method(), nksip:user_uri(), 
           nksip_lib:proplist(), nksip_lib:proplist()) ->    
    {ok, nksip:request(), nksip_lib:proplist()} | {error, Error} when
    Error :: invalid_uri | invalid_from | invalid_to | invalid_route |
             invalid_contact | invalid_cseq | invalid_content_type |
             invalid_require | invalid_accept | invalid_event | invalid_reason.

make(AppId, Method, Uri, Opts, AppOpts) ->
    try
        case opts_from_uri(Uri) of
            error -> 
                Method1 = Uri1 = Opts1 = throw(invalid_uri);
            {UriMethod, Uri1, UriOpts} ->
                Method1 = case UriMethod of
                    Method when Method/=undefined -> Method;
                    _ when Method==undefined, UriMethod/=undefined -> UriMethod;
                    undefined when Method/=undefined -> Method;
                    undefined -> 'INVITE';
                    _ -> throw(invalid_uri)
                end,
                Opts1 = Opts++UriOpts
        end,
        FullOpts = Opts1++AppOpts,
        case nksip_parse:uris(Uri1) of
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
        case nksip_lib:get_binary(call_id, Opts1) of
            <<>> -> CallId = nksip_lib:luid();
            CallId -> ok
        end,
        CSeq = case nksip_lib:get_value(cseq, Opts1) of
            undefined -> nksip_config:cseq();
            UCSeq when is_integer(UCSeq), UCSeq > 0 -> UCSeq;
            _ -> throw(invalid_cseq)
        end,
        CSeq1 = case nksip_lib:get_integer(min_cseq, Opts1) of
            MinCSeq when MinCSeq > CSeq -> MinCSeq;
            _ -> CSeq
        end,
        Forwards = case nksip_lib:get_value(max_forwards, Opts1) of
            undefined -> 
                70;
            Forw0 ->
                case nksip_lib:to_integer(Forw0) of
                    Forw1 when is_integer(Forw1), Forw1>=0 -> Forw1;
                    _ -> 70
                end
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
        Body = nksip_lib:get_value(body, Opts1, <<>>),
        ContentType = case nksip_lib:get_binary(content_type, Opts1) of
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
        Require1 = case nksip_lib:get_value(require, Opts1) of
            undefined -> 
                [];
            ReqOpts ->
                case nksip_parse:tokens(ReqOpts) of
                    error -> throw(invalid_require);
                    ReqTokens0 -> ReqTokens0
                end
        end,
        Require2 = case 
            Method1=='INVITE' andalso lists:member(require_100rel, FullOpts) 
        of
            true -> 
                case lists:keymember(<<"100rel">>, 1, Require1) of
                    true -> Require1;
                    false -> [{<<"100rel">>, []}|Require1]
                end;
            false -> 
                Require1
        end,
        Supported = case lists:member(make_supported, FullOpts) of
            true -> nksip_lib:get_value(supported, AppOpts, ?SUPPORTED);
            false -> []
        end,
        Expires = case nksip_lib:get_value(expires, Opts1) of
            undefined -> 
                undefined;
            Exp0 ->
                case nksip_lib:to_integer(Exp0) of
                    Exp1 when is_integer(Exp1), Exp1>=0 -> Exp1;
                    _ -> undefined
                end
        end,
        Event = case nksip_lib:get_value(event, Opts1) of
            undefined ->
                undefined;
            EventData ->
                case nksip_parse:tokens(EventData) of
                    [EventToken] -> EventToken;
                    _ -> throw(invalid_event)
                end
        end,
        Headers = 
                proplists:get_all_values(pre_headers, FullOpts) ++
                nksip_lib:get_value(headers, FullOpts, []) ++
                proplists:get_all_values(post_headers, FullOpts),
        
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
            case lists:member(make_accept, Opts1) of
                true -> 
                    Accept = case nksip_lib:get_value(accept, FullOpts) of
                        undefined when Method1=='INVITE'; Method1=='UPDATE'; 
                                       Method1=='PRACK' -> 
                            [{<<"application/sdp">>, []}];
                        undefined ->
                            ?ACCEPT;
                        AcceptList ->
                            case nksip_parse:tokens(AcceptList) of
                                error -> throw(invalid_accept);
                                AcceptTokens -> AcceptTokens
                            end
                    end,
                    {default_single, <<"Accept">>, nksip_unparse:token(Accept)};
                false -> 
                    []
            end,
            case lists:member(make_date, FullOpts) of
                true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                    httpd_util:rfc1123_date())};
                false -> []
            end,
            case nksip_lib:get_value(parsed_subscription_state, Opts1) of
                undefined -> 
                    [];
                SubsState0 -> 
                    SubsState = nksip_unparse:token(SubsState0),
                    {default_single, <<"Subscription-State">>, SubsState}
            end,
            case nksip_lib:get_value(reason, Opts1) of
                undefined ->
                    [];
                Reason1 ->
                    case nksip_unparse:error_reason(Reason1) of
                        error -> throw(invalid_reason);
                        Reason2 -> {default_single, <<"Reason">>, Reason2}
                    end
            end
        ]),
        Req = #sipmsg{
            id = nksip_sipmsg:make_id(req, CallId),
            class = {req, Method1},
            app_id = AppId,
            ruri = RUri#uri{headers=[], ext_opts=[], ext_headers=[]},
            vias = [],
            from = From#uri{ext_opts=FromOpts},
            to = To,
            call_id = CallId,
            cseq = CSeq1,
            cseq_method = Method1,
            forwards = Forwards,
            routes = Routes,
            contacts = Contacts,
            expires = Expires,
            headers = Headers1,
            content_type = ContentType,
            require = Require2,
            supported = Supported,
            event = Event,
            body = Body,
            from_tag = FromTag,
            to_tag = nksip_lib:get_binary(<<"tag">>, To#uri.ext_opts),
            to_tag_candidate = <<>>,
            transport = #transport{},
            start = nksip_lib:l_timestamp()
        },
        ExtOpts = [
            nksip_lib:extract(Opts1, pass),
            case lists:member(make_contact, Opts1) of
                true -> 
                    make_contact;
                false when Contacts==[] andalso
                           (Method1=='INVITE' orelse Method1=='SUBSCRIBE' orelse
                            Method1=='REFER') -> 
                    make_contact;
                _ -> 
                    []
            end,
            case lists:member(record_route, Opts1) of
                true  -> record_route;
                _ -> []
            end,
            case nksip_lib:get_value(local_host, Opts1, auto) of
                auto -> [];
                Host -> {local_host, nksip_lib:to_host(Host)}
            end,
            case nksip_lib:get_value(local_host6, Opts1, auto) of
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
            case nksip_lib:get_value(fields, Opts1) of
                undefined -> [];
                Fields -> {fields, Fields}
            end,
            case lists:member(async, Opts1) of
                true -> async;
                false -> []
            end,
            case nksip_lib:get_value(callback, Opts1) of
                Callback when is_function(Callback, 1) -> {callback, Callback};
                _ -> []
            end,
            case nksip_lib:get_value(prack, Opts1) of
                PrAck when is_function(PrAck, 2) -> {prack, PrAck};
                _ -> []
            end,
            case lists:member(get_request, Opts1) of
                true -> get_request;
                false -> []
            end,
            case lists:member(get_response, Opts1) of
                true -> get_response;
                false -> []
            end,
            case lists:member(auto_2xx_ack, Opts1) of
                true -> auto_2xx_ack;
                false -> []
            end,
            case nksip_lib:get_binary(refer_subscription_id, Opts1) of
                <<>> -> [];
                ReferSubsId -> {refer_subscription_id, ReferSubsId}
            end
        ],
        {ok, Req, lists:flatten(ExtOpts)}
    catch
        throw:Throw -> {error, Throw}
    end.



%% @private
-spec opts_from_uri(nksip:user_uri()) ->
    {undefined|nksip:method(), nksip:uri(), nksip_lib:proplist()} | error.

opts_from_uri(Uri) ->
    case nksip_parse:uris(Uri) of
        [#uri{opts=UriOpts, headers=Headers}=Uri1] ->
            {Method, Uri2} = case lists:keytake(<<"method">>, 1, UriOpts) of
                {value, {_, RawMethod}, Rest} ->
                    {nksip_parse:method(RawMethod), Uri1#uri{opts=Rest}};
                false ->
                    {undefined, Uri1}
            end,
            Opts = make_from_uri(Headers, []),
            case is_atom(Method) of
                true -> {Method, Uri2#uri{headers=[]}, Opts};
                _ -> error
            end;
        _ ->
            error
    end.


%% @private
make_from_uri([], Opts) ->
    lists:reverse(Opts);

make_from_uri([{Name, Value}|Rest], Opts) ->
    Value1 = list_to_binary(http_uri:decode(nksip_lib:to_list(Value))), 
    Opts1 = case nksip_parse:raw_header(nksip_lib:to_list(Name)) of
        <<"From">> -> [{from, Value1}|Opts];
        <<"To">> -> [{to, Value1}|Opts];
        <<"Route">> -> [{route, Value1}|Opts];
        <<"Contact">> -> [{contact, Value1}|Opts];
        <<"Call-ID">> -> [{call_id, Value1}|Opts];
        <<"User-Agent">> -> [{user_agent, Value1}|Opts];
        <<"Content-Type">> -> [{content_type, Value1}|Opts];
        <<"Require">> -> [{require, Value1}|Opts];
        <<"Supported">> -> [{supported, Value1}, make_supported|Opts];
        <<"Expires">> -> [{expires, Value1}|Opts];
        <<"Event">> -> [{event, Value1}|Opts];
        <<"Max-Forwards">> -> [{max_forwards, Value1}|Opts];
        <<"CSeq">> -> Opts;
        <<"Via">> -> Opts;
        <<"Content-Length">> -> Opts;
        <<"body">> -> [{body, Value1}|Opts];    
        _ -> [{post_headers, [{Name, Value1}]}|Opts]
    end,
    make_from_uri(Rest, Opts1).


%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request(), nksip:error_reason()|undefined) ->
    nksip:request().

make_cancel(Req, Reason) ->
    #sipmsg{class={req, _}, call_id=CallId, vias=[Via|_], headers=Hds} = Req,
    Headers1 = nksip_lib:extract(Hds, <<"Route">>),
    Headers2 = case Reason of
        undefined ->
            Headers1;
        Reason ->
            case nksip_unparse:error_reason(Reason) of
                error -> Headers1;
                BinReason -> [{<<"Reason">>, BinReason}|Headers1]
            end
    end,
    Req#sipmsg{
        class = {req, 'CANCEL'},
        id = nksip_sipmsg:make_id(req, CallId),
        cseq_method = 'CANCEL',
        forwards = 70,
        vias = [Via],
        headers = Headers2,
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



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
uri_test() ->
    {'REGISTER', #uri{opts=[<<"lr">>]}, []} = 
        opts_from_uri("<sip:host;method=REGISTER;lr>"),

    {undefined, #uri{}, 
        [
            {from, <<"sip:u1@from">>},
            {to, <<"sip:to">>},
            {contact, <<"sip:a">>},
            {post_headers, [{<<"user1">>, <<"data1">>}]},
            {call_id, <<"abc">>},
            {user_agent, <<"user">>},
            {content_type, <<"application/sdp">>},
            {require, <<"a;b;c">>},
            make_supported,
            {supported, <<"d;e">>},
            {expires, <<"5">>},
            {max_forwards, <<"69">>},
            {body, <<"my body">>},
            {post_headers, [{<<"user2">>, <<"data2">>}]}

        ]
    } = opts_from_uri("<sip:host?FROM=sip:u1%40from&to=sip:to&contact=sip:a"
                      "&user1=data1&call-ID=abc&user-agent=user"
                      "&content-type = application/sdp"
                      "&require=a;b;c&supported=d;e & expires=5"
                      "&cseq=ignored&via=ignored&max-forwards=69"
                      "&content-length=ignored&body=my%20body"
                      "&user2=data2>").
-endif.








