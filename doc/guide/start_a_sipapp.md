# Starting

First of all, you have to start the main NkSIP application (`nksip` Erlang application). You will usually embed nksip into your own Erlang application (using `rebar`). For testing, you can use:

```
git clone git https://github.com/kalta/nksip
> cd nksip
> make
> make shell
```

your are now in a normal Erlang shell and can start your own application.

## Starting a SipApp

To start your own SipApp you must use `nksip:start/4`. NkSIP can start any number of SipApps, each one listening on one or several sets of ip, port and transport (UDP, TCP, TLS, SCTP, WS and WSS currently).

You must first create a _callback module_ (you can also use the default callback module included with NkSIP, defined in the `nksip_sipapp` module). The callback module can implement a number of 
optional callbacks functions (have a look at `nksip_sipapp` to find out the currently available callbacks and default implementation for each of them).

Once defined the callback module, call `start/4` to start the SipApp. There is a number of possible options to configure the newly started SipApp, defined in the [reference page](../reference/start_options.md).

NkSIP will call `init/1' inmediatly (if defined). From this moment on, you can start sending requests using the functions in `nksip_uac` When a incoming request is received in our SipApp (sent from another SIP endpoint or proxy), NkSIP starts a process to manage it. This process starts calling specific functions in the SipApp's callback module as explained in `nksip_sipapp`.

Should the SipApp process stop due to an error, it will be automatically restarted 
by its supervisor, but all the stored SipApps variables would be lost.

Please notice that it is not necessary to tell NkSIP which kind of SIP element 
your SipApp is implementing. For every request, depending on the return of 
the call to your `route/6` callback function, NkSIP will act as an endpoint, B2BUA or proxy, request by request. 

You can now start [sending requests](sending_requests.md) and [receiving requests and sending responses](receiving_requests.md).


## Reconfigure the SipApp

You can change any configured parameter for the SiApp at any time, on the fly.