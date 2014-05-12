# Receiving Requests

Once started a SipApp with a name, a _callback module_ and a group of options, it starts listening on a set of transports, ip addresses and ports, and can start receiving requests from other SIP endpoints. For each received request, NkSIP will call specific functions in your callback module. The full list of callback functions is described in [Callback Functions](../reference/callback_functions.md) and the default implementation of each one is in the [nksip_sipapp.erl](../../src/nksip_sipapp.erl) module.

All of the callback functions are optional, so you only have to implement the functions you need. For example, if you need to perform authentication, you should implement [sip_authorize/3](../reference/callback_functions.md#authorize3). If you don't implement it, no authorization would be done.

There are currently three different kinds of callbacks:
* [_gen_server_ callbacks](#gen_server-callbacks)
* [sip callbacks](#sip-callbacks)
* [other callbacks](other-callbacks)

## _gen_server_ Callbacks

Under the hood, each started SipApp starts a new standard OTP _gen_server_ process, registered under the same _internal name_ of the SipApp.

Its state is created while starting the SipApp, in the call to [init/1](../reference/callback_functions.md#init1), and can used and modified in the callbacks [handle_call/3](../reference/callback_functions.md#handle_call3), [handle_cast/2](../reference/callback_functions.md#handle_cast2) and [handle_info2](../reference/callback_functions.md#handle_info2). You can use this process as a standar OTP gen_server process for your application, for example to control the concurrent access to resources, like the ETS supporting the SipApp variables.

When you (or any other process by the matter) calls `gen_server:call/2,3`, `gen_server:cast/2` or sends a message to the registered application's process (the same as the _internal name_), NkSIP will call [handle_call/3](../reference/callback_functions.md#handle_call3), [handle_cast/2](../reference/callback_functions.md#handle_cast2) and [handle_info2](../reference/callback_functions.md#handle_info2).

The list of available gen_server callbacks functions is available [here](../reference/callback_functions.md#gen_server-callbacks).



## SIP Callbacks

When a new request is received, NkSIP will extract the _Call-ID_ header, to see if a process to manage that specific call has already been started, sending the request to it to be processed. If it is not yet started, a new one is launched, associated to this specific Call-ID. This process will then start start calling specific functions in the callback module defined when the SipApp was started. 

Some of these functions allow you to send a response back, while others expect a authorization or routing decision or are called to inform the SipApp about a specific event and don't expect any answer. 

In all of the cases, **you shouldn't spend a long time inside them** (more than a few miliseconds), because new requests and retransmissions having the same Call-ID would be blocked until the callback function returns. INVITE processing could take a long time since it can be necessary for the user to manually accept the call, see [invite/2](../reference/callback_functions.md#invite2) documentation.

Many callback functions receive some of the following arguments:
* Request: represents a full #sipmsg{} structure. 
* Call: represents the full #call{} process state. 
* Dialog: represents a specific dialog (#dialog{}) associated to this request.
* Subscription: represents a specific subscription (#subscription{}) associated to a specific dialog.

In all cases you should use the functions in [the API](api.md) to extract information from these objects and not use them directly, as its type can change in the future. In case you need to spawn a new process, it is recommended that you don't pass any of these objects to the new process, as they are quite heavy. You should extract a _handler_ for each of them and pass it to the new process.

A typical call order would be the following:
* When a request is received having an _Authorization_ or _Proxy-Authorization_ header, [sip_get_user_pass/4](../reference/callback_functions.md#sip_get_user_pass/4]) is called to check the user`s password.
* NkSIP calls [sip_authorize/3](../reference/callback_functions.md#sip_authorize3) to check if the request should be authorized.
* If authorized, it calls [sip_route/5](../reference/callback_functions.md#sip_route5) to decide what to do with the request: proxy, reply or process it locally.
* If the request is going to be processed locally, [sip_invite/2](../reference/callback_functions.md#invite2), [sip_options/2](../reference/callback_functions.md#options2), [sip_register/2](../reference/callback_functions.md#register2) etc., are called depending on the incoming method, and the user must send a reply. If the request is a valid _CANCEL_, belonging to an active _INVITE_ transaction, the INVITE is cancelled and [sip_cancel/3](../reference/callback_functions.md#sip_cancel3) is called. After sending a successful response to an _INVITE_ request, the other party will send an _ACK_ and [sip_ack/2](../reference/callback_functions.md#sip_ack2) will be called.
* If the request creates or modifies a dialog and/or a SDP session, [sip_dialog_update/3](../reference/callback_functions.md#sip_dialog_update3) and/or [sip_session_update/3](../reference/callback_functions.md#sip_session_update3) are called.
* If the remote party sends an in-dialog invite (a _reINVITE_), NkSIP will call [sip_reinvite/2](../reference/callback_functions.md#sip_reinvite2) if it is defined, or [sip_invite/2](../reference/callback_functions.md#sip_invite_2) again if not.

Many of the functions in this group allow you to send a response to the incoming request. NkSIP allows you to use easy response codes like `busy`, `redirect`, etc. Specific responses like `authenticate` are used to send an authentication request to the other party. In case you need to, you can also reply any response code, headers, and body. It is also possible to send _reliable provisional responses_, that the other party will acknoledge with a _PRACK_ request. All of it is handled by NkSIP automatically.

The list of available SIP callbacks functions is available [here](../reference/callback_functions.md#sip-callbacks).


## Other Callbacks

There are other callbacks that are not related to the gen_server process nor the call process.
The list of the rest of callbacks functions is available [here](../reference/callback_functions.md#other-callbacks).
