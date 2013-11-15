Tutorial
========

This a simple tutorial covering the basic aspects of NkSIP.


Firt of all install last stable version of NkSIP:
```
> git clone https://github.com/kalta/nksip
> cd nksip
> git checkout v0.3.0 -q
> make
> make tutorial
```

Now you can start a simple SipApp proxy server using the included [server callback module](../samples/nksip_tutorial/src/nksip_tutorial_sipapp_server.erl). We will listen on all interfaces, port `5060` for udp and tcp and `5061` for tls. We also include the `registrar` option to tell NkSIP to process registrations (without having to implement `register/3` callback function, see [nksip_siapp.erl](../nksip/src/nksip_sipapp.erl)):
```erlang
1> nksip:start(server, nksip_tutorial_sipapp_server, [server], 
		[
			registrar, 
		 	{transport, {udp, any, 5060}}, 
		 	{transport, {tls, any, 5061}}
		 ]).
ok
```

Now we can start two clients, using the included [client callback module](../samples/nksip_tutorial/src/nksip_tutorial_sipapp_client.erl). The first is called `client1` and listens on `127.0.0.1` ports `5070` for udp and tcp and `5071` for tls, and the second is called `client2` and listens on all interfaces, random ports. We also configure the _From_ header to be used on each one, the second one using `sips`:

```erlang
2> nksip:start(client1, nksip_tutorial_sipapp_client, [client1], 
		[
			{from, "sip:client1@nksip"},
		 	{transport, {udp, {127,0,0,1}, 5070}}, 
		 	{transport, {tls, {127,0,0,1}, 5071}}
		]).
ok
3> nksip:start(client2, nksip_tutorial_sipapp_client, [client2], 
		[	{from, "sips:client2@nksip"},
		 	{transport, {udp, {127,0,0,1}, 5080}}, 
		 	{transport, {tls, {127,0,0,1}, 5081}}
		]).
ok
```

From now on, you could start tracing to see all SIP messages on the console, using `nksip_trace:start(true).`

Let's try now to send an _OPTIONS_ from `client2` to `client1` and from `client1` to the `server`:
```erlang
4> nksip_uac:options(client2, "sip:127.0.0.1:5070", []).
{ok,200,[]}
5> nksip_uac:options(client1, "sip:127.0.0.1", [{fields, [reason]}]).
{ok,407,[{reason,<<"Proxy Authentication Required">>}]}
```

Oops, the `server` didn't accept the request (we have used the `fields` option to 
order NkSIP to return the reason phrase). 

In the client callback module there is no authentication related callback function implemented, so every request is accepted. But server callback module is different:

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

We try again with a correct password. In the second case we are telling NkSIP to 
use `tls` transport. Note we must use `<` and `>` if including `uri` parameters like `transport`.
```erlang
6> nksip_uac:options(client1, "sip:127.0.0.1", [{pass, "1234"}]).
{ok,200,[]}
7> nksip_uac:options(client2, "<sip:127.0.0.1;transport=tls>", [{pass, "1234"}]).
{ok,200,[]}
```

Let's register now both clients with the server. We use the option `make_contact` to tell NkSIP to include a valid _Contact_ header in the request, and the `fields` option to get the _Contact_ header from the response, to be sure the server has stored the contact:

```erlang
8> nksip_uac:register(client1, "sip:127.0.0.1", 
                      [{pass, "1234"}, make_contact, {fields, [<<"Contact">>]}]).
{ok,200,[{<<"Contact">>, [<<"<sip:client1@127.0.0.1:5070>;expires=3600">>]}]}
10> nksip_uac:register(client2, "sips:127.0.0.1", [{pass, "1234"}, make_contact]).
{ok,200,[]}
```

We can check this second registration has worked. If we send a _REGISTER_ request with no _Contact_ header, the server will include one for each stored registration. This time, lets get all the header from the response using `all_headers` as field specification:

```erlang
12> nksip_uac:register(client2, "sips:127.0.0.1", [{pass, "1234"}, {fields, [all_headers]}]).
{ok,200,[{all_headers, [{<<"CallId">>, ...}]}]}
```

Now, if we want to send the same _OPTIONS_ again, we don't need to include the authentication, because the origins of the requests are already registered:
```erlang
13> nksip_uac:options(client1, "sip:127.0.0.1", []).
{ok,200,[]}
14> nksip_uac:options(client2, "sips:127.0.0.1", []).
{ok,200,[]}
```

Now let's send an _OPTIONS_ from `client1` to `client2` through the proxy. As they are already registered, we can use their registered names or _address-of-record_. We use the option `route` to send the request to the proxy (you usually include this option in the call to `nksip:start/4`, to send _every_ request to the proxy automatically).

The first request is not authorized. The reason is that we are using a `sips` uri as a target, so NkSIP must use tls. But the origin port is then different from the one we registered, so we must authenticate again:

```erlang
15> nksip_uac:options(client1, "sips:client2@nksip", [{route, "<sip:127.0.0.1;lr>"}]).
{ok,407,[]}
16> nksip_uac:options(client1, "sips:client2@nksip", 
                				[{route, "<sip:127.0.0.1;lr>"}, {pass, "1234"},
                                 {fields, [<<"Nksip-Id">>]}]).
{ok,200,[{<<"Nksip-Id">>, [<<"client2">>]}]}
```
In the second case we want to get the _Nksip-Id_ header from the response. 
Our callback `options/3` is called for every received options request, which includes the custom header:

```erlang
options(_ReqId, _From, #state{id=Id}=State) ->
    Headers = [{"Nksip-Id", Id}],
    Opts = [make_contact, make_allow, make_accept, make_supported],
    {reply, {ok, Headers, <<>>, Opts}, State}.
```

Now let's try a _INVITE_ from `client2` to `client1` through the proxy. NkSIP will call the callback `invite/3` in `client1`'s callback module:

```erlang
invite(ReqId, From, State) ->
    SDP = nksip_request:body(ReqId),
    case nksip_sdp:is_sdp(SDP) of
        true ->
            Fun = fun() ->
                nksip_request:reply(ReqId, ringing),
                timer:sleep(2000),
                nksip:reply(From, {ok, [], SDP})
            end,
            spawn(Fun),
            {noreply, State};
        false ->
            {reply, {not_acceptable, <<"Invalid SDP">>}, State}
    end.
```

In the first call, since we don't include a body, `client1` will reply `not_acceptable` (code `488`).
In the second, we _spawn_ a new process, reply a _provisional_ `180 Ringing`, wait two seconds and reply a `final` `200 Ok` with the same body. For _INVITE_ responses, NkSIP will allways include the `dialog_id` value, After receiving each `2xx` response to an _INVITE_, we must send an _ACK_ inmediatly:

```erlang
17> nksip_uac:invite(client2, "sip:client1@nksip", [{route, "<sips:127.0.0.1;lr>"}]).
{ok,488,[{dialog_id, ...}]}
18> {ok,200,[{dialog_id, DlgId}]}= nksip_uac:invite(client2, "sip:client1@nksip", 
					   [{route, "<sips:127.0.0.1;lr>"}, {body, nksip_sdp:new()}]).
{ok,200,[{dialog_id, <<"...">>}]}					   
19> nksip_uac:ack(client2, DlgId, []).
ok
```

The call is accepted and we have started a _dialog_:
```erlang
19> nksip_dialog:field(client2, DlgId, status).
confirmed
```

You can _print_ all dialogs in the console. We see dialogs at `client1`, `client2` and at `server`. The three dialogs are the same actually, but in different SipApps (do not use this command in production with many thousands of dialogs):
```erlang
26> nksip_dialog:get_all_data().
```

Ok, let's stop the call, the dialogs and the SipApps:
```erlang
27> nksip_uac:bye(client2, DlgId, []).
{ok,200,[]}
28> nksip:stop_all().
ok
```

The full code for this tutorial is available [here](../samples/nksip_tutorial/src/nksip_tutorial.erl).



















