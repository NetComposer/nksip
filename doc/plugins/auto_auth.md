# UAC Auto Authentication Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_uac_auto_auth`


## Description

This plugin provides the capability of, after receiving a 401 or 407 response, automatically retry the request using digest authentication. If, after a successful response, the next proxy or element sends another 401 or 407, a new authentication is added, up to the value configured in `nksip_uac_auto_auth_max_tries`.

You can configure the password to use with the [options](#configuration-values) `pass` or `passes`. When a 401 or 407 response is received, NkSIP finds a password for the _realm_ in the response. If none is found, the password with realm `<<>>` is used.



## Dependant Plugins

None


## Configuration Values

### Service configuration values

Option|Default|Description
---|---|---
sip_uac_auto_auth_max_tries|5|Number of times to attemp the request
sip_pass|-|Pass to use for digest authentication (see bellow)

You can use only one of `sip_pass` configuration option. Tt can have the form `Pass::binary()` or `{Realm::binary(), Pass::binary()}`, or a list of any of the previous types.

In case you don't want to use a clear-text function, you can use the function [nksip_auth:make_ha1/3](../../src/nksip_auth.erl) to get a hash of the password that can be used instead of the real password.



### Request sending values

The previous configuration options can also be used for a specific request when [sending a request](../reference/sending_functions.md).

If there is a `pass` or `passes` option in the global configuration values, the new values are added to the global ones.




## API functions

None


## Callback functions

None


## Examples


See [t13_auth.erl](../../test/tests/t13_auth.erl) for examples

