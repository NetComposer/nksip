# NkSIP SipApps' API

This document describes the API that NkSIP makes available to SipApps. These functions are available in the [nksip.erl](../../src/nksip.erl) module.


Function|Description
---|---
[start/4](#start4)|Starts a new SipApp
[stop/1](#stop1)|Stops a started SipApp
[stop_all/0](#stop_all/0)|Stops all started SipApps
[update/2](#update/2)|Updates the configuration of a started SipApp
[get_all/0](#get_all0)|Gets all currenty started SipApps
[get/2](#get2)|Gets a value for a SipApp variable
[get/3](#get3)|Gets a value for a SipApp variable, with a default
[put/3](#put3)|Saves a vaule for a SipApp variable
[del/2](#del2)|Deletes a SipApp variable
[get_pid/1](#get_pid1)|Gets the pid of a SipApp's gen_server process
[find_app/1](#find_app1)|Finds the _internal name_ for a currently started SipApp
[get_uuid/1](#get_uuid/1)|Get the current _UUID_ for a stared SipApp
[get_gruu_pub/1](#get_gruu_pub1)|The the current public _GRUU_ of a SipApp, if one has been received.
[get_gruu_temp/1](#get_gruu_temp1)|The the current temporary _GRUU_ of a SipApp, if one has been received.


## Functions list

### start/4
```erlang
-spec start(UserName::term(), CallbackModule::atom(), Args::term(), Opts::nksip_lib:optslist()) -> 
	{ok, app_id()} | {error, term()}.
```

Starts a new SipApp. 

See [Starting a SipApp](../guide/start_a_sipapp.md) and [Configurarion](../reference/configuration.md) to see the list of available configuration options. 

NkSIP returns the _internal name_ of the application. In most API calls you can use the _user name_ or the _internal name_.


### stop/1
```erlang
-spec stop(Name::term()|app_id()) -> 
    ok | error.
```
Stops a currently started SipApp.


### stop_all/0
```erlang
-spec stop_all() -> 
   	ok.
```
Stops all currently started SipApps.


### update/2
```erlang
-spec update(term()|app_id(), nksip_lib:optslist()) ->
    {ok, app_id()} | {error, term()}.
```
Updates the callback module or options of a running SipApp. It is not allowed to change transports.


### get_all/0
```erlang
-spec get_all() ->
    [{AppName::term(), AppId::app_id()}].
```
Gets the user and internal ids of all started SipApps.


### get/2
```erlang
-spec get(term()|nksip:app_id(), term()) ->
    {ok, term()} | not_found | error.
```
Gets a value from SipApp's store.


### get/3
```erlang
-spec get(term()|nksip:app_id(), term(), term()) ->
    {ok, term()} | error.
```
Gets a value from SipApp's store, using a default if not found.


### put/3
```erlang
-spec put(term()|nksip:app_id(), term(), term()) ->
    ok | error.
```
Inserts a value in SipApp's store.


### del/2
```erlang
-spec del(term()|nksip:app_id(), term()) ->
    ok | error.
```
Deletes a value from SipApp's store.


### get_pid/1
```erlang
-spec get_pid(term()|app_id()) -> 
    pid() | not_found.
```
Gets the SipApp's _gen_server process_ `pid()`.


### find_app/1
```erlang
-spec find_app(term()) ->
    {ok, app_id()} | not_found.
```
Finds the _internal name_ of an existing SipApp.


### get_uuid/1
```erlang
-spec get_uuid(term()|nksip:app_id()) -> 
    {ok, binary()} | error.
```
Gets the SipApp's _UUID_.


### get_gruu_pub/1
```erlang
-spec get_gruu_pub(term()|nksip:app_id()) ->
    undefined | nksip:uri() | error.
```
Gets the last detected public _GRUU_.


### get_gruu_temp/1
```erlang
-spec get_gruu_temp(term()|nksip:app_id()) ->
    undefined | nksip:uri() | error.
```
Gets the last detected temporary _GRUU_.


