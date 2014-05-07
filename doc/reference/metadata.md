# Request and Responses Metadata

Name|Type|Description
---|---|---
id|`nksip:id()`|Request or response's id
app_id|`nksip:app_id()`|Internal SipApp this request or response belongs to
app_name|`term()`|User SipApp this request or response belongs to
dialog_id|`nksip:id()`|Dialog's id of this request or response
subscription_id|`nksip_id()`|Subscription's id of this request or response
proto|`nksip:protocol()`|Transport protocol
local|`{nksip:protocol(),inet:ip_address(),inet:port_number()}`|Local transport protocol, ip and port
remote|`{nksip:protocol(),inet:ip_address(),inet:port_number()}`|Remote transport protocol, ip and port
method|`nksip:method(`)|Method of the request (undefined if it is a response)
ruri|`nksip:uri()`|Parsed RUri of the request
scheme|`nksip:scheme()`|Scheme of RUri
user|`binary()`|User of RUri
domain|`binary()`|Domain of RUri
aor|`nksip:aor()`|Address-Of-Record of the RUri
code|`nksip:response_code()`|SIP Code of the response (0 if it as request)
reason_phrase|`binary()`|Reason Phrase of the response
content_type|`nksip:token()`|Parsed Content-Type header
body|`nksip:body()`|Body
call_id|`nksip:call_id()`|Call-ID header
vias|`[nksip:via()]`|Parsed Via headers
from|`nksip:uri()`|Parsed From header
from_tag|`nksip:tag()`|From tag
from_scheme|`nksip:scheme()`|From SIP scheme
from_user|`binary()`|From user
from_domain|`binary()`|From domain
to|`nksip:uri()`|Parsed To header
to_tag|`nksip:tag()`|To tag
to_scheme|`nksip:scheme()`|To SIP scheme
to_user|`binary()`|To user
to_domain|`binary()`|To domain
cseq_num|`integer()`|CSeq numeric part
cseq_method|`nksip:method()`|CSeq method part
forwards|`integer()`|Parsed Max-Forwards header
routes|`[nksip:uri()]`|Parsed Route headers
contacts|`[nksip:uri()]`|Parsed Contact headers
require|`[binary()]`|Parsed Require values
supported|`[binary()]`|Parsed Supported values
expires|`integer()`&#124;`undefined`|Parsed Expires header
event|`nksip:token()`&#124;`undefined`|Parsed Event header
realms|`[binary()]`|Realms in authentication headers
rseq_num|`integer()`&#124;`undefined`|Parsed RSeq header
rack|`{integer(),integer(),nksip:method()}`&#124;`undefined`|Parsed RAck header
{header, Name}|`[binary()]`|Gets an unparsed header value
all_headers|`[{binary(),[binary()]}]`|Gets all headers and values

Besides this values, you can use any string() or binary() to the get that header's value

## Dialog Metadata

Name|Type|Description
---|---|---
id|`nksip:id()`|Dialog' Id
app_id|`nksip:app_id()`|Internal SipApp this dialog belongs to
app_name|`term()`|User SipApp this dialog belongs to
created|`nksip_lib:timestamp()`|Creation date
updated|`nksip_lib:timestamp()`|Last update
local_seq|`integer()`|Local CSeq number
remote_seq|`integer()`|Remote CSeq number
local_uri|`nksip:uri()`|Local URI
raw_local_uri|`binary()`|Unparsed Local URI
remote_uri|`nksip:uri()`|Remote URI
raw_remote_uri|`binary()`|Unparsed Remote URI
local_target|`nksip:uri()`|Local Target URI
raw_local_target|`binary()`|Unparsed Local Target URI
remote_target|`nksip:uri()`|Remote Target URI
raw_remote_target|`binary()`|Unpar
early|`boolean()`|Early dialog (no final response yet)
secure|`boolean()`|Secure (sips) dialog
route_set|`nksip:uri()}`|Route Set
raw_route_set|`binary()`|Unparsed Route Set
invite_status|`nksip_dialog:status()`Current dialog's INVITE status
invite_answered|`nksip_lib:timestamp()}`|Answer (first 2xx response) timestamp for INVITE usages
invite_local_sdp|`nksip:sdp()}`|Current local SDP
invite_remote_sdp|`nksip:sdp()}`|Current remote SDP
invite_timeout|`integer()`|Seconds to expire current state
invite_session_expires|`integer()`|Seconds to expire current session
invite_refresh|`integer()`|Seconds to refresh
subscriptions|`nksip:id()`|Lists all active subscriptions
call_id|`nksip:call_id()`|Call-ID of the dialog
from_tag|`binary()`|From tag
to_tag|`binary()`|To tag
