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

%% @privaye SIP tokenizer functions
%%
%% This module implements several functions to parse sip requests, responses
%% headers, uris, vias, etc.

-module(nksip_tokenizer).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").

-export([tokenize/2, untokenize/1]).
-export_type([token/0, token_list/0]).

%% Token representation in SIP Header
-type token() :: {Name::binary(), Opts::nksip_lib:proplist()}.

%% Internal tokenizer result
-type token_list() :: [{string()} | char()].



%% ===================================================================
%% Tokenizer
%% ===================================================================

%% @doc Scans an `string()' or `binary()' for tokens.
-spec tokenize(Input, Class) -> [token_list()]
    when Input :: binary() | string(), Class :: none|uri|via|token|equal.

tokenize(Bin, Class) when is_binary(Bin) ->
    tokenize(binary_to_list(Bin), Class, []);

tokenize(List, Class) when is_list(List) ->
    tokenize(List, Class, []).


tokenize(List, uri, Lines) -> 
    {UriPrev, UriRest} = pre_uri(List),
    {Words, Rest} = tokenize(UriRest, none, uri, [], []),
    Words1 = case UriPrev of
        [] -> Words;
        _ -> [{UriPrev}|Words]
    end,
    case Rest of
        [] -> lists:reverse([Words1|Lines]);
        _ -> tokenize(Rest, uri, [Words1|Lines])
    end;

tokenize(List, Class, Lines) -> 
    case tokenize(List, none, Class, [], []) of
        {Words, []} -> lists:reverse([Words|Lines]);
        {Words, Rest} -> tokenize(Rest, Class, [Words|Lines])
    end.


%% @private
tokenize([92, Ch|Rest], double, Class, Chs, Words) ->    % backlash
    tokenize(Rest, double, Class, [Ch, 92| Chs], Words);

tokenize([13, 10|Rest], Quote, Class, Chs, Words) -> 
    tokenize(Rest, Quote, Class, Chs, Words);

tokenize([Ch|Rest], Quote, Class, Chs, Words) -> 
    if
        Ch==$", Quote==none, Chs==[] ->  % Only after WS or token (Chs==[])
            tokenize(Rest, double, Class, [$"], Words);
        Ch==$", Quote==double, Class==uri  ->
            tokenize(Rest, none, Class, [Ch|Chs], Words);
        Ch==$", Quote==double  ->
            Words1 = [{lists:reverse([$"|Chs])}|Words],
            tokenize(Rest, none, Class, [], Words1);
        Ch==$,, Quote==none, 
                (Class==uri_host orelse Class==uri_opts orelse
                 Class==via orelse Class==via_token orelse 
                 Class==token orelse Class==equal) ->
            Words1 = case Chs of
                [] -> Words;
                _ -> [{lists:reverse(Chs)}|Words]
            end,
            {lists:reverse(Words1), Rest};
        Ch==$[, Quote==none, Chs==[], Class==uri_host ->
            tokenize(Rest, ipv6, uri_host, [$[], Words);
        Ch==$[, Quote==none, Chs==[], Class==via -> 
            tokenize(Rest, ipv6, Class, [$[], Words);
        Ch==$], Quote==ipv6 ->
            Words1 = [{lists:reverse([$]|Chs])}|Words],
            tokenize(Rest, none, Class, [], Words1);
        (Ch==32 orelse Ch==9) andalso Quote==none ->
            case Chs of
                [] -> tokenize(Rest, Quote, Class, [], Words);
                _ -> tokenize(Rest, Quote, Class, [], [{lists:reverse(Chs)}|Words])
            end;
        Quote==none ->
            {IsToken, Class1} = case Class of
                uri when Ch==$< -> 
                    {true, uri};
                uri when Ch==$: -> 
                    case has($@, Rest) of
                        true -> {true, uri_user};
                        false -> {true, uri_host}
                    end;
                uri_user when Ch==$: -> 
                    {true, uri_user};
                uri_user when Ch==$@ -> 
                    {true, uri_host};
                uri_host when Ch==$: -> 
                    {true, uri_host};
                uri_host when Ch==$;; Ch==$?; Ch==$> -> 
                    {true, uri_opts};
                uri_opts when Ch==$;; Ch==$?; Ch==$=; Ch==$&; Ch==$> -> 
                    {true, uri_opts};
                via when Ch==$/; Ch==$: -> 
                    {true, via};
                via when Ch==$; -> 
                    {true, via_token};
                via_token when Ch==$;; Ch==$= -> 
                    {true, via_token};
                token when Ch==$;; Ch==$= -> 
                    {true, token};
                equal when Ch==$= -> 
                    {true, equal};
                _ -> 
                    {false, Class}
            end,
            case IsToken of
                true when Chs==[] -> 
                    tokenize(Rest, Quote, Class1, [], [Ch|Words]);
                true -> 
                    Words1 = [Ch, {lists:reverse(Chs)}|Words],
                    tokenize(Rest, Quote, Class1, [], Words1);
                false ->
                    tokenize(Rest, Quote, Class1, [Ch|Chs], Words)
            end;
        true ->
            tokenize(Rest, Quote, Class, [Ch|Chs], Words)
    end;

tokenize([], Quote, Class, Chs, Words) -> 
    if
        Quote=:=double -> 
            tokenize([$"], double, Class, Chs, Words);
        Quote=:=ipv6 ->
            tokenize([$]], ipv6, Class, Chs, Words);
        Chs=:=[] -> 
            {lists:reverse(Words), []};
        true ->
            Words1 = [{lists:reverse(Chs)}|Words],
            {lists:reverse(Words1), []}
    end.


%% @doc Serializes a `token_list()' list
-spec untokenize([token_list()]) -> 
    iolist().

untokenize(Lines) ->
    untokenize_lines(Lines, []).

untokenize_lines([Line|Rest], Acc) ->
    untokenize_lines(Rest, [$,, untokenize_words(Line, [])|Acc]);
untokenize_lines([], [$,|Acc]) ->
    lists:reverse(Acc);
untokenize_lines([], []) ->
    [].

untokenize_words([{Word1}, {Word2}|Rest], Acc) ->
    untokenize_words([{Word2}|Rest], [32, Word1|Acc]);
untokenize_words([{Word1}|Rest], Acc) ->
    untokenize_words(Rest, [Word1|Acc]);
untokenize_words([Sep|Rest], Acc) ->
    untokenize_words(Rest, [Sep|Acc]);
untokenize_words([], Acc) ->
    lists:reverse(Acc).


%% @private
pre_uri(List) -> 
    case pre_uri(List, [], false) of
        {Prev, Rest} -> {Prev, Rest};
        abort -> {[], List}
    end.    


%% @private
pre_uri([], Acc, _) -> {lists:reverse(Acc), []};
pre_uri([13,10|Rest], Acc, Quote) -> pre_uri(Rest, Acc, Quote);
pre_uri([$<|Rest], Acc, false) -> {lists:reverse(Acc), [$<|Rest]};
pre_uri([$,|_Rest], _Acc, false) -> abort;
pre_uri([$:|_Rest], _Acc, false) -> abort;
pre_uri([92, $"|Rest], Acc, true) -> pre_uri(Rest, [$", 92|Acc], true);
pre_uri([$"|Rest], Acc, false) -> pre_uri(Rest, [$"|Acc], true);
pre_uri([$"|Rest], Acc, true) -> pre_uri(Rest, [$"|Acc], false);
pre_uri([Ch|Rest], Acc, Quoted) -> pre_uri(Rest, [Ch|Acc], Quoted).



%% @private
has(Char, List) -> has(Char, List, false).


%% @private
has(_Char, [], _) -> false;
has(Char, [Char|_], false) -> true;
has(Char, [92, $"|Rest], true) -> has(Char, Rest, true);
has(Char, [$"|Rest], false) -> has(Char, Rest, true);
has(Char, [$"|Rest], true) -> has(Char, Rest, false);
has(Char, [_|Rest], Quoted) -> has(Char, Rest, Quoted).














%% ===================================================================
%% EUnit tests
%% ===================================================================



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tokenize_test() -> 
    R1 = [
        [
            {"this is \"an, example; <  sip : fake>\", and this "},
            $<, {"is"}, $:, {"first"}, $;, {"\" other>, \""}, $>
        ],
        [
            {"sip"}, $:, {"second"}
        ]
    ],
    ?assert(
        R1=:=tokenize("this is \"an, example; <  sip : fake>\", "
                      "and this < is:first ; \" other>, \">,  sip:second ", uri)),
    ?assertMatch("this is \"an, example; <  sip : fake>\", "
                 "and this <is:first;\" other>, \">,sip:second",
        lists:flatten(untokenize(R1))).

-endif.




