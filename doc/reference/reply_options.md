# Reply Options

Many of the SipApp's [callback functions](callback_functions.md) allows you to send a response back for the received request. Currently the following replies are recognized:

Response|Code|Comments
---|---|---
Code|Code|
{Code, Opts}|Code|See [options](#options)
ringing|180|
rel_ringing|180|_Reliable responses_ will be used
{rel_ringing, Body}|180|_Reliable responses_ will be used, send a body
session_progress|183|
rel_session_progress|183|_Reliable responses_ will be used
{rel_session_progress, Body}|183|_Reliable responses_ will be used, send a body
ok|200|
{ok, Opts}|200|See [options](#options)
{answer, Body}|200|Send a body
accepted|202|
{redirect, [Contact]}|300|Generates _Contact_ headers
{redirect_permanent, Contact}|301|Generates a _Contact_ header
{redirect_temporary, Contact}|302|Generates a _Contact_ header
invalid_request|400|
{invalid_request, Phrase}|400|Use custom SIP phrase
authenticate|401|Generates a new _WWW-Authenticate_ header, using current _From_ domain as `realm`
{authenticate, Realm}|401|Generates a valid new _WWW-Authenticate header_, using `Realm`
forbidden|403|
{forbidden, Text}|403|Use custom SIP phrase
not_found|404|
{not_found, Text}|404|Use custom SIP phrase
{method_not_allowed, Allow}|405|Generates an _Allow_ header
proxy_authenticate|407|Generates a valid new _Proxy-Authenticate header_, using current _From_ domain as `Realm`
{proxy_authenticate, Realm}|407|Generates a valid new _Proxy-Authenticate header_, using `Realm`
timeout|408|
{timeout, Text}|408|Use custom SIP phrase
conditional_request_failed|412|
request_too_large|413|
{unsupported_media_type, Accept}|415|Generates a new _Accept_ header
{unsupported_media_encoding, AcceptEncoding}|415|Generates a new _Accept-Encoding_ header
unsupported_uri_scheme|416|
{bad_extension, Unsupported}|420|Generates a new _Unsupported_ header
{extension_required, Require}|421|Generates a new _Require_ header
{interval_too_brief, MinExpires}|423|Generates a new _Min-Expires_
flow_failed|430|
first_hop_lacks_outbound|439|
temporarily_unavailable|480|
no_transaction|481|
unknown_dialog|481|
loop_detected|482|
too_many_hops|483|
ambiguous|485|
busy|486|
request_terminated|487|
{not_acceptable, Warning}|488|Generates a new _Warning_ header
bad_event|489|
request_pending|491|
internal_error|500|
{internal_error, Text}|500|Use custom SIP phrase
busy_eveywhere|600|
decline|603|

## Options

Some previous replies allow including options. The recognized options are:

Name|Description
---|---
{add, Name, Value}|Adds a new header to the response, after all existing ones
{add, {Name, Value}}|Adds a new header to the response, after all existing ones
{replace, Name, Value}|Replaces any existing header with this new value
{replace, {Name, Value}}|Replaces any existing header with this new value
{insert, Name, Value}|Inserts a new header to the response, before any existing ones
{insert, {Name, Value}}|Inserts a new header to the response, before any existing ones
{from, From}|Replaces _From_ header
{to, To}|Replaces _To_ header
{content_type, ContentType}|Replaces _Content-Type_ value
{require, Require}|Replaces _Require_ header
{supported, Supported}|Replaces _Supported_ header
{expires, Expires}|Replaces _Expires_ header
{contact, Contact}|Replaces any _Contact_ header
{route, Route}|Replaces any _Route_ header
{reason, Reason}|Replaces _Reason_ header
{event, Event}|Replaces _Event_ header
{reason_phrase, Phrase}|Uses a custom reason phrase in the SIP response
timestamp|If the request has a _Timestamp_ header it is copied to the response
do100rel|Activates reliable provisional responses, if supported
{body, Body}|Adds a body to the response
contact|Generates an automatic _Contact_ header
no_dialog|Skips dialog processing
{local_host, Host}|Overrides SipApp configuration for this response
{local_host6, Host}|Overrides SipApp configuration for this response
user_agent|Generates an automatic _User-Agent_ header
supported|Generates an automatic _Supported_ header
allow|Generates an automatic _Allow_ header
accept|Generates an automatic _Accept_ header
date|Generates an automatic _Date_ header
allow_event|Generates an automatic _Allow-Event_ header
www_authenticate|Generates an automatic _WWW-Authenticate_ header, using _From_ as `realm`
{www_authenticate, Realm}|Generates an automatic _WWW-Authenticate_ header, using `Realm`
proxy_authenticate|Generates an automatic _Proxy-Authenticate_ header, using _From_ as `realm`
{proxy_authenticate, Realm}|Generates an automatic _Proxy-Authenticate_ header, using `Realm`
{service_route, Routes}|For REGISTER requests, if code is in the 200-299 range, generates a _Service-Route_ header
{sip_etag, ETag}|Generares a _SIP-ETag_ header

The datatype to use in most of the cases can be `string()` | `binary()` or `integer()`, depending on every situation.


## Automatic processing

NkSIP will make some aditional processing on the response (unless you use `Code` or `{Code, Opts}`):
* If Code>100, and the request had a _Timestamp_ header, it will be copied to the response.
* If Code>100 and method is INVITE, UPDATE, SUBSCRIBE or REFER, options `allow` and `supported` will be added.
* If Code is in the 101-299 range and method is INVITE or NOTIFY, and the request had any _Record-Route_ header, they will be copied to the response.
* If Code is in the 101-299 range and method is INVITE, UPDATE, SUBSCRIBE or REFER, a `contact` option will be added if no _Contact_ is already present on the response.
* If Code is in the 200-299 range and method is REGISTER, any _Path_ header will be copied from the request to the response.
* If method is SUBSCRIBE, NOTIFY or PUBLISH, the _Event_ header will be copied from the request to the response.
* If Code is in the 200-299 range and method is SUBSCRIBE, and _Expires_ header will be added to the response if not already present.






