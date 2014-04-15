# Sending Options

You can use a number of options when [sending requests](../guide/sending_requests.md) using the functions is [nksip_uac.erl](../../src/nksip_uac.erl):

Key|Type|Default|Description
---|---|---|---
`meta`|[nksip_response:field()](../../nksip_response)|[]|Use it to select which specific fields from the response are returned
`async`|||If present, the call will return inmediatly as `{async, ReqId}`, or `{error, Error}` if an error is produced before sending the request. `ReqId` can be used with the functions in [nksip_request.erl](../../src/nksip_request.erl) to get information about the request (the request may not be sent yet, so the information about transport may not be present)
`callback`|`fun/1`||If defined, it will be called for every received provisional response as `{ok, Code, Meta}`. For `async` requests, it is called also for the final response and, if an error is produced before sending the request, as `{error, Error}`
`contact`|`user_uri()`||If defined, one or several _Contact_ headers will be inserted in the request
`content_type`|`string()`&#124;`binary()`||If defined, a _Content-Type_ header will be inserted
`require`|`string()`&#124;`binary()`||If defined, a _Require_ header will be inserted
`accept`|`string()`&#124;`binary()`|"*/*"|If defined, this value will be used instead of default when option `accept` is used
`headers`|`header()`|[]|List of headers to add to the request. The following headers should not we used here: _From_, _To_, _Via_, _Call-ID_, _CSeq_, _Forwards_, _User-Agent_, _Content-Type_, 
_Route_, _Contact_, _Require_, _Supported_, _Expires_, _Event_
`body`|`body`|<<>>|Body to use. If it is a `nksip_sdp:sdp()`, a _Content-Type_ header will be generated
`local_host`|auto&#124;`string()`&#124;`binary()`|auto|Overrides SipApp config
`reason`|`error_reason()`||Generates a _Reason_ header
`user_agent`|`string()`&#124;`binary()`|"NkSIP (version)"|_User-Agent_ header to use in the request

Options available for most methods only when sent outside any dialog are:

Key|Type|Default|Description
---|---|---|---
`from`|`user_uri()`||Overrides SipApp config
`to`|`user_uri()`||_To_ header to use in the request
`call_id`|`call_id()`|(automatic)|If defined, will be used instead of a newly generated one (use `nksip_lib:luid/0`)
`cseq`|`nksip:cseq()`|(automatic)|If defined, will be used instead of a newly generated one (use `nksip_lib:cseq/0`)
`route`|`nksip:user_uri()`||Overrides SipApp config
