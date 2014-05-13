# Callback Functions

Each SipApp must provide a _callback module_. The functions this callback module can implement are described here. 

See [Receiving Requests](../guide/receiving_requests.md) and [Sending Responses](../guide/sending_responses.md) for an introduction. The default implementation of each one can be reviewed in [nksip_sipapp.erl](../../src/nksip_sipapp.erl).

## SIP Callbacks

Callback|Reason
---|---
[sip_get_user_pass/4](#sip_get_user_pass4)|Called to check a user password for a realm
[sip_authorize/3](#sip_authorize3)|Called for every incoming request to be authorized or not
[sip_route/5](#sip_route5)|Called to route the request
[sip_invite/2](#sip_invite2)|Called to process a new out-of-dialog INVITE request
[sip_reinvite/2](#sip_reinvite2)|Called to process a new in-dialog INVITE request
[sip_cancel/3](#sip_cancel3)|Called when a pending INVITE request is cancelled
[sip_ack/2](#sip_ack2)|Called by NkSIP when a new valid in-dialog ACK request has to be processed locally
[sip_bye/2](#sip_bye2)|Called to process a BYE request
[sip_update/2](#sip_update2)|Called to process a UPDATE request
[sip_info/2](#sip_info2)|Called to process a INFO request
[sip_options/2](#sip_options2)|Called to process a OPTIONS request
[sip_register/2](#sip_register2)|Called to process a REGISTER request
[sip_prack/2](#sip_prack2)|Called to process a PRACK request
[sip_subscribe/2](#sip_subscribe2)|Called to process a new out-of-dialog SUBSCRIBE request
[sip_resubscribe/2](#sip_resubscribe2)|Called to process a new in-dialog SUBSCRIBE request
[sip_notify/2](#sip_notify2)|Called to process a NOTIFY request
[sip_message/2](#sip_message2)|Called to process a MESSAGE request
[sip_refer/2](#sip_refer2)|Called to process a REFER request
[sip_publish/2](#sip_publish2)|Called to process a PUBLISH request
[sip_dialog_update/3](#sip_dialog_update3)|Called when a dialog's state changes
[sip_session_update/3](#session_update3)|Called when a SDP session is created or updated
[sip_registrar_store_op/3](#sip_registrar_store_op3)|Called when a operation database must be done on the registrar database
[sip_publish_store_op/3](#sip_publish_store_op3)|Called when a operation database must be done on the publisher database


## 'gen_server' Callbacks

Callback|Reason
---|---
[init/1](#init1)|Called when the SipApp is launched using `nksip:start/4`
[terminate/2](#terminate2)|Called when the SipApp is stopped
[handle_call/3](#handle_call3)|Called when a direct call to the SipApp process is made using `nksip:call/2` or `nksip:call/3`
[handle_cast/2](#handle_cast2)|Called when a direct cast to the SipApp process is made using `nksip:cast/2`
[handle_info/2](#handle_info2)|Called when a unknown message is received at the SipApp process
[code_change/3](#code_change3)|See gen_server's documentation


## Other Callbacks

Callback|Reason
---|---
[sip_ping_update/3](#sip_ping_update3)|Called when an automatic ping state changes
[sip_register_update/3](#sip_register_update3)|Called when an automatic registration state changes


## Callback List



<!-- SIP Callbacks ---------------------------------------------->


### sip_get_user_pass/4
```erlang
-spec get_user_pass(User::binary(), Realm::binary(), Request:nksip:request(), Call::nksip:call()) ->
    true | false | Pass::binary().
```

Called to check the user password for a realm.

When a request is received containing a _Authorization_ or _Proxy-Authorization_ header, this function is called by NkSIP including the header's `User` and `Realm`, to check if the authorization data in the header corresponds to the user's password. You should reply with the user's password for this realm. NkSIP will use the password and the digest information in the header to check if it is valid, offering this information in the call to [sip_authorize/3](#sip_authorize3).

You can also reply `true` if you want to accept any request from this user without checking any password, or `false` if you don`t have a password for this user or want her blocked.

If you don't want to store _clear-text_ passwords of your users, you can use `nksip_auth:make_ha1/3` to generate a _hash_ of the password for an user and a realm, and store this hash only, instead of the real password. Later on you can reply here with the hash instead of the real password.

If you don't define this function, NkSIP will reply with password `<<>>` if user is `anonymous`, and `false` for any other user. 


### sip_authorize/3
```erlang
-spec authorize(AuthList, Request::nksip:request(), Call::nksip:call()) ->
    ok | forbidden | authenticate | {authenticate, Realm::binary()} |
    proxy_authenticate | {proxy_authenticate, Realm::binary()}
    when AuthList :: [dialog|register|{{digest, Realm::binary}, boolean()}].
```

Called for every incoming request to be authorized or not.

* If `ok` is replied the request is authorized and the request processing continues.
* If `forbidden`, a 403 _Forbidden_ is replied statelessly.
* If `authenticate` is replied, the request will be rejected (statelessly) with a 401 _Unauthorized_. The other party will usually send the request again, this time with an _Authorization_ header. * If you reply `proxy_authenticate`, it is rejected with a 407 _Proxy Authentication Rejected_ response and the other party will include a _Proxy-Authorization_ header.

You can use the tags included in `AuthList` in order to decide to authenticate or not the request. `AuthList` includes the following tags:
* `dialog`: the request is in-dialog and coming from the same ip and port than the last request for an existing dialog.
* `register`: the request comes from the same ip, port and transport of a currently valid registration (and the method is not _REGISTER_).
* `{{digest, Realm}, true}`: there is at least one valid user authenticated (has a correct password) with this `Realm`.
* `{{digest, Realm}, false}`: there is at least one user offering an authentication header for this `Realm`, but all of them have failed the authentication (no password was valid). 

You will usually want to combine these strategies. Typically you will first check using SIP digest authentication, and, in case of faillure, you can use previous registration and/or dialog authentication. 

If you don't define this function all requests will be authenticated.

Example:
```erlang
sip_authorize(Auth, Req, _Call) ->
    IsDialog = lists:member(dialog, Auth),
    IsRegister = lists:member(register, Auth),
    case IsDialog orelse IsRegister of
        true ->
            ok;
        false ->
            case nksip_lib:get_value({digest, <<"my_realm">>}, Auth) of
                true -> ok;
                false -> forbidden;
                undefined -> {proxy_authenticate, BinId}
            end
    end.
```


### sip_route/5
```erlang
-spec sip_route(Scheme::nksip:scheme(), User::binary(), Domain::binary(), 
                Request::nksip:request(), Call::nksip:call()) ->
    proxy | {proxy, ruri | nksip:uri_set()} | 
    {proxy, ruri | nksip:uri_set(), nksip_lib:optslist()} | 
    proxy_stateless | {proxy_stateless, ruri | nksip:uri_set()} | 
    {proxy_stateless, ruri | nksip:uri_set(), nksip_lib:optslist()} | 
    process | process_stateless |
    {reply, nksip:sipreply()} | {reply_stateless, nksip:sipreply()}.
```

This function is called by NkSIP for every new request, to check if it must be proxied, processed locally or replied immediately. 
For convenience, the scheme, user and domain parts of the _Request-Uri_ are included.

If we want to **act as a proxy** and route the request, and we are not responsible for `Domain`, we must return `proxy` or `{proxy, ruri, ProxyOpts}`. We must not return an `UriSet` in this case. NkSIP will then make additional checks to the request (like inspecting the `Proxy-Require` header) and will route it statefully to the same `Request-URI` contained in the request.

If we are the responsible proxy for `Domain` we can provide a new list of URIs to route the request to. NkSIP will use **_serial_** and/or **_parallel_** _forking_ depending on the format of `UriSet`. If `UriSet` is a simple Erlang array of binaries representing uris, NkSIP will try each one serially. If any of the elements of the arrary is in turn a new array of binaries, it will fork them in parallel. 
For example, for  `[ <<"sip:aaa">>, [<<"sip:bbb">>, <<"sip:ccc">>], <<"sip:ddd">>]` NkSIP will first forward the request to `aaa`. If it does not receive a successful (2xx) response, it will try `bbb` and `cccc` in parallel. If no 2xx is received again, `ddd` will be tried. See `nksip_registrar` to find out how to get the registered contacts for this `Request-Uri`. For `ProxyOpts` you can use the same options defined for [sending requests](../sending_options.md). Common options are:

* `record_route`: NkSIP will insert a _Record-Route_ header before sending the request, so that following request inside the dialog will be routed to this proxy.
* `path`: For REGISTER requests, if the request includes "path" as part of the supported tokens, it will insert a _Path_ header (see RFC3327). If path it is not supported, it will reply a 421 _Extension Required_ response.
* `follow_redirects`: If any 3xx response is received, the received contacts will be inserted in the list of uris to try.
* `{route, nksip:user_uri()}`: NkSIP will insert theses routes as _Route_ headers in the request, before any other existing `Route` header. The request would then be sent to the first _Route_.
* Header additions

You can also add headers to the request if the URI contains a _Route_ header.

If you use `proxy_stataless` instead of `proxy`, the request will be proxied statelessly, without storing any state about it in the server. In this case you should use only one _url_.

If we want to **act as an endpoint or B2BUA** and answer to the request from this SipApp, we must return `process` or `process_stataless`. NkSIP will then make additional checks to the request (like inspecting `Require` header), and will call the function corresponding to the method in the request (like `sip_invite/2`, `sip_options/2`, etc.)

We can also **send a reply immediately**, replying `{reply, Reply}` `{reply_stateless, Reply}`. See [Reply Options](reply_options.md) for a descriptions of available reply options.

If route/3 is not defined the default reply would be `process`.

Example:
```erlang
sip_route(Scheme, User, Domain, Req, _Call) ->
    Opts = [{route, "<sip:127.0.0.1:5061;lr>"}],
    case User of
        <<>> -> 
            process;
        _ when Domain =:= <<"127.0.0.1">> ->
            proxy;
        _ ->
            App = nksip_request:app_name(Req),
            case nksip_registrar:find(App, Scheme, User, Domain) of
                [] -> 
                    {reply, temporarily_unavailable};
                UriList -> 
                    {proxy, UriList, Opts}
            end
    end.
```


### sip_invite/2
```erlang
-spec sip_invite(Request::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.
```

This function is called by NkSIP to process a new INVITE request as an endpoint.

You would usually extract information from the Request (using the [API](api.md)) like user, body, content-type, etc., and maybe get information from the body with the functions in the `nksip_sdp` module, and should then reply a final response (like `ok`, `{answer, Body}` or `busy`, see options [here](reply_options.md)).

Alteratively, you can grab a request handle (calling `nksip_request:get_id(Request)`), return a provisional response (like `{reply, ringing}`) and spawn a new process to send a final response later on calling `nksip_request:reply/2` (like `ok`, `{answer, Body}` or `busy`). You should use this technique anycase if you are going to spend more than a few miliseconds processing the callback function, in order to not to block new requests and retransmissions having the same _Call-ID_. You shouldn´t copy the `Request` and `Call` objects to the spawned process, as they are quite heavy. It is recommended to extract all needed information before spawning the request and pass it to the spawned process.

NkSIP will usually send a `100 Trying` response before calling this callback, unless option `no_100` is used.

Inmediatly after you send the first provisional or final response a dialog will be created, and NkSIP will call [sip_dialog_update/3](#sip_update_dialog3) and possibly [sip_session_update/3](#sip_session_update3). The dialog will be destroyed if no ACK in received after sending a successful final response.

Example:
```erlang
sip_invite(Req, Call) ->
    ReqId = nksip_request:get_id(Req),
    HasSDP = case nksip_dialog:get_dialog(Req, Call) of
        {ok, Dialog} -> {true, nksip_dialog:meta(invite_local_sdp, Dialog)};
        error -> false
    end,
    proc_lib:spawn(
        fun() ->
            nksip_request:reply(ringing, ReqId),
            timer:sleep(5000),
            case HasSDP of
                {true, SDP1} ->
                    SDP2 = nksip_sdp:increment(SDP1),
                    nksip_request:reply({ok, [{body, SDP2}|Hds]}, ReqId);
                false ->
                    nksip:reply(decline, ReqId)
            end
        end),
    noreply.
```

If this functions is not implemented, it will reply with a _603 Decline_


### sip_reinvite/2
```erlang
-spec sip_reinvite(Request::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.
```

This function is called when a new in-dialog INVITE request is received. 

It works the same way as `sip_invite/2`, and, if it is not implement, it will call `sip_invite/2`. You should implement it to have different behaviours for new and in-dialog INVITE requests.


### sip_cancel/3
```
-spec sip_cancel(InviteRequest::nksip:request(), Request::nksip:request(), 
                 Call::nksip:call()) ->
    ok.
```

Called when a pending INVITE request is cancelled.

When a CANCEL request is received by NkSIP, it will check if it belongs to an existing INVITE transaction. If not, a 481 _Call/Transaction does not exist_ will be automatically replied. If it belongs to an existing INVITE transaction, NkSIP replies 200 _OK_ to the CANCEL request. If the matching INVITE transaction has not yet replied a final response, NkSIP replies it with a 487 (Request Terminated) and this function is called. If a final response has already beeing replied, it has no effect.

You can get additional information of the cancelled INVITE using `InviteRequest`


### sip_ack/2
```
-spec sip_ack(Request::nksip:request(), Call::nksip:call()) ->
    ok.

This function is called by NkSIP when a new valid in-dialog ACK request has to be processed locally.

You don't usually need to implement this callback. One possible reason to do it is to receive the SDP body from the other party in case it was not present in the INVITE (you can also get it from the `session_update/3` callback).


### sip_bye/2
```
-spec sip_bye(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.
```

Called when a valid BYE request is received.

When a BYE request is received, NkSIP will automatically response 481 _Call/Transaction does not exist_ if it doesn't belong to a current dialog. If it does, NkSIP stops the dialog and this callback functions is called. You won't usually need to implement this function, but in case you do, you should reply `ok` to send a 200 response back. See [sip_invite/2](#sip_invite2) for delayed responses.


### sip_info/2
```
-spec sip_info(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.
```

Called when a valid INFO request is received.

When an INFO request is received, NkSIP will automatically response 481 _Call/Transaction does not exist_ if it doesn't belong to a current dialog. If it does, NkSIP this callback functions is called. If implementing this function, you should reply `ok` to send a 200 response back. See [sip_invite/2](#sip_invite2) for delayed responses.


### sip_options/2
```
-spec sip_options(Req::nksip:request(), Call::nksip:call()) ->
    {reply, nksip:sipreply()} | noreply.
```

Called when a OPTIONS request is received.

This function is called by NkSIP to process a new incoming OPTIONS request as an endpoint. If not defined, NkSIP will reply with a 200 _OK_ response, including options `contact`, `allow`, `allow_event`, `accept` and `supported`. See the list of available options [here](reply_options.md)).

NkSIP will not send any body in its automatic response. This is ok for proxies. If you are implementing an endpoint or B2BUA, you should implement this function and include in your response a SDP body representing your supported list of codecs, and also the previous options.



### sip_register/2
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


### sip_prack/2
Called when a valid PRACK request is received.

This function is called by NkSIP when a new valid in-dialog PRACK request has to be processed locally, in response to a sent reliable provisional response. You don't usually need to implement this callback. One possible reason to do it is to receive the SDP body from the other party in case it was not present in the INVITE (you can also get it from the `session_update/3` callback).

`Meta` will include at least the following parameters: dialog_id, content_type and body (see `nksip_request` for details).

```erlang
-spec prack(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(ok).

prack(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


### sip_update/2
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


### sip_subscribe/2
This function is called by NkSIP to process a new incoming SUBSCRIBE request that has an allowed _Event_ header.

If you reply a 2xx response like `ok` or `accepted`, a dialog and a subscription will start, and you **must inmeditaly send a NOTIFY** using `nksip_uac:notify/3`. You can use the option `{expires, integer()}` to override the expires present in the request, but the new value must be lower, or even 0 to cancel the subscription.

`Meta` will include at least the following parameters: aor, dialog_id, event, subscription_id and parsed_expires (see `nksip_request` for details).

```erlang
-spec subscribe(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

subscribe(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


### sip_resubscribe/2
This function is called by NkSIP to process a new in-subscription SUBSCRIBE request, sent in order to refresh the subscription.

You won't usually have to implement this function.

```erlang
-spec resubscribe(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

resubscribe(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


### sip_notify/2
This function is called by NkSIP to process a new incoming NOTIFY request belonging to a current active subscription.

`Meta` will include at least the following parameters: aor, dialog_id, event, subscription_id, notify_status, content_type and body. Field `notify_status` will have the status of the NOTIFY: `active`, `pending` or `{terminated, Reason::nksip_subscription:terminated_reason()}`.

You should always return `ok`.

```erlang
-spec notify(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

notify(_ReqId, _Meta, _From, State) ->
    {reply, ok, State}.
```


### sip_message/2
This function is called by NkSIP to process a new incoming MESSAGE request.

If you reply a 2xx response like `ok`  or `accepted`, you are telling to the remote party that the message has been received. Use a 6xx response (like `decline`) to tell it has been refused.

`Meta` will include at least the following parameters: aor, expired, content_type and body. Field `expired` will have `true` if the MESSAGE has already expired.

```erlang
-spec message(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

message(_ReqId, _Meta, _From, State) ->
    {reply, decline, State}.
```


### sip_refer/2
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


### sip_publish/2
This function is called by NkSIP to process a new incoming PUBLISH request. 

`Meta` will include at least the following parameters: app_id, aor, event, etag, parsed_expires. Parameter `etag` will include the incoming _SIP-If-Match_ header if present.

If the event package is ok, you can use the funcion `nksip_publish:request/5` to process it according to RFC3903

```erlang
-spec publish(ReqId::nksip:id(), Meta::meta(), From::from(), State::term()) ->
    call_reply(nksip:sipreply()).

publish(_ReqId, _Meta, _From, State) ->
    {reply, forbidden, State}.
```


### sip_dialog_update/3
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


### sip_session_update/3
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


### sip_registrar_store_op/3
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


### sip_publish_store_op/3
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



<!-- gen_server Callbacks ---------------------------------------------->



### init/1
This callback function is called when the SipApp is launched using `nksip:start/4`.
If `{ok, State}` or `{ok, State, Timeout}` is returned the SipApp is started with this initial state. If a `Timeout` is provided (in milliseconds) a `timeout` message will be sent to the process (you will need to implement `handle_info/2` to receive it). If `{stop, Reason}` is returned the SipApp will not start. 

```erlang
-spec init(Args::term()) ->
    init_return().

init([]) ->
    {ok, {}}.
```

### terminate/2
Called when the SipApp is stopped.

```erlang
-spec terminate(Reason::term(), State::term()) ->
    ok.

terminate(_Reason, _State) ->
    ok.
```

### handle_call/3
Called when a direct call to the SipApp process is made using `gen_server:call/2,3`.

```erlang
-spec handle_call(Msg::term(), From::from(), State::term()) ->
      {noreply, State} | {noreply, State, Timeout} | 
      {reply, Reply, State} | {reply, Reply, State, Timeout} | 
      {stop, Reason, State} | {stop, Reason, Reply, State}
      when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term().

handle_call(Msg, _From, State) ->
    lager:warning("Unexpected handle_call in ~p: ~p", [Msg, ?MODULE]),
    {noreply, State}.
```


### handle_cast/2
Called when a direct cast to the SipApp process is made using `gen_server:cast/2`.

```erlang
-spec handle_cast(Msg::term(), State::term()) ->
      {noreply, State} | {noreply, State, Timeout} | 
      {stop, Reason, State} 
      when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term().

handle_cast(Msg, State) ->
    lager:warning("Unexpected handle_cast in ~p: ~p", [Msg, ?MODULE]),
    {noreply, State}.
```


### handle_info/2
Called when the SipApp process receives an unknown message.

```erlang
-spec handle_info(Msg::term(), State::term()) ->
      {noreply, State} | {noreply, State, Timeout} | 
      {stop, Reason, State} 
      when State :: term(), Timeout :: infinity | non_neg_integer(), Reason :: term().

handle_info(_Msg, State) ->
    {noreply, State}.
```

### code_change/3
See gen_server's documentation


```erlang
-spec code_change(OldVsn::term(), State::term(), Extra::term()) ->
    {ok, NewState::term()}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
```


<!-- Other Callbacks ---------------------------------------------->


### sip_ping_update/3
Called when the status of an automatic ping configuration changes.
See [nksip_sipapp_auto:start_ping/5](../../src/nksip_sipapp_auto.erl).

```erlang
-spec ping_update(PingId::term(), OK::boolean(), State::term()) ->
    call_noreply().

ping_update(_PingId, _OK, State) ->
    {noreply, State}.
```


### sip_register_update/3
Called when the status of an automatic registration configuration changes.
See [nksip_sipapp_auto:start_register/5](../../src/nksip_sipapp_auto.erl).


```erlang
-spec register_update(RegId::term(), OK::boolean(), State::term()) ->
    call_noreply().

register_update(_RegId, _OK, State) ->
    {noreply, State}.
```




