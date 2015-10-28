# NkSIP Services' API

This document describes the API that NkSIP makes available to Services.<br/>
Then SIP-specific functions are available in the [nksip.erl](../../src/nksip.erl) module, while other functions are available in the [nkservice_server](https://github.com/Nekso/nkservice/blob/master/src/nkservice_server.erl) module.<br/>
See [Starting a Service](../guide/start_a_service.md) for a general overview.


Function|Description
---|---
[start/2](#start4)|Starts a new Service
[stop/1](#stop1)|Stops a started Service
[stop_all/0](#stop_all/0)|Stops all started Services
[update/2](#update/2)|Updates the configuration of a started Service
[get_all/0](#get_all0)|Gets all currenty started Services
[get/2](#get2)|Gets a value for a Service variable
[get/3](#get3)|Gets a value for a Service variable, with a default
[put/3](#put3)|Saves a vaule for a Service variable
[del/2](#del2)|Deletes a Service variable
[get_srv_id/1](#get_srv_id1)|Finds the _internal name_ for a currently started Service
[call/2](#call2)|Synchronous call to the Service's gen_server process
[call/3](#call3)|Synchronous call to the Service's gen_server process with timeout
[cast/2](#call3)|Asynchronous call to the Service's gen_server process
[get_uuid/1](#get_uuid/1)|Get the current _UUID_ for a stared Service


## Functions list

### start/4
```erlang
nksip:start(nkservice:name(), 
	{ok, nksip:srv_id()} | {error, term()}.
```

Starts a new Service. 

See [Starting a Service](../guide/start_a_service.md) and [Configuration](../reference/configuration.md) to see the list of available configuration options. 

NkSIP returns the _internal name_ of the application. In most API calls you can use the _user name_ or the _internal name_.


### stop/1
```erlang
nksip:stop(Name::nksip:srv_name()|nksip:srv_id()) -> 
    ok | {error,term()}.
```
Stops a currently started Service.


### stop_all/0
```erlang
nksip:stop_all() -> 
   	ok.
```
Stops all currently started Services.


### update/2
```erlang
nksip:update(nksip:srv_name()|nksip:srv_id(), nksip:optslist()) ->
    {ok, nksip:srv_id()} | {error, term()}.
```
Updates the callback module or options of a running Service.

You can change any configuration parameter on the fly, except for transports. See [Configuration](../reference/configuration.md).


### get_all/0
```erlang
nksip:get_all() ->
    [{AppName::term(), AppId::nksip:srv_id()}].
```
Gets the user and internal ids of all started Services.


### get/2
```erlang
nkservice_server:get(nksip:srv_name()|nksip:srv_id(), term()) ->
    {ok, term()} | undefined | {error, term()}.
```
Gets a value from Service's store.
See [saving state information](../guide/start_a_service.md#saving-state-information).


### get/3
```erlang
nkservice_server:get(nksip:srv_name()|nksip:srv_id(), term(), term()) ->
    {ok, term()} | {error, term()}.
```
Gets a value from Service's store, using a default if not found.
See [saving state information](../guide/start_a_service.md#saving-state-information).

### put/3
```erlang
nkservice_server:put(nksip:srv_name()|nksip:srv_id(), term(), term()) ->
    ok | {error, term()}.
```
Inserts a value in Service's store.
See [saving state information](../guide/start_a_service.md#saving-state-information).

### del/2
```erlang
nkservice_server:del(nksip:srv_name()|nksip:srv_id(), term()) ->
    ok | {error, term()}.
```
Deletes a value from Service's store.
See [saving state information](../guide/start_a_service.md#saving-state-information).


### find_srv_id/1
```erlang
nkservice_server:get_srv_id(term()) ->
    {ok, srv_id()} | not_found.
```
Finds the _internal name_ of an existing Service.


### call/2
```erlang
nkservice_server:call(nksip:srv_name()|nksip:srv_id(), term()) ->
    term().
```
Synchronous call to the Service's gen_server process. It is a simple `gen_server:call/2` but allowing Service names.


### call/3
```erlang
nkservice_server:call(nksip:srv_name()|nksip:srv_id(), term(), pos_integer()|infinity) ->
    term().
```
Synchronous call to the Service's gen_server process. It is a simple `gen_server:call/3` but allowing Service names.


### cast/2
```erlang
nkservice_server:cast(nksip:srv_name()|nksip:srv_id(), term()) ->
    term().
```
Asynchronous call to the Service's gen_server process. It is a simple `gen_server:cast/2` but allowing Service names.


### get_uuid/1
```erlang
nksip:get_uuid(nksip:srv_name()|nksip:nksip:srv_id()) -> 
    {ok, binary()} | {error, term()}.
```
Gets the Service's _UUID_.

