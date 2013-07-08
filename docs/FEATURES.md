In the current version the following RFCs are supported:

RFC|Description|Coverage
---|---|---
[RFC3261](http://tools.ietf.org/html/rfc3261)|SIP 2.0|Full
[RFC2617](http://tools.ietf.org/html/rfc2617)|Digest authentication|Full
[RFC3263](http://tools.ietf.org/html/rfc3263)|SRV Resolution|Full (no SRV/NAPTR weight support)
[RFC3264](http://tools.ietf.org/html/rfc3264)|Offer/Answer Model|Full
[RFC3581](http://tools.ietf.org/html/rfc3581)|RPort|Full
[RFC4566](http://tools.ietf.org/html/rfc4566)|SDP Parser and Generator|Full (limited processing utilities)
[RFC5389](http://tools.ietf.org/html/rfc5389)|STUN|Basic STUN client and server
[RFC6026]([http://tools.ietf.org/html/rfc6026)|2xx responses|Full


NkSIP features also:
 * Full RFC3261 coverage, including SIP Registrar (RAM storage only).
 * A written from scratch, fully typed Erlang code easy to understand and extend, with more than 50 unit tests.
 * Hot core and application code upgrade.
 * Very few external dependencies: [Lager](https://github.com/basho/lager) for error logging and [Cowboy](http://ninenines.eu") as TCP/SSL acceptor and Websocket server.
 * UDP, TCP and TLS transports, capable of handling thousands of simultaneous sessions.
 * Stateful proxy servers with serial and parallel forking.
 * Stateless proxy servers, even using TCP/TLS.
 * Automatic registrations and timed pings.
 * Dialog and SDP media start and stop detection.
 * SDP processing utilities.
 * Simple STUN server (for future SIP Outbound support).
 * Robust and highly scalable, using all available processor cores.

