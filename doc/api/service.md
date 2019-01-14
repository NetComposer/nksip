# NkSIP Services' API

It is imporant to note that starting an nksip service, is really starting
a nkserver service!  An nkserver is a generic service that can be many different
things, including in this case, a SIP service.

Much of the functionality of the nksip module is done via nkserver.  There are
helper or convinience functions here, that really just call nkserver functions.

NkSIP can be used as a stand-alone product or with other services available via nkserver.


This document describes the API that NkSIP makes available to Services.<br/>
The SIP-specific functions are available in the [nksip.erl](../../src/nksip.erl) module, while other functions are available in the [nkserver](https://github.com/NetComposer/nkserver/blob/master/src/nkserver.erl) module.<br/>

***See Also:***
* [Starting a Service](../guide/start_a_service.md) for a general overview.
* [Tutorial](../guide/tutorial.md) For more examples of start and other options
* [Configuration Options](../reference/configuration.md) for a list of available configuration options. 
* [Source Code](../../src/nksip.erl) 


Function|Description
---|---
[start_link/2](#start_link2)|Starts a new Service
[stop/1](#stop1)|Stops a started Service
[get_sup_spec72](#get_sup_spec2)|Gets the service as a supervidor's child
[update/2](#update2)|Updates the configuration of a started Service


## Functions list


### start_link/2
----
Starts a new Service. 

NkSIP returns the _pid()_ of the service supervisor.

```erlang
-spec start(ServiceId, Opts) -> Result when
            ServiceId :: nksip:id(),
            Opts :: nksip:config(),
            Result :: {ok, pid()}  {error, term()}.
```

***Example(s):***

```erlang
nksip:start(test_server_1, #{
        sip_local_host => "localhost",
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }).
{ok, <...>}
```


***See Also:***
* [Tutorial](../guide/tutorial.md) For more examples of start and other options
* [Starting a Service](../guide/start_a_service.md)
* [Configuration Options](../reference/configuration.md) for a list of available configuration options. 

***Note:***
> The provided name of the service will be registered as an Erlang process.


### get_sup_spec/2
----
Gets an OTP supervisor child specification, to be included in your own application supervisor tree.

```erlang
-spec get_sup_spec(ServiceId, Opts) -> Result when
            ServiceId :: nksip:id(),
            Opts :: nksip:config(),
            Result :: {ok, supervisor:child_spec()}  {error, term()}.
```



### stop/1
----
Stops a currently started Service.

```erlang
-spec stop(ServiceId) -> Result when
        ServiceId :: nksip:id(),
        Result :: ok |  {error, not_running}.
```



### update/2
----
Updates the current configuration for a service, on the fly.

You can change any configuration parameter on the fly, even for transports. See [Configuration Options](../reference/configuration.md) for a list of available configuration options. 

See [Configuration](../reference/configuration.md).

```erlang
-spec update(ServiceId, Opts) -> Result when
            ServiceId :: nksip:id(),
            Opts :: nksip:config(),
            Result :: ok | {error, term()}.
```
