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

% @doc Scans an `string()' or `binary()' for tokens.
%%  
%%  The string is first partitioned in lines using `","' as separator, and each line
%%  will be a term in the resulting arrary. For each line, each token is found using 
%%  whitespace as separator, and returned as `{string()}'. 
%%
%%  Depending on `Class', new separators are used: (`<>:@;=?&' for `uri', 
%% `/:;=' for `via', `:=' for `token' and `=' for `equal').
%%
%%  Any part enclosed in double quotes is returned as a token, including the
%%  quotes.  Any part enclosed in `<' and `>' is processed, but the `<' and `>' 
%%  separators are included in the returned list and no `","' is processed inside.
%%  <br/><br/>
%%  Example: 
%%
%%  ```tokenize(<<"this is \"an, example;\", and this < is ; other, bye> ">>, uri)'''
%%  returns
%%  ```
%%  [
%%      [{"this"},{"is"},{"\"an, example;\""}],
%%      [{"and"},{"this"},$<,{"is"},$;,{"other"}],
%%      [{"bye"},$>]
%%  ]
%%  '''
%%
-spec tokenize(Input, Class) -> [token_list()]
    when Input :: binary() | string(), Class :: none|uri|via|token|equal.

tokenize(Bin, Class) when is_binary(Bin) ->
    tokenize(binary_to_list(Bin), Class);

tokenize([], _) ->
    [];

tokenize(List, Class) when is_list(List), is_atom(Class) -> 
    tokenize(List, none, Class, [], [], []);

tokenize(_, _) ->
    [].


tokenize([Ch|Rest], Quote, Class, Chs, Words, Lines) -> 
    if
        Ch=:=$", Quote=:=none, Chs=:=[] ->  % Only after WS or token (Chs==[])
            tokenize(Rest, double, Class, [$"], Words, Lines);
        Ch=:=$", Quote=:=double  ->
            Words1 = [{lists:reverse([$"|Chs])}|Words],
            tokenize(Rest, none, Class, [], Words1, Lines);
        Ch=:=$,, Quote=:=none ->
            Class1 = case Class of 
                uri_token -> uri;
                via_token -> via;
                _ -> Class
            end,
            Words1 = case Chs of
                [] -> Words;
                _ -> [{lists:reverse(Chs)}|Words]
            end,
            tokenize(Rest, none, Class1, [], [], [lists:reverse(Words1)|Lines]);
        Ch=:=$[, Quote=:=none, Chs=:=[], (Class=:=uri orelse Class=:=via) -> 
            tokenize(Rest, ipv6, Class, [$[], Words, Lines);
        Ch=:=$], Quote=:=ipv6 ->
            Words1 = [{lists:reverse([$]|Chs])}|Words],
            tokenize(Rest, none, Class, [], Words1, Lines);
        (Ch=:=32 orelse Ch=:=9) andalso Quote=:=none ->
            case Chs of
                [] -> tokenize(Rest, Quote, Class, [], Words, Lines);
                _ -> tokenize(Rest, Quote, Class, [], [{lists:reverse(Chs)}|Words], Lines)
            end;
        Quote=:=none ->
            {IsToken, Class1} = case Class of
                uri when Ch==$<; Ch==$>; Ch==$:; Ch==$@ -> 
                    {true, uri};
                uri when Ch==$;; Ch==$? -> 
                    {true, uri_token}; 
                uri_token when Ch==$;; Ch==$?; Ch==$=; Ch==$&; Ch==$> -> 
                    {true, uri_token};
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
                true when Chs=:=[] -> 
                    tokenize(Rest, Quote, Class1, [], [Ch|Words], Lines);
                true -> 
                    Words1 = [Ch, {lists:reverse(Chs)}|Words],
                    tokenize(Rest, Quote, Class1, [], Words1, Lines);
                false ->
                    tokenize(Rest, Quote, Class1, [Ch|Chs], Words, Lines)
            end;
        true ->
            tokenize(Rest, Quote, Class, [Ch|Chs], Words, Lines)
    end;

tokenize([], Quote, Class, Chs, Words, Lines) -> 
    if
        Quote=:=double -> 
            tokenize([$"], double, Class, Chs, Words, Lines);
        Quote=:=ipv6 ->
            tokenize([$]], ipv6, Class, Chs, Words, Lines);
        Chs=:=[] -> 
            lists:reverse([lists:reverse(Words)|Lines]);
        true ->
            Words1 = [{lists:reverse(Chs)}|Words],
            lists:reverse([lists:reverse(Words1)|Lines])
    end.

% %% @private
% is_token($<, none) -> false;

% is_token($<, uri) -> true;
% is_token($>, uri) -> true;
% is_token($:, uri) -> true;
% is_token($@, uri) -> true;
% is_token($;, uri) -> true;
% is_token($=, uri) -> true;
% is_token($?, uri) -> true;
% is_token($&, uri) -> true;

% is_token($/, via) -> true;
% is_token($:, via) -> true;
% is_token($;, via) -> true;
% is_token($=, via) -> true;

% is_token($;, token) -> true;
% is_token($=, token) -> true;
% is_token($=, equal) -> true;
% is_token(_, _) -> false.


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





%% ===================================================================
%% EUnit tests
%% ===================================================================



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tokenize_test() -> 
    R1 = [
        [{"this"}, {"is"}, {"\"an, example;\""}],
        [{"and"}, {"this"}, $<, {"is"}, $;, {"\" other, \""}, {"bye"}, $>]
    ],
    ?assert(
        R1=:=tokenize("this is \"an, example;\", and this < is ; \" other, \" bye> ", uri)),
    ?assertMatch("this is \"an, example;\",and this<is;\" other, \" bye>",
        lists:flatten(untokenize(R1))).

-endif.




