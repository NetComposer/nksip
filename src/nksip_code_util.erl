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

%% @doc NkSIP Erlang code parser and hot loader


-module(nksip_code_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([expresion/2, getter/2, callback/3, compile/2, get_funs/1]).

-compile([export_all]).


%% ===================================================================
%% Private
%% ===================================================================


%% @doc Parses an erlang expression intro a 
-spec expresion(string(), [erl_syntax:syntaxTree()]) ->
    [erl_syntax:syntaxTree()].

expresion(Expr, Tree) ->
    case parse_string(Expr) of
        {ok, Form} -> [Form|Tree];
        {error, Error} -> throw(Error)
    end.


%% @doc Generates a getter function
-spec getter(atom(), term()) ->
    erl_syntax:syntaxTree().

getter(Fun, Value) ->
    erl_syntax:function(
       erl_syntax:atom(Fun),
       [erl_syntax:clause([], none, [erl_syntax:abstract(Value)])]).


%% @doc Generates a callback to another function
-spec callback(atom(), pos_integer(), atom()) ->
    erl_syntax:syntaxTree().

callback(Fun, Arity, Mod) ->
    fun_expr(Mod, Fun, Arity, [call_expr(Mod, Fun, Arity)]).

ce() ->
    S = case_callback(fun1, 1, mod1, [erl_syntax:atom(go_next)]),
    ?P("S: ~p", [S]),
    compile(t1, [S]).


case_expr(Mod, Fun, Arity, Next) ->
    erl_syntax:case_expr(
        call_expr(Mod, Fun, Arity),
        [
            erl_syntax:clause(
                [erl_syntax:atom(continue)],
                none,
                Next),
            erl_syntax:clause(
                [erl_syntax:tuple([
                    erl_syntax:atom(continue), 
                    erl_syntax:list(var_list(Mod, Arity))])],
                none,
                Next),
            erl_syntax:clause(
                [erl_syntax:variable("Other")],
                none,
                [erl_syntax:variable("Other")])
        ]).



% fun1(A) ->
%   case mod1:fun1(A) of 
%       continue -> go_next;
%       Other -> Other
%   end
%
% 
% 


case_callback(Fun, Arity, Mod, Next) ->
    fun_expr(Fun, Arity, [
        erl_syntax:case_expr(
            call_expr(Mod, Fun, Arity),
            [
                erl_syntax:clause(
                    [erl_syntax:atom(continue)],
                    none,
                    Next),
                erl_syntax:clause(
                    [erl_syntax:tuple([
                        erl_syntax:atom(continue), 
                        erl_syntax:list(var_list(Mod, Arity))])],
                    none,
                    Next),
                erl_syntax:clause(
                    [erl_syntax:variable("Other")],
                    none,
                    [erl_syntax:variable("Other")])
            ])
    ]).




%% @doc Compiles a syntaxTree into a module
-spec compile(atom(), erl_syntax:syntaxTree()) ->
    ok | {error, term()}.

compile(Mod, Tree) ->
    Tree1 = [
        erl_syntax:attribute(
            erl_syntax:atom(module),
            [erl_syntax:atom(Mod)]),
        erl_syntax:attribute(
            erl_syntax:atom(compile),
            [erl_syntax:list([erl_syntax:atom(export_all)])])
        | Tree
    ],
    Forms1 = [erl_syntax:revert(X) || X <- Tree1],
    Options = [report_errors, report_warnings, return_errors],
    case compile:forms(Forms1, Options) of
        {ok, Mod, Bin} ->
            code:purge(Mod),
            File = atom_to_list(Mod)++".erl",
            case code:load_binary(Mod, File, Bin) of
                {module, Mod} -> ok;
                Error -> {error, Error}
            end;
        Error ->
            {error, Error}
    end.


%% @doc Gets the list of exported functions of a module
-spec get_funs(atom()) ->
    [{atom(), pos_integer()}] | error.

get_funs(Mod) ->
    case catch Mod:module_info() of
        List when is_list(List) ->
            lists:foldl(
                fun({Fun, Arity}, Acc) ->
                    case Fun of
                        module_info -> Acc;
                        _ -> [{Fun, Arity}|Acc]
                    end
                end,
                [],
                nksip_lib:get_value(exports, List));
        _ ->
            error
    end.


%% ===================================================================
%% Internal
%% ===================================================================


%% @private
-spec parse_string(string()) ->
    {ok, erl_parse:abstract_form()} | {error, term()}.

parse_string(String) ->
    case erl_scan:string(String) of
        {ok, Tokens, _} ->
            case erl_parse:parse_form(Tokens) of
                {ok, Form} -> {ok, Form};
                _ -> {error, parse_error}
            end;
        _ ->
            {error, parse_error}
    end.


%% @private Generates a function expression
fun_expr(Mod, Fun, Arity, Value) ->
    erl_syntax:function(
        erl_syntax:atom(Fun),
        [erl_syntax:clause(var_list(Mod, Arity), none, Value)]).


%% @private Generates a call expression
call_expr(Mod, Fun, Arity) ->
    erl_syntax:application(
        erl_syntax:atom(Mod),
        erl_syntax:atom(Fun),
        var_list(Arity)).


%% @private Generates a var list (A,B..)
var_list(Mod, Arity) ->
    ModS = atom_to_list(Mod),
    [erl_syntax:variable([V, $_|ModS]) || V <- lists:seq(65, 64+Arity)].




