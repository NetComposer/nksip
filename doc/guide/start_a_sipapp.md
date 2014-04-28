# Starting a SipApp

A SipApp is a SIP entity NkSIP starts for you, that starts listening on one or several sets of transport (UDP, TCP, TLS, SCTP, WS and WSS currently), ip address and port. After starting it, you can [send any SIP request](sending_requests.md), and, when any other SIP entity [sends you a request](receiving_requests.md) NkSIP will notify you so that you can process it and [send an answer](sending_responses.md).

You must first create a _callback Erlang module_ (for very simple applications, you can use the default callback module included with NkSIP, [_nksip_sipapp_](../../src/nksip_sipapp.erl)). The callback module can implement any callback function from the list of NkSIP SipApp's [callback functions](../reference/callback_functions.md). You can take a look to the [`nksip_sipapp`](../../src/nksip_sipapp.erl) module to find the default implementation of each of them.

Once defined the callback module, call `nksip:start/4` to start the SipApp:
```erlang
> nksip:start("my_app", nksip_sipapp, [], [{transports, [{udp, {127,0,0,1}, 5060}]}]).
{ok,ac0a6o5}
```

* You can name you new SipApp whatever you want, using any valid Erlang type, but NkSIP will generate a _internal name_ as an _atom_, based on a hash over your application name (`ac0a6o5` in the example). In most NkSIP functions you can use any of them to refer to your SipApp, but the internal format is faster.
* The second argument should be the name of a valid, already loaded Erlang module implementing the SipApp's _callback module_. 
* The third argument refers to the initial arguments to be sent to `init/1` callback function, and is described later in this page.
* The fourth argument refers to the list of options you want configure your application with, defined in the [reference page](../reference/configuration.md).

After starting your SipApp, you can send any request:
```erlang
> nksip_uac:options("my_app", "sip:sip2sip.info", []).
{ok,200,[]}
```

or 

```erlang
> nksip_uac:options(ac0a6o5, "sip:sip2sip.info", []).
{ok,200,[]}
```

If another entity sends you a SIP request to one of your listening addresses, NkSIP will call one or several functions in your _callback module_, if implemented. For example, for an _OPTIONS_ request it will call your `options/3` callback function, among others.


## SipApp Implementation

The first time you start a SipApp, NkSIP will generate a new RFC4122 compatible _UIID_ (used in SIP registrations), and will save to disk in a file with the same name of the internal application (see configuration options for the default directory).

Each started SipApp is modelled in NkSIP with a standard _gen&#95;server_ process. If you define the [_init/1_](../reference/callback_functions.md#init1) callback function in your _callback module_, NkSIP will call in on starting the SipApp, using the third argument in the call to `nksip:start/4`. The returning value will become the initial state value, associated with the gen_server process.

If you implement callback functions [_handle_call/3_](../reference/callback_functions.md#handle_call3), [_handle_cast/2_](../reference/callback_functions.md#handle_cast2) or [_handle_info/2_](../reference/callback_functions.md#handle_info2), this will be the value that will be passed as state, and you will have the opportunity to change it.


## Saving state information

SipApps' can use two different methos to store specific application information:
* SipApp variables
* SipApp gen_server state

### SipApp Variables
Yon can store any Erlang term under any key (which can be any Erlang term also) using `nksip:put/3`, `nksip:get/2,3` and `nksip:del/2` (see [SipApp API](../reference/sipapp_api.md)). NkSIP uses a standard Erlang _ETS table_ for storage, and it will destroyed when you stop the SipApp.

You can call these functions from any point, inside or outside a callback functions. Keep in mind that, as and ETS table, if you are calling them from simultaenous processes (as it will happen from callback functions belonging to different calls) there is no guarantee that any call will be processed before another. If you want to control that, you can call them from inside the SipApp's gen_server process, using nksip:cal/2,3 or nksip:cast/2, and calling `nksip:put/3`, `nksip:get/2,3` and `nksip:del/2` from inside the `handle_call` or _handle_cast` callback function.








 


















NkSIP will call `init/1' inmediatly (if defined). From this moment on, you can start sending requests using the functions in `nksip_uac` When a incoming request is received in our SipApp (sent from another SIP endpoint or proxy), NkSIP starts a process to manage it. This process starts calling specific functions in the SipApp's callback module as explained in `nksip_sipapp`.

Should the SipApp process stop due to an error, it will be automatically restarted 
by its supervisor, but all the stored SipApps variables would be lost.

Please notice that it is not necessary to tell NkSIP which kind of SIP element 
your SipApp is implementing. For every request, depending on the return of 
the call to your `route/6` callback function, NkSIP will act as an endpoint, B2BUA or proxy, request by request. 

You can now start [sending requests](sending_requests.md) and [receiving requests and sending responses](receiving_requests.md).


## Reconfigure the SipApp

You can change any configured parameter for the SiApp at any time, on the fly.
