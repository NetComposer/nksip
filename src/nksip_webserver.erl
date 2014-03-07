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

%% @doc NkSIP Webserver control

-module(nksip_webserver).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(gen_server).

-include("nksip.hrl").

-export([start_server/3, stop_server/2, get_port/1, stop_all/0]).
-export([start_link/0, init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, 
         handle_info/2]).
-export([ranch_start_link/6, do_stop_server/1]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Starts a new webserver, or returns a already started one
-spec start_server(nksip:app_id(), nksip:transport(), nksip_lib:proplist()) ->
    {ok, pid()} | {error, term()}.

start_server(AppId, Transp, Opts) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port, dispatch=Disp} = Transp,
    gen_server:call(?MODULE, {start, AppId, {Proto, Ip, Port}, Disp, Opts}).


%% @doc Stops a started webserver
-spec stop_server(nksip:app_id(), nksip:transport()) ->
    ok | {error, in_use} | {error, not_found}.

stop_server(AppId, Transp) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp,
    gen_server:call(?MODULE, {stop, AppId, {Proto, Ip, Port}}).


%% @doc Get the real port of a webserver
-spec get_port(nksip:transport()) ->
    inet:port_number() | undefined.

get_port(Transp) ->
    #transport{proto=Proto, listen_ip=Ip, listen_port=Port} = Transp,
    case catch ranch:get_port({Proto, Ip, Port}) of
        Port1 when is_integer(Port1) -> Port1;
        _ -> undefined
    end.


%% @doc Stops all servers
stop_all() ->
    gen_server:cast(?MODULE, stop_all).

    
%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {
    servers :: [],
    apps :: []
}).


%% @private
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
        

%% @private 
-spec init(term()) ->
    gen_server_init(#state{}).

init([]) ->
    {ok, #state{servers=[], apps=[]}}.


%% @private
-spec handle_call(term(), from(), #state{}) ->
    gen_server_call(#state{}).

handle_call({start, AppId, Ref, Disp, Opts}, _From, State) ->
    #state{servers=Servers, apps=Apps} = State,
    case nksip_transport_sup:get_pid(AppId) of
        AppPid when is_pid(AppPid) ->
            case lists:keytake(Ref, 1, Servers) of
                false ->
                    case do_start_server(Ref, Disp, Opts) of
                        {ok, Pid} ->
                            Servers1 = [{Ref, [AppId], Pid}|Servers],
                            Mon = erlang:monitor(process, AppPid),
                            Apps1 = [{{AppId, Ref}, Mon}|Apps],
                            State1 = State#state{servers=Servers1, apps=Apps1},
                            {reply, {ok, Pid}, State1};
                        {error, Error} ->
                            {reply, {error, Error}, State}
                    end;
                {value, {_, WApps, Pid}, Rest} ->
                    case lists:member(AppId, WApps) of
                        true -> 
                            {reply, {error, already_started}, State};
                        false ->
                            Servers1 = [{Ref, [AppId|WApps], Pid}|Rest],
                            Mon = erlang:monitor(process, AppPid),
                            Apps1 = [{{AppId, Ref}, Mon}|Apps],
                            State1 = State#state{servers=Servers1, apps=Apps1},
                            {reply, {ok, Pid}, State1}
                    end
            end;
        undefined ->
            {reply, {error, app_not_found}, State}
    end;

handle_call({stop, AppId, Ref}, _From, State) ->
    #state{servers=Servers, apps=Apps} = State,
    case lists:keytake(Ref, 1, Servers) of
        false ->
            {reply, {error, not_found}, State};
        {value, {_, WApps, WPid}, Rest} ->
            Apps1 = case lists:keytake({AppId, Ref}, 1, Apps) of
                false -> Apps;
                {value, {_, Mon}, RestApps} -> erlang:demonitor(Mon), RestApps
            end,
            State1 = State#state{apps=Apps1},
            case lists:member(AppId, WApps) of
                true ->
                    case WApps -- [AppId] of
                        [] ->
                            Reply = do_stop_server(Ref),
                            {reply, Reply, State1#state{servers=Rest}};
                        WApps1 ->
                            Servers1 = [{Ref, WApps1, WPid}|Rest],
                            {reply, ok, State1#state{servers=Servers1}}
                    end;
                false ->
                    {reply, {error, not_found}, State1}
            end
    end;

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(Msg, _From, State) -> 
    lager:error("Module ~p received unexpected call ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec handle_cast(term(), #state{}) ->
    gen_server_cast(#state{}).

handle_cast(stop_all, State) ->
    nksip_webserver_sup:terminate_all(),
    {noreply, State#state{servers=[]}};

handle_cast(Msg, State) -> 
    lager:error("Module ~p received unexpected cast ~p", [?MODULE, Msg]),
    {noreply, State}.


%% @private
-spec handle_info(term(), #state{}) ->
    gen_server_info(#state{}).

handle_info({'DOWN', MRef, process, _Pid, _Reason}, State) ->
    #state{apps=Apps} = State,
    case lists:keyfind(MRef, 2, Apps) of
        {{AppId, Ref}, _} -> 
            {reply, _, State1} = handle_call({stop, AppId, Ref}, none, State),
            {noreply, State1};
        false ->
            {noreply, State}
    end.


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


%% ===================================================================
%% Private
%% ===================================================================


%% @private
do_start_server(Ref, Dispatch, Opts) ->
    {Proto, Ip, Port} = Ref,
    Module = case Proto of
        tcp -> ranch_tcp;
        tls -> ranch_ssl;
        ws -> ranch_tcp;
        wss -> ranch_ssl
    end,
    Env = {env, [{dispatch, cowboy_router:compile(Dispatch)}]},
    Spec = ranch:child_spec(
        Ref,
        nksip_lib:get_value(listeners, Opts, 1), 
        Module,
        listen_opts(Proto, Ip, Port, Opts), 
        cowboy_protocol,
        [Env]),
    % Little hack to use our start_link instead of ranch's one
    {ranch_listener_sup, start_link, StartOpts} = element(2, Spec),
    Spec1 = setelement(2, Spec, {?MODULE, ranch_start_link, StartOpts}),
    nksip_webserver_sup:start_child(Spec1).


do_stop_server(Ref) ->
    SupRef = {ranch_listener_sup, Ref},
    nksip_webserver_sup:terminate_child(SupRef).


%% @private Gets socket options for listening connections
-spec listen_opts(nksip:protocol(), inet:ip_address(), inet:port_number(), 
                    nksip_lib:proplist()) ->
    nksip_lib:proplist().

listen_opts(ws, Ip, Port, _Opts) ->
    lists:flatten([
        {ip, Ip}, {port, Port}, 
        % {keepalive, true}, 
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]);

listen_opts(wss, Ip, Port, Opts) ->
    case code:priv_dir(nksip) of
        PrivDir when is_list(PrivDir) ->
            DefCert = filename:join(PrivDir, "certificate.pem"),
            DefKey = filename:join(PrivDir, "key.pem");
        _ ->
            DefCert = "",
            DefKey = ""
    end,
    Cert = nksip_lib:get_value(certfile, Opts, DefCert),
    Key = nksip_lib:get_value(keyfile, Opts, DefKey),
    lists:flatten([
        {ip, Ip}, {port, Port}, 
        % {keepalive, true}, 
        case Cert of "" -> []; _ -> {certfile, Cert} end,
        case Key of "" -> []; _ -> {keyfile, Key} end,
        case nksip_config:get(max_connections) of
            undefined -> [];
            Max -> {max_connections, Max}
        end
    ]).


%% @private Our version of ranch_listener_sup:start_link/5
-spec ranch_start_link(any(), non_neg_integer(), module(), term(), module(), term())-> 
    {ok, pid()}.

ranch_start_link(Ref, NbAcceptors, RanchTransp, TransOpts, Protocol, [Env]) ->
    case 
        ranch_listener_sup:start_link(Ref, NbAcceptors, RanchTransp, TransOpts, 
                                      Protocol, [Env])
    of
        {ok, Pid} ->
            {Proto, Ip, _} = Ref,
            Port = ranch:get_port(Ref),
            nksip_proc:put({nksip_webserver, {Proto, Ip, Port}}, [], Pid),
            {ok, Pid};
        Other ->
            Other
    end.





