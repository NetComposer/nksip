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

%% @doc RFC4566 SDP utilities
-module(nksip_sdp_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([add_candidates/2, extract_candidates/1]).
-export([extract_codec_map/1, insert_codec_map/2]).
-export([get_codecs/2, remove_codec/3, filter_codec/3]).

-export_type([candidate_map/0, codec_map/0]).


%% ===================================================================
%% Types
%% ===================================================================


-type candidate_map() ::
    #{
        {Mid::binary(), Index::integer()} => binary()
    }.


-type codec_map() ::
    #{
        Media::binary() => [{Fmt::binary(), Name::binary(), [nksip_sdp:sdp_a()]}]
    }.




%% ===================================================================
%% Public
%% ===================================================================



%% @doc Add trickle ICE candidates to an SDP
-spec add_candidates(#sdp{}|binary(), [#candidate{}]) ->
    #sdp{} | {error, term()}.

add_candidates(#sdp{medias=Medias}=SDP, Candidates) ->
    case add_candidates(Medias, 0, Candidates, []) of
        {ok, Medias2} ->
            SDP#sdp{medias=Medias2};
        {error, Error} ->
            {error, Error}
    end;

add_candidates(SDP, Candidates) ->
    case nksip_sdp:parse(SDP) of
        #sdp{} = Parsed ->
            add_candidates(Parsed, Candidates);
        error ->
            {error, parse_error}
    end.


%% @private
add_candidates([], _Index, _Candidates, Acc) ->
    {ok, lists:reverse(Acc)};

add_candidates([#sdp_m{attributes=Attrs}=Media|Rest], Index, Candidates, Acc) ->
    List = case lists:keyfind(<<"mid">>, 1, Attrs) of
        {_, [Mid]} ->
            [A || #candidate{m_id=M, m_index=I, a_line=A} <-Candidates,
                  M==Mid andalso I==Index];
        _ ->
            % Janus does not send mid field
            [A || #candidate{m_index=I, a_line=A} <-Candidates, I==Index]
    end,
    Attrs2 = lists:foldr(
        fun(Line, FAcc) ->
            case Line of
                <<"candidate:", FRest/binary>> ->
                    Data = binary:split(FRest, <<" ">>, [global]),
                    [{<<"candidate">>, Data}|FAcc];
                _ ->
                    lager:error("L: ~p", [Line]),
                    FAcc
            end
        end,
        [],
        List),
    Media2 = Media#sdp_m{attributes=Attrs++Attrs2},
    add_candidates(Rest, Index+1, Candidates, [Media2|Acc]).


%% @doc Extract trickle ICE candidates from an SDP
-spec extract_candidates(#sdp{}|binary()) ->
    [#candidate{}] | {error, term()}.

extract_candidates(#sdp{medias=Medias}) ->
    extract_candidates(Medias, 0, []);

extract_candidates(SDP) ->
    case nksip_sdp:parse(SDP) of
        #sdp{} = Parsed ->
            extract_candidates(Parsed);
        error ->
            {error, parse_error}
    end.

%% @private
extract_candidates([], _Index, Acc) ->
    Acc;

extract_candidates([#sdp_m{attributes=Attrs}|Rest], Index, Acc) ->
    case lists:keyfind(<<"mid">>, 1, Attrs) of
        {_, [Mid]} ->
            List = proplists:get_all_values(<<"candidate">>, Attrs),
            Acc2 = lists:foldr(
                fun(AList, FAcc) ->
                    Line1 = nklib_util:bjoin(AList, <<" ">>),
                    Line2 = <<"candidate:", Line1/binary>>,
                    [#candidate{m_id=Mid, m_index=Index, a_line=Line2}|FAcc]
                end,
                Acc,
                List),
            extract_candidates(Rest, Index+1, Acc2);
        _ ->
            {error, missing_mid_in_sdp}
    end.


%% @doc Extract all codecs from SDP
-spec extract_codec_map(binary()|#sdp{}) ->
    {codec_map(), #sdp{}}.

extract_codec_map(#sdp{medias=Medias}=SDP) ->
    {Codecs, Medias2} = extract_codec_map_media(Medias, #{}, []),
    {Codecs, SDP#sdp{medias=Medias2}};

extract_codec_map(SDP) ->
    case nksip_sdp:parse(SDP) of
        #sdp{} = Parsed ->
            extract_codec_map(Parsed);
        error ->
            {error, parse_error}
    end.


%% @private
extract_codec_map_media([], Codecs, Medias) ->
    {Codecs, Medias};

extract_codec_map_media([Media|Rest], Codecs, Medias) ->
    #sdp_m{media=Name, fmt=Fmts, attributes=Attrs} = Media,
    Base = [{Fmt, Fmt, []} || Fmt <- Fmts],
    {MediaCodecs, Outs} = extract_codec_map_fmt(Attrs, Base, []),
    Codecs2 = maps:put(Name, MediaCodecs, Codecs),
    Medias2 = [Media#sdp_m{attributes=Outs, fmt=[]}|Medias],
    extract_codec_map_media(Rest, Codecs2, Medias2).


%% @private
extract_codec_map_fmt([], Codecs, Outs) ->
    {Codecs, lists:reverse(Outs)};

extract_codec_map_fmt([{Key, [Fmt|Values2]=Values}|Rest], Codecs, Outs) ->
    case lists:keyfind(Fmt, 1, Codecs) of
        {Fmt, OldName, List} ->
            case Key of
                <<"rtpmap">> ->
                    [Name2|_] = Values2;
                _ ->
                    Name2 = OldName
            end,
            List2 = [{Key, Values2}|List],
            Codecs2 = lists:keystore(Fmt, 1, Codecs, {Fmt, Name2, List2}),
            extract_codec_map_fmt(Rest, Codecs2, Outs);
        false ->
            Outs2 = [{Key, Values}|Outs],
            extract_codec_map_fmt(Rest, Codecs, Outs2)
    end;

extract_codec_map_fmt([{Key, Values}|Rest], Codecs, Outs) ->
    Outs2 = [{Key, Values}|Outs],
    extract_codec_map_fmt(Rest, Codecs, Outs2).


%% @doc Inserts a previously extract lists of codecs back
-spec insert_codec_map(codec_map(), #sdp{}) ->
    #sdp{}.

insert_codec_map(CodecMap, #sdp{medias=Medias}=SDP) ->
    Medias2 = insert_codec_map_media(Medias, CodecMap, []),
    SDP#sdp{medias=Medias2}.


insert_codec_map_media([], _CodecMap, Acc) ->
    Acc;

insert_codec_map_media([Media|Rest], CodecMap, Acc) ->
    #sdp_m{media=Name, attributes=Attrs1} = Media,
    Codecs = maps:get(Name, CodecMap),
    Fmts2 = [Key || {Key, _, _} <- Codecs],
    case Fmts2 of
        [] ->
            insert_codec_map_media(Rest, CodecMap, Acc);
        _ ->
            Attrs2 = insert_codec_map_fmt(Codecs, Attrs1),
            Media2 = Media#sdp_m{fmt=Fmts2, attributes=Attrs2},
            insert_codec_map_media(Rest, CodecMap, [Media2|Acc])
    end.


%% @private
insert_codec_map_fmt([], Attrs) ->
    Attrs;

insert_codec_map_fmt([{Fmt, _Name, Values}|Rest], Attrs) ->
    Attrs2 = [{Key, [Fmt|Data]} || {Key, Data} <-Values] ++ Attrs,
    insert_codec_map_fmt(Rest, Attrs2).



%% @doc Get a the list of codec names
-spec get_codecs(Media::atom()|binary(), codec_map()) ->
    [binary()].

get_codecs(Media, CodecMap) ->
    case maps:find(nklib_util:to_binary(Media), CodecMap) of
        {ok, List} ->
            [Name || {_Fmt, Name, _Data}<- List];
        error ->
            []
    end.



%% @doc Remove a codec from a code_map(). Only header is neccesary.
-spec remove_codec(Media::atom()|binary(), Codec::atom()|binary(), codec_map()) ->
    codec_map().

remove_codec(Media, Name, CodecMap) ->
    Media2 = nklib_util:to_binary(Media),
    Name2 = nklib_util:to_upper(Name),
    case maps:find(Media2, CodecMap) of
        {ok, List} ->
            List2 = lists:filter(
                fun({_Fmt, FName1, _Data}) ->
                    FName2 = nklib_util:to_upper(FName1),
                    case binary:match(FName2, Name2) of
                        {0, _} -> false;
                        _ -> true
                    end
                end,
                List),
            maps:put(Media2, List2, CodecMap);
        error ->
            CodecMap
    end.


%% @doc Filter codecs not having a header
-spec filter_codec(Media::atom()|binary(), Codec::atom()|binary(), codec_map()) ->
    codec_map().

filter_codec(Media, Name, CodecMap) ->
    Media2 = nklib_util:to_binary(Media),
    Name2 = nklib_util:to_upper(Name),
    case maps:find(Media2, CodecMap) of
        {ok, List} ->
            List2 = lists:filter(
                fun({_Fmt, FName1, _Data}) ->
                    FName2 = nklib_util:to_upper(FName1),
                    case binary:match(FName2, Name2) of
                        {0, _} -> true;
                        _ -> false
                    end
                end,
                List),
            maps:put(Media2, List2, CodecMap);
        error ->
            CodecMap
    end.




%% ===================================================================
%% EUnit tests
%% ===================================================================


% -define(TEST, 1).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


sdp1_test() ->
    SDP2 = nksip_sdp:unparse(add_candidates(sdp1(), candidates1())),
    SDP3 = binary:replace(SDP2, <<"\r\n">>, <<"\n">>, [global]),
    SDP3 = sdp2(),
    Candidates = lists:sort(extract_candidates(SDP3)),
    Candidates = lists:sort(candidates1()).


sdp2_test() ->
    SDP1 = sdp1(),
    {Codecs, SDP2} = extract_codec_map(sdp1()),    

    #{
        <<"audio">> := [
            {<<"111">>, <<"opus/48000/2">>, [
                {<<"fmtp">>,[<<"minptime=10;useinbandfec=1">>]},
                {<<"rtpmap">>,[<<"opus/48000/2">>]}]},
            {<<"0">>, <<"PCMU/8000">>,[{<<"rtpmap">>,[<<"PCMU/8000">>]}]}
        ],
        <<"video">> := [
            {<<"100">>, <<"VP8/90000">>, [
                {<<"rtcp-fb">>,[<<"goog-remb">>]},
                {<<"rtcp-fb">>,[<<"nack">>,<<"pli">>]},
                {<<"rtcp-fb">>,[<<"nack">>]},
                {<<"rtcp-fb">>,[<<"ccm">>,<<"fir">>]},
                {<<"rtpmap">>,[<<"VP8/90000">>]}]}
        ],
        <<"application">> := [{<<"5000">>, <<"5000">>, []}]
    } = Codecs,

    SDP3 = nksip_sdp:unparse(insert_codec_map(Codecs, SDP2)),
    SDP1_S = sorted_sdp(SDP1),
    SDP3_S = sorted_sdp(SDP3),
    SDP1_S = SDP3_S,
    ok.



sdp1() -> 
<<"v=0
o=- 3680359967 3680359967 IN IP4 0.0.0.0
s=Kurento Media Server
c=IN IP4 0.0.0.0
t=0 0
a=msid-semantic: WMS FunlozxAXEnhW2MQ5pAmuJDLu4idCoGvdpGd
a=group:BUNDLE audio video
m=audio 1 UDP/TLS/RTP/SAVPF 111 0
a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=mid:audio
a=rtcp:9 IN IP4 0.0.0.0
a=rtpmap:111 opus/48000/2
a=rtpmap:0 PCMU/8000
a=setup:active
a=sendrecv
a=rtcp-mux
a=fmtp:111 minptime=10;useinbandfec=1
a=ssrc:478735377 cname:user2232009940@host-6307df3c
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
m=video 1 UDP/TLS/RTP/SAVPF 100
b=AS:500
a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=mid:video
a=rtcp:9 IN IP4 0.0.0.0
a=rtpmap:100 VP8/90000
a=rtcp-fb:100 ccm fir
a=rtcp-fb:100 nack
a=rtcp-fb:100 nack pli
a=rtcp-fb:100 goog-remb
a=setup:active
a=sendrecv
a=rtcp-mux
a=ssrc:732679706 cname:user2232009940@host-6307df3c
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
m=application 0 DTLS/SCTP 5000
a=inactive
a=mid:data
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
">>.

sdp2() ->
<<"v=0
o=- 3680359967 3680359967 IN IP4 0.0.0.0
s=Kurento Media Server
c=IN IP4 0.0.0.0
t=0 0
a=msid-semantic: WMS FunlozxAXEnhW2MQ5pAmuJDLu4idCoGvdpGd
a=group:BUNDLE audio video
m=audio 1 UDP/TLS/RTP/SAVPF 111 0
a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=mid:audio
a=rtcp:9 IN IP4 0.0.0.0
a=rtpmap:111 opus/48000/2
a=rtpmap:0 PCMU/8000
a=setup:active
a=sendrecv
a=rtcp-mux
a=fmtp:111 minptime=10;useinbandfec=1
a=ssrc:478735377 cname:user2232009940@host-6307df3c
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
a=candidate:1 1 UDP 2013266431 fe80::42:85ff:fe08:1f8d 39573 typ host
a=candidate:2 1 TCP 1019217407 fe80::42:85ff:fe08:1f8d 9 typ host tcptype active
m=video 1 UDP/TLS/RTP/SAVPF 100
b=AS:500
a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
a=mid:video
a=rtcp:9 IN IP4 0.0.0.0
a=rtpmap:100 VP8/90000
a=rtcp-fb:100 ccm fir
a=rtcp-fb:100 nack
a=rtcp-fb:100 nack pli
a=rtcp-fb:100 goog-remb
a=setup:active
a=sendrecv
a=rtcp-mux
a=ssrc:732679706 cname:user2232009940@host-6307df3c
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
a=candidate:1 1 UDP 2013266431 fe80::42:85ff:fe08:1f8d 39574 typ host
a=candidate:2 1 TCP 1019217407 fe80::42:85ff:fe08:1f8d 10 typ host tcptype active
m=application 0 DTLS/SCTP 5000
a=inactive
a=mid:data
a=ice-ufrag:KASd
a=ice-pwd:aAGwQCWJ327QPNBMBOkT0U
a=fingerprint:sha-256 3B:8E:41:18:5F:68:50:A5:7E:57:91:12:CB:0A:27:86:67:E1:DA:61:2A:42:F4:07:98:84:4B:0E:06:84:94:76
">>.


candidates1() -> [
    #candidate{
        m_id = <<"audio">>, 
        m_index = 0, 
        a_line= <<"candidate:1 1 UDP 2013266431 fe80::42:85ff:fe08:1f8d 39573 typ host">>
    },
    #candidate{
        m_id = <<"audio">>, 
        m_index = 0, 
        a_line = <<"candidate:2 1 TCP 1019217407 fe80::42:85ff:fe08:1f8d 9 typ host tcptype active">>
    },
    #candidate{
        m_id = <<"video">>, 
        m_index = 1, 
        a_line = <<"candidate:1 1 UDP 2013266431 fe80::42:85ff:fe08:1f8d 39574 typ host">>
    },
    #candidate{
        m_id = <<"video">>, 
        m_index = 1, 
        a_line = <<"candidate:2 1 TCP 1019217407 fe80::42:85ff:fe08:1f8d 10 typ host tcptype active">>
    }
].


sorted_sdp(SDP) ->
    Split = case binary:split(SDP, <<"\r\n">>, [global]) of
        [_] ->
            binary:split(SDP, <<"\n">>, [global]);
        Split0 ->
            Split0
    end,
    lists:sort(Split).



-endif.


