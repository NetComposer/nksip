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

-export([make/4, make_cancel/1, is_stateless/2]).
-include("nksip.hrl").
 

%% ===================================================================
%% Public
%% ===================================================================


%% @doc Generates a new request.
%% See {@link nksip_uac} for the decription of most options.
%% It will also add a <i>From</i> tag if not present.
-spec make(nksip:app_id(), nksip:method(), nksip:user_uri(), nksip_lib:proplist()) ->    
    {ok, nksip:request(), nksip_lib:proplist()} | {error, Error} when
    Error :: invalid_uri | invalid_from | invalid_to | invalid_route |
             invalid_contact | invalid_cseq.

make(AppId, Method, Uri, Opts) ->
    try
        case nksip_parse:uris(Uri) of
            [RUri] -> ok;
            _ -> RUri = throw(invalid_uri)
        end,
        case nksip_parse:uris(nksip_lib:get_value(from, Opts)) of
            [From] -> ok;
            _ -> From = throw(invalid_from) 
        end,
        case nksip_lib:get_value(to, Opts) of
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
        case nksip_lib:get_value(route, Opts, []) of
            [] ->
                Routes = [];
            RouteSpec ->
                case nksip_parse:uris(RouteSpec) of
                    [] -> Routes = throw(invalid_route);
                    Routes -> ok
                end
        end,
        case nksip_lib:get_value(contact, Opts, []) of
            [] ->
                Contacts = [];
            ContactSpec ->
                case nksip_parse:uris(ContactSpec) of
                    [] -> Contacts = throw(invalid_contact);
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
        case nksip_lib:get_value(tag, From#uri.ext_opts) of
            undefined -> 
                FromTag = nksip_lib:uid(),
                FromOpts = [{tag, FromTag}|From#uri.ext_opts];
            FromTag -> 
                FromOpts = From#uri.ext_opts
        end,
        case nksip_lib:get_binary(user_agent, Opts) of
            <<>> -> UserAgent = <<"NkSIP ", ?VERSION>>;
            UserAgent -> ok
        end,
        Headers = 
                proplists:get_all_values(pre_headers, Opts) ++
                nksip_lib:get_value(headers, Opts, []) ++
                proplists:get_all_values(post_headers, Opts),
        Body = nksip_lib:get_value(body, Opts, <<>>),
        Headers1 = nksip_headers:update(Headers, [
            {default_single, <<"User-Agent">>, UserAgent},
            case lists:member(make_allow, Opts) of
                true -> {default_single, <<"Allow">>, nksip_sipapp_srv:allowed(AppId)};
                false -> []
            end,
            case lists:member(make_supported, Opts) of
                true -> {default_single, <<"Supported">>, ?SUPPORTED};
                false -> []
            end,
            case lists:member(make_accept, Opts) of
                true -> {default_single, <<"Accept">>, ?ACCEPT};
                false -> []
            end,
            case lists:member(make_date, Opts) of
                true -> {default_single, <<"Date">>, nksip_lib:to_binary(
                                                    httpd_util:rfc1123_date())};
                false -> []
            end
        ]),
        ContentType = case nksip_lib:get_binary(content_type, Opts) of
            <<>> when is_record(Body, sdp) -> [{<<"application/sdp">>, []}];
            <<>> when not is_binary(Body) -> [{<<"application/nksip.ebf.base64">>, []}];
            <<>> -> [];
            ContentTypeSpec -> nksip_parse:tokens([ContentTypeSpec])
        end,
         Req = #sipmsg{
            id = erlang:phash2(make_ref()),
            class = req,
            app_id = AppId,
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
            data = [],
            start = nksip_lib:l_timestamp()
        },
        Opts1 = case lists:member(make_contact, Opts) of
            false when Method=:='INVITE', Contacts=:=[] -> [make_contact];
            _ -> []
        end,
        {ok, Req, Opts1}
    catch
        throw:Throw -> {error, Throw}
    end.





%% @doc Generates a <i>CANCEL</i> request from an <i>INVITE</i> request.
-spec make_cancel(nksip:request()) ->
    nksip:request().

make_cancel(#sipmsg{class=req, vias=[Via|_]}=Req) ->
    Req#sipmsg{
        method = 'CANCEL',
        cseq_method = 'CANCEL',
        forwards = 70,
        vias = [Via],
        headers = [],
        contacts = [],
        content_type = [],
        body = <<>>,
        data = []
    }.


%% @doc Checks if a response is a stateless response
-spec is_stateless(nksip:response(), binary()) ->
    boolean().

is_stateless(Resp, GlobalId) ->
    #sipmsg{vias=[#via{opts=Opts}|_]} = Resp,
    case nksip_lib:get_binary(branch, Opts) of
        <<"z9hG4bK", Branch/binary>> ->
            StatelessId = nksip_lib:hash({Branch, GlobalId, stateless}),
            case nksip_lib:get_binary(nksip, Opts) of
                StatelessId -> true;
                _ -> false
            end;
        _ ->
            false
    end.


