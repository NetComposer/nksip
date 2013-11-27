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

%% @doc NkSIP Config Server.
%%
%%
%% This module implements a simple ETS-based config store.
%%
%% NkSIP has few global configuration options. Config values are set using standard 
%% nksip application's erlang environmet (file `nksip.app').
%% Their default values are defined in the following table. 
%%
%% <table border="1">
%%   <tr><th>Name</th><th>Default</th><th>Comments</th></tr>
%%   <tr><td>`timer_t1'</td><td>500</td><td>Standar SIP T1 timer (msecs).</td></tr>
%%   <tr><td>`timer_t2'</td><td>4000</td><td>Standar SIP T2 timer (msecs).</td></tr>
%%   <tr><td>`timer_t4'</td><td>5000</td><td>Standar SIP T4 timer (msecs).</td></tr>
%%   <tr><td>`timer_c'</td><td>180000</td><td>Standar SIP C timer (msecs).</td></tr>
%%   <tr><td>`transaction_timeout'</td><td>900000</td><td>INVITE transaction maximum time
%%           (secs).</td></tr>
%%   <tr><td>`dialog_timeout'</td><td>900000</td>
%%       <td>Time to destroy dialog if no message has been received (msecs).</td></tr>
%%   <tr><td>`tcp_timeout'</td><td>180000</td>
%%       <td>Time to disconnect TCP/SSL connection if no message 
%%           has been received (msecs).</td></tr>
%%   <tr><td>`sctp_timeout'</td><td>180000</td>
%%       <td>Time to disconnect SCTP associations if no message 
%%           has been received (msecs).</td></tr>
%%   <tr><td>`nonce_timeout'</td><td>30000</td>
%%       <td>Time a new `nonce' in an authenticate header will be usable 
%%           (msecs, only for <i>ACK</i> or requests coming from the same 
%%           `ip' and `port').</td></tr>
%%   <tr><td>`max_calls'</td><td>100000</td><td>Maximum number of allowed calls.
%%           Each different Call-ID counts as a call.</td></tr>
%%   <tr><td>`max_connections'</td><td>1024</td>
%%       <td>Maximum number of simultaneous TCP/TLS connections NkSIP will accept 
%%           in each transport belonging to each SipApp.</td></tr>
%%   <tr><td>`registrar_default_time'</td><td>3600</td>
%%       <td>Registrar default time (secs).</td></tr>
%%   <tr><td>`registrar_min_time'</td><td>60</td>
%%       <td>Registrar minimum allowed time (secs).</td></tr>
%%   <tr><td>`registrar_max_time'</td><td>86400</td>
%%       <td>Registrar maximum allowed time (secs).</td></tr>
%%   <tr><td>`dns_cache_ttl'</td><td>3600</td>
%%       <td>DNS cache TTL (See {@link nksip_dns}) (secs).</td></tr>
%% </table>

-module(nksip_config).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-include("nksip.hrl").

-export([get/1, get/2, put/2, del/1, cseq/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,     handle_info/2]).

-compile({no_auto_import,[put/2]}).

-define(MINUS_CSEQ, 46111468).  % Lower values to debug


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Equivalent to `get(Key, undefined)'.
-spec get(term()) -> 
    Value :: term().

get(Key) ->
    get(Key, undefined).


%% @doc Gets an config value.
-spec get(term(), term()) -> 
    Value :: term().

get(Key, Default) -> 
    case ets:lookup(?MODULE, Key) of
        [] -> Default;
        [{_, Value}] -> Value
    end.

%% @doc Sets a config value.
-spec put(term(), term()) -> 
    ok.

put(Key, Val) -> 
    true = ets:insert(?MODULE, {Key, Val}),
    ok.


%% @doc Deletes a config value.
-spec del(term()) -> 
    ok.

del(Key) -> 
    true = ets:delete(?MODULE, Key),
    ok.


%% @doc Gets a new `CSeq'.
%% After booting, CSeq's counter is set using {@link nksip_lib:cseq/0}. Then each call 
%% to this function increments the counter by one.
-spec cseq() -> 
    nksip:cseq().

cseq() ->
    ets:update_counter(?MODULE, current_cseq, 1).


%% @private Default config values
-spec default_config() ->
    nksip_lib:proplist().

default_config() ->
    [
        {timer_t1, 500},                % 500 msecs
        {timer_t2, 4000},               % 4 secs
        {timer_t4, 5000},               % 5 secs
        {timer_c,  180000},             % 3 minutes
        {transaction_timeout, 900000},  % 15 min
        {dialog_timeout, 900000},       % 15 min
        {tcp_timeout, 180000},          % 3 min
        {sctp_timeout, 180000},         % 3 min
        {nonce_timeout, 30000},         % 30 secs
        {sipapp_timeout, 32000},        % 32 secs  
        {max_calls, 100000},            % Each Call-ID counts as a call
        {max_connections, 1024},        % Per transport and SipApp
        {registrar_default_time, 3600}, % 1 hour
        {registrar_min_time, 60},       % 1 min
        {registrar_max_time, 86400},    % 24 hour
        {dns_cache_ttl, 3600}           % 1 hour
    ].


%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
}).


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
        

%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([]) ->
    ets:new(?MODULE, [named_table, public, {read_concurrency, true}]),
    ?MODULE:put(current_cseq, nksip_lib:cseq()-?MINUS_CSEQ),
    % Store config values in config table to speed access
    lists:foreach(
        fun({Key, Default}) ->
            case application:get_env(nksip, Key) of
                {ok, Value} -> Value;
                _ -> Value = Default
            end,
            nksip_config:put(Key, Value)
        end,
        default_config()),
    put(global_id, nksip_lib:luid()),
    put(local_ips, nksip_lib:get_local_ips()),
    put(main_ip, nksip_lib:find_main_ip()),
    put(main_ip6, nksip_lib:find_main_ip(auto, ipv6)),
    {ok, #state{}}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info(Info, State) -> 
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.


%% @private
-spec code_change(term(), #state{}, term()) ->
    gen_server_code_change(#state{}).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% @private
-spec terminate(term(), #state{}) ->
    gen_server_terminate().

terminate(_Reason, _State) ->  
    ok.



