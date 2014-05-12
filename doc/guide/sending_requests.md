# Sending Requests

To send a new request, you should use one of the functions in [nksip_uac](../../src/nksip_uac.erl) module. NkSIP supports all defined SIP methods: OPTIONS, REGISTER, INVITE, ACK, BYE, CANCEL, INFO, PRACK, UPDATE, SUBSCRIBE, NOTIFY, REFER, PUBLISH and MESSAGE.

Depending on the specific method, the request should be sent out of any existing dialog and/or in-dialog. Out-of-dialog sending request functions will need a SipApp name (_user name_ or _internal name_), a _sip uri_ to send the request to and an optional [list of options](../reference/sending_options.md). In-dialog sending request functions will usually need the _dialog's id_ or _subscription's id_ of the dialog or subscription. You can get them from the returned _meta_ values of dialog-generating functions (like INVITE or SUBSCRIBE) or from [sip_dialog_update/3](../reference/callback_functions.md#sip_dialog_update3) callback function. 

`Meta` can include some metadata about the response. Use the option `meta` to select which metadatas you want to receive (see [metadata fields](../reference/metadata.md). Some methods (like INVITE and SUBSCRIBE) will allways include some metadata (see bellow). You can use the functions in [nksip_dialog](../../src/nksip_dialog.erl) to get additional information (see [the API](../reference/api.md)).

You can define a callback function using option `callback`, and it will be called for every received provisional response as `{reply, Code, Response, Call}`. Use the functions in [the API](../reference/api.md) to extract relevant information from each specific response. It's important to notice this callback function will be called in the same process as the (see explanation in [callback functions](../reference/callback_functions.md)) so you shouldn't spend a lot of time inside it. You shouldn't also copy the `Response` or `Call` to other processes, as that operation is expensive.

By default, most functions will block until a final response is received or a an error is produced before sending the request, returning `{ok, Code, Meta}` or `{error, Error}`. You can also call most of these functions _asynchronously_ using `async` option, and the call will return immediately, usually with `{async, RequestId}`, before even trying to send the request, instead of blocking. You should use the callback function to receive provisional responses, final response and errors. `RequestId` is a handle to the current request and can be used to get additional information from it (see, the [API](../reference/api.md), before it's destroyed) or to CANCEL the request.

Most functions in this list add specific behaviour for each specific mehtod. For example, `invite/3,2` will allways include a Contact header. You can use the generic `request/3,2` function to avoid any specific addition. 

In case of using a SIP URI as destination, is is possible to include custom headers, for example `<sip:host;method=REGISTER?contact=*&expires=10>`, but it must be escaped (using for example `http_uri:encode/1`). You should use `request/3,2` if you specify the method in the _uri_.


See the full list of options in [Sending Options](../reference/sending_options.md).

Function|Comment
---|---
[options/3](#options)|Sends an out-of-dialog OPTIONS request
[options/2](#options)|Sends an in-dialog OPTIONS request
[register/3](#register)|Sends an out-of-dialog REGISTER request
[invite/3](#invite)|Sends an out-of-dialog INVITE request
[invite/2](#invite)|Sends an in-dialog INVITE request
[ack/2](#ack)|Sends an in-dialog ACK request for a successful INVITE response
[bye/2](#bye)|Sends an in-dialog BYE request
[cancel/2](#cancel)|Sends a CANCEL for a previous sent INVITE
[update/2](#update)|Sends an in-dialog UPDATE request
[info/2](#info)|Sends an in-dialog INFO request
[subscribe/3](#subscribe)|Sends an out-of-dialog SUBSCRIBE request
[subscribe/2](#subscribe)|Sends an in-dialog SUBSCRIBE request
[notify/2](#notify)|Sends an in-dialog NOTIFY request
[message/3](#message)|Sends an out-of-dialog MESSAGE request
[message/2](#message)|Sends an in-dialog MESSAGE request
[refer/3](#refer)|Sends an out-of-dialog REFER request
[refer/2](#refer)|Sends an in-dialog REFER request
[publish/3](#publish)|Sends an out-of-dialog PUBLISH request
[publish/2](#publish)|Sends an in-dialog PUBLISH request
[request/3](#request)|Sends an out-of-dialog generic request
[request/2](#request)|Sends an in-dialog generic request
[stun/3](#stun)|Sends a STUN request


### Options
```
options(App, Uri, Opts)
options(DialogId, Opts)
```

OPTIONS requests are usually sent to get the current set of SIP features and codecs the remote party supports, and to detect if it is _up_, it has failed or it is not responding requests for any reason. It can also be used to measure the remote party response time.

Options `supported`, `allow` and `allow_event` are automatically added.
NkSIP has an automatic remote _pinging_ feature that can be activated on any SipApp (see plugins).


### Register
```
register(App, Uri, Opts)
```


This function is used to send a new REGISTER request to any registrar server, to register a new _Contact_, delete a current registration or get the list of current registered contacts from the registrar. To register a contact you should use optons `{contact, Contact}` or `contact`, and typically `expires`. If you include no contact, the current list of registered contacts should be returned by the server.

Options `to_as_from`, `supported`, `allow` and `allow_events` are automatically added. 
You can use also use the options `unregister` to unregister included or default contact and `unregister_all` to unregister all contacts. Option `reg_id` is also available for outbound support.
Keep in mind that, once you send a REGISTER requests, following refreshes should have the same _Call-ID_ and incremented _CSeq_ headers.|


### Invite
```
invite(App, Uri, Opts)
invite(DialogId, Opts)
```

This functions sends a new session invitation to another endpoint or proxy. Options `contact`, `supported`, `allow` and `allow_event` are automatically added.

When the first provisional response from the remote party is received (as 180 _Ringing_) a new dialog will be started, and the corresponding callback [sip_dialog_update/3](../reference/callback_functions.md#sdp_dialog_update3) in the callback module will be called. If this response has also a valid SDP body, a new session will be associated with the dialog and the corresponding callback [sip_session_update/3](../reference/callback_functions.md#sip_session_update3)  will also be called.

When the first 2xx response is received, the dialog is confirmed. **You must then call `ack/2` immediately** (or use the `auto_2xx_ack` option), offering an SDP body if you haven't done it in the INVITE request. The dialog is destroyed when a BYE is sent or received, or a 408 _Timeout_ or 481 _Call Does Not Exist_ response is received. If a secondary 2xx response is received (usually because a proxy server has forked the request) NkSIP will automatically acknowledge it and send BYE. 

If a 3xx-6xx response is received instead of a 2xx response, the _early dialog_ is destroyed. You should not call `ack/2` in this case, as NkSIP will do it for you automatically.

After a dialog has being established, you can send new INVITE requests (called _reINVITEs_) _inside_ this dialog, as well as in-dialog OPTIONS, BYE, UPDATE, INFO, SUBSCRIBE, MESSAGE, REFER or PUBLISH.

You case use specific options:
* `{expires, Expires}`: NkSIP will CANCEL the request if no final response has been received in this period in seconds. 
* `{session_expires, SE}`: NkSIP will automatically start a session timer (according to RFC4028). Use SE=0 to disable it. If the session timer is active, and a 422 (_Session Interval Too Small_) is received, NkSIP will automatically resend the request updating Session-Expires header.
* `{prack_callback, Fun}`: If included, this function will be called when a reliable provisional response has been received, and before sending the corresponding PRACK. It will be called as `{RemoteSDP, Response, Call}'. If RemoteSDP is a SDP, it is an offer and you must supply an answer as function return. If it is `<<>>', you can return `<<>>' or send a new offer. If this option is not included, PRACKs will be sent with no body.

If you want to be able to _CANCEL_ the request, you should use the `async` option to get the corresponding `RequestId` to use when calling `cancel/2`.

If a 491 response is received, it usually means that the remote party is starting another reINVITE transaction right now. You should call `nksip_response:wait_491/0` and try again.

The first meta returned value is allways `{dialog_id, DialogId}`, even if the `meta` option is not used.


### Ack
```ack(DialogId, Opts)
```

After sending an INVITE and receiving a successfully (2xx) response, you must call this function immediately to send the mandatory ACK (unless option `auto_2xx_ack` is used). NkSIP won`t send it for you automatically in case of a successful response, because you may want to include a SDP body if you didn`t do it in the INVITE request.

For sync requests, it will return `ok` if the request could be sent or `{error, Error}` if an error is detected. For async requests, it will return `async`. If a callback is defined, it will be called as `ok` or `{error, Error}`.    


### Bye
```bye(DialogId, Opts)
```

Sends an _BYE_ for a current dialog, terminating the session.


### Cancel

`cancel(RequestId, Opts)`

Sends an _CANCEL_ for a currently ongoing _INVITE_ request.

You can use this function to send a CANCEL requests to abort a currently _calling_ INVITE request, using the `RequestId` obtained when calling `invite/2,3` _asynchronously_. The CANCEL request will eventually be received at the remote end, and, if it hasn`t yet answered the matching INVITE request, it will finish it with a 487 code. 

This call is always asychronous. It returns a soon as the request is received and the cancelling INVITE is found.


### Update

`update(DialogId, Opts)`

Sends an  UPDATE on a currently ongoing dialog, allowing to change the media session before the dialog has been confirmed. A session timer will be started.
Options `supported`, `accept` and `allow` are automatically added.


### Info

```
info(DialogId, Opts)
```

Sends an INFO request. Doesn`t change the state of the current session.



### Subscribe
```
subscribe(App, Uri, Opts)
subscribe(Id, Opts)
```

Sends an SUBSCRIBE request.

This functions sends a new subscription request to the other party. You must use option `{event, Event}` to select an _Event Package_ supported at the server, and commonly an `{expires, Expires}` option (default for this package will be used if not defined). Options `supported`, `allow` and `allow_event` are automatically added.

If the remote party returns a 2xx response, it means that the subscription has been accepted, and a NOTIFY request should arrive inmediatly. After the reception of the NOTIFY, the subscription state will change and NkSIP will call [sip_dialog_update/3](../reference/callback_functions.md#sdp_dialog_update3).

If `Id` is a _subscription's id_, it will send as a reSUBSCRIBE, using the same _Event_ and _Expires_ as the last _SUBSCRIBE_, refreshing the subscription in order to avoid its expiration.

After a 2xx response, you should send a new reSUBSCRIBE request to refresh the subscription before the indicated _Expires_, calling this function again but using the subscription specification. When half the time before expire has been completed, NkSIP will call callback [sip_dialog_update/3](../reference/callback_functions.md#sdp_dialog_update3) as `{subscription_state, middle_timer, SubscriptionId}` to remind you to send the reSUBSCRIBE.


### Notify
```
notify(SubscriptionId, Opts)
```

Sends an _NOTIFY_ for a current server subscription.

When your SipApp accepts a incoming SUBSCRIBE request, replying a 2xx response, you should send a NOTIFY inmediatly. You have to use the subscription`s id from the call to callback `subscribe/3`. NkSIP will include the mandatory _Event_ and _Subscription-State_ headers for you, but you must include a `{subscription_state, ST}` options with the following allowed values:

* `active`: the subscription is active. NkSIP will add a `expires` parameter indicating the remaining time
* `pending`: the subscription has not yet been authorized. A `expires` parameter will be added
* `{terminated, Reason}`: the subscription has been terminated. You must use a reason: `deactivated` (the remote party should retry again inmediatly), `probation` (the remote party should retry again), `rejected` (the remote party should no retry again), `timeout` (the subscription has timed out, the remote party can send a new one inmediatly), `giveup` (we have not been able to authorize the request, the remote party can try again), `noresource` (the subscription has ended because of the resource does not exists any more, do not retry) and `invariant` (the subscription has ended because of the resource is not going to change soon, do not retry).
* `{terminated, Reason, Retry}`: Only with reasons `probation` and `giveup` you can send a retry-after parameter


### Message
```
message(App, Uri, Opts)
message(DialogId, Opts
```

Sends an MESSAGE request.


### Refer
```
refer(App, Uri, Opts)
refer(DialogId, Opts
```

Sends an _REFER_ for a remote party. 

Asks the remote party to start a new connection to the indicated uri in the mandatory `refer_to` parameter. If a 2xx response is received, the remote party has agreed and will start a new connection. A new subscription will be stablished, and you will start to receive NOTIFYs. Implement the callback function [notify/2](../reference/callback_functions.md#notify2) to receive them, filtering using the indicated `subscription_id`

In case of 2xx response, the first returned value is allways `{subscription_id, SubscriptionId}`, even if the `meta` option is not used.



### Publish 

```
publish(App, Uri, Opts)
publish(DialogId, Opts)
```

Sends an PUBLISH request. Options `supported`, `allow` and `allow_event` are automatically added.

This functions sends a new publishing to the other party, using a mandatory `{event, Event}` remote supported event package and including a body. 

If the remote party returns a 2xx response, it means that the publishing has been accepted, and the body has been stored. A _SIP-ETag_ header will be returned (a `sip_etag` parameter will always be returned in meta). You can use this parameter to update the stored information (sending a new body), or deleting it (using `{expires, 0}`)


### Generic request
```
request(App, Uri, Opts)
request(DialogId, Opts)
```

Allows you to send any SIP request, without the automatic processing of the previous functions. 


### Stun
```
stun(App, Uri, Opts)
```

Sends a _STUN_ binding request.

Use this function to send a STUN binding request to a remote STUN or STUN-enabled SIP server, in order to get our remote ip and port. If the remote server is a standard STUN server, use port 3478 (i.e. `sip:stunserver.org:3478`). If it is a STUN server embedded into a SIP UDP, use a standard SIP uri.


