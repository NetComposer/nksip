# Session Timers Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_timers`


## Description

This module provides full support for the SIP Session Timers extension, according to RFC4028. Once activated, the time before the dialog is timed out and destroyed is negotiated as described in the RFC.

`timer` will be added to all automatically generated _Supported_ headers.


## Dependant Plugins

None


## Configuration Values

### SipApp configuration values

Option|Default|Description
---|---|---
nksip_timers_se|1800 (secs)|Default value for the Session Timer
nksip_timers_min_se|90 (secs)|Minimum acceptable Session Timer (min 90, recomended 1800)


### Request generation values
The previous options can also be used in each _INVITE_ request sent calling [invite/2,3](../reference/sending_functions.md#invite)



## API functions

None


## Callback functions

None


## Examples

See [timer_test.erl](../../test/timer_test.erl) for examples