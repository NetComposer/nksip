%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc NkSIP UAC Auto Authentication Plugin
-module(nksip_uac_auto_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../include/nksip.hrl").
-include("../include/nksip_call.hrl").

-export([get_config/2, make_config/2, check_auth/4]).


%% ===================================================================
%% Private
%% ===================================================================

-record(nksip_uac_auto_auth, {
    max_tries,
    pass
 }).


%% @doc Get cached config
get_config(SrvId, max_tries) ->
    (SrvId:config_nksip_uac_auto_auth())#nksip_uac_auto_auth.max_tries;
get_config(SrvId, pass) ->
    (SrvId:config_nksip_uac_auto_auth())#nksip_uac_auto_auth.pass.


%% @private
make_config(Tries, Pass) ->
    #nksip_uac_auto_auth{max_tries=Tries, pass=Pass}.


% @doc Called after the UAC processes a response
-spec check_auth(nksip:request(), nksip:response(), nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

check_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = TransId,
        opts = Opts,
        method = Method, 
        code = Code, 
        from = From,
        iter = Iters
    } = UAC,
    IsProxy = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code==401 orelse Code==407) andalso Method/='CANCEL' andalso 
        (not IsProxy)
    of
        true ->
            #call{srv_id=SrvId, call_id=CallId} = Call,
            Max = case nklib_util:get_value(sip_uac_auto_auth_max_tries, Opts) of
                undefined -> 
                    get_config(SrvId, max_tries);
                Max0 ->
                    Max0
            end,
            DefPasses = get_config(SrvId, pass),
            Passes = case nklib_util:get_value(sip_pass, Opts) of
                undefined -> DefPasses;
                Passes0 -> Passes0++DefPasses
            end,
            case 
                Passes/=[] andalso Iters < Max andalso 
                nksip_auth:make_request(Req, Resp, [{sip_pass, Passes}|Opts]) 
            of
                {ok, Req1} ->
                    {ok, nksip_call_uac:resend(Req1, UAC, Call)};
                {error, Error} ->
                    ?debug(SrvId, CallId, 
                           "UAC ~p could not generate new auth request: ~p", 
                           [TransId, Error]),    
                    continue;
                false ->
                    continue
            end;
        false ->
            continue
    end.




