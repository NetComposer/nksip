In the current version the following RFCs are fully implemented (see notes):

RFC|Description|Notes
---|---|---
[RFC2617](http://tools.ietf.org/html/rfc2617)|Digest authentication|
[RFC2782](http://tools.ietf.org/html/rfc2782)|DNS SRV|
[RFC2915](http://tools.ietf.org/html/rfc2915)|DNS NAPTR|
[RFC2976](http://tools.ietf.org/html/rfc2976)|INFO|
[RFC3261](http://tools.ietf.org/html/rfc3261)|SIP 2.0|
[RFC3262](http://tools.ietf.org/html/rfc3262)|Reliable provisional responses|
[RFC3263](http://tools.ietf.org/html/rfc3263)|Locating SIP Services|
[RFC3264](http://tools.ietf.org/html/rfc3264)|Offer/Answer Model|
[RFC3265](http://tools.ietf.org/html/rfc3265)|Event Notification|
[RFC3311](http://tools.ietf.org/html/rfc3311)|UPDATE|
[RFC3581](http://tools.ietf.org/html/rfc3581)|RPort|
[RFC4168](http://tools.ietf.org/html/rfc4168)|SCTP Transport|No TLS-SCTP
[RFC4475](http://tools.ietf.org/html/rfc4475)|Torture Tests|Included in unit tests
[RFC4566](http://tools.ietf.org/html/rfc4566)|SDP|Only parser and generator
[RFC4660](http://tools.ietf.org/html/rfc4660)|Event Notification|Updates 3261
[RFC5518](http://tools.ietf.org/html/rfc5118)|IPv6 Torture Tests|Included in unit tests
[RFC5389](http://tools.ietf.org/html/rfc5389)|STUN|Basic STUN client and server (no IPv6)
[RFC6026](http://tools.ietf.org/html/rfc6026)|2xx responses|
[RFC6157](http://tools.ietf.org/html/rfc6157)|IPv6 Transition|
[RFC6665](http://tools.ietf.org/html/rfc6665)|Event Notification|Obsoletes 3265,4660. GRUU support pending


NkSIP features also:
 * Full RFC3261 coverage, including SIP Registrar (using the RAM built-in store or any other external database).
 * Full support for PRACK,INFO,UPDATE,SUBSCRIBE,NOTIFY.
 * A written from scratch, fully typed Erlang code easy to understand and extend. Unit tests cover nearly all of the functionality.
 * Hot core and application code upgrade.
 * Very few external dependencies: [Lager](https://github.com/basho/lager) for error logging and [Cowboy](http://ninenines.eu") as TCP/SSL acceptor and Websocket server.
 * UDP, TCP, TLS and SCTP transports, capable of handling thousands of simultaneous sessions.
 * Stateful proxy servers with serial and parallel forking.
 * Stateless proxy servers, even using TCP/TLS.
 * Full IPv6 support. NkSIP can connect IPv4-only with IPv6-only hosts.
 * Full support for NAPTR and SRV location, including priority and weights.
 * Automatic registrations and timed pings.
 * Dialog and SDP media start and stop detection.
 * SDP processing utilities.
 * Simple STUN server (for future SIP Outbound support).
 * Full RFC4475 and RFC5518 Torture Tests passing.
 * Robust and highly scalable, using all available processor cores.

