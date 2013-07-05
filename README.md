Introduction
============

NkSIP is an Erlang framework or _application server_, which greatly facilitates the development of robust and scalable server-side SIP applications like proxy, registrar, redirect or outbound servers and [B2BUAs](http://en.wikipedia.org/wiki/Back-to-back_user_agent).

**This software is still alpha quality!! Do not use it in production!!**

SIP is very powerful and flexible protocol, but also very complex to manage. SIP basic concepts are easy to understand, but developing robust, scalable, highly available applications is usually quite hard and time consuming, because of the many details you have to take into account.

NkSIP allows you to run any number of **SipApps**. To start a SipApp, you define a _name_, a set of _transports_ to start listening on and a _callback module_. Currently the only way to develop NkSIP applications is using [Erlang]("http://www.erlang.org") (a new, language-independent way of developing SipApps is in the works). You can now start sending SIP requests, and when your application starts receiving requests, specific functions in the callback module will be called. Each defined callback function has a sane default functionality, so you only have to implement the functions you need to customize. You don't have to deal with transports, retransmissions, authentications or dialog management. All of those aspects are managed by NkSIP in a standard way. In case you need to, you can implement the related callback functions, or even process the request by yourself using the powerful NkSIP Erlang functions.

NkSIP has a clean, written from scratch, [OTP compliant](http://www.erlang.org/doc/design_principles/users_guide.html) and [fully typed](http://www.erlang.org/doc/reference_manual/typespec.html) pure Erlang code. New RFCs and features can be implemented securely and quickly. The codebase includes currently more than 50 unit tests. If you want to customize the way NkSIP behaves beyond what the callback mechanism offers, it should be easy to understand the code and use it as a powerful base for your specific application server.

NkSIP is currently alpha quality, it probably has important bugs and is not **not yet production-ready**, but it is already very robust, thanks to its OTP design. Also thanks to its Erlang roots it can perform many actions while running: starting and stopping SipApps, hot code upgrades, configuration changes and even changing your application behavior and function callbacks on the fly.

NkSIP scales automatically using all of the available cores on the machine. Without any serious optimization done yet, and using common hardware (4-core i7 MacMini), it is easy to get more than 1.000 call cycles (INVITE-ACK-BYE) or 8.000 stateless registrations per second. On the roadmap there is a **fully distributed version**, based on [Riak Core](https://github.com/basho/riak_core), that will allow you to add and remove nodes while running, scale as much as needed and offer a very high availability, all of it without changing your application.

NkSIP is a pure SIP framework, so it _does not support any real RTP media processing_ it can't record a call, host an audio conference or transcode. These type of tasks should be done with a SIP media server, like [Freeswitch](http://www.freeswitch.org) or [Asterisk](http://www.asterisk.org). However NkSIP can act as a standard endpoint (or a B2BUA, actually), which is very useful in many scenarios: registering with an external server, answering and redirecting a call or recovering in real time from a failed media server.


Current Features
----------------


 * Full RFC3261 coverage, including SIP Registrar (RAM storage only).
 * A written from scratch, fully typed Erlang code easy to understand and extend. More than 50 unit tests.
 * Very few external dependencies: [Lager](https://github.com/basho/lager) for error logging and [Cowboy](http://ninenines.eu") as TCP/SSL acceptor and Websocket server.
 * UDP, TCP and TLS transports, capable of handling thousands of simultaneous sessions.
 * Stateful proxy servers with serial and parallel forking.
 * Stateless proxy servers, even using TCP/TLS.
 * Automatic registrations and timed pings.
 * Dialog and SDP media start and stop detection.
 * SDP processing utilities.
 * Simple STUN server (for SIP Outbound).
 * Robust and highly scalable, using all available processor cores. Hot code loading.

See [FEATURES.md](../nksip/FEATURES.md) for up to date RFC support



Documentation
-------------
Full documentation is available [here](http://kalta.github.io/nksip)


Sample Applications
-------------------

There are currently two samples applications included with NkSIP:
 * NkPBX. Implements a SIP registrar and forking proxy, with endpoints monitoring. 
 * NkLoadTest. Heavy-load NkSIP testing.

Full documentation fot both applications is available [here](http://kalta.github.io/nksip)


Quick Start
===========

```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
> make tests
```

Now you can start a simple SipApp using default `nksip_sipapp.erl` callback module:

```erlang
> make shell
1> nksip:start(test1, nksip_sipapp, [], [])
2> nksip_uac:options(test1, "sip:sip2sip.info", [])
{ok, 200}
```
 
You could also start the sample application `NkPBX` to have a target SIP server to test:
```erlang
3> nksip_pbx:start()
4> nksip_uac:register(test1, "sip:127.0.0.1;transport=tls", [])
{ok, 407}
```

We need a password. We use now `make_contact` option to generate a valid _Contact_ header:
```erlang
5> nksip_uac:register(test1, "sip:127.0.0.1;transport=tls", [{pass, "1234"}, make_contact])
{ok, 200}
6> {reply, Reply1} = nksip_uac:register(test1, "sip:127.0.0.1;transport=tls", [{pass, "1234"}, full_response]).
7> nksip_response:headers(<<Contact>>, Reply1)
```

We have now registered. With the option `full_response` we get a full resonse object instead of simple the code. The server replies with the stored _Contact_.

Roadmap
-------
See [ROADMAP.md](../nksip/ROADMAP.md)










