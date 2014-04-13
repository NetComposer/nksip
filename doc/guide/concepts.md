# NkSIP Concepts

NkSIP hides most SIP complexity from the developer, so even with some basic SIP knowledge it is possible to build complex, robust and scalable SIP applications. But _it is necessary_ to know some basic SIP concepts to use NkSIP. We don't try to explain SIP here (it would be difficult even to scratch the surface of the first of the RFCs), but we will try to explain the way NkSIP uses some basic SIP concepts in order to better understand how to use it.

## SipApps

A **SipApp** represents a SIP entity started by NkSIP. When starting a SipApp, you configure some basic aspects and the new SIP element is started in the network. From this moment, it can send requests and receive them from other SIP elements. NkSIP allows you to start any number of SipApps simultaneously, as long as they don't listen on the same ip and port or _url resource_.

You can develop _any_ kind of SIP application with NkSIP. This includes endpoints, stateful and stateless proxies, registrars and redirect servers, B2BUAs or any combination of the above, all at the same time, in the same SipApp or in different ones.

Each SipApp starts listening on one or more sets of ip, port and transport. For example, you could start a _server1_ SipApp, which could be a proxy server listening on 192.168.0.1:5060 using protocols UDP and TCP, and on 192.168.0.1:5061 using TLS, and another one called _b2bua2_ behaving as a B2BUA could be started listening on any other ip and port of the host. For websocket (WS and WSS transports), SipApps can share the same ip and port, and the request is routed to the right SipApp depending on the _url_.

When starting a SipApp, you must supply a **callback Erlang module** for it. There is a number of callback functions this module can implement. Each of them has an default behaviour, so all of them are optional.

## Requests and responses

SIP is all about sending specific SIP messages (_requests_), and receiving one or more messages in response for them (_responses_). Any SIP element must behave, at the same time, as a client (_uac_ in SIP terminology) sending requests and receiving responses, and as a  server (_uas_), receiving requests and sending responses.

There are a number of SIP request types (INVITE, OPTIONS, etc.), and each corresponding response will have a HTTP-type code (100-699). Responses of type 1xx are _provisional_, and the rest are _final_. 2xx responses denote a successful processing, 3xx denote a redirect proposal, 4xx indicate an error processing the request, 5xx a server error and 6xx a global error.

In NkSIP you can start sending requests using the functions in `nksip_uac`module, such as `options/3`, `invite/3` etc., and the response will be received as part of the function's return value. For example, if you send and OPTIONS request, the called party will probably reply with a 200 response containing, among other things, the codecs it supports.

Your application will also start receiving requests sent from other SIP endpoints or proxies, and NkSIP will then call the corresponding function in your `callback module`. Depending on the value your function returns, a specific SIP response will be generated and sent. For example, if someone sends you an INVITE, NkSIP will call `invite(Request, From)` in your callback module (if this function is not defined, the default implementation in `nksip_sipapp` module would be used). You could answer `{reply, busy}` to send a standard _busy_ (code 486) response, and NkSIP will generate all required SIP headers and send back the response.


## Transactions

SIP offers two possibilities for sending requests and receiving responses: _inside a transaction_ or _without transaction_. 

A _SIP transaction_ is a piece of state created by a SIP endpoint acting as a client when the request is sent, and it is destroyed soon after a final response is received, or it is created by a SIP endpoint acting as a server when a request is received, and it is destroyed after a final response is sent. Among other things, transactions take care of message retransmissions automatically.

Most SIP requests are usually sent and received inside transactions, but in some cases it makes sense to send or receive requests without a corresponding transaction. As no additional state is stored, the application will scale better. NkSIP request generating functions such as `nksip_uac:invite/3` or `nksip_uac:options` always use transactions. But you have the option to process incoming requests statelessly, mainly for failed authentication responses (or to test the maximum speed NkSIP is able to process messages). They are also not used if you decide to behave as a _stateless proxy_ for any incoming request.

If transactions are no used, retransmissions and forked responses will not be detected, and they will look like brand new requests to the application. NkSIP won't send retransmissions either.

Except for INVITE, SIP transactions should be very short-lived. They should complete quickly (bellow half a second) or retransmissions will start to be sent. Final responses for INVITE transactions can last for seconds or even minutes (as the user must usually reply to the invite manually), but even in this case provisional responses should be sent quickly.


## Dialogs

A _SIP dialog_ represents a long-term relationship between two endpoints, usually lasting for the duration of a call or subscription.

A dialog can host several _usages_ simultaneously: zero or one _INVITE usage_, and any number of _SUBSCRIBE usages_ simultaneously. The first usage creates the dialog, and it is destroyed after the last usage is removed.

A successful response to a INVITE request creates a _INVITE usage_, that is maintained until a BYE request is received. Any starting call will usually create a new dialog (it can actually create several dialogs, but NkSIP will automatically send BYE to all but the first one). When the call is _hung up_, a BYE is usually sent and NkSIP destroys the usage.

New requests can be sent _inside_ the newly created dialog. If no new request is sent or received during a specific period of time, NkSIP would also destroy the usage. You should _refresh_ the usage periodically (for example calling ` nksip_uac:refresh/3` or sending a new in-dialog request).

A successfull SUBSCRIBE followed by a NOTIFY request creates a _SUBSCRIBE usage_, and it is maintained until a NOTIFY with status _terminated_ is received or the subscription expires. You should refresh the usage sending new SUBSCRIBE requests. 

When a dialog is created, destroyed or updated the corresponding function in your callback module is called. You can use these calls to know about the dialog current state, for example for billing purposes. Stateless proxies don't generate or process dialogs.



## Sessions

INVITE SIP requests usually carry a body describing a session proposal, using [SDP](http://tools.ietf.org/html/rfc4566) protocol. The remote party can reply with its own SDP, and a new _session_ is then established (audio, video or any other class), associated to the corresponding dialog. During the dialog lifetime, any of the parties can send a new INVITE (it would be what is commonly known as a _reINVITE_) with a new SDP to modify the current session (for example, to put the call _on hold_).

When, inside a dialog, NkSIP detects that a session has been established, modified or terminated, it calls the corresponding function in the `callback module`. You can use this callback to discover the codecs being used, if a call has been put on hold, or the RTP and RTCP ips and ports been used.

NkSIP is a pure SIP framework and, as such, has no RTP processing capability by itself. This means it cannot decode any _codec_, put the audio on the speaker, save the call audio on disk or host an audio conference. This functions are usually done by a SIP media server.

If you are developing a SIP proxy, you won't usually want to do any media processing. If you are developing an endpoint or an B2BUA, you can pretend to have media processing capabilities using a media server as a backend, for example inviting the media server before answering the call and sending the media server's SDP as if it were generated by ours. 

You can use the functions in `nksip_sdp` to access, create or modify SDP bodies.


## Subscriptions

Youn can start a new subscription requirement to a server sending a `nksip_uac:subscribe/3` request. You should select an _event package_ supported at the server. It the remote party accepts the request, it will start sending NOTIFYs requests any time it wants to, and NkSIP will call your callback `nksip_sipapp:notify/3` for each one. The body of the NOTIFY will have the meaning defined in this specific event package. You should send a new SUBSCRIBE before the subscriptions expires. 

If you are defining a server, you indicate in the SipApp's config the event packages you support, and NkSIP will call your callback `nksip_sipapp:subscribe/3` when a new valid SUBSCRIBE arrives. If you accept it, you should call inmeditaly `nksip_uac:notify/2` to send a NOTIFY, and after that, any time you want to. You can also terminate the subscription at any moment.


## Contacts

There are several situations in any SIP enabled application where we must send to the other party a SIP URI showing the protocol, ip and port where we are currently listening to receive new requests. A _Contact_ header is used for this. For example when sending a REGISTER we must indicate to the registrar where it must send any request directed to us. When starting a dialog with INVITE we must inform the other party where to receive in-dialog requests.

NkSIP will try to automatically generate a correct _Contact_ header for you, using the same transport, ip and port used to send this specific request. For example, if we have a _SipApp_ listening on 192.168.0.1:5070 for UDP and TCP, and 192.168.0.1:5071 for TLS, sending a REGISTER to the _URI_ `<sip:registrar.com;transport=tcp>`, will generate a Contact header like `<sip:192.168.0.1:5070;transport=tcp>`.

If the listening address of the selected transport is _all_ (meaning "listen on all interfaces"). NkSIP will try to find, among all the ips of the host, which is the _best_ one to use. It uses a sorted list of network cards (specifically `eth0`, `eth1`, `en0` and `en1`) fetching the ip from the first active network card. If none is available it will get any ip from the host.

In some circumstances, it makes sense to override NkSIP automatic calculation of contacts and provide a specific one, for example if we want to offer a host name instead of an ip (typically a host resolving to several different ips in different hosts), or to force the use of a specific IP of the host or a specific transport.
