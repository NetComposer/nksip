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

%% @doc NkSIP Config Cache
%%
%%
%% This module is hot compiled in run-time, after NkSIP application has started
%% It maintains a number of functions to cache some parts of the configuration,
%% currently:
%%
%% - global_id
%% - local_ips
%% - main_ip
%% - main_ip6

-module(nksip_config_cache).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
