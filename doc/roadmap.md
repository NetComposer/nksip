# Roadmap

## v0.4

* ~~Documentation improvement~~.
* ~~Extraction of non-core functionality into plugins~~.
* ~~**Powerful plugin mechanism**~~.
* ~~New UAS API~~
* ~~Reliable provisional responses~~.
* ~~UPDATE and MESSAGE methods~~.
* ~~Full event support (SUBSCRIBE/NOTIFY)~~.
* ~~Full PUBLISH support, using in-memory or external database~~.
* ~~RFC4028 Session Timers~~
* ~~Outbound (RFC5626) and GRUU (RFC5627) support~~.
* ~~Path support, as client, proxy and registrar~~.
* ~~SIP-over-Websockets support, as a server and as a client!~~
* ~~Reason header support in request and responses.~~ 
* ~~Service-Route header support~~.
* ~~Support for headers in URIs~~.
* ~~UAS callback functions receive contextual metadata~~.
* ~~New options to customize supported extensions and to generate Require and Accept headers~~.
* ~~Use of any external store for registrar instead of in-memory built-in~~.
* ~~Allow an endpoint to start a dialog with itself~~.
* ~~Bug corrections~~.


## v0.5 (next version from master)

* ~~Test in R17~~
* ~~Extraction of non-SIP functionality into a new Erlang project, NkCore~~ (they have been extracted into three projects: [NkLIB](https://github.com/Nekso/nklib), [NkPACKET](https://github.com/Nekso/nkpacket) and [NkSERVICE](https://github.com/Nekso/nkservice).


## v0.6 (next version from development)

* Maps everywhere
* External control (to be able to use NkSIP without having to use Erlang or outside of the NkSIP Erlang VM).
* Heavy testing


## No date

* _Bridge_ support for B2BUA.
* IMS and RCS extensions.
* More application examples.
* Better statistics support.
* Admin web console.
* Flood control.
* Congestion control.
* Extract examples into new repository.
* [RFC3891](http://tools.ietf.org/html/rfc3891): Replaces
* [RFC3892](http://tools.ietf.org/html/rfc3892): Referred-By
* [RFC3911](http://tools.ietf.org/html/rfc3903): Join
* [RFC4320](http://tools.ietf.org/html/rfc4320): Invite transactions
* [RFC4321](http://tools.ietf.org/html/rfc4321): Invite recomendations
* [RFC4488](http://tools.ietf.org/html/rfc4488): REFER without subscription
* [RFC4538](http://tools.ietf.org/html/rfc4538): Dialog authorization


# Other features

The future distributed and highly available features of NkSIP will be developed in a new, much more ambitious project, [NetComposer.io](http://www.slideshare.net/carlosjgf/net-composer-v2).

Please contact carlosj.gf@gmail.com for details.









