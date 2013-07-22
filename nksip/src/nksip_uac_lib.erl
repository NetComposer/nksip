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

-export([make/4, make_cancel/1, response/1]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
%% It will also add a <i>From</i> tag if not present.
-spec make(nksip:sipapp_id(), nksip:method(), nksip:user_uri(), nksip_lib:proplist()) ->    
    {ok, nksip:request()} | {error, Error} when
    Error :: unknown_core | invalid_uri | invalid_from | invalid_to | invalid_route |
             invalid_contact | invalid_cseq.

make(AppId, Method, Uri, Opts) ->
    try
        Opts1 = case catch nksip_sipapp_srv:get_opts(AppId) of
            {'EXIT', _} -> throw(unknown_core);
            CoreOpts -> Opts ++ CoreOpts
        end,
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uris(nksip_lib:get_value(from, Opts1)) of
            [From] -> ok;
            _ -> From = throw(invalid_from) 
        end,
        case nksip_lib:get_value(to, Opts1) of
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
        case nksip_lib:get_value(route, Opts1, []) of
            [] ->
                Routes = [];
            RouteSpec ->
                case nksip_parse:uris(RouteSpec) of
                    [] -> Routes = throw(invalid_route);
                    Routes -> ok
                end
        end,
        case nksip_lib:get_value(contact, Opts1, []) of
            [] ->
                Contacts = [];
            ContactSpec ->
                case nksip_parse:uris(ContactSpec) of
                    [] -> Contacts = throw(invalid_contact);
                    Contacts -> ok
                end
        end,
        case nksip_lib:get_binary(call_id, Opts1) of
            <<>> -> CallId = nksip_lib:luid();
            CallId -> ok
        end,
        CSeq = case nksip_lib:get_integer(cseq, Opts1, -1) of
            -1 -> nksip_config:cseq();
            UCSeq when is_integer(UCSeq), UCSeq > 0 -> UCSeq;
            _ -> throw(invalid_cseq)
        end,
        CSeq1 = case nksip_lib:get_integer(min_cseq, Opts1) of
            MinCSeq when MinCSeq > CSeq -> MinCSeq;
            _ -> CSeq
        end,
        case nksip_lib:get_value(tag, From#uri.ext_opts) of
            undefined -> 
                FromTag = nksip_lib:uid(),
                FromOpts = [{tag, FromTag}|From#uri.ext_opts];
            FromTag -> 
                FromOpts = From#uri.ext_opts
        end,
        case nksip_lib:get_binary(user_agent, Opts1) of
            <<>> -> UserAgent = <<"NkSIP ", ?VERSION>>;
            UserAgent -> ok
        end,
        Headers = 
                proplists:get_all_values(pre_headers, Opts1) ++
                nksip_lib:get_value(headers, Opts1, []) ++
                proplists:get_all_values(post_headers, Opts1),
        Body = nksip_lib:get_value(body, Opts1, <<>>),
        Headers1 = nksip_headers:update(Headers, [
            {default_single, <<"User-Agent">>, UserAgent},
            case lists:member(make_allow, Opts1) of
                true -> {default_single, <<"Allow">>, nksip_sipapp_srv:allowed(AppId)};
                false -> []
            end,
            case lists:member(make_supported, Opts1) of
                true -> {default_single, <<"Supported">>, ?SUPPORTED};
                false -> []
            end,
            case lists:member(make_accept, Opts1) of
                true -> {default_single, <<"Accept">>, ?ACCEPT};
                false -> []
            end,
            case lists:member(make_date, Opts1) of
                true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                    httpd_util:rfc1123_date())};
                false -> []
            end
        ]),
        ContentType = case nksip_lib:get_binary(content_type, Opts1) of
            <<>> when is_record(Body, sdp) -> [{<<"application/sdp">>, []}];
            <<>> when not is_binary(Body) -> [{<<"application/nksip.ebf.base64">>, []}];
            <<>> -> [];
            ContentTypeSpec -> nksip_parse:tokens(ContentTypeSpec)
        end,
        Opts2 = case lists:member(make_contact, Opts1) of
            true -> Opts1;
            false when Method=:='INVITE', Contacts=:=[] -> [make_contact|Opts1];
            false -> Opts1
        end,
        Opts3 = nksip_lib:extract(lists:flatten(Opts2), 
                        [respfun, make_contact, local_host, pass, 
                            full_response, full_request, dialog_force_send,
                            no_uac_expire]),
        SipMsg = #sipmsg{
            class = request,
            sipapp_id = AppId,
            method = nksip_parse:method(Method),
            ruri = nksip_parse:uri2ruri(RUri),
            vias = [],
            from = From#uri{ext_opts=FromOpts},
            to = To,
            call_id = CallId,
            cseq = CSeq1,
            cseq_method = Method,
            forwards = 70,
            routes = Routes,
            contacts = Contacts,
            headers = Headers1,
            content_type = ContentType,
            body = Body,
            response = undefined,
            from_tag = FromTag,
            to_tag = nksip_lib:get_binary(tag, To#uri.ext_opts),
            transport = #transport{},
            opts = Opts3,
            start = nksip_lib:l_timestamp()
        },
        {ok, SipMsg}
    catch
        throw:Throw -> {error, Throw}
    end.


%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request()) ->
    nksip:request().

make_cancel(#sipmsg{vias=[Via|_], opts=Opts}=Req) ->
    Req#sipmsg{
        method = 'CANCEL',
        cseq_method = 'CANCEL',
        forwards = 70,
        vias = [Via],
        headers = [],
        contacts = [],
        content_type = [],
        body = <<>>,
        opts = Opts
    }.


%% @private Called when a response is received to be processed
-spec response(nksip:response()) ->
    ok.

response(#sipmsg{vias=[#via{opts=Opts}|ViaR], sipapp_id=AppId, call_id=CallId,
                    cseq_method=Method, response=Code}=Response) ->
    case nksip_transaction_uac:response(Response) of
        ok -> 
            ?debug(AppId, CallId, "UAC response ~p, (~p) is in transaction", 
                   [Code, Method]),
            ok;
        no_transaction ->
            case nksip_lib:get_binary(branch, Opts) of
                <<"z9hG4bK", Branch/binary>> when ViaR =/= [] ->
                    GlobalId = nksip_config:get(global_id),
                    StatelessId = nksip_lib:hash({Branch, GlobalId, stateless}),
                    case nksip_lib:get_binary(nksip, Opts) of
                        StatelessId -> nksip_uas_proxy:response_stateless(Response);
                        _ -> response_error(Response)
                    end;
                _ ->
                    response_error(Response)
            end
    end.


%% @private
-spec response_error(nksip:response()) ->
    ok.

response_error(#sipmsg{
                    sipapp_id = AppId, 
                    call_id = CallId, 
                    vias= [Via|_], 
                    cseq_method = Method,
                    response = Code, 
                    transport=#transport{remote_ip=Ip, remote_port=Port}
                  }) ->
    case nksip_transport:is_local(AppId, Via) of
        true ->
            ?notice(AppId, CallId, "UAC received ~p ~p response with no "
                    "matching transaction", [Code, Method]);
        false ->
            ?notice(AppId, CallId, 
                    "UAC received non-local ~p response from ~p:~p", [Code, Ip, Port])
    end.