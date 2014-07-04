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

%% @doc Call UAS Management
-module(nksip_call_uas).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([timer/3, terminate_request/2, transaction_id/1]).
-export_type([status/0, id/0]).

-import(nksip_call_lib, [update/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-type status() ::  authorize | route | ack |
                   invite_proceeding | invite_accepted | invite_completed | 
                   invite_confirmed | 
                   trying | proceeding | completed | finished.

-type id() :: integer().


%% ===================================================================
%% Timers
%% ===================================================================

%% @private
-spec timer(nksip_call_lib:timer()|term(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

timer(Tag, UAS, #call{app_id=AppId}=Call) ->
    case AppId:nkcb_uas_timer(Tag, UAS, Call) of
        {ok, Call1} ->
            Call1;
        {continue, [Tag1, UAS1, Call1]} ->
            do_timer(Tag1, UAS1, Call1)
    end.


%% @private
-spec do_timer(nksip_call_lib:timer(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_timer(timer_c, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p Timer C fired", [Id, Method]),
    reply({timeout, <<"Timer C Timeout">>}, UAS, Call);

do_timer(noinvite, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p No-INVITE timer fired", [Id, Method]),
    reply({timeout, <<"No-INVITE Timeout">>}, UAS, Call);

% INVITE 3456xx retrans
do_timer(timer_g, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, Code, _Reason}} = Resp,
    UAS2 = case nksip_transport_uas:resend_response(Resp, []) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", [Id, Code]),
            nksip_call_lib:retrans_timer(timer_g, UAS, Call);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p response", [Id, Code]),
            UAS1 = UAS#trans{status=finished},
            nksip_call_lib:timeout_timer(cancel, UAS1, Call)
    end,
    update(UAS2, Call);

% INVITE accepted finished
do_timer(timer_l, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer L fired", [Id]),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% INVITE confirmed finished
do_timer(timer_i, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id]),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% NoINVITE completed finished
do_timer(timer_j, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_debug("UAS ~p ~p Timer J fired", [Id, Method]),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    update(UAS2, Call);

% INVITE completed timeout
do_timer(timer_h, #trans{id=Id}=UAS, Call) ->
    ?call_notice("UAS ~p 'INVITE' timeout (Timer H) fired, no ACK received", [Id]),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:timeout_timer(cancel, UAS1, Call),
    UAS3 = nksip_call_lib:retrans_timer(cancel, UAS2, Call),
    update(UAS3, Call);

do_timer(expire, #trans{id=Id, method=Method, status=Status}=UAS, Call) ->
    ?call_debug("UAS ~p ~p (~p) Timer Expire fired: sending 487",[Id, Method, Status]),
    terminate_request(UAS, Call).

% timer({callback, Fun}, #trans{id=Id, method=Method}=UAS, Call) ->
%     ?call_notice("UAS ~p ~p timeout, no SipApp response calling ~p", 
%                  [Id, Method, Fun]),
%     Msg = {internal_error, <<"No SipApp Response">>},
%     UAS1 = nksip_call_lib:callback_timer(cancel, UAS, Call),
%     reply(Msg, UAS1, update(UAS1, Call)).



%% ===================================================================
%% Utils
%% ===================================================================


%% @private Sends a transaction reply
-spec reply(nksip:sipreply() | {nksip:response(), nksip:optslist()}, 
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply(Reply, UAS, Call) ->
    {_, Call1} = nksip_call_uas_reply:reply(Reply, UAS, Call),
    Call1.

%% @private
-spec terminate_request(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

terminate_request(#trans{status=Status}=UAS, Call)
                  when Status==authorize; Status==route ->
    UAS1 = UAS#trans{cancel=cancelled},
    Call1 = update(UAS1, Call),
    reply(request_terminated, UAS1, Call1);

terminate_request(#trans{status=invite_proceeding, from=From}=UAS, Call) ->
    case From of
        {fork, ForkId} -> 
            nksip_call_fork:cancel(ForkId, Call);
        _ ->  
            UAS1 = UAS#trans{cancel=cancelled},
            Call1 = update(UAS1, Call),
            reply(request_terminated, UAS1, Call1)
    end;

terminate_request(_, Call) ->
    Call.
    

%% @private
-spec transaction_id(nksip:request()) ->
    integer().
    
transaction_id(Req) ->
        #sipmsg{
            class = {req, Method},
            ruri = RUri, 
            from = {_, FromTag}, 
            to = {_, ToTag}, 
            vias = [Via|_], 
            cseq = {CSeq, _}
        } = Req,
    {_Transp, ViaIp, ViaPort} = nksip_parse:transport(Via),
    case nksip_lib:get_value(<<"branch">>, Via#via.opts) of
        <<"z9hG4bK", Branch/binary>> when byte_size(Branch) > 0 ->
            erlang:phash2({Method, ViaIp, ViaPort, Branch});
        _ ->
            % pre-RFC3261 style
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            -erlang:phash2({UriIp, UriPort, FromTag, ToTag, CSeq, 
                            Method, ViaIp, ViaPort})
    end.





