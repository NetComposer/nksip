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

%% @doc NkSIP Event State Compositor Plugin
%%
%% This module implements a Event State Compositor, according to RFC3903
%% By default, it uses the RAM-only built-in store, but any Service can implement 
%% sip_event_compositor_store/3 callback to use any external database.

-module(nksip_event_compositor).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include_lib("nklib/include/nklib.hrl").
-include("../include/nksip.hrl").
-include("nksip_event_compositor.hrl").

-export([find/3, request/1, clear/1]).
-export([version/0, deps/0, parse_config/1, terminate/2]).
-export_type([reg_publish/0]).


%% ===================================================================
%% Types and records
%% ===================================================================

-type reg_publish() :: #reg_publish{}.


%% ===================================================================
%% Plugin specific
%% ===================================================================

%% @doc Version
-spec version() ->
    string().

version() ->
    "0.1".


%% @doc Dependant plugins
-spec deps() ->
    [{atom(), string()}].
    
deps() ->
    [nksip].


%% @doc Parses this plugin specific configuration
-spec parse_config(nksip:optslist()) ->
    {ok, nksip:optslist()} | {error, term()}.

parse_config(Opts) ->
    Defaults = [{nksip_event_compositor_default_expires, 60}],
    Opts1 = nklib_util:defaults(Opts, Defaults),
    Allow = nklib_util:get_value(sip_allow, Opts1),
    Opts2 = case lists:member(<<"PUBLISH">>, Allow) of
        true -> 
            Opts1;
        false -> 
            nklib_util:store_value(sip_allow, Allow++[<<"PUBLISH">>], Opts1)
    end,
    case nklib_util:get_value(nksip_event_compositor_default_expires, Opts2) of
        Secs when is_integer(Secs), Secs>=1 ->
            {ok, Opts2};
        _ ->
            {error, {invalid_config, nksip_event_compositor_default_expires}}
    end.



%% @doc Called when the plugin is shutdown
-spec terminate(nkservice:id(), nkservice_server:sub_state()) ->
    {ok, nkservice_server:sub_state()}.

terminate(SrvId, ServiceState) ->  
    catch clear(SrvId),
    {ok, ServiceState}.




%% ===================================================================
%% Public
%% ===================================================================

%% @doc Finds a stored published information
-spec find(nkservice:id()|term(), nksip:aor(), binary()) ->
    {ok, #reg_publish{}} | not_found | {error, term()}.

find(App, AOR, Tag) ->
    {ok, SrvId} = nkservice_server:find(App),
    nksip_event_compositor_lib:store_get(SrvId, AOR, Tag).


%% @doc Processes a PUBLISH request according to RFC3903
-spec request(nksip:request()) ->
    nksip:sipreply().

request(#sipmsg{class={req, 'PUBLISH'}}=Req) ->
    #sipmsg{srv_id=SrvId, ruri=RUri, expires=Expires, body=Body} = Req,
    Expires1 = case is_integer(Expires) andalso Expires>0 of
        true -> 
            Expires;
        _ -> 
            SrvId:cache_sip_event_compositor_default_expires()
    end,
    AOR = {RUri#uri.scheme, RUri#uri.user, RUri#uri.domain},
    case nksip_sipmsg:header(<<"sip-if-match">>, Req) of
        [] when Body == <<>> ->
            {invalid_request, <<"No Body">>};
        [] ->
            Tag = nklib_util:uid(),
            nksip_event_compositor_lib:store_put(SrvId, AOR, Tag, Expires1, Body);
        [Tag] ->
            case find(SrvId, AOR, Tag) of
                {ok, _Reg} when Expires==0 -> 
                    nksip_event_compositor_lib:store_del(SrvId, AOR, Tag);
                {ok, Reg} when Body == <<>> -> 
                    nksip_event_compositor_lib:store_put(SrvId, AOR, Tag, Expires1, Reg);
                {ok, _} -> 
                    nksip_event_compositor_lib:store_put(SrvId, AOR, Tag, Expires1, Body);
                not_found ->    
                    conditional_request_failed;
                {error, Error} ->
                    ?warning(SrvId, <<>>, "Error calling callback: ~p", [Error]),
                    {internal_error, <<"Callback Invalid Response">>}
            end;
        _ ->
            invalid_request
    end.


%% @doc Clear all stored records by a Service's core.
-spec clear(nkservice:name()|nkservice:id()) -> 
    ok | callback_error | service_not_found.

clear(App) -> 
    case nkservice_server:find(App) of
        {ok, SrvId} ->
            case nksip_event_compositor_lib:store_del_all(SrvId) of
                ok -> ok;
                _ -> callback_error
            end;
        _ ->
            service_not_found
    end.





