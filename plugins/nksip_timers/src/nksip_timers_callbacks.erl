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

%% @doc NkSIP Event State Compositor Plugin Callbacks
-module(nksip_timers_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").

-export([nkcb_parse_uac_opts/2, nkcb_dialog_update/3]).

%%%%%%%%%%%%%%%% Implemented core plugin callbacks %%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Called to parse specific UAC options
-spec nkcb_parse_uac_opts(nksip:request(), nksip:optslist()) ->
    {continue, list()}.

nkcb_parse_uac_opts(Req, Opts) ->
    case nksip_timers_lib:parse_uac_config(Opts, Req, []) of
        {ok, Opts1} ->
            {continue, [Req, Opts1]};
        {error, Error} ->
            {error, Error}
    end.


 %% @private
-spec nkcb_dialog_update(term(), nksip:dialog(), nksip_call:call()) ->
    {ok, nksip_call:call()} | continue.

nkcb_dialog_update({update, Class, Req, Resp}, Dialog, Call) ->
    Dialog1 = nksip_call_dialog:target_update(Class, Req, Resp, Dialog, Call),
    Dialog2 = nksip_call_dialog:session_update(Dialog1, Call),
    Dialog3 = nksip_timers_lib:timer_update(Req, Resp, Class, Dialog2, Call),
    {ok, nksip_call_dialog:store(Dialog3, Call)};

nkcb_dialog_update({invite, {stop, Reason}}, #dialog{invite=Invite}=Dialog, Call) ->
    #invite{
        media_started = Media,
        retrans_timer = RetransTimer,
        timeout_timer = TimeoutTimer,
        meta = Meta
    } = Invite,    
    RefreshTimer = nksip_lib:get_value(nksip_timers_refresh, Meta),
    nksip_lib:cancel_timer(RetransTimer),
    nksip_lib:cancel_timer(TimeoutTimer),
    nksip_lib:cancel_timer(RefreshTimer),
    StopReason = nksip_call_dialog:reason(Reason),
    nksip_call_dialog:dialog_update({invite_status, {stop, StopReason}}, Dialog, Call),
    case Media of
        true -> nksip_call_dialog:session_update(stop, Dialog, Call);
        _ -> ok
    end,
    {ok, nksip_call_dialog:store(Dialog#dialog{invite=undefined}, Call)};

nkcb_dialog_update({invite, Status}, Dialog, Call) ->
    #dialog{
        id = DialogId, 
        blocked_route_set = BlockedRouteSet,
        invite = #invite{
            status = OldStatus, 
            media_started = Media,
            class = Class,
            request = Req, 
            response = Resp
        } = Invite
    } = Dialog,
    Dialog1 = case Status of
        OldStatus -> 
            Dialog;
        _ -> 
            nksip_call_dialog:dialog_update({invite_status, Status}, Dialog, Call),
            Dialog#dialog{invite=Invite#invite{status=Status}}
    end,
    ?call_debug("Dialog ~s ~p -> ~p", [DialogId, OldStatus, Status]),
    Dialog2 = if
        Status==proceeding_uac; Status==proceeding_uas; 
        Status==accepted_uac; Status==accepted_uas ->
            D1 = nksip_call_dialog:route_update(Class, Req, Resp, Dialog1),
            D2 = nksip_call_dialog:target_update(Class, Req, Resp, D1, Call),
            nksip_call_dialog:session_update(D2, Call);
        Status==confirmed ->
            nksip_call_dialog:session_update(Dialog1, Call);
        Status==bye ->
            case Media of
                true -> 
                    nksip_call_dialog:session_update(stop, Dialog1, Call),
                    #dialog{invite=I1} = Dialog1,
                    Dialog1#dialog{invite=I1#invite{media_started=false}};
                _ ->
                    Dialog1
            end
    end,
    Dialog3 = case 
        (not BlockedRouteSet) andalso 
        (Status==accepted_uac orelse Status==accepted_uas)
    of
        true -> Dialog2#dialog{blocked_route_set=true};
        false -> Dialog2
    end,
    Dialog4 = nksip_timers_lib:timer_update(Req, Resp, Class, Dialog3, Call),
    {ok, nksip_call_dialog:store(Dialog4, Call)};

nkcb_dialog_update(_, _, _) ->
    continue.
    