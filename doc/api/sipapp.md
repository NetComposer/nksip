# NkSIP SipApps' API

This document describes the API that NkSIP makes available to SipApps.<br/>
These functions are available in the [nksip.erl](../../src/nksip.erl) module.<br/>
See [Starting a SipApp](../guide/start_a_sipapp.md) for a general overview.


Function|Description
---|---
[start/4](#nksipstart4)|Starts a new SipApp
[stop/1](#nksipstop1)|Stops a started SipApp
[stop_all/0](#nksipstop_all/0)|Stops all started SipApps
[update/2](#nksipupdate/2)|Updates the configuration of a started SipApp
[get_all/0](#nksipget_all0)|Gets all currenty started SipApps
[get/2](#nksipget2)|Gets a value for a SipApp variable
[get/3](#nksipget3)|Gets a value for a SipApp variable, with a default
[put/3](#nksipput3)|Saves a vaule for a SipApp variable
[del/2](#nksipdel2)|Deletes a SipApp variable
[get_pid/1](#nksipget_pid1)|Gets the pid of a SipApp's gen_server process
[find_app/1](#nksipfind_app1)|Finds the _internal name_ for a currently started SipApp
[call/2](#nksipcall2)|Synchronous call to the SipApp's gen_server process
[call/3](#nksipcall3)|Synchronous call to the SipApp's gen_server process with timeout
[cast/2](#nksipcall3)|Asynchronous call to the SipApp's gen_server process
[get_uuid/1](#get_uuid/1)|Get the current _UUID_ for a stared SipApp
[get_gruu_pub/1](#get_gruu_pub1)|The the current public _GRUU_ of a SipApp, if one has been received.
[get_gruu_temp/1](#get_gruu_temp1)|The the current temporary _GRUU_ of a SipApp, if one has been received.


## Functions list

### nksip:start/4
```erlang
-spec start(UserName::nksip:app_name(), CallbackModule::atom(), Args::term(), Opts::nksip:optslist()) -> 
	{ok, nksip:app_id()} | {error, term()}.
```

Starts a new SipApp. 

See [Starting a SipApp](../guide/start_a_sipapp.md) and [Configurarion](../reference/configuration.md) to see the list of available configuration options. 

NkSIP returns the _internal name_ of the application. In most API calls you can use the _user name_ or the _internal name_.


### nksip:stop/1
```erlang
-spec stop(Name::nksip:app_name()|nksip:app_id()) -> 
    ok | {error,term()}.
```
Stops a currently started SipApp.


### nksip:stop_all/0
```erlang
-spec stop_all() -> 
   	ok.
```
Stops all currently started SipApps.


### nksip:update/2
```erlang
-spec update(nksip:app_name()|nksip:app_id(), nksip:optslist()) ->
    {ok, nksip:app_id()} | {error, term()}.
```
Updates the callback module or options of a running SipApp. It is not allowed to change transports.


### nksip:get_all/0
```erlang
-spec get_all() ->
    [{AppName::term(), AppId::nksip:app_id()}].
```
Gets the user and internal ids of all started SipApps.


### nksip:get/2
```erlang
-spec get(nksip:app_name()|nksip:app_id(), term()) ->
    {ok, term()} | undefined | {error, term()}.
```
Gets a value from SipApp's store.


### nksip:get/3
```erlang
-spec get(nksip:app_name()|nksip:app_id(), term(), term()) ->
    {ok, term()} | {error, term()}.
```
Gets a value from SipApp's store, using a default if not found.


### nksip:put/3
```erlang
-spec put(nksip:app_name()|nksip:app_id(), term(), term()) ->
    ok | {error, term()}.
```
Inserts a value in SipApp's store.


### nksip:del/2
```erlang
-spec del(nksip:app_name()|nksip:app_id(), term()) ->
    ok | {error, term()}.
```
Deletes a value from SipApp's store.


### nksip:get_pid/1
```erlang
-spec get_pid(nksip:app_name()|app_id()) -> 
    pid() | undefined.
```
Gets the SipApp's _gen_server process_ `pid()`.


### nksip:find_app/1
```erlang
-spec find_app(term()) ->
    {ok, app_id()} | not_found.
```
Finds the _internal name_ of an existing SipApp.


### nksip:call/2
```erlang
-spec call(nksip:app_name()|nksip:app_id(), term()) ->
    term().
```
Synchronous call to the SipApp's gen_server process. It is a simple `gen_server:call/2` but allowing SipApp names.


### nksip:call/3
```erlang
-spec call(nksip:app_name()|nksip:app_id(), term(), pos_integer()|infinity) ->
    term().
```
Synchronous call to the SipApp's gen_server process. It is a simple `gen_server:call/3` but allowing SipApp names.


```erlang
-spec cast(nksip:app_name()|nksip:app_id(), term()) ->
    term().
```
Asynchronous call to the SipApp's gen_server process. It is a simple `gen_server:cast/2` but allowing SipApp names.


### nksip:get_uuid/1
```erlang
-spec get_uuid(nksip:app_name()|nksip:nksip:app_id()) -> 
    {ok, binary()} | {error, term()}.
```
Gets the SipApp's _UUID_.


### nksip:get_gruu_pub/1
```erlang
-spec get_gruu_pub(nksip:app_name()|nksip:nksip:app_id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.
```
Gets the last detected public _GRUU_.


### nksip:get_gruu_temp/1
```erlang
-spec get_gruu_temp(nksip:app_name()|nksip:nksip:app_id()) ->
    {ok, nksip:uri()} | undefined | {error, term()}.
```
Gets the last detected temporary _GRUU_.


