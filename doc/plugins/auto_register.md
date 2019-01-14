# UAC Auto Registration Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_uac_auto_register`


## Description

This plugin allows a Service to program a serie of automatic registrations (sending REGISTER request) to a remote registrar, or automatic pings (sending OPTIONS requests) to any other SIP entity.


## Dependant Plugins

None


## Configuration Values

### Service configuration values

Option|Default|Description
---|---|---
nksip_uac_auto_register_timer|5 (secs)|Interval to check for new expired timers


## API functions

### start_register/4 

```erlang
start_register(nksip:srv_id(), Id::term(), Uri::nksip:user_uri(), list()) ->
    {ok, boolean()} | {error, term()}.
```

Programs the Service to start a serie of automatic registrations to the registrar at `Uri`. `Id` indentifies this request to be be able to stop it later. Use [get_registers/1](#get_registers1) or the  callback function [sip_uac_auto_register_updated_register/3](#sip_uac_auto_register_updated_register3) to know about the registration status.

Opts are passed to the REGISTER sending functions. You can use the `expires` option to change the default re-register time from the default of 300 secs.


### stop_register/2

```erlang
stop_register(nksip:srv_id(), Id::term()) ->
    ok | not_found.
```

Stops a previously started registration serie.


### get_registers/1

```erlang
get_registers(nksip:srv_id()) ->
    [{Id::term(), OK::boolean(), Time::non_neg_integer()}].
```
Get current registration status, including if last registration was successful and time remaining to next one.
 

### start_ping/4

```erlang
start_ping(nksip:srv_id(), Id::term(), Uri::nksip:user_uri(), list()) ->
    {ok, boolean()} | {error, term()}.
```

Programs the Service to start a serie of _pings_ (OPTION requests) to the SIP element at `Uri`. `Id` indentifies this request to be able to stop it later. Use [get_pings/1](#get_pings1) or the callback function [sip_uac_auto_register_updated_ping/3](#sip_uac_auto_register_updated_ping3) to know about the ping status.

You can use the `expires` option to change the default re-options time from the default of 300 secs.



### stop_ping/2

```erlang
stop_ping(nksip:srv_id(), Id::term()) ->
    ok | not_found.
```

Stops a previously started ping serie.


### get_pings/1

```erlang
get_pings(nksip:srv_id()) ->
    [{Id::term(), OK::boolean(), Time::non_neg_integer()}].
```

Get current ping status, including if last ping was successful and time remaining to next one.
 


## Callback functions

You can implement any of these callback functions in your Service callback module.



### sip_uac_auto_register_updated_register/3

```erlang
sip_uac_auto_register_updated_register(Id::term(), OK::boolean(), nksip:srv_id()) ->
    ok.
```

If implemented, it will called each time a registration serie changes its state.


### sip_uac_auto_register_updated_ping/3

```erlang
sip_uac_auto_register_updated_ping(Id::term(), OK::boolean(), 
                                         AppId::nksip:srv_id()) ->
    ok.
```

If implemented, it will called each time a ping series changes its state.

## Examples

See [t04_uas.erl](../../test/tests/t04_uas.erl) for examples
