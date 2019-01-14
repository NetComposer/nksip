# UAC Auto Outbound Registration Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_uac_auto_outbound`


## Description

This plugin allows a Service to program a serie of automatic registrations (sending REGISTER request) to a remote registrar, using SIP Outbound (RFC5626).

Once a REGISTER to a remote registrar is successful, NkSIP will keep the flow opened sending refreshes over the connection as described in the outbound specification. If the flow fails, a new REGISTER will be send automatically to reopen it (after a specific time described in the specification).


## Dependant Plugins

* [nksip_uac_auto_register](auto_register.md)
* [nksip_outbound](outbound.md)


## Configuration Values

### Service configuration values

Option|Default|Description
---|---|---
sip_uac_auto_outbound_all_fail|30|Basetime to use then all connections have failed
sip_uac_auto_outbound_any_ok|90|Basetime to use when some, but not all, connections have failed
sip_uac_auto_outbound_max_time|1800|Maximum time for outbound
sip_uac_auto_outbound_default_udp_ttl|25|UDP connection default TTL
sip_uac_auto_outbound_default_tcp_ttl|120|TCP connection default TTL


## API functions

### start_register/4

```erlang
start_register(nksip:srv_id(), Id::term(), Uri::nksip:user_uri(), list()) ->
    {ok, boolean()} | {error, term()}.
```

Similar to [nksip_uac_auto_register:start_register/4](auto_register.md#start_register4), but using the outbound algorithm as described above.


### stop_register/2

```erlang
stop_register(nksip:srv_id(), Id::term()) ->
    ok | not_found.
```

Stops a previously started registration series.


### get_registers/1

```erlang
get_registers(nksip:srv_id()) ->
    [{Id::term(), OK::boolean(), Time::non_neg_integer(), Fails::non_neg_integer}].
```
Get current registration status, including if last registration was successful, the time remaining to next one and the number of current outbound fails.
 


## Examples

See [t21_outbound.erl](../../test/tests/t21_outbound.erl) for examples



