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

%% @doc NkSIP SIP Trace Registrar Plugin Callbacks
-module(nksip_trace_plugin).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").

-export([plugin_deps/0, plugin_config/3, plugin_cache/3, plugin_start/3, plugin_stop/3]).


%% ===================================================================
%% Plugin
%% ===================================================================

plugin_deps() ->
    [nksip].


plugin_config(_PkgId,  Config, #{class:=?PACKAGE_CLASS_SIP}) ->
    Syntax = #{
        sip_trace => boolean,
        sip_trace_file => [{atom, [console]}, binary],
        sip_trace_ips => {list, binary},
        '__defaults' => #{
            sip_trace => false,
            sip_trace_file => console,
            sip_trace_ips => []
        }
    },
    nklib_syntax:parse_all(Config, Syntax).


plugin_cache(_PkgId, Config, _Service) ->
    Cache = {
        maps:get(sip_trace, Config),
        maps:get(sip_trace_file, Config),
        compile_ips(maps:get(sip_trace_ips, Config), [])
    },
    {ok, #{config=>Cache}}.


plugin_start(SrvId, Config, _Service) ->
    case Config of
        #{sip_trace_file:=File} ->
            ok = nksip_trace:open_file(SrvId, File);
        _ ->
            ok
    end.


plugin_stop(SrvId, _Config, _Service) ->
    catch nksip_trace:close_file(SrvId),
    ok.



%% ===================================================================
%% Internal
%% ===================================================================


%% @private
compile_ips([], Acc) ->
    lists:reverse(Acc);

compile_ips([Ip|Rest], Acc) when is_binary(Ip) ->
    case re:compile(Ip) of
        {ok, Comp} ->
            compile_ips(Rest, [Comp|Acc]);
        {error, _Error} ->
            error(_Error)
    end;

compile_ips([Re|Rest], Acc) when element(1, Re)==re_pattern ->
    compile_ips(Rest, [Re|Acc]).
