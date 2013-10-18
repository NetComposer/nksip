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
-spec timer(nksip_call_lib:timer(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

timer(timer_c, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p Timer C fired", [Id, Method], Call),
    reply({timeout, <<"Timer C Timeout">>}, UAS, Call);

timer(noinvite, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_notice("UAS ~p ~p No-INVITE timer fired", [Id, Method], Call),
    reply({timeout, <<"No-INVITE Timeout">>}, UAS, Call);

% INVITE 3456xx retrans
timer(timer_g, #trans{id=Id, response=Resp}=UAS, Call) ->
    #sipmsg{class={resp, Code}} = Resp,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    UAS1 = case nksip_transport_uas:resend_response(Resp, Opts) of
        {ok, _} ->
            ?call_info("UAS ~p retransmitting 'INVITE' ~p response", 
                       [Id, Code], Call),
            nksip_call_lib:retrans_timer(timer_g, UAS, Call);
        error -> 
            ?call_notice("UAS ~p could not retransmit 'INVITE' ~p response", 
                         [Id, Code], Call),
            nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished})
    end,
    update(UAS1, Call);

% INVITE accepted finished
timer(timer_l, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer L fired", [Id], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE confirmed finished
timer(timer_i, #trans{id=Id}=UAS, Call) ->
    ?call_debug("UAS ~p 'INVITE' Timer I fired", [Id], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% NoINVITE completed finished
timer(timer_j, #trans{id=Id, method=Method}=UAS, Call) ->
    ?call_debug("UAS ~p ~p Timer J fired", [Id, Method], Call),
    UAS1 = nksip_call_lib:cancel_timers([timeout], UAS#trans{status=finished}),
    update(UAS1, Call);

% INVITE completed timeout
timer(timer_h, #trans{id=Id}=UAS, Call) ->
    ?call_notice("UAS ~p 'INVITE' timeout (Timer H) fired, no ACK received", 
                [Id], Call),
    UAS1 = UAS#trans{status=finished},
    UAS2 = nksip_call_lib:cancel_timers([timeout, retrans], UAS1),
    update(UAS2, Call);

timer(expire, #trans{id=Id, method=Method, status=Status}=UAS, Call) ->
    ?call_debug("UAS ~p ~p (~p) Timer Expire fired: sending 487",
                [Id, Method, Status], Call),
    terminate_request(UAS, Call);

timer(Timer, #trans{id=Id, method=Method}=UAS, Call)
      when Timer=:=authorize; Timer=:=route; Timer=:=invite; Timer=:=bye;
           Timer=:=options; Timer=:=register ->
    UAS1 = nksip_call_lib:cancel_timers([app], UAS),
    ?call_notice("UAS ~p ~p timeout, no SipApp response", [Id, Method], Call),
    Msg = {internal_error, <<"No SipApp Response">>},
    reply(Msg, UAS1, update(UAS1, Call)).



%% ===================================================================
%% Utils
%% ===================================================================


%% @private Sends a transaction reply
-spec reply(nksip:sipreply() | {nksip:response(), nksip_lib:proplist()}, 
            nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

reply(Reply, UAS, Call) ->
    {_, Call1} = nksip_call_uas_reply:reply(Reply, UAS, Call),
    Call1.

%% @private
-spec terminate_request(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

terminate_request(#trans{status=Status, from=From}=UAS, Call)
                  when Status=:=authorize; Status=:=route ->
    case From of
        {fork, _ForkId} -> ok;
        _ -> app_cast(cancel, [], UAS, Call)
    end,
    UAS1 = UAS#trans{cancel=cancelled},
    Call1 = update(UAS1, Call),
    reply(request_terminated, UAS1, Call1);

terminate_request(#trans{status=invite_proceeding, from=From}=UAS, Call) ->
    case From of
        {fork, ForkId} -> 
            nksip_call_fork:cancel(ForkId, Call);
        _ ->  
            app_cast(cancel, [], UAS, Call),
            UAS1 = UAS#trans{cancel=cancelled},
            Call1 = update(UAS1, Call),
            reply(request_terminated, UAS1, Call1)
    end;

terminate_request(_, Call) ->
    Call.
    

%% @private
-spec app_cast(atom(), list(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

app_cast(Fun, Args, UAS, Call) ->
    #trans{id=Id, method=Method, status=Status, request=Req} = UAS,
    #call{app_id=AppId, opts=#call_opts{app_module=Module}} = Call,
    ?call_debug("UAS ~p ~p (~p) casting SipApp's ~p", 
                [Id, Method, Status, Fun], Call),
    Args1 = Args ++ [Req],
    Args2 = Args ++ [Req#sipmsg.id],
    nksip_sipapp_srv:sipapp_cast(AppId, Module, Fun, Args1, Args2),
    Call.


%% @private
-spec transaction_id(nksip:request()) ->
    integer().
    
transaction_id(Req) ->
        #sipmsg{
            class = {req, Method},
            app_id = AppId, 
            ruri = RUri, 
            from_tag = FromTag, 
            to_tag = ToTag, 
            vias = [Via|_], 
            call_id = CallId, 
            cseq = CSeq
        } = Req,
    {_Transp, ViaIp, ViaPort} = nksip_parse:transport(Via),
    case nksip_lib:get_value(branch, Via#via.opts) of
        <<"z9hG4bK", Branch/binary>> ->
            erlang:phash2({AppId, CallId, Method, ViaIp, ViaPort, Branch});
        _ ->
            % pre-RFC3261 style
            {_, UriIp, UriPort} = nksip_parse:transport(RUri),
            -erlang:phash2({AppId, UriIp, UriPort, FromTag, ToTag, CallId, CSeq, 
                            Method, ViaIp, ViaPort})
    end.





