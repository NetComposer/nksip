# Sending Options

You can use a number of options when [sending requests](../guide/sending_requests.md) using the functions is [nksip_uac.erl](../../src/nksip_uac.erl):

* [Common Options](#common-options)
* [Out of Dialog Options](#out-of-dialog-options)
* [Proxy Options](#proxy-options)


## Common Options
All header names should be lowercase.

Option|Types|Description|Commment
---|---|---|---|
ignore|-|Ignore this option|
{add, Name, Value}|Name::`nksip:name()`, Value::`nksip:value()`|Adds a new header, after any previous one with the same name|
{add, {Name, Value}}|(same as before)|Same as before|
{replace, Name, Value}|(same as before)|Adds a new header, replacing any previous one|
{replace, {Name, Value}}|(same as before)|Same as before|
{insert, Name, Value}|(same as before)|Inserts a new header, before any previous one with the same name|
{insert, {Name, Value}}|(same as before)|Same as before|
{from, From}|From::`string()`&#124;`binary()`&#124;`nksip:uri()`|Same as {replace, "from", From}|Do not use in in-dialog requests
{to, From}|To::`string()`&#124;`binary()`&#124;`nksip:uri()`|Same as {replace, "to", From}|Do not use in in-dialog requests
{call_id, CallId}|CallId::`binary()`|Same as {replace, "call-id", Call-ID}|Do not use in in-dialog requests
{content_type, ContentType}|ContentType::`string()`&#124;`binary()`&#124;`nksip:token()`|Same as {replace, "content-type", ContentType}
{require, Require}|Require::`string()`&#124;`binary()|Same as {replace, "require", Require}|
{supported, Supported}|Supported::`string()`&#124;`binary()`|Same as {replace, "supported", Supported}
{expires, Expires}|Expires::`string()`&#124;`binary()`&#124;`integer()`|Same as {replace, "expires", Expires}
{contact, Contact}|Contact::`string()`&#124;`binary()`&#124;`nksip:uri()`&#124;`[nksip:uri()]`|Same as {replace, "contact", Contact}
{route, Route}|Route::`string()`&#124;`binary()`&#124;`nksip:uri()`&#124;`[nksip:uri()]`|Same as {replace, "route", Route}
{reason, Reason}|Reason::`string()`&#124;`binary()`|Same as {replace, "reason", Reason}|
{event, Reason}|Event::`string()`&#124;`binary()`&#124;`nksip:token()`|Same as {replace, "event", Event}|
to_as_from|-|Replace To header with current From value|Useful for REGISTER requests
{body, Body}|Body::`nksip:body()`|Sets the request body|
{cseq_num, CSeq}|CSeq::`integer()`|Sets the numeric part of the CSeq header|Do not use in in-dialog requests
contact|-|Automatically generates a Contact header, if none is already present|Use it in dialog generaing requests as INVITE
record_route|-|Automatically generates a Record-Route header, if none is already present|Used in proxies to force new in-dialog requests to pass through this proxy
path|-|Automatically generates a Path header, if none is already present|Used in proxies to force new registrations to go through this proxy
get_request|-|If present, and the callback function is present, if will be called when the request has been sent as `{req, Request, Call}`|You can use the functions in [the API](api.md) to extract relevant information from the request
no_dialog|-|Do not process dialogs for this request|
no_auto_expire|-|Do not generate automatic CANCEL for expired INVITE requests|
auto_2xx_ack|-|Generates and sends an ACK automatically after a successful INVITE response|
{pass, Pass}|Pass::`binary()`&#124;`{Realm, binary()}`&#124;`[binary()`&#124;`{Realm, binary()}`, Realm::`binary()`|Passwords to use when a 401 or 407 response is received to generate an automatic new request|Firt matching Realms are used, then passwords without realm
meta|`[nksip_sipmsg:field()]`|Use it to select [which specific fields](metadata.md) from the response shall be returned. 
async|||If present, the call will return inmediatly as `{async, ReqId}`, or `{error, Error}` if an error is produced before sending the request. `ReqId` can be used with the functions in [the API](api.md) to get information about the request (the request may not be sent yet, so the information about transport may not be present)
callback|`fun/1`|If defined, it will be called for every received provisional response as `{reply, Code, Resp, Call}`. For `async` requests, it is called also for the final response and, if an error is produced before sending the request, as `{error, Error}`
{local_host, LocalHost}|LocalHost::`auto`&#124;`string()`&#124;`binary()`|Host or IP to use when auto generating headers like Contact or Record-Route.
{local_host6, LocalHost}|LocalHost::`auto`&#124;`string()`&#124;`binary()`|Host or IP to use when auto generating headers like Contact or Record-Route using IPv6
prack_callback|`fun/2`|If present, it will be called ?|
{reg_id, RegId}|RegId::`integer()`|`reg-id` field to use in REGISTER requests|For Outbound support
{refer_subscription_id, Refer}|Refer::`nksip:id()`|If present, ...
user_agent|-|Automatically generates a User-Agent header, replacing any previous value
supported|-|Automatically generates a Supported header, replacing any previous value
allow|-|Automatically generates an Allow header, replacing any previous value
accept|-|Automatically generates an Accept header, replacing any previous value
accept|-|Automatically generates an Date header, replacing any previous value
allow_event|-|Automatically generates an Allow-Event header, replacing any previous value
{min_se, SE}|SE::`integer()`|Includes a Min-SE header in the request|Used for Session Timers
{session_expires, SE}|SE::`integer()`&#124;`{integer(), uac}`&#124;`{integer(), uas}`|Includes a Session-Expires header in the request|Used for Session Timers
{subscription_state, ST}|ST::`{active, Expires}`&#124;`{pending, Expires}`&#124;`{terminated, Reason}`&#124;`{terminated, Reason, Retry}`, Expires::`undefined&#124;integer()`, Reason::`undefined`&#124;`atom()`|Generates a Subscription-State header
{sip_etag, ETag}|ETag::`string()`&#124;`binary()`|Includes a Sip-ETag header in the request


no_100|-|Do not generate 100 responses


Key|Type|Default|Description




&#124;



## Out of Dialog Options
Options available for most methods only when sent outside any dialog are:

Key|Type|Default|Description
---|---|---|---
from|`user_uri()`||Overrides SipApp config
to|`user_uri()`||_To_ header to use in the request
call_id|`call_id()`|(automatic)|If defined, will be used instead of a newly generated one (use `nksip_lib:luid/0`)
cseq|`nksip:cseq()`|(automatic)|If defined, will be used instead of a newly generated one (use `nksip_lib:cseq/0`)
route|`nksip:user_uri()`||Overrides SipApp config


## Proxy Options
