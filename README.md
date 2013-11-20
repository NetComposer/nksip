[![Build Status](https://travis-ci.org/kalta/nksip.png?branch=master)](https://travis-ci.org/kalta/nksip)

Introduction
============

NkSIP is an Erlang SIP framework or _application server_, which greatly facilitates the development of robust and scalable server-side SIP applications like proxy, registrar, redirect or outbound servers and [B2BUAs](http://en.wikipedia.org/wiki/Back-to-back_user_agent).

SIP is the standard protocol related to IP voice, video and remote sessions, supported by thousands of devices, softphones and network operators. It is the basic building block for most current voice or video enabled networks and it is the core protocol of the IP Multimedia Subsytem ([IMS](https://en.wikipedia.org/wiki/IP_Multimedia_Subsystem)). SIP is powerful and flexible, but also very complex to work with. SIP basic concepts are easy to understand, but developing robust, scalable, highly available applications is usually quite hard and time consuming, because of the many details you have to take into account.

NkSIP takes care of much of the SIP complexity, while allowing full access to requests and responses. 

NkSIP allows you to run any number of **SipApps**. To start a SipApp, you define a _name_, a set of _transports_ to start listening on and a **callback module**. Currently the only way to develop NkSIP applications is using [Erlang]("http://www.erlang.org") (a new, language-independent way of developing SipApps is in the works). You can now start sending SIP requests, and when your application starts receiving requests, specific functions in the callback module will be called. Each defined callback function has a _sane_ default functionality, so you only have to implement the functions you need to customize. You don't have to deal with transports, retransmissions, authentications or dialog management. All of those aspects are managed by NkSIP in a standard way. In case you need to, you can implement the related callback functions, or even process the request by yourself using the powerful NkSIP Erlang functions.

NkSIP has a clean, written from scratch, [OTP compliant](http://www.erlang.org/doc/design_principles/users_guide.html) and [fully typed](http://www.erlang.org/doc/reference_manual/typespec.html) pure Erlang code. New RFCs and features can be implemented securely and quickly. The codebase includes currently more than 50 unit tests. If you want to customize the way NkSIP behaves beyond what the callback mechanism offers, it should be easy to understand the code and use it as a powerful base for your specific application server.

NkSIP is currently **alpha quality**. It is **not yet production-ready**, but it is already very robust, thanks to its OTP design. Also thanks to its Erlang roots it can perform many actions while running: starting and stopping SipApps, hot code upgrades, configuration changes and even updating your application behavior and  function callbacks on the fly.

NkSIP scales automatically using all of the available cores on the machine. Using common hardware (4-core i7 MacMini), it is easy to get more than 3.000 call cycles (INVITE-ACK-BYE) or 10.000 stateless registrations per second. On the roadmap there is a **fully distributed version**, based on [Riak Core](https://github.com/basho/riak_core), that will allow you to add and remove nodes while running, scale as much as needed and offer a very high availability, all of it without changing your application.

NkSIP is a pure SIP framework, so it _does not support any real RTP media processing_ it can't record a call, host an audio conference or transcode. These type of tasks should be done with a SIP media server, like [Freeswitch](http://www.freeswitch.org) or [Asterisk](http://www.asterisk.org). However NkSIP can act as a standard endpoint (or a B2BUA, actually), which is very useful in many scenarios: registering with an external server, answering and redirecting a call or recovering in real time from a failed media server.


New Features
============

Last released version is [v0.3.0](https://github.com/kalta/nksip/releases/tag/v0.3.0). New features include:

* INFO method.
* New caching locating server with NAPTR and SRVS support.
* Outbound connection controlling process.
* SCTP transport.
* IPv6 support.
* New SIP parsers fully RFC4475 _Torture Tests_ compliant.


Documentation
=============

* API documentation is available [here](http://kalta.github.io/nksip).
* [Change log](doc/CHANGELOG.md).
* [Current features](doc/FEATURES.md).
* [Roadmap](doc/ROADMAP.md).

There are currently **three sample applications** included with NkSIP:
 * [Simple PBX](http://kalta.github.io/nksip/docs/v0.2.0/nksip_pbx/index.html): Registrar server and forking proxy with endpoints monitoring.
 * [LoadTest](http://kalta.github.io/nksip/docs/v0.2.0/nksip_loadtest/index.html): Heavy-load NkSIP testing. 
 * [Tutorial](doc/TUTORIAL.md): Code base for the included tutorial.



Quick Start
===========

NkSIP has been tested on OSX and Linux, using Erlang R15B y R16B

```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
> make tests
```

Now you can start a simple SipApp using the included [default callback module](src/nksip_sipapp.erl):
```erlang
> make shell
1> nksip:start(test1, nksip_sipapp, [], []).
ok
2> nksip_uac:options(test1, "sip:sip2sip.info", []).
{ok, 200, []}
```
 
From this point you can read the [tutorial](doc/TUTORIAL.md) or start hacking with the included [nksip_pbx](http://kalta.github.io/nksip/docs/v0.1.0/nksip_pbx/index.html) application:
```erlang
> make pbx
1> nksip_pbx:start().
```

You could also perform a heavy-load test using the included application [nksip_loadtest](http://kalta.github.io/nksip/docs/v0.1.0/nksip_loadtest/index.html):
```erlang
> make loadtest
1> nksip_loadtest:full().
```


Contributing
============

Please contribute with code, bug fixes, documentation fixes, testing with SIP devices or any other form. Use 
GitHub Issues and Pull Requests, forking this repository.


[![githalytics.com alpha](https://cruel-carlota.pagodabox.com/eaae4b01a225feae6da3b7142c17d8c0 "githalytics.com")](http://githalytics.com/kalta/nksip)
