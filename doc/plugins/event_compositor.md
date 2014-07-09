# Registrar Server Plugin

* [Description](#description)
* [Dependant Plugins](#dependant-plugins)
* [Configuration Values](#configuration-values)
* [API Functions](#api-functions)
* [Callback Functions](#callback-functions)
* [Examples](#examples)


## Description

This plugin provides full support to implement an Event State Compositor, according to RFC3903. It used by default the built-in RAM-only store, but can be configured to use any other database implementing callback [sip_publish_store/2](#sip_publish_store2).

## Dependant Plugins

None


## Configuration Values

### SipApp configuration values

Option|Default|Description
---|---|---
nksip_event_compositor_default_expires|60 (secs)|Default expiration for stored events

## API functions

### find/3

```erlang
-spec find(App::nksip:app_id()|term(), AOR::nksip:aor(), Tag::binary()) ->
    {ok, #reg_publish{}} | not_found | {error, term()}.
```

Finds a stored published information


### request/1
```erlang
-spec request(nksip:request()) ->
    nksip:sipreply().
```

Call this function to process and incoming _PUBLISH_ request. It returns an appropiate response, depending on the registration result.

For example, you could implement the following [sip_publish/2](../reference/callback_functions.md#sip_publish2) callback function:

```erlang
sip_publish(Req, _Call) ->
	case nksip_request:meta(domain, Req) of
		<<"nksip">> -> {reply, nksip_event_compositor:process(Req)};
		_ -> {reply, forbidden}
	end.
```

* If No _Sip-If-Match_ header is found
  * If we have a body, the server will generate a Tag, and store the boy under this AOR and Tag.
  * If we have no body, the request fails
* If _Sip-If-Match_ header is found 
  * We alredy had a body stored with this Tag, and Expires=0, it is deleted
  * If Expires>0, and we have no body, the content is refreshed
  * If Expires>0, and we have a body, the content is updated
  * If we had no body stored, the request fails


### clear/1

```erlang
-spec clear(nksip:app_name()|nksip:app_id()) -> 
    ok | callback_error | sipapp_not_found.
```

Clear all stored records by a SipApp's




## Callback functions

You can implement any of these callback functions in your SipApp callback module.

### sip_event_compositor_store/2

```erlang
% @doc Called when a operation database must be done on the compositor database.
%% This default implementation uses the built-in memory database.
-spec sip_event_compositor_store(StoreOp, AppId) ->
    [RegPublish] | ok | not_found when
        StoreOp :: {get, AOR, Tag} | {put, AOR, Tag, RegPublish, TTL} | 
                   {del, AOR, Tag} | del_all,
        AppId :: nksip:app_id(),
        AOR :: nksip:aor(),
        Tag :: binary(),
        RegPublish :: nksip_event_compositor:reg_publish(),
        TTL :: integer().
```

Implement this callback function in your callback function to use a different store thant then defaut RAM-only storage.
See the [default implementation](../../plugins/nksip_event_compositor/src/nksip_event_compositor_sipapp.erl) as a basis. 


## Examples

