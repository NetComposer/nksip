# Requests API

This document describes the API NkSIP makes available to extract information from Requests.

Most functions in the API allows two ways to refer to the requests:
* From a full *request object* (`nksip:request()`). Most functions called in the SipApp's _callback module_ receive a full request object, and you can use these functions to get information from it.
* From a *request handle* (`nksip:id()`). You can get a request handle from a request object using [get_id/1](#get_id1). You can then use the handle to call most functions in this API. 
    
    In this case, the API function must contact with the corresponding call process to get the actual request, so you cannot use this method _inside_ the same call process (like in the callback functions). This method is useful to refer to the request from a _spawned_ process (specially for [reply/2](#reply2)), avoiding the need to copy the full object. Please notice that the request object may not exists any longer at the moment that the handle is used. Most functions return `error` in this case.


<br/>


Function|Description
---|---
[get_handle/1](#get_handle1)|Grabs a request's handle
[app_id/1](#app_id1)|Gets then SipApp's _internal name_
[app_name/1](#app_name1)|Gets the SipApp's _user name_
[method/1](#method1)|Gets the method of the request
[body/1](#body1)|Gets the body of the request
[call_id/1](#call_id1)|Gets the Call-ID header of the request
[meta/2](#meta2)|Gets specific metadata from the request
[header/2](#header2)|Gets the values for a header or headers in a request
[reply/2](#reply2)|Sends a reply to a request using a handle
[is_local_route/1](#is_local_route1)|Checks if this request would be sent to a local address in case of beeing proxied


## Functions List

### get_handle/1
```erlang
nksip_request:get_id(nksip:request()|nksip:id()) ->
    nksip:id().
```
Grabs a request's handle.


### app_id/1
```erlang
nksip_request:app_id(nksip:request()|nksip:id()) -> 
    nksip:app_id().
```
Gets then SipApp's _internal name_.


### app_name/1
```erlang
nksip_request:app_name(nksip:request()|nksip:id()) -> 
    term().
```
Gets the SipApp's _user name_


### method/1
```erlang
nksip_request:method(nksip:request()|nksip:id()) ->
    nksip:method() | error.
```
Gets the method of the request.


### body/1
```erlang
nksip_request:body(nksip:request()|nksip:id()) ->
    nksip:body() | error.
```
Gets the body of the request.


### call_id/1
```erlang
nksip_request:call_id(nksip:request()|nksip:id()) ->
    nksip:call_id().
```
Gets the Call-ID header of the request.


### meta/2
```erlang
nksip_request:meta(Meta::nksip_sipmsg:field()|[nksip_sipmsg:field()], nksip:request()|nksip:id()) ->
    term() | [{nksip_sipmsg:field(), term()}] | error.
```
Gets specific metadata from the request.

See [Metadata Fields](../reference/metadata.md) for a description of available fields.
If `Meta` is simple term, its value is returned. If it is a list, it will return a list of tuples, where the first element is the field name and the second is the value.


### header/2
```erlang
nksip_request:header(Name::string()|binary()|[string()|binary()], nksip:request()|nksip:id()) -> 
    [binary()] | [{binary(), binary()}] | error.
```
Gets the values for a header or headers in a request.

If `Name` is a single value, a list is returned with the values of all the headers having that name. If it is a list, a list of tuples is returned, where the first element is the header name and the second is the list of values.

NkSIP uses only lowercase for header names.


### reply/2
```erlang
nksip_request:reply(nksip:sipreply(), nksip:id()) -> 
    ok | {error, Error}
    when Error :: invalid_call | invalid_request | nksip_call_router:sync_error().
```
Sends a reply to a request using a handle.

See [Receiving Requests](../guide/receiving_requests.md) for a overall description and [Reply Options](../reference/reply_options.md) for a description of available responses.


### is_local_route/1
```erlang
nksip_request:is_local_route(nksip:request()) -> 
    boolean().
```
Checks if this request would be sent to a local address in case of beeing proxied.

It will return `true` if the first _Route_ header points to a local address or, if there are no Route header, the _Request-Uri_ points to a local address.

