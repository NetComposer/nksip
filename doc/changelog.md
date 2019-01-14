# Changelog

## Current (main branch)

* Another really big refactorization
* Everything updated to Erlang 21 and rebar3
* Switched form NkSERVER to NkSERVER, as a (much simpler) core
* Important changes in NkPACKET


## [0.5.0](https://github.com/kalta/nksip/releases/tag/v0.5.0)

* Massive refactorization, removing 21 files and 2.500 changes in the code. All non-SIP functionality has been extracted into other projects (NkLIB, NkPACKET and NkSERVER).
* SipApps converted to Services.
* New configuration system.
* New plugin system.
* Allow for Services without callback module (only for outgoing SIP applications).
* Added offset time to subscriptions (Thanks Luis Azedo).
* Removed no reg-id test for GRUUs (Thanks James Van Vleet).
* Minimum Erlang version is now 17.0.


## [0.4.0](https://github.com/kalta/nksip/releases/tag/v0.4.0)
 
* Extraction of non-core functionality intro plugins.
* New UAS API.
* Powerful plugin mechanism.
* Reliable provisional responses.
* UPDATE and MESSAGE methods.
* Full event support (SUBSCRIBE/NOTIFY).
* Full PUBLISH support, using in-memory or external database.
* RFC4028 Session Timers
* Outbound (RFC5626) and GRUU (RFC5627) support.
* Path support, as client, proxy and registrar.
* SIP-over-Websockets support, as a server and as a client!
* Reason header support in request and responses. 
* Service-Route header support.
* Support for headers in URIs.
* UAS callback functions receive contextual metadata.
* New options to customize supported extensions and to generate Require and Accept headers.
* Use of any external store for registrar instead of in-memory built-in.
* Allow an endpoint to start a dialog with itself.
* Bug corrections.



## [0.3.0](https://github.com/kalta/nksip/releases/tag/v0.3.0)
 
* Full NAPTR/SRV caching resolver.
* Outbound connection controller.
* INFO Method.
* SCTP transport.
* IPv6.
* New parsers fully RFC4476 _Torture Tests_ compliant.
* Bug corrections.


## [0.2.0](https://github.com/kalta/nksip/releases/tag/v0.2.0)

* SIP message processing engine rewrite
* Heavy API changes
* Inline callback functions
* Bug corrections


## [0.1.0](https://github.com/kalta/nksip/releases/tag/v0.1.0)

* Initial release


