# SIP Trace Plugin

* [Name](#name)
* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Name
### `nksip_trace`


## Description

This plugin allows to trace sent and received SIP messages to console or disk. 
You can start tracing any specific Service, and for any IP or a specific set of IPs.

See the `nksip_trace` option [bellow](#configuration-values).



## Dependant Plugins

None


## Configuration Values

### Service configuration values

Option|Default|Description
---|---|---
sip_trace|false|Configures tracing for this Service (see bellow)
sip_trace_file|-|File path to trace to
sip_trace_ips|-|Ips to focus on

Ips can be an IP (like `"10.0.0.1"`), list of IPs (like `["10.0.0.1", "10.0.0.2"]`) or a regular expression or list of regular expressions (like `["10.0.0.1", "^11.*"]`)

Tracing will be much faster if you don't use IP filtering.


## API functions


### start/1
```erlang
start(nksip:srv_id()) ->
    ok | {error, term()}.
```

Equivalent to `start(SrvId, console, all)`.


### start/2
```erlang
start(nksip:srv_id(), File::file()) ->
    ok | {error, term()}.
```

Equivalent to `start(SrvId, File, all)` for a started Service.


### start/3
```erlang
start(nksip:srv_id(), file(), ip_list()) ->
    ok | {error, term()}.
```

Configures a Service to start tracing SIP messages.


### stop/1
```erlang
stop(nksip:srv_id()) ->
    ok | {error, term()}.
```

Stop tracing in a specific Service, closing trace file if it is opened.


### print/1
```erlang
print(Msg::nksip:request()|nksip:response()) ->
 ok.
```

Pretty-print a `nksip:request()` or `nksip:response()`.


### print/2
```erlang
print(Tag::string()|binary(), Msg::nksip:request()|nksip:response()) ->
    ok.
```

Pretty-print a `nksip:request()` or `nksip:response()` with a Tag.

