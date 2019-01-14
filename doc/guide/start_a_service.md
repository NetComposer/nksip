# Starting a Service

* [Starting a Service](#starting-a-service)
* [Implementation](#service-implementation)
* [Saving State](#saving-state-information)
* [Reconfiguration](#reconfigure-the-service)


## Starting a Service
A _Service_ is a SIP entity that starts listening on one or several sets of transport (UDP, TCP, TLS, SCTP, WS or WSS currently), ip address and port. After starting it, you can [send any SIP request](sending_requests.md), and, when any other SIP entity [sends you a request](receiving_requests.md) NkSIP will notify you so that you can process it and send an answer.

You must _name_ your service with an Erlang _atom_, that will be used also as a callback module, if available (for very simple or outbound-only applications, you can omit the callback module). The callback module can implement any callback function from the list of NkSIP service's [callback functions](../reference/callback_functions.md). You can take a look to the [`nksip_callbacks`](../../src/nksip_callbacks.erl) module to find the default implementation of each of them.

Once defined the callback module, call [`nksip:start_link/2`](../../src/nksip.erl) to start the service:
```erlang
> nksip:start_link(my_sip_service, #{sip_listen=>"sip:127.0.0.1:5060"}).
{ok, <pid>}
```

The started service is really an Erlang supervisor that is linked to the calling process. You can also get it as a supervisor child specification to include it in your application supervisor tree:

```erlang
> nksip:get_sup_spec(my_sip_service, #{sip_listen=>"sip:127.0.0.1:5060"}).
{ok, ...}
```

The second argument refers to the list of options you want configure your application with, defined in the [reference page](../reference/configuration.md).

After starting your service, you can send any request:
```erlang
> nksip_uac:options(my_sip_service, "sip:sip2sip.info", []).
{ok,200,[]}
```

If another entity sends you a SIP request to one of your listening addresses, NkSIP will call one or several functions in your _callback module_, if implemented. For example, for an _OPTIONS_ request it will call your [sip_options/2](../reference/callback_functions.md#sip_options2) callback function, among others.


## Reconfigure the Service
You can change any configured parameter for the service at any time, on the fly. You only need to call [nksip:update/2](../api/service.md#update2) to update any configuration parameter.
