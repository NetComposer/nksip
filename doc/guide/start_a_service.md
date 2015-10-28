# Starting a Service

* [Starting a Service](#starting-a-service)
* [Implementation](#service-implementation)
* [Saving State](#saving-state-information)
* [Reconfiguration](#reconfigure-the-service)


## Starting a Service
A _Service_ is a SIP entity that starts listening on one or several sets of transport (UDP, TCP, TLS, SCTP, WS or WSS currently), ip address and port. After starting it, you can [send any SIP request](sending_requests.md), and, when any other SIP entity [sends you a request](receiving_requests.md) NkSIP will notify you so that you can process it and send an answer.

You can create a _callback Erlang module_ (for very simple or outbound-only applications, you can omit the callback module). The callback module can implement any callback function from the list of NkSIP service's [callback functions](../reference/callback_functions.md). You can take a look to the [`nksip_callbacks`](../../src/nksip_callbacks.erl) module to find the default implementation of each of them.

Once defined the callback module, call [`nksip:start/2`](../../src/nksip.erl) to start the service:
```erlang
> nksip:start("my_app", #{transports=>"sip:127.0.0.1:5060"}).
{ok,ac0a6o5}
```

* You can use any Erlang term you want to name your service, but NkSIP will generate a _internal name_ as an `atom()`, based on a hash over your application name (`ac0a6o5` in the example). In most NkSIP functions you can use any of them to refer to your service, but the internal format is faster.
* The second argument refers to the list of options you want configure your application with, defined in the [reference page](../reference/configuration.md).

After starting your service, you can send any request:
```erlang
> nksip_uac:options("my_app", "sip:sip2sip.info", []).
{ok,200,[]}
```

If another entity sends you a SIP request to one of your listening addresses, NkSIP will call one or several functions in your _callback module_, if implemented. For example, for an _OPTIONS_ request it will call your [sip_options/2](../reference/callback_functions.md#sip_options2) callback function, among others.


## Service Implementation

The first time you start a service, NkSIP will generate a new RFC4122 compatible _UUID_ (used for example in SIP registrations), and will save it to disk in a file with the same name of the internal application (see configuration options for the default directory).

Each started service is under the hood a OTP-like _gen&#95;server_ process. If you define the [`init/2`](../reference/callback_functions.md#init2) callback function in your _callback module_, NkSIP will call it while starting the service, sending to it the same arguments used when calling `nksip:start/2`. The returning value can modify the current service state.

Similar to a gen_server process, you can use functions like `gen_server:call/3` or `gen_server:cast/2`. The registered name of the process is the same atom as the internal application name. If you implement callback functions [`handle_call/3`](../reference/callback_functions.md#handle_call3), [`handle_cast/2`](../reference/callback_functions.md#handle_cast2) or [`handle_info/2`](../reference/callback_functions.md#handle_info2), they will called as in a standard gen_server behaviour (when someone calls `gen_server:call/2,3`, `gen_server:cast/2` or the process receives a message). The state management is special, since it is always an erlang map.

Should the service process stop due to an error, it will be automatically restarted by its supervisor.


## Saving state information

NkSIP offers services two different methods to store specific runtime application information:
* Service variables
* Service gen_server state


### Service Variables
Yon can store, read and delete _any Erlang term_ under _any key_ calling [nkservice_server:put/3](../api/service.md#put3), [nkservice_server:get/2,3](../api/service.md#get2) and [nkservice_server:del/2](../api/service.md#del2) API functions. NkSIP uses a standard Erlang _ETS table_ for storage, and it will destroyed when you stop the Service.

You can call these functions from any point, inside or outside a callback function. Keep in mind that, as and ETS table, if you are calling them from simultaenous processes (as it will happen from callback functions belonging to different calls) there is no guarantee that any call will be processed before another. You shouldn't, for example, read a value and store a modified version later on with a key that another call can also use, because another process could have changed it in between. If you want to control access using shared keys, you can call them from inside the Service's gen_server process, using `nkservice_server:call/2,3` or `nkservice_server:cast/2`, and calling `nkservice_server:put/3`, `nkservice_server:get/2,3` and `nkservice_server:del/2` from inside the `handle_call` or `handle_cast` callback function.

The ETS table is associated to the Service's supervisor process, so it will not be lost in case your application fails and it is restarted by the supervisor. It will be lost when stopping the Service.


### Service gen_server state
You can also use the state stored in the gen_server process, following the a procedure similar to the OTP pattern. The initial state is generated by the server and sent to the callback `init/2`, where you can add keys to the map. You should call `gen_server:call/2,3` or `gen_server:cast/2` from your callbacks functions, or send any message to the registered application name, and NkSIP will call again your `handle_call/3`, `handle_cast/2` or `handle_info/2` with the current state, so that you can access it and change it necessary.

Keep in mind that if your are receiving heavy traffic this can be a bottleneck, as all callbacks must wait for the gen_server process. Also if the application fails and the supervisor restarts the gen_server process the state would be lost.


## Reconfigure the Service
You can change any configured parameter for the service at any time, on the fly, except for new transports specifications. You only need to call [nksip:update/2](../api/server.md#update2) to update any configuration parameter.
