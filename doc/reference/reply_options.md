# Reply Options

This module offers helper functions to easy the generation of common SIP responses.

Currently the following replies are recognized:

Response|Code|Comments
---|---|---
Code|Code|
{Code, Opts}|Code|See options bellow
ringing|180|
rel_ringing|180|_Reliable responses_ will be used
{rel_ringing, Body}|180|_Reliable responses_ will be used, send a body
session_progress|183|
rel_session_progress|183|_Reliable responses_ will be used
{rel_session_progress, Body}|183|_Reliable responses_ will be used, send a body
ok|200|
{ok, Opts}|200|See [options](#options) bellow
{answer, Body}|200|Send a body
accepted|202|
{redirect, [Contact]}|300|Generates _Contact_ headers
{redirect_permanent, Contact}|301|Generates a _Contact_ header
{redirect_temporary, Contact}|302|Generates a _Contact_ header
invalid_request|400|
{invalid_request, Phrase}|400|Use custom SIP phrase
authenticate|401|Generates a new _WWW-Authenticate_ header, using current _From_ domain as realm
{authenticate, Realm}|401|Generates a valid new _WWW-Authenticate header_, using `Realm`
forbidden|403|
{forbidden, Text}|Use custom SIP phrase
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

### Options

Some previous replies allow including options. The recognized options are:
Name|Description
---|---


