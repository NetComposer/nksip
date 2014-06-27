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

%% @doc NkSIP Reliable Provisional Responses Plugin
-module(nksip_100rel).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("../../../include/nksip.hrl").
-include("../../../include/nksip_call.hrl").

-export([is_prack_retrans/2, check_prack/3]).
-export([version/0, deps/0, parse_config/2]).


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
    [].


%% @doc Parses this plugin specific configuration
-spec parse_config(PluginOpts, Config) ->
    {ok, PluginOpts, Config} | {error, term()} 
    when PluginOpts::nksip:optslist(), Config::nksip:optslist().

parse_config(PluginOpts, Config) ->
    Allow = nksip_lib:get_value(allow, Config),
    Config1 = case lists:member(<<"PRACK">>, Allow) of
        true -> 
            Config;
        false -> 
            nksip_lib:store_value(allow, Allow++[<<"PRACK">>], Config)
    end,
    Supported = nksip_lib:get_value(supported, Config),
    Config2 = case lists:member(<<"100rel">>, Supported) of
        true -> Config1;
        false -> nksip_lib:store_value(supported, Supported++[<<"100rel">>], Config1)
    end,
    parse_config(PluginOpts, [], Config2).





%% ===================================================================
%% Private
%% ===================================================================


%% @private
-spec parse_config(PluginConfig, Unknown, Config) ->
    {ok, Unknown, Config} | {error, term()}
    when PluginConfig::nksip:optslist(), Unknown::nksip:optslist(), 
         Config::nksip:optslist().

parse_config([], Unknown, Config) ->
    {ok, Unknown, Config};

parse_config([Term|Rest], Unknown, Config) ->
    Op = case Term of
        {nksip_100rel_default_expires, Secs} ->
            case is_integer(Secs) andalso Secs>=1 of
                true -> update;
                false -> error
            end;
        _ ->
            unknown
    end,
    case Op of
        update ->
            Key = element(1, Term),
            Val = element(2, Term),
            Config1 = [{Key, Val}|lists:keydelete(Key, 1, Config)],
            parse_config(Rest, Unknown, Config1);
        error ->
            {error, {invalid_config, element(1, Term)}};
        unknown ->
            parse_config(Rest, [Term|Unknown], Config)
    end.


%% @private
-spec is_prack_retrans(nksip:response(), nksip_call:trans()) ->
    boolean().

is_prack_retrans(Resp, UAC) ->
    #sipmsg{dialog_id=DialogId, cseq={CSeq, Method}} = Resp,
    #trans{pracks=PRAcks} = UAC,
    case nksip_sipmsg:header(<<"rseq">>, Resp, integers) of
        [RSeq] when is_integer(RSeq) ->
            lists:member({RSeq, CSeq, Method, DialogId}, PRAcks);
        _ ->
            false
    end.


%% @private
-spec check_prack(nksip:response(), nksip_call:trans(), nksip:call()) ->
    continue | {ok, nksip:call()}.

check_prack(Resp, UAC, Call) ->
    #trans{id=Id, from=From, method=Method} = UAC,
    #sipmsg{
        class = {resp, Code, _Reason}, 
        dialog_id = DialogId,
        require = Require
    } = Resp,
    case From of
        {fork, _} ->
            continue;
        _ ->
            case Method of
                'INVITE' when Code>100, Code<200 ->
                    case lists:member(<<"100rel">>, Require) of
                        true -> send_prack(Resp, Id, DialogId, Call);
                        false -> continue
                    end;
                _ ->
                    continue
            end
    end.


%% @private
-spec send_prack(nksip:response(), nksip_call_uac:id(), 
                 nksip_dialog:id(), nksip_call:call()) ->
    continue | {ok, nksip:call()}.

send_prack(Resp, Id, DialogId, Call) ->
    #sipmsg{class={resp, Code, _Phrase}, cseq={CSeq, _}} = Resp,
    #call{trans=Trans} = Call,
    try
        case nksip_sipmsg:header(<<"rseq">>, Resp, integers) of
            [RSeq] when RSeq > 0 -> ok;
            _ -> RSeq = throw(invalid_rseq)
        end,
        case lists:keyfind(Id, #trans.id, Trans) of
            #trans{} = UAC -> ok;
            _ -> UAC = throw(no_transaction)
        end,
        #trans{
            method = Method, 
            rseq = LastRSeq, 
            pracks = PRAcks,
            opts = UACOpts
        } = UAC,
        case LastRSeq of
            0 -> ok;
            _ when RSeq==LastRSeq+1 -> ok;
            _ -> throw(rseq_out_of_order)
        end,
        case nksip_call_dialog:find(DialogId, Call) of
            #dialog{invite=#invite{sdp_offer={remote, invite, RemoteSDP}}} -> ok;
            _ -> RemoteSDP = <<>>
        end,
        Body = case nksip_lib:get_value(prack_callback, UACOpts) of
            Fun when is_function(Fun, 2) -> 
                case catch Fun(RemoteSDP, {resp, Code, Resp, Call}) of
                    Bin when is_binary(Bin) ->
                        Bin;
                    #sdp{} = LocalSDP -> 
                        LocalSDP;
                    Other ->
                        ?call_warning("error calling prack_sdp/2: ~p", [Other]),
                        <<>>
                end;
            _ ->
                <<>>
        end,
        RAck = list_to_binary([ 
            integer_to_list(RSeq),
            32,
            integer_to_list(CSeq),
            32,
            nksip_lib:to_list(Method)
        ]),
        Opts2 = [{add, "rack", RAck}, {body, Body}],
        case nksip_call:make_dialog(DialogId, 'PRACK', Opts2, Call) of
            {ok, Req, ReqOpts, Call1} -> 
                PRAcks1 = [{RSeq, CSeq, Method, DialogId}|PRAcks],
                UAC1 = UAC#trans{rseq=RSeq, pracks=PRAcks1},
                Call2 = nksip_call_lib:update(UAC1, Call1),
                {ok, nksip_call_uac_req:request(Req, ReqOpts, none, Call2)};
            {error, Error} ->
                throw(Error)
        end
    catch
        throw:TError ->
            ?call_warning("could not send PRACK: ~p", [TError]),
            continue
    end.



