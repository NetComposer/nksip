# Sending Requests

NkSIP supports all defined SIP methods: OPTIONS, REGISTER, INVITE, ACK, BYE, CANCEL, INFO, PRACK, UPDATE, SUBSCRIBE, NOTIFY, REFER, PUBLISH and MESSAGE.

To send a new request, you should use one of the functions in `nksip_uac` module. Depending on the specific method, the request should be sent out of any existing dialog and/or in-dialog. Out-of-dialog sending request functions will use need the SipApp they should use, the _sip uri_ to send the request to and a optional list of options (see the full list of options in the [reference page](../reference/uac_options.md)). In-dialog sending request functions will usually need the _dialog's id_ or _subscription`s id_ of the dialog or subscriptions. You can get these from the returned values (see bellow) or from specific callback functions.

By default, most functions will block until a final response is received or a an error is produced before sending the request, returning `{ok, Code, Meta}` or `{error, Error}`.

`Meta` can include some metadata about the response. Use the option `meta` to select which metadatas you want to receive. Some methods (like INVITE and SUBSCRIBE) will allways include some metadata (see bellow). You can use the functions in `nksip_dialog` to get additional information.

You can define a callback function using option `callback`, and it will be called for every received provisional response as `{ok, Code, Meta}`.

You can also call most of these functions _asynchronously_ using `async` option, and the call will return immediately, before even trying to send the request, instead of blocking. You should use the callback function to receive provisional responses, final response and errors.


## Request sending functions

### OPTIONS

`options(App, Uri, Opts)`
`options(DialogId, Opts)`

OPTIONS requests are usually sent to get the current set of SIP features and codecs the remote party supports, and to detect if it is _up_, it has failed or it is not responding requests for any reason. It can also be used to measure the remote party response time.

### REGISTER

`register(App, Uri, Opts`

This function is used to send a new REGISTER request to any registrar server, to register a new _Contact_, delete a current registration or get the list of current registered contacts from the registrar. 

Typical options are `contact`, `expires`, `unregister`, `unregister_all` and `reg_id`. Keep in mind that, once you send a REGISTER requests, following refreshes should have the same _Call-ID_ and incremented _CSeq_ headers.|


### INVITE

`invite(App, Uri, Opts)`
`invite(DialogId, Opts)`

INVITE|This functions sends a new session invitation to another endpoint or proxy. 
When the first provisional response from the remote party is received (as 180 _Ringing_) a new dialog will be started, and the corresponding callback `dialog_update/3` in the callback module will be called. If this response has also a valid SDP body, a new session will be associated with the dialog and the corresponding callback `session_update/3` will also be called.

When the first 2xx response is received, the dialog is confirmed. **You must then call `ack/2` immediately**, offering an SDP body if you haven't done it in the INVITE request. The dialog is destroyed when a BYE is sent or received, or a 408 _Timeout_ or 481 _Call Does Not Exist_ response is received. If a secondary 2xx response is received (usually because a proxy server has forked the request) NkSIP will automatically acknowledge it and send BYE. 

If a 3xx-6xx response is received instead of a 2xx response, the _early dialog_ is destroyed. You should not call `ack/2` in this case, as NkSIP will do it for you automatically.

After a dialog has being established, you can send new INVITE requests (called _reINVITEs_) _inside_ this dialog. Common options are `contact`, expires`, `prack`, `session_expires`. Options `supported`, `allow` and `allow_event` are automatically added.

A `contact` option will be automatically added if no contact is defined.

If _Expires_ header is used, NkSIP will CANCEL the request if no final response has been received in this period in seconds. The default value for `contact` parameter would be `auto` in this case.

If you want to be able to _CANCEL_ the request, you should use the `async` option.

NkSIP will automatically start a session timer (according to RFC4028). Use option `session_expires` to 0 to disable. If the session timer is active, and a 422 (_Session Interval Too Small_) is received, NkSIP will automatically resend the request updating Session-Expires header.

If a 491 response is received, it usually means that the remote party is starting another reINVITE transaction right now. You should call `nksip_response:wait_491` and try again.

The first meta returned value is allways `{dialog_id, DialogId}`, even if the `meta` option is not used.


### ACK

`ack(DialogId, Opts)`

After sending an INVITE and receiving a successfully (2xx) response, you must call this function immediately to send the mandatory ACK request. NkSIP won`t send it for you automatically in case of a successful response, 
because you may want to include a SDP body if you didn`t do it in the INVITE request.

For sync requests, it will return `ok` if the request could be sent or `{error, Error}` if an error is detected. For async requests, it will return `async`. If a callback is defined, it will be called as `ok` or `{error, Error}`.    


### BYE

`bye(DialogId, Opts)`

Sends an _BYE_ for a current dialog, terminating the session.


### INFO

`info(DialogId, Opts)`

Sends an INFO request. Doesn`t change the state of the current session.


### CANCEL

`cancel(RequestId, Opts)`

Sends an _CANCEL_ for a currently ongoing _INVITE_ request.

You can use this function to send a CANCEL requests to abort a currently _calling_ INVITE request, using the `RequestId` obtained when calling `invite/2,3` _asynchronously_. The CANCEL request will eventually be received at the remote end, and, if it hasn`t yet answered the matching INVITE request, it will finish it with a 487 code. 

This call is always asychronous. It returns a soon as the request is received and the cancelling INVITE is found.


### UPDATE

`update(DialogId, Opts)`

Sends a UPDATE on a currently ongoing dialog.

This function sends a in-dialog UPDATE, allowing to change the media session before the dialog has been confirmed.
A session timer will be started.


### SUBSCRIBE

`subscribe(App, Uri, Opts)`
`subscribe(Id, Opts)`

Sends an SUBSCRIBE request.

This functions sends a new subscription request to the other party. If the remote party returns a 2xx response, it means that the subscription has been accepted, and a NOTIFY request should arrive inmediatly. After the reception of the NOTIFY, the subscription state will change and NkSIP will call `dialog_update/3`. 

In case of 2xx response, the first returned value is allways `{subscription_id, SubscriptionId}`, even if the `meta` option is not used.

If `Id` is a _subscription's id_, it will send as a re-SUBSCRIBE, using the same _Event_ and _Expires_ as the last _SUBSCRIBE_, refreshing the subscription in order to avoid its expiration.

Common options are `event`, `expires`.

After a 2xx response, you should send a new re-SUBSCRIBE request to refresh the subscription before the indicated _Expires_, calling this function again but using the subscription specification. When half the time before expire has been completed, NkSIP will call callback `dialog_update/3` as `{subscription_state, SubscriptionId, middle_timer}`.


### NOTIFY

`notify(SubscriptionId, Opts)`

Sends an _NOTIFY_ for a current server subscription.

When your SipApp accepts a incoming SUBSCRIBE request, replying a 2xx response, you should send a NOTIFY inmediatly. You have to use the subscription`s id from the call to callback `subscribe/3`.

NkSIP will include the mandatory _Event_ and _Subscription-State_ headers for you, depending on the following parameters:

`state`|`active|pending|{terminated,Reason}|{terminated,Reason,Retry}`(see bellow)

Valid states are

`active`|the subscription is active. NkSIP will add a `expires` parameter indicating the remaining time
`pending`|the subscription has not yet been authorized. A `expires` parameter will be added
`terminated`|the subscription has been terminated. You must use a reason: `deactivated` (the remote party should retry again inmediatly), `probation` (the remote party should retry again. You can use `Retry` to inform of the minimum time for a new try), `rejected` (the remote party should no retry again), `timeout` (the subscription has timed out, the remote party can send a new one inmediatly), `giveup` (we have not been able to authorize the request, the remote party can try again, you can use `Retry`), `noresource` (the subscription has ended because of the resource does not exists any more, do not retry) and `invariant` (the subscription has ended because of the resource is not going to change soon, do not retry).

### MESSAGE

`message(App, Uri, Opts)`
`message(DialogId, Opts`

Sends an MESSAGE request.


### REFER

`refer(App, Uri, Opts)`
`refer(DialogId, Opts`

 Sends an _REFER_ for a remote party

Asks the remote party to start a new connection to the indicated uri in `refer_to` parameter. If a 2xx response is received, the remote party has agreed and will start a new connection. A new subscription will
be stablished, and you will start to receive NOTIFYs. Implement the callback function `notify/4` to receive, filtering using the indicated `subscription_id`

In case of 2xx response, the first returned value is allways `{subscription_id, SubscriptionId}`, even if the `meta` option is not used.
%


### PUBLISH 

`publish(App, Uri, Opts)`
`publish(DialogId, Opts)`

Sends an PUBLISH request.

This functions sends a new publishing to the other party, using a remote supported event package and including a body. 

If the remote party returns a 2xx response, it means that the publishing has been accepted, and the body has been stored. A _SIP-ETag_ header will be returned (a `sip_etag` parameter will always be returned in meta). You can use this parameter to update the stored information (sending a new body), or deleting it (using `{expires, 0}`)

Typical options are `event`, `expires` and `sip_etag`.


## Other sending functions


### Generic request

`request(App, Uri, Opts)`
`request(DialogId, Opts)`

Allows you to send any SIP request, without the automatic processing of the previous functions. See _using URI parameters_ bellow.


### Refresh

`refresh(DialogId, Opts)`

Sends a update on a currently ongoing dialog using INVITE.

This function sends a in-dialog INVITE, using the same current parameters of the dialog, only to refresh it. The current local SDP version will be incremented before sending it. The following aditional options are recognized:

`active`|activate the medias on SDP (sending `a=sendrecv`)
`inactive`|deactivate the medias on SDP (sending `a=inactive`)
`hold`|activate the medias on SDP (sending `a=sendonly`)


### Stun

`stun(App, Uri, Opts)`

Sends a _STUN_ binding request.

Use this function to send a STUN binding request to a remote STUN or STUN-enabled SIP server, in order to get our remote ip and port. If the remote server is a standard STUN server, use port 3478 (i.e. `sip:stunserver.org:3478`). If it is a STUN server embedded into a SIP UDP, use a standard SIP uri.

