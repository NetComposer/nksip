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

%% @private Call UAS Timer anagement
-module(nksip_call_uas_timer).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([timer/3]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkserver/include/nkserver.hrl").


%% ===================================================================
%% Timers
%% ===================================================================

%% @private
-spec timer(nksip_call_lib:timer()|term(), nksip_call:trans_id(), nksip_call:call()) ->
    nksip_call:call().

timer(Tag, Id, #call{pkg_id=PkgId, trans=Trans}=Call) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            case  ?CALL_PKG(PkgId, nksip_uas_timer, [Tag, UAS, Call]) of
                {ok, Call1} ->
                    Call1;
                {continue, [Tag1, UAS1, Call1]} ->
                    do_timer(Tag1, UAS1, Call1)
            end;
        false ->
            ?CALL_LOG(warning, "Call ignoring uas timer (~p, ~p)", [Tag, Id], Call),
            Call
    end.


%% @private
-spec do_timer(nksip_call_lib:timer(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_timer(timer_c, UAS, Call) ->
    ?CALL_LOG(notice, "UAS ~p ~p timer C fired", [UAS#trans.id, UAS#trans.method], Call),
    nksip_call_uas:do_reply({timeout, <<"Timer C Timeout">>}, UAS, Call);

do_timer(noinvite, UAS, Call) ->
    ?CALL_LOG(notice, "UAS ~p ~p No-INVITE timer fired", [UAS#trans.id, UAS#trans.method], Call),
    nksip_call_uas:do_reply({timeout, <<"No-INVITE Timeout">>}, UAS, Call);

% INVITE 3456xx retrans
do_timer(timer_g, #trans{response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, _Code, _Reason}} = Resp,
    UAS2 = case nksip_call_uas_transp:resend_response(Resp, []) of
        {ok, _} ->
            ?CALL_LOG(info, "UAS ~p retransmitting 'INVITE' ~p response", [UAS#trans.id, _Code], Call),
            nksip_call_lib:retrans_timer(timer_g, UAS, Call);
        {error, _} ->
            ?CALL_LOG(notice, "UAS ~p could not retransmit 'INVITE' ~p response", [UAS#trans.id, _Code], Call),
            UAS1 = UAS#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAS1, Call)
    end,
    update(UAS2, Call);

% INVITE accepted finished
do_timer(timer_l, UAS, Call) ->
    ?CALL_DEBUG("UAS ~p 'INVITE' timer L fired", [UAS#trans.id], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% INVITE confirmed finished
do_timer(timer_i, UAS, Call) ->
    ?CALL_DEBUG("UAS ~p 'INVITE' timer I fired", [UAS#trans.id], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% NoINVITE completed finished
do_timer(timer_j, UAS, Call) ->
    ?CALL_DEBUG("UAS ~p ~p timer J fired", [UAS#trans.id, UAS#trans.method], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% INVITE completed timeout
do_timer(timer_h, UAS, Call) ->
    ?CALL_LOG(notice, "UAS ~p 'INVITE' timeout (timer H) fired, no ACK received", [UAS#trans.id], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    UAS3 = nksip_call_lib:retrans_timer(cancel, UAS2, Call),
    update(UAS3, Call);

do_timer(expire, #trans{status=invite_proceeding, from=From}=UAS, Call) ->
    ?CALL_DEBUG("UAS ~p 'INVITE' timer Expire fired: sending 487",[UAS#trans.id], Call),
    case From of
        {fork, ForkId} ->
            % We do not cancel our UAS request, we send it to the fork
            % Proxied remotes should send the 487 (ot not)
            nksip_call_fork:cancel(ForkId, Call);
        _ ->  
            UAS1 = UAS#trans{cancel=cancelled},
            Call1 = update(UAS1, Call),
            nksip_call_uas:do_reply(request_terminated, UAS1, Call1)
    end;

do_timer(expire, UAS, Call) ->
    ?CALL_DEBUG("UAS ~p 'INVITE' (~p) timer Expire fired (ignored)", [UAS#trans.id, UAS#trans.status], Call),
    Call.