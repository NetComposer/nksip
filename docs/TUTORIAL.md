Tutorial
========

This a simple tutorial covering the basic aspects of NkSIP.


Firt of all install NkSIP:
```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
> make tutorial
```

Now you can start a simple SipApp proxy server using the included [server callback module](../samples/nksip_tutorial/src/nksip_tutorial_sipapp_server.erl). We will listen on all interfaces, port `5060` for udp and tcp and `5061` for tls. We also include the `registrar` option to tell NkSIP to process registrations (without having to implement `register/3` callback function, see [nksip_siapp.erl](../nksip/src/nksip_sipapp.erl)):
```erlang
1> nksip:start(server, nksip_tutorial_sipapp_server, [server], 
		[
			registrar, 
		 	{transport, {udp, {0,0,0,0}, 5060}}, 
		 	{transport, {tls, {0,0,0,0}, 5061}}
		 ]).
ok
```

Now we can start two clients, using the included [client callback module](../samples/nksip_tutorial/src/nksip_tutorial_sipapp_client.erl). The first is called `client1` and listens on `127.0.0.1` ports `5070` for udp and tcp and `5071` for tls, and the second is called `client2` and listens on all interfaces, random ports. We also configure the _From_ header to be used on each one, the second one, using `sips`:

```erlang
2> nksip:start(client1, nksip_tutorial_sipapp_client, [client1], 
		[
			{from, "sip:client1@nksip"},
		 	{transport, {udp, {127,0,0,1}, 5070}}, 
		 	{transport, {tls, {127,0,0,1}, 5071}}
		]).
ok
3> nksip:start(client2, nksip_tutorial_sipapp_client, [client2], 
		[{from, "sips:client2@nksip"}]).
ok
```

From now on, you could start tracing to see all SIP messages on the console, using `nksip_trace:start().`

Let's try now to send an _OPTIONS_ from `client2` to `client1` and from `client1` to the `server`:
```erlang
4> nksip_uac:options(client2, "sip:127.0.0.1:5070", []).
{ok, 200}
5> nksip_uac:options(client1, "sip:127.0.0.1", []).
{ok, 407}
```

Oops, the `server` didn't accept the request. In the client callback module there is no authentication related callback function implemented, so every request is accepted. But server callback module is different:
```erlang
%% @doc Called to check user's password.
%% If the incoming user's realm is "nksip", the password for any user is "1234". 
%% For other realms, no password is valid.
get_user_pass(_User, <<"nksip">>, _From, State) -> 
    {reply, <<"1234">>, State};
get_user_pass(_User, _Realm, _From, State) -> 
    {reply, false, State}.


%% @doc Called to check if a request should be authorized.
%%
%% 1) We first check to see if the request is an in-dialog request, coming from 
%%    the same ip and port of a previously authorized request.
%% 2) If not, we check if we have a previous authorized REGISTER request from 
%%    the same ip and port.
%% 3) Next, we check if the request has a valid authentication header with realm 
%%    "nksip". If '{{digest, <<"nksip">>}, true}' is present, the user has 
%%    provided a valid password and it is authorized. 
%%    If '{{digest, <<"nksip">>}, false}' is present, we have presented 
%%    a challenge, but the user has failed it. We send 403.
%% 4) If no digest header is present, reply with a 407 response sending 
%%    a challenge to the user.
authorize(Auth, _ReqId, _From, State) ->
    case lists:member(dialog, Auth) orelse lists:member(register, Auth) of
        true -> 
            {reply, true, State};
        false ->
            case nksip_lib:get_value({digest, <<"nksip">>}, Auth) of
                true -> 
                    {reply, true, State};       % Password is valid
                false -> 
                    {reply, false, State};      % User has failed authentication
                undefined -> 
                    {reply, {proxy_authenticate, <<"nksip">>}, State}
                    
            end
    end.
```

If we try again with a correct password:
```erlang
6> nksip_uac:options(client1, "sip:127.0.0.1", [{pass, "1234"}]).
{ok, 200}
7> nksip_uac:options(client2, "sip:127.0.0.1;transport=tls", [{pass, "1234"}]).
{ok, 200}
```

Let's register now both clients with the server. We use the option `make_contact` to tell NkSIP to include a valid _Contact_ header in the request:

```erlang
8> nksip_uac:register(client1, "sip:127.0.0.1", [{pass, "1234"}, make_contact]).
{ok, 200}
9> nksip_uac:register(client2, "sip:127.0.0.1;transport=tls", [{pass, "1234"}, make_contact]).
{ok, 200}
```

We can check that the server has stored the registration. If we send a _REGISTER_ request with no _Contact_ header, the server will include one for each stored registration. We usedthe option `full_response` to tell NkSIP to send the full response as the return, instead of only the code. 

```erlang
10> {reply, Resp1} = nksip_uac:register(client2, "sip:127.0.0.1;transport=tls", [{pass, "1234"}, full_response]).
{reply, ...}
11> nksip_response:code(Resp1).
200
12> nksip_response:headers(<<"Contact">>, Resp1).
[<<"<sips:client2@...">>]
```

Now, if we want to send the same _OPTIONS_ again, we don't need to include the authentication, because the origins of the requests are already registered:
```erlang
13> nksip_uac:options(client1, "sip:127.0.0.1", []).
{ok, 200}
14> nksip_uac:options(client2, "sip:127.0.0.1;transport=tls", []).
{ok, 200}
```

Now let's send and _OPTIONS_ from `client1` to `client2` through the proxy. As they are already registered, we can use their registered names or _address-of-record_. We use the option `route` to send the request to the proxy (you usually include this option in the call to `nksip:start/4`, to send _every_ request to the proxy automatically).

The first request is not authorized. The reason is that we are using a `sips` uri as a target, so NkSIP must use tls. But the origin port is then different from the one we registered, so we must authenticate again:
```erlang
15> nksip_uac:options(client1, "sips:client2@nksip", [{route, "sip:127.0.0.1;lr"}]).
{ok, 407}
16> {reply, Resp2} = nksip_uac:options(client1, "sips:client2@nksip", 
                				[{route, "sip:127.0.0.1;lr"}, full_response,{pass, "1234"}]).
{reply, ...}
17> nksip_response:code(Resp2).
200
18> nksip_response:headers(<<"Nksip-Id">>, Resp2).
[<<"client2">>]
19> {reply, Resp3} = nksip_uac:options(client2, "sip:client1@nksip", 
                                        [{route, "sips:127.0.0.1;lr"}, full_response]).
{reply, ...}
20> nksip_response:code(Resp3).
200
21> nksip_response:headers(<<"Nksip-Id">>, Resp3).
[<<"client1">>]
```



The callback `options/3` is called for every client, which includes the custom header:

```erlang
options(_ReqId, _From, #state{id=Id}=State) ->
    Headers = [{"NkSip-Id", Id}],
    Opts = [make_contact, make_allow, make_accept, make_supported],
    {reply, {ok, Headers, <<>>, Opts}, State}.
```

Now let's try a _INVITE_ from `client2` to `client1` through the proxy. NkSIP will call the callback `invite/4` in client1's callback module:

```erlang
invite(_DialogId, ReqId, From, State) ->
    SDP = nksip_request:body(ReqId),
    case nksip_sdp:is_sdp(SDP) of
        true ->
            Fun = fun() ->
                nksip_request:provisional_reply(ReqId, ringing),
                timer:sleep(2000),
                nksip:reply(From, {ok, [], SDP})
            end,
            spawn(Fun),
            {noreply, State};
        false ->
            {reply, {not_acceptable, <<"Invalid SDP">>}, State}
    end.
```

In the first call, since we don't include a body, client1 will reply `not_acceptable` (code `488`).
In the second, we _spawn_ a new process, reply a _provisional_ `180 Ringing`, wait two seconds and reply a `final` `200 Ok` with the same body. After receiving each `2xx` response to an _INVITE_, we must send an _ACK_ inmediatly:
```erlang
22> nksip_uac:invite(client2, "sip:client1@nksip", [{route, "sips:127.0.0.1;lr"}]).
{ok, 488, ...}
23> {ok, 200, Dialog1} = nksip_uac:invite(client2, "sip:client1@nksip", 
					   [{route, "sips:127.0.0.1;lr"}, {body, nksip_sdp:new()}]),
	ok = nksip_uac:ack(Dialog1, []).
ok
```

The call is accepted and we have started a _dialog_:
```erlang
24> nksip_dialog:field(local_sdp, Dialog1).
```

You can _print_ all dialogs in the console. We see dialogs at `client1`, `client2` and at `server`. The three dialogs are the same actually, but in different SipApps:
```erlang
25> nksip_dialog:get_all().
```

Ok, let's stop the call, the dialogs and the SipApps:
```erlang
26> nksip_uac:bye(Dialog1, []).
ok
27> nksip:stop_all().
ok
```

The full code for this tutorial is available [here](../samples/nksip_tutorial/src/nksip_tutorial.erl).



















