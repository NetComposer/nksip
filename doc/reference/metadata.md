# Request and Responses Metadata

Name|Type|Description
---|---|---
id|nksip:id()|Request or response's id
app_id|nksip:app_id()|Internal SipApp this request or response belongs to
app_name|term()|User SipApp this request or response belongs to
dialog_id|nksip:id()|Dialog's id of this request or response
subscription_id|nksip_id()|Subscription's id of this request or response
proto|nksip:protocol()|Transport protocol
local|{nksip:protocol(), inet:ip_address(), inet:port_number()}|Local transport protocol, ip and port
remote|{nksip:protocol(), inet:ip_address(), inet:port_number()}|Remote transport protocol, ip and port
method|nksip:method()|Method of the request (undefined if it is a response)
ruri|nksip:uri()|Parsed RUri of the request
scheme|nksip:scheme()|Scheme of RUri
user|binary()|User of RUri
domain|binary()|Domain of RUri
aor|nksip:aor()|Address-Of-Record of the RUri
code|nksip:response_code()|SIP Code of the response (0 if it as request)
reason_phrase|binary()|Reason Phrase of the response
content_type|nksip:token()|Parsed Content-Type header
body|nksip:body()|Body
call_id|nksip:call_id()|Call-ID header
vias|[nksip:via()]|Parsed Via headers
from|nksip:uri()|Parsed From header
from_tag|nksip:tag()|From tag
from_scheme|nksip:scheme()|From SIP scheme
from_user|binary()|From user
from_domain|binary()|From domain
to|nksip:uri()|Parsed To header
to_tag|nksip:tag()|To tag
to_scheme|nksip:scheme()|To SIP scheme
to_user|binary()|To user
to_domain|binary()|To domain
cseq_num|integer()|CSeq numeric part
cseq_method|nksip:method()|CSeq method part
forwards|integer()|Parsed Max-Forwards header
routes|[nksip:uri()]Parsed Route headers
contacts|[nksip:uri()]Parsed Contact headers
require|[binary()]|Parsed Require values
supported|[binary()]|Parsed Supported values
expires|integer()&#124;undefined|Parsed Expires header
event|nksip:token()&#124;undefined|Parsed Event header
realms|[binary()]|Realms in authentication headers
rseq_num|integer()&#124;undefined|Parsed RSeq header
rack|{integer(), integer(), nksip:method()}&#124;undefined|Parsed RAck header
{header, Name}|[binary()]|Gets an unparsed header value
all_headers|[{binary(), [binary()]}]|Gets all headers and values

Besides this values, you can use any string() or binary() to the get that header's value



