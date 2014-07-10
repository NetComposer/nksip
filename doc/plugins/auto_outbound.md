# Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_`


## Description


, at `Time` (in seconds) intervals. 

If the SipApp is configured to support outbound (RFC5626), there is a `reg_id` option in `Opts` with a numeric value, and also the remote party replies indicating it has outbound support, NkSIP will keep the _flow_ opened sending _keep-alive_ packets. If the flow goes down, NkSIP will try to re-send the registration at specific intervals.


## Dependant Plugins

None


## Configuration Values

### SipApp configuration values

Option|Default|Description
---|---|---


## API functions

### find/2

```erlang
```



## Callback functions

You can implement any of these callback functions in your SipApp callback module.

### sip_registrar_store/2

```erlang
```

## Examples

