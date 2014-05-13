# Requests API

Function|Description
---|---
[get_handle/1](#)|Grabs a request's handle
[app_id/1](#)|Gets then SipApp's _internal name_
[app_name/1](#)|Gets the SipApp's _user name_
[method/1](#)|Gets the method of the request
[body/1](#)|Gets the body of the request
[call_id/1](#)|Gets the Call-ID header of the request
[meta/2](#)|Gets specific metadata from the request
[header/2](#)|Gets the values for a header or headers in a request
[reply/2](#)|Sends a reply to a request using a handle
[is_local_route/1](#)|Checks if this request would be sent to a local address in case of beeing proxied


## Functions List

### nksip_request:get_handle/1
```erlang
-spec get_id(nksip:request()|nksip:id()) ->
    nksip:id().
```
Grabs a request's handle.


### nksip_request:app_id/1
```erlang
-spec app_id(nksip:request()|nksip:id()) -> 
    nksip:app_id().
```
Gets then SipApp's _internal name_.


### nksip_request:app_name/1
```erlang
-spec app_name(nksip:request()|nksip:id()) -> 
    term().
```
Gets the SipApp's _user name_


### nksip_request:method/1
```erlang
-spec method(nksip:request()|nksip:id()) ->
    nksip:method() | error.
```
Gets the method of the request.


### nksip_request:body/1
```erlang
-spec body(nksip:request()|nksip:id()) ->
    nksip:body() | error.
```
Gets the body of the request.


### nksip_request:call_id/1
```erlang
-spec call_id(nksip:request()|nksip:id()) ->
    nksip:call_id().
```
Gets the Call-ID header of the request.


### nksip_request:meta/2
```erlang
-spec meta(Meta::nksip_sipmsg:field()|[nksip_sipmsg:field()], nksip:request()|nksip:id()) ->
    term() | [{nksip_sipmsg:field(), term()}] | error.
```
Gets specific metadata from the request.

See [Metadata Fields](../reference/metatada.md) for a description of available fields.
If `Meta` is simple term, its value is returned. If it is a list, it will return a list of tuples, where the first element is the field name and the second is the value.


### nksip_request:header/2
```erlang
-spec header(Name::string()|binary()|[string()|binary()], nksip:request()|nksip:id()) -> 
    [binary()] | [{binary(), binary()}] | error.
```
Gets the values for a header or headers in a request.

If `Name` is a single value, a list is returned with the values of all the headers having that name. If it is a list, a list of tuples is returned, where the first element is the header name and the second is the list of values.

NkSIP uses only lowercase for header names.


### nksip_request:reply/2
```erlang
-spec reply(nksip:sipreply(), nksip:id()) -> 
    ok | {error, Error}
    when Error :: invalid_call | invalid_request | nksip_call_router:sync_error().
```
Sends a reply to a request using a handle.

See [Receiving Requests](../guide/receiving_requests.md) for a overall description and [Reply Options](../reference/reply_options) for a description of available responses.


### nksip_request:is_local_route/1
```erlang
-spec is_local_route(nksip:request()) -> 
    boolean().
```
Checks if this request would be sent to a local address in case of beeing proxied.

It will return `true` if the first _Route_ header points to a local address or, if there are no Route header, the _Request-Uri_ points to a local address.

