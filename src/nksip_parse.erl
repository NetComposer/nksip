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

%% @doc SIP message parsing functions
%%
%% This module implements several functions to parse sip requests, responses
%% headers, uris, vias, etc.

-module(nksip_parse).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-export([method/1, aors/1, ruris/1, vias/1]).
-export([uri_method/2]).
-export([transport/1]).
-export([packet/4, packet/3]).

-export_type([msg_class/0]).

-type msg_class() :: {req, nksip:method(), binary()} | 
                     {resp, nksip:sip_code(), binary()}.



%% ===================================================================
%% Public
%% ===================================================================

%% @doc Parses any `term()' into a valid `nksip:method()'. If recognized it will be an
%% `atom', or a `binary' if not.
-spec method(binary() | atom() | string()) -> 
    nksip:method() | binary().

method(Method) when is_atom(Method) ->
    Method;
method(Method) when is_list(Method) ->
    method(list_to_binary(Method));
method(Method) when is_binary(Method) ->
    case Method of
        <<"INVITE">> -> 'INVITE';
        <<"REGISTER">> -> 'REGISTER';
        <<"BYE">> -> 'BYE';
        <<"ACK">> -> 'ACK';
        <<"CANCEL">> -> 'CANCEL';
        <<"OPTIONS">> -> 'OPTIONS';
        <<"SUBSCRIBE">> -> 'SUBSCRIBE';
        <<"NOTIFY">> -> 'NOTIFY';
        <<"PUBLISH">> -> 'PUBLISH';
        <<"REFER">> -> 'REFER';
        <<"MESSAGE">> -> 'MESSAGE';
        <<"INFO">> -> 'INFO';
        <<"PRACK">> -> 'PRACK';
        <<"UPDATE">> -> 'UPDATE';
        _ -> Method 
    end.


%% @doc Parses all AORs found in `Term'.
-spec aors(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:aor()].
                
aors(Term) ->
    [{Scheme, User, Domain} || 
     #uri{scheme=Scheme, user=User, domain=Domain} <- nklib_parse:uris(Term)].


%% @doc Parses all URIs found in `Term'.
-spec ruris(Term :: nksip:user_uri() | [nksip:user_uri()]) -> 
    [nksip:uri()] | error.
                
ruris(RUris) -> 
    case nklib_parse:uris(RUris) of
        error -> error;
        Uris -> parse_ruris(Uris, [])
    end.
          

%% @doc Extracts all `via()' found in `Term'
-spec vias(Term :: binary() | string() | [binary() | string()]) -> 
    [nksip:via()] | error.

vias([]) -> [];
vias([First|_]=String) when is_integer(First) -> vias([String]);    % It's a string
vias(List) when is_list(List) -> parse_vias(List, []);
vias(Term) -> vias([Term]).



%% @private Gets the scheme, host and port from an `nksip:uri()' or `via()'
-spec transport(nksip:uri()|nksip:via()) -> 
    {Proto::nksip:protocol(), Host::binary(), Port::inet:port_number()}.

transport(#uri{scheme=Scheme, domain=Host, port=Port, opts=Opts}) ->
    Proto1 = case nklib_util:get_value(<<"transport">>, Opts) of
        Atom when is_atom(Atom) -> 
            Atom;
        Other ->
            LcTransp = string:to_lower(nklib_util:to_list(Other)),
            case catch list_to_existing_atom(LcTransp) of
                {'EXIT', _} -> nklib_util:to_binary(Other);
                Atom -> Atom
            end
    end,
    Proto2 = case Proto1 of
        undefined when Scheme==sips -> tls;
        undefined -> udp;
        Other2 -> Other2
    end,
    Port1 = case Port > 0 of
        true -> Port;
        _ -> nksip_transport:default_port(Proto2)
    end,
    {Proto2, Host, Port1};

transport(#via{proto=Proto, domain=Host, port=Port}) ->
    Port1 = case Port > 0 of
        true -> Port;
        _ -> nksip_transport:default_port(Proto)
    end,
    {Proto, Host, Port1}.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private First-stage SIP message parser
%% 50K/sec on i7
-spec packet(nksip:app_id(), nksip:call_id(), nksip_transport:transport(), binary()) ->
    {ok, #sipmsg{}} | {error, term()} | {reply_error, term(), binary()}.

packet(SrvId, CallId, Transp, Packet) ->
    Start = nklib_util:l_timestamp(),
    case nksip_parse_sipmsg:parse(Packet) of
        {ok, Class, Headers, Body} ->
            try 
                MsgClass = case Class of
                    {req, Method, RUri} ->
                        case nklib_parse:uris(RUri) of
                            [RUri1] -> 
                                [RUri1];
                            _ -> RUri1 = 
                                throw({invalid, <<"Request-URI">>})
                        end,
                        {req, Method};
                    {resp, Code, Reason} ->
                        case catch list_to_integer(Code) of
                            Code1 when is_integer(Code1), Code1>=100, Code1<700 -> 
                                ok;
                            _ -> 
                                Code1 = throw({invalid, <<"Code">>})
                        end,
                        RUri1 = undefined,
                        {resp, Code1, Reason}
                end,
                Req0 = #sipmsg{
                    id = nklib_util:uid(),
                    class = MsgClass,
                    app_id = SrvId,
                    ruri = RUri1,
                    call_id = CallId,
                    body = Body,
                    transport = Transp,
                    start = Start
                },
                {ok, parse_sipmsg(Req0, Headers)}
            catch
                throw:{invalid, InvHeader} ->
                    case Class of
                        {req, _, _} ->
                            Msg = <<"Invalid ", InvHeader/binary>>,
                            Resp = nksip_unparse:response(Headers, 400, Msg),
                            {reply_error, {invalid, InvHeader}, Resp};
                        _ ->
                            {error, {invalid, InvHeader}}
                    end
            end;
        error ->
            {error, invalid_message}
    end.



%% @private First-stage SIP message parser
%% 50K/sec on i7
-spec packet(nksip:app_id(), nksip_transport:transport(), binary()) ->
    {ok, #sipmsg{}, binary()} | partial | {error, term()} |
    {reply_error, term(), binary()}.

packet(SrvId, #transport{proto=Proto}=Transp, Packet) ->
    Start = nklib_util:l_timestamp(),
    case nksip_parse_sipmsg:parse(Proto, Packet) of
        {ok, Class, Headers, Body, Rest} ->
            try 
                CallId = case nklib_util:get_value(<<"call-id">>, Headers) of
                    CallId0 when byte_size(CallId0) > 0 -> CallId0;
                    _ -> throw({invalid, <<"Call-ID">>})
                end,
                MsgClass = case Class of
                    {req, Method, RUri} ->
                        case nklib_parse:uris(RUri) of
                            [RUri1] -> [RUri1];
                            _ -> RUri1 = throw({invalid, <<"Request-URI">>})
                        end,
                        {req, Method};
                    {resp, Code, Reason} ->
                        case catch list_to_integer(Code) of
                            Code1 when is_integer(Code1), Code1>=100, Code1<700 -> ok;
                            _ -> Code1 = throw({invalid, <<"Code">>})
                        end,
                        RUri1 = undefined,
                        {resp, Code1, Reason}
                end,
                Req0 = #sipmsg{
                    id = nklib_util:uid(),
                    class = MsgClass,
                    app_id = SrvId,
                    ruri = RUri1,
                    call_id = CallId,
                    body = Body,
                    transport = Transp,
                    start = Start
                },
                {ok, parse_sipmsg(Req0, Headers), Rest}
            catch
                throw:{invalid, InvHeader} ->
                    case Class of
                        {req, _, _} ->
                            Msg = <<"Invalid ", InvHeader/binary>>,
                            Resp = nksip_unparse:response(Headers, 400, Msg),
                            {reply_error, {invalid, InvHeader}, Resp};
                        _ ->
                            {error, {invalid, InvHeader}}
                    end
            end;
        partial ->
            partial;
        error ->
            {error, invalid_message};
        {reply, {req, _, _}, Headers, InvHeader} ->
            Msg = <<"Invalid ", InvHeader/binary>>,
            Resp = nksip_unparse:response(Headers, 400, Msg),
            {reply_error, {invalid, InvHeader}, Resp};
        {reply, _, _, InvHeader} ->
            {error, {invalid, InvHeader}}
    end.
  

%% @private
-spec parse_sipmsg(#sipmsg{}, [nksip:header()]) -> 
    #sipmsg{}.

parse_sipmsg(SipMsg, Headers) ->
    From = case nklib_parse:uris(proplists:get_all_values(<<"from">>, Headers)) of
        [From0] -> From0;
        _ -> throw({invalid, <<"From">>})
    end,
    FromTag = nklib_util:get_value(<<"tag">>, From#uri.ext_opts, <<>>),
    To = case nklib_parse:uris(proplists:get_all_values(<<"to">>, Headers)) of
        [To0] -> To0;
        _ -> throw({invalid, <<"To">>})
    end,
    ToTag = nklib_util:get_value(<<"tag">>, To#uri.ext_opts, <<>>),
    Vias = case vias(proplists:get_all_values(<<"via">>, Headers)) of
        [] -> throw({invalid, <<"via">>});
        error -> throw({invalid, <<"Via">>});
        Vias0 -> Vias0
    end,
    CSeq = case proplists:get_all_values(<<"cseq">>, Headers) of
        [CSeq0] -> 
            case nklib_util:words(CSeq0) of
                [CSeqNum, CSeqMethod] -> 
                    CSeqMethod1 = nksip_parse:method(CSeqMethod),
                    case SipMsg#sipmsg.class of
                        {req, CSeqMethod1} -> ok;
                        {req, _} -> throw({invalid, <<"CSeq">>});
                        {resp, _, _} -> ok
                    end,
                    case nklib_util:to_integer(CSeqNum) of
                        CSeqInt 
                            when is_integer(CSeqInt), CSeqInt>=0, CSeqInt<4294967296 ->
                            {CSeqInt, CSeqMethod1};
                        _ ->
                            throw({invalid, <<"CSeq">>})
                    end;
                _ ->
                    throw({invalid, <<"CSeq">>})
            end;
        _ -> 
            throw({invalid, <<"CSeq">>})
    end,
    Forwards = case nklib_parse:integers(proplists:get_all_values(<<"max-forwards">>, Headers)) of
        [] -> 70;
        [Forwards0] when Forwards0>=0, Forwards0<300 -> Forwards0;
        _ -> throw({invalid, <<"Max-Forwards">>})
    end,
    Routes = case nklib_parse:uris(proplists:get_all_values(<<"route">>, Headers)) of
        error -> throw({invalid, <<"Route">>});
        Routes0 -> Routes0
    end,
    Contacts = case nklib_parse:uris(proplists:get_all_values(<<"contact">>, Headers)) of
        error -> 
            lager:warning("C: ~p", [Headers]),
            throw({invalid, <<"Contact">>});
        Contacts0 -> Contacts0
    end,
    Expires = case nklib_parse:integers(proplists:get_all_values(<<"expires">>, Headers)) of
        [] -> undefined;
        [Expires0] when Expires0>=0 -> Expires0;
        _ -> throw({invalid, <<"Expires">>})
    end,
    ContentType = case nklib_parse:tokens(proplists:get_all_values(<<"content-type">>, Headers)) of
        [] -> undefined;
        [ContentType0] -> ContentType0;
        _ -> throw({invalid, <<"Content-Type">>})
    end,
    Require = case nklib_parse:tokens(proplists:get_all_values(<<"require">>, Headers)) of
        error -> throw({invalid, <<"Require">>});
        Require0 -> [N || {N, _} <- Require0]
    end,
    Supported = case nklib_parse:tokens(proplists:get_all_values(<<"supported">>, Headers)) of
        error -> throw({invalid, <<"Supported">>});
        Supported0 -> [N || {N, _} <- Supported0]
    end,
    Event = case nklib_parse:tokens(proplists:get_all_values(<<"event">>, Headers)) of
        [] ->
            case SipMsg#sipmsg.class of
                {req, 'SUBSCRIBE'} -> throw({invalid, <<"Event">>});
                {req, 'NOTIFY'} -> throw({invalid, <<"Event">>});
                _ -> undefined
            end;
        [Event0] -> 
            Event0;
        _ -> 
            throw({invalid, <<"Event">>})
    end,
    RestHeaders = lists:filter(
        fun({Name, _}) ->
            case Name of
                <<"from">> -> false;
                <<"to">> -> false;
                <<"call-id">> -> false;
                <<"via">> -> false;
                <<"cseq">> -> false;
                <<"max-forwards">> -> false;
                <<"route">> -> false;
                <<"contact">> -> false;
                <<"expires">> -> false;
                <<"require">> -> false;
                <<"supported">> -> false;
                <<"event">> -> false;
                <<"content-type">> -> false;
                <<"content-length">> -> false;
                _ -> true
            end
        end, Headers),
    #sipmsg{body=Body} = SipMsg,
    ParsedBody = case ContentType of
        {<<"application/sdp">>, _} ->
            case nksip_sdp:parse(Body) of
                error -> Body;
                SDP -> SDP
            end;
        {<<"application/nksip.ebf.base64">>, _} ->
            case catch binary_to_term(base64:decode(Body)) of
                {'EXIT', _} -> Body;
                ErlBody -> ErlBody
            end;
        _ ->
            Body
    end,
    SipMsg#sipmsg{
        from = {From, FromTag},
        to = {To, ToTag},
        vias = Vias,
        cseq = CSeq,
        forwards = Forwards,
        routes = Routes,
        contacts = Contacts,
        expires = Expires,
        content_type = ContentType,
        require = Require,
        supported = Supported,
        event = Event,
        headers = RestHeaders,
        body = ParsedBody,
        to_tag_candidate = <<>>
    }.

          

%% @private
-spec parse_ruris([#uri{}], [#uri{}]) ->
    [#uri{}] | error.

parse_ruris([], Acc) ->
    lists:reverse(Acc);

parse_ruris([#uri{opts=[], headers=[], ext_opts=Opts}=Uri|Rest], Acc) ->
    parse_ruris(Rest, [Uri#uri{opts=Opts, ext_opts=[], ext_headers=[]}|Acc]);

parse_ruris(_, _) ->
    error.



%% @private
-spec parse_vias([#via{}|binary()|string()], [#via{}]) ->
    [#via{}] | error.

parse_vias([], Acc) ->
    Acc;

parse_vias([Next|Rest], Acc) ->
    case nksip_parse_via:vias(Next) of
        error -> error;
        UriList -> parse_vias(Rest, Acc++UriList)
    end.



%% @doc Modifies a request based on uri options
-spec uri_method(nksip:user_uri(), nksip:method()) ->
    {nksip:method(), nksip:uri()} | error.

uri_method(RawUri, Default) ->
    case nklib_parse:uris(RawUri) of
        [#uri{opts=UriOpts}=Uri] ->
            case lists:keytake(<<"method">>, 1, UriOpts) of
                false ->
                    {Default, Uri};
                {value, {_, RawMethod}, Rest} ->
                    case nksip_parse:method(RawMethod) of
                        Method when is_atom(Method) -> {Method, Uri#uri{opts=Rest}};
                        _ -> error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

