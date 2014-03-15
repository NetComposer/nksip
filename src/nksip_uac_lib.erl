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

% R: requests
% S: responses
% D: dialogs
% U: subscriptions

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
             invalid_require | invalid_accept | invalid_event | invalid_reason |
             invalid_supported.

make(AppId, Method, Uri, Opts, AppOpts) ->
    try
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uri_method(RUri, Method) of
            {Method1, RUri1} -> ok;
            error -> Method1 = RUri1 = throw(invalid_uri)
        end,
        DefFrom = #uri{user = <<"user">>, domain = <<"nksip">>},
        From = nksip_lib:get_value(from, AppOpts, DefFrom),
        FromTag = nksip_lib:uid(),
        CallId = nksip_lib:luid(),
        Req1 = #sipmsg{
            id = nksip_sipmsg:make_id(req, CallId),
            class = {req, Method1},
            app_id = AppId,
            ruri = RUri1#uri{headers=[], ext_opts=[], ext_headers=[]},
            from = From#uri{ext_opts=[{<<"tag">>, FromTag}]},
            to = RUri1#uri{port=0, opts=[], headers=[], ext_opts=[], ext_headers=[]},
            call_id = CallId,
            cseq = nksip_config:cseq(),
            cseq_method = Method1,
            forwards = 70,
            routes = nksip_lib:get_value(route, AppOpts, []),
            from_tag = FromTag,
            transport = #transport{},
            start = nksip_lib:l_timestamp()
        },
        Req2 = nksip_parse_headers:uri_request(RUri, Req1),
        {Req3, Opts1} = parse_opts(Opts, Req2, [], AppOpts),
        {ok, Req3, Opts1}
    catch
        throw:{invalid, Invalid} -> {invalid, Invalid}
    end.


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




%% @private
-spec parse_opts(nksip_lib:proplist(), nksip:request(), 
            nksip_lib:proplist(), nksip_lib:proplist()) ->
    {nksip_lib:proplist(), nksip:request()}.


parse_opts([], Req, Opts, _AppOpts) ->
    {Req, Opts};

% Options user_agent, supported, allow, accept, date, allow_event,
% from, to, max_forwards, call_id, cseq, content_type, require, expires, 
% contact, reason, event, subscription_state, session_exires and min_se replace 
% existing headers.
% Option route adds new routes before existing routes.
% Any other header is inserted before existing ones.
parse_opts([Term|Rest], Req, Opts, AppOpts) ->
    {Req1, Opts1} = case Term of
        
        % Special parameters
        {body, Body} ->
            ContentType = case Req#sipmsg.content_type of
                undefined when is_record(Body, sdp) -> <<"application/sdp">>;
                undefined when not is_binary(Body) -> <<"application/nksip.ebf.base64">>;
                CT0 -> CT0
            end,
            {Req#sipmsg{body=Body, content_type=ContentType}, Opts};
        {min_cseq, MinCSeq} ->
            case is_integer(MinCSeq) of
                true when MinCSeq > Req#sipmsg.cseq -> {Req#sipmsg{cseq=MinCSeq}, Opts};
                true -> {Req, Opts};
                false -> throw({invalid, min_cseq})
            end;
        {pre_headers, Headers} when is_list(Headers) ->
            {Req#sipmsg{headers=Headers++Req#sipmsg.headers}, Opts};
        {post_headers, Headers} when is_list(Headers) ->
            {Req#sipmsg{headers=Req#sipmsg.headers++Headers}, Opts};

        %% Pass-through options
        contact ->
            {Req, [contact|Opts]};
        record_route ->
            {Req, [record_route|Opts]};
        path ->
            {Req, [path|Opts]};
        get_request ->
            {Req, [get_request|Opts]};
        get_response ->
            {Req, [get_response|Opts]};
        auto_2xx_ack ->
            {Req, [auto_2xx_ack|Opts]};
        async ->
            {Req, [async|Opts]};
        {pass, Pass} ->
            {Req, [{pass, Pass}|Opts]};
        {fields, List} when is_list(List) ->
            {Req, [{fields, List}|Opts]};
        {local_host, auto} ->
            {Req, Opts};
        {local_host, Host} ->
            {Req, [{local_host, nksip_lib:to_host(Host)}|Opts]};
        {local_host6, auto} ->
            {Req, Opts};
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {Req, [{local_host6, nksip_lib:to_host(HostIp6, true)}|Opts]};
                error -> 
                    {Req, [{local_host6, nksip_lib:to_binary(Host)}|Opts]}
            end;
        {callback, Fun} when is_function(Fun, 1) ->
            {Req, [{callback, Fun}|Opts]};
        {prack_callback, Fun} when is_function(Fun, 2) ->
            {Req, [{prack_callback, Fun}|Opts]};
        {reg_id, RegId} when is_integer(RegId), RegId>0 ->
            {Req, [{reg_id, RegId}|Opts]};
        {refer_subscription_id, Refer} when is_binary(Refer) ->
            {Req, [{refer_subscription_id, Refer}|Opts]};

        %% Automatic header generation (replace existing headers)
        user_agent ->
            {write_header(Req, <<"User-Agent">>, <<"NkSIP ", ?VERSION>>), Opts};
        supported ->
            {Req#sipmsg{supported=?SUPPORTED}, Opts};
        allow ->
            Allow = case lists:member(registrar, AppOpts) of
                true -> <<(?ALLOW)/binary, ", REGISTER">>;
                false -> ?ALLOW
            end,
            {write_header(Req, <<"Allow">>, Allow), Opts};
        accept ->
            Accept = case Req of
                #sipmsg{class={req, Method}} 
                    when Method=='INVITE'; Method=='UPDATE'; Method=='PRACK' ->
                    <<"application/sdp">>;
                _ -> 
                    ?ACCEPT
            end,
            {write_header(Req, <<"Accept">>, Accept), Opts};
        date ->
            Date = nksip_lib:to_binary(httpd_util:rfc1123_date()),
            {write_header(Req, <<"Date">>, Date), Opts};
        allow_event ->
            case nksip_lib:get_value(event, AppOpts) of
                undefined -> 
                    {Req, Opts};
                Events -> 
                    AllowEvent = nksip_lib:bjoin(Events),
                    {write_header(Req, <<"Allow-Event">>, AllowEvent), Opts}
            end;

        % Standard headers (replace existing headers)
        {from, From} ->
            case nksip_parse:uris(From) of
                [#uri{ext_opts=ExtOpts}=FromUri] -> 
                    FromTag1 = case nksip_lib:get_value(<<"tag">>, ExtOpts) of
                        undefined -> Req#sipmsg.to_tag;
                        NewToTag -> NewToTag
                    end,
                    ExtOpts1 = nksip_lib:store_value(<<"tag">>, FromTag1, ExtOpts),
                    FromUri1 = FromUri#uri{ext_opts=ExtOpts1},
                    {Req#sipmsg{from=FromUri1, from_tag=FromTag1}, Opts};
                _ -> 
                    throw({invalid, from}) 
            end;
        {to, as_from} ->
            {Req#sipmsg{to=(Req#sipmsg.from)#uri{ext_opts=[]}}, Opts};
        {to, To} ->
            case nksip_parse:uris(To) of
                [#uri{ext_opts=ExtOpts}=ToUri] -> 
                    ToTag = nksip_lib:get_value(<<"tag">>, ExtOpts, <<>>),
                    {Req#sipmsg{to=ToUri, to_tag=ToTag}, Opts};
                _ -> 
                    throw({invalid, to}) 
            end;
        {max_forwards, Fwds} when is_integer(Fwds), Fwds>=0 -> 
            {Req#sipmsg{forwards=Fwds}, Opts};
        {call_id, CallId} when is_binary(CallId), byte_size(CallId)>=1 ->
            {Req#sipmsg{call_id=CallId}, Opts};
        {cseq, CSeq} when is_integer(CSeq), CSeq>0 ->
            {Req#sipmsg{cseq=CSeq}, Opts};
        {cseq, _} ->
            throw({invalid, cseq});
        {content_type, CT} ->
            case nksip_parse:tokens(CT) of
               [CT1] -> {Req#sipmsg{content_type=CT1}, Opts};
               error -> throw({invalid, content_type})
            end;
        {require, Require} ->
            case nksip_parse:tokens(Require) of
                error -> throw({invalid, require});
                Tokens -> {Req#sipmsg{require=[T||{T, _}<-Tokens]}, Opts}
            end;
        {supported, Supported} ->
            case nksip_parse:tokens(Supported) of
                error -> throw({invalid, supported});
                Tokens -> {Req#sipmsg{supported=[T||{T, _}<-Tokens]}, Opts}
            end;
        {expires, Expires} when is_integer(Expires), Expires>=0 ->
            {Req#sipmsg{expires=Expires}, Opts};
        {contact, Contact} ->
            case nksip_parse:uris(Contact) of
                error -> throw({invalid, contact});
                Uris -> {Req#sipmsg{contacts=Uris}, Opts}
            end;
        {reason, Reason} when is_tuple(Reason) ->
            case nksip_unparse:error_reason(Reason) of
                error -> throw({invalid, reason});
                Bin -> {write_header(Req, <<"Reason">>, Bin), Opts}
            end;
        {event, Event} ->
            case nksip_parse:tokens(Event) of
                [Token] -> {Req#sipmsg{event=Token}, Opts};
                _ -> throw({invalid, event})
            end;
        {subscription_state, ST} when is_tuple(ST) ->
            case catch nksip_unparse:token(ST) of
                Bin when is_binary(Bin) ->
                    {write_header(Req, <<"Subscription-State">>, Bin), Opts};
                _ ->
                    throw({invalid, subscription_state})
            end;
        {session_expires, SE} ->
            MinSE = nksip_config:get_cached(min_session_expires, AppOpts),
            case SE of
                0 ->
                    {Req, Opts};
                {Int, Class} when 
                        (Class==uac orelse Class==uas) andalso
                        is_integer(Int) andalso Int >= MinSE ->
                    Token = {Int, [{<<"refresher">>, Class}]},
                    {write_header(Req, <<"Session-Expires">>, Token), Opts};
                Int when is_integer(Int) andalso Int >= MinSE ->
                    {write_header(Req, <<"Session-Expires">>, Int), Opts};
                _ ->
                    throw({invalid, session_expires})
            end;
        {min_se, MinSE} when is_integer(MinSE), MinSE > 0 ->
            {write_header(Req, <<"Min-SE">>, MinSE), Opts};

        % Routes (added before existing ones)
        {route, Route} ->
            % Routes are inserted before any other
            case nksip_parse:uris(Route) of
                error -> throw({invalid, route});
                Uris -> {Req#sipmsg{routes=Uris++Req#sipmsg.routes}, Opts}
            end;

        % Default header (inserted before existing ones)
        {Name, Value} ->
            case nksip_parse_header:header_name(Name) of
                unknown -> throw({invalid, Name});
                Name -> Req#sipmsg{headers=[{Name, Value}|Req#sipmsg.headers]}
            end;
        _ ->
            throw({invalid_option, Term})
    end,
    parse_opts(Rest, Req1, Opts1, AppOpts).


%% @private
write_header(#sipmsg{headers=Headers}=Req, Name, Value) ->
    Headers1 = nksip_lib:delete(Headers, Name),
    Req#sipmsg{headers=[{Name, Value}|Headers1]}.




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





