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
-export([make/5, make/3, make_cancel/2, make_ack/2, make_ack/1, is_stateless/2]).
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
    {ok, nksip:request(), nksip_lib:proplist()} | {error, term()}.
    
make(AppId, Method, Uri, Opts, Config) ->
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
        FromTag = nksip_lib:uid(),
        DefTo = RUri1#uri{port=0, opts=[], headers=[], ext_opts=[], ext_headers=[]},
        CallId = nksip_lib:luid(),
        Req1 = #sipmsg{
            id = nksip_sipmsg:make_id(req, CallId),
            class = {req, Method1},
            app_id = AppId,
            ruri = RUri1#uri{headers=[], ext_opts=[], ext_headers=[]},
            from = {DefFrom, FromTag},
            to1 = {DefTo, <<>>},
            call_id = CallId,
            cseq = {nksip_config:cseq(), Method1},
            forwards = 70,
            transport = #transport{},
            start = nksip_lib:l_timestamp()
        },
        ConfigOpts = [
            O || O <- Config, 
            case O of
                no_100 -> 
                    true;
                {H, _} when H==from; H==route; H==pass; 
                            H==local_host; H==local_host6 -> 
                    true;
                _ -> 
                    false
            end
        ],
        {Req2, ReqOpts1} = parse_opts(ConfigOpts, Req1, [], Config),
        Req3 = case RUri of
            #uri{headers=[]} -> Req2;
            #uri{headers=Headers} -> nksip_parse_header:headers(Headers, Req2, post)
        end,
        {Req4, ReqOpts2} = parse_opts(Opts, Req3, ReqOpts1, Config),
        {ok, Req4, ReqOpts2}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @private 
-spec make(nksip:request(), nksip_lib:proplist(), nksip_lib:proplist()) ->    
    {ok, nksip:request(), nksip_lib:proplist()} | {error, term()}.
    
make(Req, Opts, Config) ->
    try
        Req1 = case Req#sipmsg.ruri of
            #uri{headers=[]} -> Req;
            #uri{headers=Headers} -> nksip_parse_header:headers(Headers, Req, post)
        end,
        {Req2, ReqOpts} = parse_opts(Opts, Req1, [], Config),
        {ok, Req2, ReqOpts}
    catch
        throw:Throw -> {error, Throw}
    end.



%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request(), nksip:error_reason()|undefined) ->
    nksip:request().

make_cancel(Req, Reason) ->
    #sipmsg{
        class = {req, _}, 
        cseq = {CSeq, _}, 
        call_id = CallId, 
        vias = [Via|_], 
        headers = Hds
    } = Req,
    Headers1 = nksip_lib:extract(Hds, <<"route">>),
    Headers2 = case Reason of
        undefined ->
            Headers1;
        Reason ->
            case nksip_unparse:error_reason(Reason) of
                error -> Headers1;
                BinReason -> [{<<"reason">>, BinReason}|Headers1]
            end
    end,
    Req#sipmsg{
        class = {req, 'CANCEL'},
        id = nksip_sipmsg:make_id(req, CallId),
        cseq = {CSeq, 'CANCEL'},
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

make_ack(Req, #sipmsg{to1=To}) ->
    make_ack(Req#sipmsg{to1=To}).


%% @private
-spec make_ack(nksip:request()) ->
    nksip:request().

make_ack(#sipmsg{vias=[Via|_], call_id=CallId, cseq={CSeq, _}}=Req) ->
    Req#sipmsg{
        class = {req, 'ACK'},
        id = nksip_sipmsg:make_id(req, CallId),
        vias = [Via],
        cseq = {CSeq, 'ACK'},
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


parse_opts([], Req, Opts, _Config) ->
    {Req, Opts};

% Options user_agent, supported, allow, accept, date, allow_event,
% from, to, max_forwards, call_id, cseq, content_type, require, expires, 
% contact, reason, event, subscription_state, session_exires and min_se replace 
% existing headers.
% Option route adds new routes before existing routes.
% Any other header is inserted before existing ones.
parse_opts([Term|Rest], Req, Opts, Config) ->
    Op = case Term of
        
        % Header manipulation
        {add, Name, Value} -> {add, Name, Value};
        {add, {Name, Value}} -> {add, Name, Value};
        {replace, Name, Value} -> {replace, Name, Value};
        {replace, {Name, Value}} -> {replace, Name, Value};
        {insert, Name, Value} -> {insert, Name, Value};
        {insert, {Name, Value}} -> {insert, Name, Value};

        {Header, Value} when Header==from; Header==to; Header==call_id;
                             Header==content_type; Header==require; Header==supported; 
                             Header==expires; Header==contact; Header==route; 
                             Header==reason; Header==event; 
                             Header==min_se ->
            {replace, Header, Value};

        %% TODO: CHECK
        {subscription_state, ST} when is_tuple(ST) ->
            case catch nksip_unparse:token(ST) of
                Bin when is_binary(Bin) ->
                    {replace, <<"subscription-state">>, Bin};
                _ ->
                    throw({invalid, subscription_state})
            end;
        
        % Special parameters
        to_as_from ->
            case [true || {from, _} <- Rest] of
                [] -> 
                    #sipmsg{from={From, _}} = Req,
                    {replace, <<"To">>, From#uri{ext_opts=[]}};
                _ ->
                    put_at_end
            end;
        {body, Body} ->
            ContentType = case Req#sipmsg.content_type of
                undefined when is_record(Body, sdp) -> <<"application/sdp">>;
                undefined when is_tuple(Body) -> <<"application/nksip.ebf.base64">>;
                CT0 -> CT0
            end,
            {update_req, Req#sipmsg{body=Body, content_type=ContentType}};
        {cseq_num, CSeq} when is_integer(CSeq), CSeq>0, CSeq<4294967296 ->
            #sipmsg{cseq={_, Method}} = Req,
            {update_req, Req#sipmsg{cseq={CSeq, Method}}};
        {min_cseq, MinCSeq} ->
            case [true || {cseq_num, _} <- Rest] of
                [] -> 
                    #sipmsg{cseq={OldCSeq, Method}} =Req,
                    case is_integer(MinCSeq) of
                        true when MinCSeq > OldCSeq -> 
                            {update_req, Req#sipmsg{cseq={MinCSeq, Method}}};
                        true -> 
                            {update_req, Req};
                        false -> 
                            throw({invalid, min_cseq})
                    end;
                _ ->
                    put_at_end
            end;
        {session_expires, SE} ->
            Req1 = nksip_parse_header:parse(<<"session-expires">>, SE, Req, replace),
            {Time, _} = nksip_lib:get_value(<<"session-expires">>, Req1#sipmsg.headers),
            case nksip_config:get_cached(min_se, Config) of
                MinSE when Time<MinSE -> throw({invalid, <<"session-expires">>});
                _ -> ok
            end,
            {update_req, Req1};


        %% Pass-through options
        Opt when Opt==contact; Opt==record_route; Opt==path; Opt==get_request;
                 Opt==get_response; Opt==auto_2xx_ack; Opt==async; Opt==no_100;
                 Opt==stateless; Opt==follow_redirects ->
            {update_opts, [Opt|Opts]};
        {pass, Pass} ->
            {update_opts, [{pass, Pass}|Opts]};
        {meta, List} when is_list(List) ->
            {update_opts, [{meta,List}|Opts]};
        {local_host, Host} ->
            {update_opts, [{local_host, nksip_lib:to_host(Host)}|Opts]};
        {local_host6, Host} ->
            case nksip_lib:to_ip(Host) of
                {ok, HostIp6} -> 
                    % Ensure it is enclosed in `[]'
                    {update_opts, [{local_host6, nksip_lib:to_host(HostIp6, true)}|Opts]};
                error -> 
                    {update_opts, [{local_host6, nksip_lib:to_binary(Host)}|Opts]}
            end;
        {callback, Fun} when is_function(Fun, 1) ->
            {update_opts, [{callback, Fun}|Opts]};
        {prack_callback, Fun} when is_function(Fun, 2) ->
            {update_opts, [{prack_callback, Fun}|Opts]};
        {reg_id, RegId} when is_integer(RegId), RegId>0 ->
            {update_opts, [{reg_id, RegId}|Opts]};
        {refer_subscription_id, Refer} when is_binary(Refer) ->
            {update_opts, [{refer_subscription_id, Refer}|Opts]};

        %% Automatic header generation (replace existing headers)
        user_agent ->
            {replace, <<"user-agent">>, <<"NkSIP ", ?VERSION>>};
        supported ->
            Supported = nksip_lib:get_value(supported, Config, ?SUPPORTED),
            {replace, <<"supported">>, Supported};
        allow ->        
            DefAllow = case lists:member(registrar, Config) of
                true -> <<(?ALLOW)/binary, ",REGISTER">>;
                false -> ?ALLOW
            end,
            Allow = nksip_lib:get_value(allow, Config, DefAllow),
            {replace, <<"allow">>, Allow};
        accept ->
            DefAccept = case Req of
                #sipmsg{class={req, Method}} 
                    when Method=='INVITE'; Method=='UPDATE'; Method=='PRACK' ->
                    <<"application/sdp">>;
                _ -> 
                    ?ACCEPT
            end,
            Accept = nksip_lib:get_value(accept, Config, DefAccept),
            {replace, <<"accept">>, Accept};
        date ->
            Date = nksip_lib:to_binary(httpd_util:rfc1123_date()),
            {replace, <<"date">>, Date};
        allow_event ->
            case nksip_lib:get_value(events, Config) of
                undefined -> {update_req, Req};
                Events -> {replace, <<"allow-event">>, Events}
            end;

        {Name, _} ->
            throw({invalid_option, Name});
        _ ->
            throw({invalid_option, Term})
    end,
    case Op of
        {add, Name1, Value1} ->
            Name2 = nksip_parse_header:name(Name1), 
            ReqP = nksip_parse_header:parse(Name2, Value1, Req, post),
            parse_opts(Rest, ReqP, Opts, Config);
        {replace, Name1, Value1} ->
            Name2 = nksip_parse_header:name(Name1), 
            ReqP = nksip_parse_header:parse(Name2, Value1, Req, replace),
            parse_opts(Rest, ReqP, Opts, Config);
        {insert, Name1, Value1} ->
            Name2 = nksip_parse_header:name(Name1), 
            ReqP = nksip_parse_header:parse(Name2, Value1, Req, pre),
            parse_opts(Rest, ReqP, Opts, Config);
        {update_req, ReqP} -> 
            parse_opts(Rest, ReqP, Opts, Config);
        {update_opts, Opts1} -> 
            parse_opts(Rest, Req, Opts1, Config);
         put_at_end ->
            parse_opts(Rest++[Term], Req, Opts, Config)
    end.





%% ===================================================================
%% EUnit tests
%% ===================================================================

