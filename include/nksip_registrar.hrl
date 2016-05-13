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


-record(reg_contact, {
    index :: nksip_registrar_lib:index(),
    contact :: nksip:uri(), 
    updated :: nklib_util:l_timestamp(),
    expire :: nklib_util:timestamp(),
    q :: float(),  
    call_id :: nksip:call_id(),
    cseq :: nksip:cseq(),
    nkport :: nkpacket:nkport(),
    path = [] :: [nksip:uri()],
    meta = [] :: nksip:optslist()  
}).

-record(nksip_registrar_time, {
    min :: pos_integer(),
    max :: pos_integer(),
    default :: pos_integer(),
    time :: pos_integer(),
    time_long :: pos_integer()
}).
