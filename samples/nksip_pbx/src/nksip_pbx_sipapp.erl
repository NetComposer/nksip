%% -------------------------------------------------------------------
%%
%% Server Callback module
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

%% @doc SipApp callback module.
%%
%% This module implements the mandatory callback module of each SipApp application,
%% with behaviour `nksip_sipapp'.
%%
%% This SipApp implements a SIP proxy, allowing  endpoints to register 
%% and call each other using its registered uri. 
%% Each registered endpoint's speed is monitored and special "extensions" are
%% available to call all nodes, call the fastest, etc.
%%
%% See {@link //nksip_pbx} for an overview.

-module(nksip_pbx_sipapp).

-export([start/0, stop/0, check_speed/1, get_speed/0]).
-export([init/1, sip_get_user_pass/4, sip_authorize/3, sip_route/5]). 
-export([sip_dialog_update/3, sip_session_update/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-define(DOMAINS, [<<"nksip">>, <<"127.0.0.1">>]).
-define(TIME_CHECK, 10000).

-include("../../../include/nksip.hrl").
-include("../../../plugins/include/nksip_registrar.hrl").


%% @doc Starts a new SipApp, listening on port 5060 for udp and tcp and 5061 for tls,
%% and acting as a registrar.
start() ->
    CoreOpts = [
        {plugins, [nksip_registrar]},                      
        {transports, [{udp, all, 5060}, {tls, all, 5061}]}
    ],
    ok = nksip:start(pbx, ?MODULE, [], CoreOpts).


%% @doc Stops the SipApp.
stop() ->
    nksip:stop(pbx).


%% @doc Stops or restart automatic response time detection.
check_speed(Bool) ->
    nksip:cast(pbx, {check_speed, Bool}).


%% @doc Get all registered endpoints with their last respnse time.
get_speed() ->
    nksip:call(pbx, get_speed).


%%%%%%%%%%%%%%%%%%%%%%%  NkSIP CallBacks %%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    auto_check
}).

%% @doc SipApp Callback: initialization.
%% This function is called by NkSIP after calling `nksip:start/4'.
%% We program a timer to check our nodes.
init([]) ->
    erlang:start_timer(?TIME_CHECK, self(), check_speed),
    nksip:put(pbx, speed, []),
    {ok, #state{auto_check=true}}.


%% @doc SipApp Callback: Called to check user's password.
%% If the incoming user's realm is one of our domains, the password for any 
%% user is "1234". For other realms, no password is valid.
sip_get_user_pass(_User, <<"nksip">>, _Req, _Call) ->
    <<"1234">>;
sip_get_user_pass(_User, _Realm, _Req, _Call) -> 
    false.


%% @doc SipApp Callback: Called to check if a request should be authorized.
%% <ul>
%%      <li>We first check to see if the request is an in-dialog request, coming from 
%%          the same ip and port of a previously authorized request.</li>
%%      <li>If not, we check if we have a previous authorized REGISTER request from 
%%          the same ip and port.</li> 
%%      <li>Next, we check if the request has a valid authentication header with realm 
%%          "nksip". If `{{digest, <<"nksip">>}, true}' is present, the user has 
%%          provided a valid password and it is authorized. 
%%          If `{{digest, <<"nksip">>}, false}' is present, we have presented 
%%          a challenge, but the user has failed it. We send 403.</li>
%%      <li>If no digest header is present, reply with a 407 response sending 
%%          a challenge to the user.</li>
%% </ul>
sip_authorize(Auth, Req, _Call) ->
    Method = nksip_request:method(Req),
    lager:notice("Request ~p auth data: ~p", [Method, Auth]),
    case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
        true -> 
            ok;
        false ->
            case nksip_lib:get_value({digest, <<"nksip">>}, Auth) of
                true -> 
                    ok;             % Password is valid
                false -> 
                    forbidden;      % User has failed authentication
                undefined -> 
                    {proxy_authenticate, <<"nksip">>}
                    
            end
    end.


%% @doc SipApp Callback: Called to decide how to route every new request.
%%
%% <ul>
%%      <li>If the user part of the request-uri is 200, proxy in parallel to all
%%          registered endpoints but me, including a <i>Record-Route</i>, so
%%          all dialog requests will go to this proxy.</li>
%%      <li>If it is 201, call in parallel each two random endpoints, including
%%          a custom header but no <i>Record-Route</i>, so next dialog requests will
%%          go directly to the endpoint.</li>
%%      <li>For 202, send the request to the fastest registered endpoint.</li>
%%      <li>For 203, to the slowest.</li>
%%      <li>If there is a different user part in the request-uri, check to see if 
%%          it is already registered with us and redirect to it.</li>
%%      <li>If the there is no user part in the request-uri (only the domain) 
%%          process locally if it is one of our domains.
%%          (Since we have not implemented `invite/4', `options/4,' etc., all responses
%%          will be default responses). REGISTER will be processed as configured
%%          when starting the SipApp.</li>
%% </ul>

sip_route(_Scheme, <<"200">>, _, Req, _Call) ->
    UriList = find_all_except_me(Req),
    {proxy, UriList, [record_route]};

sip_route(_Scheme, <<"201">>, _, Req, _Call) ->
    All = random_list(find_all_except_me(Req)),
    UriList = take_in_pairs(All),
    {proxy, UriList, [{add, "x-nksip-server", <<"201">>}]};

sip_route(_Scheme, <<"202">>, _, _Req, _Call) ->
    Speed = nksip:get(pbx, speed),
    UriList = [[Uri] || {_Time, Uri} <- lists:sort(Speed)],
    {proxy, UriList};

sip_route(_Scheme, <<"203">>, _, _Req, _Call) ->
    Speed = nksip:get(pbx, speed),
    UriList = [[Uri] || {_Time, Uri} <- lists:sort(Speed)],
    {proxy, lists:reverse(UriList)};

sip_route(_Scheme, <<>>, Domain, Req, _Call) ->
    case lists:member(Domain, ?DOMAINS) of
        true ->
            process;
        false ->
            case nksip_request:is_local_route(Req) of
                true -> process;
                false -> proxy
            end
    end;
    
sip_route(Scheme, User, Domain, _Req, _Call) ->
    case lists:member(Domain, ?DOMAINS) of
        true ->
            UriList = nksip_registrar:find(pbx, Scheme, User, Domain),
            {proxy, UriList, [record_route]};
        false ->
            proxy
    end.


sip_dialog_update(Status, Dialog, _Call) ->
    DialogId = nksip_dialog:get_id(Dialog),
    lager:notice("PBX Dialog ~s Update: ~p", [DialogId, Status]),
    ok.


sip_session_update({start, LocalSDP, RemoteSDP}, Dialog, _Call) ->
    DialogId = nksip_dialog:get_id(Dialog),
    lager:notice("PBX Session ~s Update: start", [DialogId]),
    lager:notice("Local SDP: ~p", [nksip_sdp:unparse(LocalSDP)]),
    lager:notice("Remote SDP: ~p", [nksip_sdp:unparse(RemoteSDP)]),
    ok;

sip_session_update(Status, Dialog, _Call) ->
    DialogId = nksip_dialog:get_id(Dialog),
    lager:notice("PBX Session ~s Update: ~p", [DialogId, Status]),
    ok.




%% @doc SipApp Callback: Synchronous user call.
handle_call(get_speed, _From, State) ->
    Speed = nksip:get(pbx, speed),
    Reply = [{Time, nksip_unparse:uri(Uri)} || {Time, Uri} <- Speed],
    {reply, Reply, State}.


%% @doc SipApp Callback: Asynchronous user cast.
handle_cast({speed_update, Speed}, State) ->
    Speed = nksip:put(pbx, speed, Speed),
    erlang:start_timer(?TIME_CHECK, self(), check_speed),
    {noreply, State};

handle_cast({check_speed, true}, State) ->
    handle_info({timeout, none, check_speed}, State#state{auto_check=true});

handle_cast({check_speed, false}, State) ->
    {noreply, State#state{auto_check=false}}.


%% @doc SipApp Callback: External erlang message received.
%% The programmed timer sends a `{timeout, _Ref, check_speed}' message
%% periodically to the SipApp.
handle_info({timeout, _, check_speed}, #state{auto_check=true}=State) ->
    Self = self(),
    spawn(fun() -> test_speed(Self) end),
    {noreply, State};

handle_info({timeout, _, check_speed}, #state{auto_check=false}=State) ->
    {noreply, State}.



%%%%%%%%%%%%%%%%%%%%%%%  Internal %%%%%%%%%%%%%%%%%%%%%%%%


%% @doc Gets all registered contacts and sends an OPTION to each of them
%% to measure its response time.
test_speed(Pid) ->
    Speed = test_speed(find_all(), []),
    gen_server:cast(Pid, {speed_update, Speed}).

%% @private
test_speed([], Acc) ->
    Acc;
test_speed([Uri|Rest], Acc) ->
    case timer:tc(fun() -> nksip_uac:options(pbx, Uri, []) end) of
        {Time, {ok, 200, []}} -> 
            test_speed(Rest, [{Time/1000, Uri}|Acc]);
        {_, _} -> 
            test_speed(Rest, Acc)
    end.


%% @doc Gets all registered contacts
find_all() ->
    All = [
        [Uri || #reg_contact{contact=Uri} <- List] 
        || {_, _, List} <- nksip_registrar_util:get_all()
    ],
    lists:flatten(All).


%% @doc Gets all registered contacts, excluding the one in `Request'
find_all_except_me(ReqId) ->
    [From] = nksip_request:header(<<"from">>, ReqId),
    [{Scheme, User, Domain}] = nksip_parse:aors(From),
    AOR = {Scheme, User, Domain},
    All = [
        [Uri || #reg_contact{contact=Uri} <- List] 
        || {_, R_AOR, List} <- nksip_registrar_util:get_all(), R_AOR /= AOR
    ],
    lists:flatten(All).



%%%%%%%%%%%%%%%%%%%%%%%  Utilities %%%%%%%%%%%%%%%%%%%%%%%%


%% @private
random_list(List) ->
    List1 = [{crypto:rand_uniform(1, length(List)+1), Term} || Term <- List],
    [Term || {_, Term} <- lists:sort(List1)].


%% @private
take_in_pairs([]) -> [];
take_in_pairs(List) -> take_in_pairs(List, []).

take_in_pairs([], Acc) -> lists:reverse(Acc);
take_in_pairs([Last], Acc) -> take_in_pairs([], [[Last]|Acc]);
take_in_pairs([One, Two|Rest], Acc) -> take_in_pairs(Rest, [[One, Two]|Acc]).
