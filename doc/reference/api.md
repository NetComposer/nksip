# SipApps callback functions

Each SipApp must provide a _callback module_. The functions this callback module can implement are described here. The default implementation of each one can be reviewed in [nksip_sipapp.erl](../../src/nksip_sipapp.erl)

Depending on the phase of the request processing, different functions will be called. Some of these calls expect an answer from the SipApp to continue the processing, and some others are called to inform the SipApp about a specific event and don`t expect any answer. 

Except for `init/1`, all defined functions belong to one of two groups: _expected answer_ functions and _no expected answer_ functions.

The supported return values for _expected answer functions_ are:
```erlang
  call_reply() :: 
      {noreply, State} | {noreply, State, Timeout} | 
      {reply, Reply, State} | {reply, Reply, State, Timeout} | 
      {stop, Reason, State} | {stop, Reason, Reply, State}
      when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term()
```     

The function is expected to return `State` as new SipApp user`s state and a `Reply`, whose meaning is specific to each function and it is described bellow. If a `Timeout` is defined the SipApp process will receive a `timeout` message after the indicated milliseconds period (you must implement `handle_info/2` to receive it. If the function returns `stop` the SipApp will be stopped. If the function does not want to return a reply just know, it must return `{noreply, State}` and call `nksip:reply/2` later on, possibly from a different spawned process.

The supported return values for _no expected answer functions_ are:
```erlang
  call_noreply() :: 
      {noreply, State} | {noreply, State, Timeout} | 
      {stop, Reason, State} 
      when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term()
```

Some of the callback functions allow the SipApp to send a response back to the calling party. See the available responses in [sending responses](sending_responses.md).

A typical call order would be the following:
* When starting the SipApp, `init/1` is called to initialize the application state.
* When a request is received having an _Authorization_ or _Proxy-Authorization_ header, `get_user_pass/3` is called to check the user`s password.
* NkSIP calls `authorize/4` to check is the request should be authorized.
* If authorized, it calls `route/6` to decide what to do with the request: reply, route or process locally.
* If the request is going to be processed locally, `invite/3`, `options/3`, `register/3` or `bye/3` are called, and the user must send a reply. If the request is a valid _CANCEL_, belonging to an active _INVITE_ transaction, the INVITE is cancelled and `cancel/2` is called.
* After sending a successful response to an _INVITE_ request, the other party will send an _ACK_ and `ack/3` will be called.
* If the request creates or modifies a dialog and/or a SDP session, `dialog_update/3` and/or `session_update/3` are called.
* If the remote party sends an in-dialog invite (a _reINVITE_), NkSIP will call `reinvite/3`.
* If the user has set up an automatic ping or registration, `ping_update/3` or `register_update/3` are called on each status change.
* When the SipApp is stopped, `terminate/2` is called.

It is **very important** to notice that, as in using normal `gen_server`, there is a single SipApp core process, so you must not spend a long time in any of the callback functions. If you do so, new requests arriving at your SipApp will be blocked and the other party will start to send retransmissions. As no transaction has been created yet, NkSIP will see them as new requests that will be also blocked, and so on.

If the expected processing time of any of your callback functions is high (more than a few milliseconds), you must spawn a new process, return `{noreply, ...}` and do any time-consuming work there. If the called function spawning the process is in the expected answer group, it must call `nksip:reply/2` from the spawned process when a reply is available. Launching new processes in Erlang is a very cheap operation, so in case of doubt follow this recommendation.

Many of the callback functions receive a `RequestId` (`nksip:id()`) and a `Meta` (a list of properties) parameters. Depending on the function, `Meta` will contain the most useful parameters you
will need to process the request (like de content-type and body). You can use `ReqId` to obtain any oher parameter from the request or dialog, using the helper funcions in `nksip_request` and `nksip_dialog`.

### Inline functions

NkSIP offers another option for defining callback functions. Many of them have an _inline_ form, which, if defined, it will be called instead of the _normal_ form.

Inline functions have the same name of normal functions, but they don`t have the last `State` parameter. They are called in-process, inside the call processing process and not from the SipApp`s process like the normal functions.

Inline functions are much quicker, but they can`t modify the SipApp state. They received a full `nksip:request()` object in `Meta`, so it can use the functions in `nksip_sipmsg` to process it. See `inline_test` for an example of use


# Callbacks

Callback|Reason
---|---
[init/1](#init1)|Called when the SipApp is launched using `nksip:start/4`
[terminate/2](#terminate2)|Called when the SipApp is stopped
[get_user_pass/3](#get_user_pass3)|Called to check a user password for a realm
[authorize/4](#authorize4)|Called for every incoming request to be authorized or not
[route/6](#route6)|Called to route the request
[invite/4](#invite4)|Called to process a new out-of-dialog INVITE request
[reinvite/4](#reinvite4)|Called to process a new in-dialog INVITE request
[cancel/3](#cancel3)|Called when a pending INVITE request is cancelled
[ack/4](#ack4)|Called by NkSIP when a new valid in-dialog ACK request has to be processed locally
[bye/4](#bye4)|Called to process a BYE request
[update/4](#update4)|Called to process a UPDATE request
[info/4](#info4)|Called to process a INFO request
[options/4](#options4)|Called to process a OPTIONS request
[register/4](#register4)|Called to process a REGISTER request
[prack/4](#prack4)|Called to process a PRACK request
[subscribe/4](#subscribe4)|Called to process a new out-of-dialog SUBSCRIBE request
[resubscribe/4](#resubscribe4)|Called to process a new in-dialog SUBSCRIBE request
[notify/4](#notify4)|Called to process a NOTIFY request
[message/4](#message4)|Called to process a MESSAGE request
[refer/4](#refer4)|Called to process a REFER request
[publish/4](#publish4)|Called to process a PUBLISH request
[dialog_update/3](#dialog_update3)|Called when a dialog's state changes
[session_update/3](#session_update3)|Called when a SDP session is created or updated
[ping_update/3](#ping_update3)|Called when an automatic ping state changes
[register_update/3](#register_update3)|Called when an automatic registration state changes
[handle_call/3](#handle_call3)|Called when a direct call to the SipApp process is made using `nksip:call/2` or `nksip:call/3`
[handle_cast/2](#handle_cast2)|Called when a direct cast to the SipApp process is made using `nksip:cast/2`
[handle_info/2](#handle_info2)|Called when a unknown message is received at the SipApp process
[registrar_store_op/3](#registrar_store_op3)|Called when a operation database must be done on the registrar database
[publish_store_op/3](#publish_store_op3)|Called when a operation database must be done on the publisher database


## init/1
This callback function is called when the SipApp is launched using `nksip:start/4`.
If `{ok, State}` or `{ok, State, Timeout}` is returned the SipApp is started with this initial state. If a `Timeout` is provided (in milliseconds) a `timeout` message will be sent to the process 
(you will need to implement `handle_info/2` to receive it). If `{stop, Reason}` is returned the SipApp will not start. 

```erlang
-spec init(Args::term()) ->
    init_return().

init([]) ->
    {ok, {}}.
```


## terminate/2
Called when the SipApp is stopped.

```erlang
-spec terminate(Reason::term(), State::term()) ->
    ok.

terminate(_Reason, _State) ->
    ok.
```


## get_user_pass/3
Called to check a user password for a realm.

When a request is received containing a `Authorization` or `Proxy-Authorization` header, this function is called by NkSIP including the headers `User` and `Realm`, to check if the authorization data in the header corresponds to the user`s password. 

You should normally reply with the user's password (if you have it for this user and realm). NkSIP will use the password and the digest information in the header to check if it is valid, offering this information in the call to `authorize/4`. 

You can also reply `true` if you want to accept any request from this user without checking any password, or `false` if you don`t have a password for this user or want her blocked.

If you don't want to store _clear-text_ passwords of your users, you can use `nksip_auth:make_ha1/3` to generate a _hash_ of the password for an user and a realm, and store only this hash instead of the real password. Later on you can reply here with the hash instead of the real password.

If you don't define this function, NkSIP will reply with password `<<>>` if user is `anonymous`, and `false` for any other user. 

```erlang
-spec get_user_pass(User::binary(), Realm::binary(), State::term()) ->
    {reply, Reply, NewState}
    when Reply :: true | false | binary(), NewState :: term().

get_user_pass(<<"anonymous">>, _, State) ->
    {reply, <<>>, State};
get_user_pass(_User, _Realm, State) ->
    {reply, false, State}.
```


## authorize/4
Called for every incoming request to be authorized or not.

If `ok` is replied the request is authorized and the request processing continues. If `authenticate` is replied, the request will be rejected (statelessly) with a 401 _Unauthorized_. The other party will usually send the request again, this time with an `Authorization` header. If you reply `proxy_authenticate`, it is rejected with a 407 _Proxy Authentication Rejected_ response and the other party will include a `Proxy-Authorization` header.

You can use the tags included in `AuthList` in order to decide to authenticate or not the request. `AuthList` includes the following tags:
* `dialog`: the request is in-dialog and coming from the same ip and port than the last request for an existing dialog.
* `register`: the request comes from the same ip, port and transport of a currently valid registration (and the method is not _REGISTER_).
* `{{digest, Realm}, true}`: there is at least one valid user authenticated (has a correct password) with this `Realm`.
* `{{digest, Realm}, false}`: there is at least one user offering an authentication header for this `Realm`, but all of them have failed the authentication (no password was valid). 

You will usually want to combine these strategies. Typically you will first check using SIP digest authentication, and, in case of faillure, you can use previous registration and/or dialog authentication. 

If you don't define this function all requests will be authenticated.

```erlang
-spec authorize(ReqId::nksip:id(), AuthList, From::from(), State::term()) ->
    call_reply(ok | authenticate | proxy_authenticate | forbidden)
    when AuthList :: [dialog|register|{{digest, Realm::binary}, boolean()}].

authorize(_ReqId, _AuthList, _From, State) ->
    {reply, ok, State}.
```

## route/6
This function is called by NkSIP for every new request, to check if it must be proxied, processed locally or replied immediately. 
For convenience, the scheme, user and domain parts of the _Request-Uri_ are included.

If we want to **act as a proxy** and route the request, and we are not responsible for `Domain` we must return `proxy` or `{proxy, ruri, ProxyOpts}`. We must not return an `UriSet` in this case. NkSIP will then make additional checks to the request (like inspecting the `Proxy-Require` header) and will route it statefully to the same `Request-URI` contained in the request.

If we are the responsible proxy for `Domain` we can provide a new list of URIs to route the request to. NkSIP will use **_serial_** and/or **_parallel_** _forking_ depending on the format of `UriSet`. If `UriSet` is a simple Erlang array of binaries representing uris, NkSIP will try each one serially. If any of the elements of the arrary is in turn a new array of binaries, it will fork them in parallel. 
For example, for  `[ <<"sip:aaa">>, [<<"sip:bbb">>, <<"sip:ccc">>], <<"sip:ddd">>]` NkSIP will first forward the request to `aaa`. If it does not receive a successful (2xx) response, it will try `bbb` and `cccc` in parallel. If no 2xx is received again, `ddd` will be tried. See `nksip_registrar` to find out how to get the registered contacts for this `Request-Uri`.

Available options for `ProxyOpts` are:
* `stateless`: Use it if you want to proxy the request _statelessly_. Only one URL is allowed in `UriSet` in this case.
* `record_route`: NkSIP will insert a _Record-Route_ header before sending the request, so that following request inside the dialog will be routed to this proxy.
* `path`: For REGISTER requests, if the request includes "path" as part of the supported tokens, it will insert a _Path_ header (see RFC3327). If path it is not supported, it will reply a 421 _Extension Required_ response.
* `follow_redirects`: If any 3xx response is received, the received contacts will be inserted in the list of uris to try.
* `{route, nksip:user_uri()}`: NkSIP will insert theses routes as _Route_ headers in the request, before any other existing `Route` header. The request would then be sent to the first _Route_.
* `{headers, [nksip:header()]}`: Inserts these headers before any existing header.
* `remove_routes`: Removes any previous _Route_ header in the request. A proxy should not usually do this. Use it with care.
* `remove_headers`: Remove previous non-vital headers in the request. You can use modify the headers and include them with using `{headers, Headers}`. A proxy should not usually do this. Use it with care.

You can also add headers to the request if the URI contains a _Route_ header.

If we want to **act as an endpoint or B2BUA** and answer to the request from this SipApp, we must return `process` or `{process, ProcessOpts}`. NkSIP will then make additional checks to the request (like inspecting `Require` header), start a new transaction and call the function corresponding to the method in the request (like `invite/3`, `options/3`, etc.)

Available options for `ProcessOpts` are:
* `stateless`: Use it if you want to process this request _statelessly_. No transaction will be started.
* `{headers, [nksip:header()]}`: Insert these headers before any existing header, before calling the next callback function.

We can also **send a reply immediately**, replying `{response, Response}`, `{response, Response, ResponseOpts}` or simply `Response`. See `nksip_reply` to find the recognized response values. The typical reason to reply a response here is to send <b>redirect</b> or an error like `not_found`, `ambiguous`, `method_not_allowed` or any other. If the form `{response, Response}` or `{response, Response, ResponseOpts}` is used the response is sent statefully, and a new transaction will be started, unless `stateless` is present in `ResponseOpts`.

If simply `Response` is used no transaction will be started. 
The only recognized option in `ResponseOpts` is `stateless`.

If route/3 is not defined the default reply would be `process`.

```erlang
-type route_reply() ::
    proxy | {proxy, ruri | nksip:uri_set()} | 
    {proxy, ruri | nksip:uri_set(), nksip_lib:optslist()} | 
    process | {process, nksip_lib:optslist()} |
    {response, nksip:sipreply()} | 
    {response, nksip:sipreply(), nksip_lib:optslist()}.

-spec route(ReqId::nksip:id(), Scheme::nksip:scheme(), 
            User::binary(), Domain::binary(), From::from(), State::term()) ->
    call_reply(route_reply()).

route(_ReqId, _Scheme, _User, _Domain, _From, State) ->
    {reply, process, State}.
```

## invite/4
This function is called by NkSIP to process a new INVITE request as an endpoint.

`Meta` will include at least the following parameters: aor, dialog_id, content_type and body (see `nksip_request` for details). If content-type is `application/sdp` the body will be decoded as a `nksip_sdp:sdp()` object you can manage with the functions in `nksip_sdp`.

Before replying a final response, you will usually call `nksip_request:reply/3` to send a provisional response like `ringing` (which would send a 180 _Ringing_ reply) or `ringing_rel` to send
a _reliable provisional response_.

If a quick response (like `busy`) is not going to be sent immediately (which is typical for INVITE requests, as the user would normally need to accept the call) you must return `{noreply, NewState}` and spawn a new process, calling `nksip:reply/2` from the new process, in order to avoid blocking the SipApp process.

You must then answer the request. The possible responses are defined in `nksip_reply`.
If a successful (2xx) response is sent, you should include a new generated SDP body in the response. A new dialog will then start. The remote party should then send an ACK request immediately. If none is received, NkSIP will automatically stop the dialog.

```erlang
-spec invite(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

invite(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


## reinvite/4
This function is called when a new in-dialog INVITE request is received.

The guidelines and `Meta` in `invite/4` are still valid, but you shouldn`t send provisional responses, sending a final response inmediatly.

If the dialog's target or the SDP session parameters are updated by the request or its response, `dialog_update/3` and/or `session_update/3` would be called.

```erlang
-spec reinvite(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

reinvite(_ReqId, _Meta, __From, State) ->
    {reply, decline, State}.
```


## cancel/3
Called when a pending INVITE request is cancelled.

When a CANCEL request is received by NkSIP, it will check if it belongs to an existing INVITE transaction. If not, a 481 _Call/Transaction does not exist_ will be automatically replied.

If it belongs to an existing INVITE transaction, NkSIP replies 200 _OK_ to the CANCEL request. If the matching INVITE transaction has not yet replied a final response, NkSIP replies it with a 487 (Request Terminated) and this function is called. If a final response has already beeing replied, it has no effect.

`Meta` will include a parameter `{req_id, InviteId}` showing the request id of the INVITE being cancelled.

```erlang
-spec cancel(ReqId::nksip:id(), Meta::meta(), State::term()) ->
    call_noreply().

cancel(_ReqId, _Meta, State) ->
    {noreply, State}.
```


## ack/4
This function is called by NkSIP when a new valid in-dialog ACK request has to be processed locally.

`Meta` will include at least the following parameters: dialog_id, content_type and body (see `nksip_request` for details).

You don't usually need to implement this callback. One possible reason to do it is to receive the SDP body from the other party in case it was not present in the INVITE (you can also get it from the `session_update/3` callback).


```erlang
-spec ack(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(ok).

ack(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


## bye/4
Called when a valid BYE request is received.

When a BYE request is received, NkSIP will automatically response 481 _Call/Transaction does not exist_ if it doesn't belong to a current dialog. If it does, NkSIP stops the dialog and this callback functions is called. You won't usually need to implement this function, but in case you do, you should reply `ok` to send a 200 response back.

`Meta` will include at least the following parameters: aor, dialog_id (see `nksip_request` for details).

```erlang
-spec bye(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

bye(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


## info/4
Called when a valid INFO request is received.

When an INFO request is received, NkSIP will automatically response 481 _Call/Transaction does not exist_ if it doesn't belong to a current dialog. If it does, NkSIP this callback functions is called. If implementing this function, you should reply `ok` to send a 200 response back.

`Meta` will include at least the following parameters: aor, content-type, body (see `nksip_request` for details).

```erlang
-spec info(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
  call_reply(nksip:sipreply()).

info(_ReqId, _Meta, _From, State) ->
  {reply, ok, State}.
```


## options/4
Called when a OPTIONS request is received.

This function is called by NkSIP to process a new incoming OPTIONS request as an endpoint. If not defined, NkSIP will reply with a 200 _OK_ response, including automatically generated `Allow`, `Accept` and `Supported` headers. 

NkSIP will not send any body in its automatic response. This is ok for proxies. If you are implementing an endpoint or B2BUA, you should implement this function and include in your response a SDP body representing your supported list of codecs, and also `Allow`, `Accept` and `Supported` headers.

`Meta` will include at least the following parameters: aor (see `nksip_request` for details).

```erlang
-spec options(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

options(_ReqId, _Meta, _From, State) ->
    Reply = {ok, [contact, allow, allow_event, accept, supported]},
    {reply, Reply, State}.
```


## register/4
This function is called by NkSIP to process a new incoming REGISTER request. 

If it is not defined, but `registrar` option was present in the SipApp's startup config, NkSIP will process the request. It will NOT check if _From_ and _To_ headers contains the same URI, or if the registered domain is valid or not. If you need to check this, implement this function returning `register` if everything is ok. See `nksip_registrar` for other possible response codes defined in the SIP standard registration process.

`Meta` will include at least the following parameters: app_id, registrar, req. Parameter `registrar` will be `true` if this `registrar` is present in SipApp's config. Parameter `req` will have the full `#sipmsg{}` object.

If this function is not defined, and no `registrar` option is found, a 405 _Method not allowed_ would be replied. 

You should define this function in case you are implementing a registrar server and need a specific REGISTER processing (for example to add some headers to the response).

```erlang
-spec register(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

register(_ReqId, Meta, _From, State) ->
    NOTE: In this default implementation, Meta contains the SipApp options.
    Reply = case nksip_lib:get_value(registrar, Meta) of
        true -> 
            Req = nksip_lib:get_value(req, Meta),
            nksip_registrar:request(Req);
        false -> 
            {method_not_allowed, ?ALLOW}
    end,
    {reply, Reply, State}.
```


## prack/4
Called when a valid PRACK request is received.

This function is called by NkSIP when a new valid in-dialog PRACK request has to be processed locally, in response to a sent reliable provisional response. You don't usually need to implement this callback. One possible reason to do it is to receive the SDP body from the other party in case it was not present in the INVITE (you can also get it from the `session_update/3` callback).

`Meta` will include at least the following parameters: dialog_id, content_type and body (see `nksip_request` for details).

```erlang
-spec prack(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(ok).

prack(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


## update/4
Called when a valid UPDATE request is received.

When a UPDATE request is received, NkSIP will automatically response 481 _Call/Transaction does not exist_ if it doesn`t belong to a current dialog. If it does, this function is called. The request will probably have a SDP body. 

If a `ok` is replied, a SDP answer is inclued, the session may change (and the corresponding callback function will be called). If other non 2xx response is replied (like decline) the media is not changed.

`Meta` will include at least the following parameters: dialog_id, content_type and body (see `nksip_request` for details).

```erlang
-spec update(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

update(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


## subscribe/4
This function is called by NkSIP to process a new incoming SUBSCRIBE request that has an allowed _Event_ header.

If you reply a 2xx response like `ok` or `accepted`, a dialog and a subscription will start, and you **must inmeditaly send a NOTIFY** using `nksip_uac:notify/3`. You can use the option `{expires, integer()}` to override the expires present in the request, but the new value must be lower, or even 0 to cancel the subscription.

`Meta` will include at least the following parameters: aor, dialog_id, event, subscription_id and parsed_expires (see `nksip_request` for details).

```erlang
-spec subscribe(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

subscribe(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


## resubscribe/4
This function is called by NkSIP to process a new in-subscription SUBSCRIBE request, sent in order to refresh the subscription.

You won't usually have to implement this function.

```erlang
-spec resubscribe(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

resubscribe(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


## notify/4
This function is called by NkSIP to process a new incoming NOTIFY request belonging to a current active subscription.

`Meta` will include at least the following parameters: aor, dialog_id, event, subscription_id, notify_status, content_type and body. Field `notify_status` will have the status of the NOTIFY: `active`, `pending` or `{terminated, Reason::nksip_subscription:terminated_reason()}`.

You should always return `ok`.

```erlang
-spec notify(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

notify(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


## message/4
This function is called by NkSIP to process a new incoming MESSAGE request.

If you reply a 2xx response like `ok`  or `accepted`, you are telling to the remote party that the message has been received. Use a 6xx response (like `decline`) to tell it has been refused.

`Meta` will include at least the following parameters: aor, expired, content_type and body. Field `expired` will have `true` if the MESSAGE has already expired.

```erlang
-spec message(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

message(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


## refer/4
This function is called by NkSIP to process a new incoming REFER.

`Meta` will include at least the following parameters: aor, dialog_id, event, subscription_id and refer_to. Field `refer_to` contains the mandatory _Refer-To_ header.

If you reply a 2xx response like `ok`  or `accepted`, a dialog and a subscription will start. You must connect to the url in `refer_to` and send any response back to the subscription using `nksip_uac:notify/3`, according to RFC3515.

You should send `ok` if the request has been accepte or `decline` if not. If you are going to spend more than a few seconds to reply, you should reply `accepted`, and if the request is not accepted later on, send a NOTIFY with appropiate reason.

You can use the functions in `nksip_uac` like `invite/4`, `options/4`, etc., using parameter `refer_subscription_id`, and NkSIP will automatically send a valid NOTIFY after each provisional or the final response.

This would be a typical implementation:
```erlang
refer(_ReqId, Meta, _From, #state{id=AppId}=State) ->
    ReferTo = nksip_lib:get_value(refer_to, Meta),
    SubsId = nksip_lib:get_value(subscription_id, Meta),
    Opts = [async, auto_2xx_ack, {refer_subscription_id, SubsId}],
    spawn(fun() -> nksip_uac:invite(AppId, ReferTo, Opts) end),
    {reply, ok, State}.
```

```erlang
-spec refer(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

refer(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


## publish/4
This function is called by NkSIP to process a new incoming PUBLISH request. 

`Meta` will include at least the following parameters: app_id, aor, event, etag, parsed_expires. Parameter `etag` will include the incoming _SIP-If-Match_ header if present.

If the event package is ok, you can use the funcion `nksip_publish:request/5` to process it according to RFC3903

```erlang
-spec publish(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

publish(_ReqId, _Meta, _From, State) ->
    {reply, forbidden, State}.
```


## dialog_update/3
Called when a dialog has changed its state.

A new dialog will be created when you send an INVITE request (using `nksip_uac:invite/3`) and a provisional (1xx) or successful (2xx) response is received, or after an INVITE is received and the call to `invite/3` callback replies with a successful response. If the response is provisional, the dialog will be marked as temporary or _early_, waiting for the final response to be confirmed or deleted.

Dialogs will also be created for _subscriptions_, after a valid NOTIFY is sent or received. Any dialog can have multiple usages simultaneously, as much as _one_ _INVITE uage_ and a _unlimited_ number of _SUBSCRIBE usages_.

Once the dialog is established, some in-dialog methods (like INVITE, UPDATE, SUBSCRIBE and NOTIFY) can update the `target` of the dialog. 

The _INVITE usage_ is destroyed when a valid in-dialog BYE request is sent or received. A _SUBSCRIPTION usage_ is destroyed when a NOTIFY with _status=terminated_ is received. When no usage is left, the dialog itself is destroyed.

NkSIP will call this function every time a dialog is created, its target is updated or it is destroyed.

For INVITE usages, it will be called also when the status of the _usage_ changes, as `{invite_status, nksip_dialog:invite_status()}`. For SUBSCRIBE usages, also when the status of that _usage_ changes, as
`{subscription_status, nksip_subscription:status()}`. 

```erlang
-spec dialog_update(DialogId::nksip_dialog:id(), DialogStatus, State::term()) ->
    call_noreply()
    when DialogStatus :: start | target_update | 
                         {invite_status, nksip_dialog:invite_status()} |
                         {subscription_status, nksip_subscription:status()} |
                         {stop, nksip_dialog:stop_reason()}.
    
dialog_update(_DialogId, _Status, State) ->
    {noreply, State}.
```


## session_update/3
Called when a dialog has updated its SDP session parameters.

When NkSIP detects that, inside an existing dialog, both parties have agreed on a specific SDP defined session, it will call this function. You can use the functions in [nksip_sdp.erl](../../src/nksip_sdp.erl) to process the SDP data. This function will be also called after each new successful SDP negotiation.

```erlang
-spec session_update(DialogId::nksip_dialog:id(), SessionStatus, State::term()) ->
    call_noreply()
    when SessionStatus :: {start, Local, Remote} | {update, Local, Remote} | stop,
                          Local::nksip_sdp:sdp(), Remote::nksip_sdp:sdp().

session_update(_DialogId, _Status, State) ->
    {noreply, State}.
```


## ping_update/3
Called when the status of an automatic ping configuration changes.
See [nksip_sipapp_auto:start_ping/5](../../src/nksip_sipapp_auto.erl).

```erlang
-spec ping_update(PingId::term(), OK::boolean(), State::term()) ->
    call_noreply().

ping_update(_PingId, _OK, State) ->
    {noreply, State}.
```


## register_update/3
Called when the status of an automatic registration configuration changes.
See [nksip_sipapp_auto:start_register/5](../../src/nksip_sipapp_auto.erl).


```erlang
-spec register_update(RegId::term(), OK::boolean(), State::term()) ->
    call_noreply().

register_update(_RegId, _OK, State) ->
    {noreply, State}.
```


## handle_call/3
Called when a direct call to the SipApp process is made using `nksip:call/2` or `nksip:call/3`.

```erlang
-spec handle_call(Msg::term(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

handle_call(Msg, _From, State) ->
    lager:warning("Unexpected handle_call in ~p: ~p", [Msg, ?MODULE]),
    {noreply, State}.
```


## handle_cast/2
Called when a direct cast to the SipApp process is made using `nksip:cast/2`.

```erlang
-spec handle_cast(Msg::term(), State::term()) ->
    call_noreply().

handle_cast(Msg, State) ->
    lager:warning("Unexpected handle_cast in ~p: ~p", [Msg, ?MODULE]),
    {noreply, State}.
```


## handle_info/2
Called when the SipApp process receives an unknown message.

```erlang
-spec handle_info(Msg::term(), State::term()) ->
    call_noreply().

handle_info(_Msg, State) ->
    {noreply, State}.
```

## registrar_store_op/3
Called when a operation database must be done on the registrar database.

The possible values for Op and their allowed reply are:

Op|Response|Comments
---|---|---
{get, AOR::`nksip:aor()`}|[Contact::`nksip_registrar:reg_contact()`]|Retrieve all stored contacts for this AOR
{put, AOR::`nksip:aor()`, [Contact::`nksip_registrar:reg_contact()`], TTL::`integer()`}|ok|Store the list of contacts for this AOR. The record must be automatically deleted after TTL seconds
{del, AOR::`nksip:aor()`}|ok &#124; not_found|Delete all stored contacts for this AOR, returning `ok` or `not_found` if the AOR is not found
del_all|ok|Delete all stored information for this AppId

The function must return `{reply, Reply, NewState}`. This default implementation uses the built-in memory database.

```erlang
-type registrar_store_op() ::
    {get, nksip:aor()} | 
    {put, nksip:aor(), [nksip_registrar:reg_contact()], integer()} |
    {del, nksip:aor()} |
    del_all.

-spec registrar_store(nksip:app_id(), registrar_store_op(), term()) ->
    {reply, term(), term()}.

registrar_store(AppId, Op, State) ->
    Reply = case Op of
        {get, AOR} ->
            nksip_store:get({nksip_registrar, AppId, AOR}, []);
        {put, AOR, Contacts, TTL} -> 
            nksip_store:put({nksip_registrar, AppId, AOR}, Contacts, [{ttl, TTL}]);
        {del, AOR} ->
            nksip_store:del({nksip_registrar, AppId, AOR});
        del_all ->
            FoldFun = fun(Key, _Value, Acc) ->
                case Key of
                    {nksip_registrar, AppId, AOR} -> 
                        nksip_store:del({nksip_registrar, AppId, AOR});
                    _ -> 
                        Acc
                end
            end,
            nksip_store:fold(FoldFun, none)
    end,
    {reply, Reply, State}.
```


## publish_store_op/3
Called when a operation database must be done on the publiser database.

The possible values for Op and their allowed reply are:

Op|Response|Comments
---|---|---
{get, AOR::`nksip:aor()`, Tag::`binary()`}|[`nksip_publish:reg_publish()`] &#124; not_found|Retrieve store information this AOR and Tag
{put, AOR::`nksip:aor()`, Tag::`binary()`, [`nksip_publish:reg_publish()`], TTL::`integer()`}|ok|Store this information this AOR and Tag. The record must be automatically deleted after TTL seconds
{del, AOR::`nksip:aor()`, Tag::`binary()}`|ok &#124; not_found|Delete stored information for this AOR and Tag, returning `ok` or `not_found` if it is not found
del_all|ok|Delete all stored information for this AppId

The function must return `{reply, Reply, NewState}`.
This default implementation uses the built-in memory database.

```erlang
-type publish_store_op() ::
    {get, nksip:aor(), binary()} | 
    {put, nksip:aor(), binary(), nksip_publish:reg_publish(), integer()} |
    {del, nksip:aor(), binary()} |
    del_all.

-spec publish_store(nksip:app_id(), publish_store_op(), term()) ->
    {reply, term(), term()}.

publish_store(AppId, Op, State) ->
    Reply = case Op of
        {get, AOR, Tag} ->
            nksip_store:get({nksip_publish, AppId, AOR, Tag}, not_found);
        {put, AOR, Tag, Record, TTL} -> 
            nksip_store:put({nksip_publish, AppId, AOR, Tag}, Record, [{ttl, TTL}]);
        {del, AOR, Tag} ->
            nksip_store:del({nksip_publish, AppId, AOR, Tag});
        del_all ->
            FoldFun = fun(Key, _Value, Acc) ->
                case Key of
                    {nksip_publish, AppId, AOR, Tag} -> 
                        nksip_store:del({nksip_publish, AppId, AOR, Tag});
                    _ -> 
                        Acc
                end
            end,
            nksip_store:fold(FoldFun, none)
    end,
    {reply, Reply, State}.
```








