<!---
NkSIP passes 100% tests in branch master
Travis CI still fails sometimes due to timers
[![Build Status](https://travis-ci.org/kalta/nksip.png?branch=master)](https://travis-ci.org/kalta/nksip)
-->

## Introduction

NkSIP is an Erlang SIP framework or _application server_, which greatly facilitates the development of robust and scalable server-side SIP applications like [proxy](http://en.wikipedia.org/wiki/Session_Initiation_Protocol#Proxy_server), [registrar](http://en.wikipedia.org/wiki/Session_Initiation_Protocol#Registrar), [redirect](http://en.wikipedia.org/wiki/Session_Initiation_Protocol#Redirect_server) or outbound servers, [B2BUAs](http://en.wikipedia.org/wiki/Back-to-back_user_agent), [SBCs](https://en.wikipedia.org/wiki/Session_border_controller) or load generators. NkSIP takes care of much of the SIP complexity, while allowing full access to requests and responses. 

**IMPORTANT** - This version has important, incompatible changes, see the [CHANGELOG](doc/changelog.md) - **IMPORTANT**

A single NkSIP instance can start any number of SIP Services, each one listening on a specific set of transports (_udp_, _tcp_, _tls_, _sctp_, _ws_ or _wss_), ip addresses and ports. A Service can provide a _callback module_ where it can implement a number of _callback functions_. All of them are optional, having _sane defaults_ in case they are not implemented. For outgoing-only SIP applications, a callback module is not necessary.

NkSIP also includes a powerful **plugin mechanism**, that can be used to modify its behaviour without having to fully understand or modify the core engine, and with virtually zero overhead, even if the Service uses a large number of plugins.

NkSIP is very stable and robust. Thanks to its Erlang roots it can perform many actions while running: starting and stopping Services, hot code upgrades, configuration changes and even updating your application behavior, used plugins and function callbacks _on the fly_.

NkSIP scales automatically using all of the available cores on the machine. Using common hardware (4-core i7 MacMini), it is easy to get more than 3.000 call cycles (INVITE-ACK-BYE) or 10.000 registrations per second. A disributed, highly available version of NkSIP will be a service of the upcoming NetComposer platform. 


## Features
* Full support for all curently defined SIP methods: INVITE, ACK, REGISTER, OPTIONS, INFO, UPDATE, PRACK, SUBSCRIBE, NOTIFY, REFER, PUBLISH and MESSAGE, as an UAC, an UAS or a Proxy.
* Can be used to develop very easily any possible SIP application: endpoints, stateful proxies with serial and parallel forking, stateless proxies, B2BUAs, application servers, registrars, SBCs, load generators, etc. 
* Transports UDP, TCP, TLS, SCTP, WS and WSS (websockets) are available, all of them capable of handling thousands of simultaneous sessions.
* Full SIP Event support.
* A written from scratch, fully typed 100% Erlang code with few external dependencies.
* Robust and highly scalable, using all available processor cores automatically.
* More than 140 tests covering nearly all of the functionality.
* Sophisticated plugin mechanism, that adds very low overhead to the core.
* Hot, on-the-fly core and application configuration and code upgrades.
* IPv6 support and IPv4 <-> IPv6 bridge.
* Full support for NAPTR and SRV location, including priority and weights.
* Dialog and SDP processing utility functions, including media start and stop detection.

## Standard plugins
* Digest Authentication.
* Registrar Server and Automatic Registrations.
* Event State Compositor.
* Reliable provisional responses.
* Session Timers
* SIP REFER.
* Outbound and GRUU.
* Trace and Statistics.


# Documentation

[ 1. User Guide](doc/README.md#1-user-guide)<br/>
[ 2. Reference  Guide](doc/README.md#2-reference--guide)<br/>
[ 3. API Guide](doc/README.md#3-api)<br/>
[ 4. Standard Plugins](doc/README.md#4-standard-plugins)<br/>
[ 5. Cookbook](doc/README.md#5-cookbook)<br/>
[ 6. Advanced Concepts](doc/README.md#7-advanced-concepts)<br/>
[ 7. Roadmap](doc/roadmap.md)<br/>
[ 8. Changelog](doc/changelog.md)<br/>


# Quick Start

NkSIP has been tested on OSX and Linux, using Erlang 17

```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
> make tests
```

Now you can start a simple Service using the included [default callback module](src/nksip_callbacks.erl):
```erlang
> make shell
1> nksip:start(test, #{sip_listen=>"sip:all, sips:all"}).
{ok,b746wle}
2> nksip_uac:options(test1, "sip:sip2sip.info", []).
{ok,200,[]}
```


You can check now the tutorial and sample applications on [nksip_samples](https://github.com/NetComposer/nksip_samples).

# Contributing

Please contribute with code, bug fixes, documentation fixes, testing with SIP devices or any other form. Use 
GitHub Issues and Pull Requests, forking this repository.

