Tutorial
========

Firt of all install NkSIP
```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
> make tutorial
```

Now you can start a simple SipApp proxy server using the included `nksip_tutorial_sipapp_server.erl` callback module. We will listen on all interfaces, port `5060` for udp and tcp and `5061` for tls. We also include the `registrar` option to tell NkSIP to process registrations (without having to implement the `register/3' callback function):
```erlang
1> nksip:start(server, nksip_tutorial_sipapp_server, [server], 
		[
			registrar, 
		 	{transport, {udp, {0,0,0,0}, 5060}}, 
		 	{transport, {tls, {0,0,0,0}, 5061}}
		 ]).
ok
```

Now we can start two clients, the first `client1` listens on `127.0.0.1` ports `5070` for udp and tcp and `5071` for tls, and the second `client2` listens on all interfaces, random ports. We also configure the _From_ to be used on each one, the second using `sips`:

```erlang
2> nksip:start(client1, nksip_tutorial_sipapp_client, [client1], 
		[
			{from, "sip:client1@nksip"},
		 	{transport, {udp, {127,0,0,1}, 5070}}, 
		 	{transport, {tls, {127,0,0,1}, 5071}}
		]).
ok
3>	nksip:start(client2, nksip_tutorial_sipapp_client, [client2], 
		[{from, "sips:client2@nksip"}]),1> nksip:start(server, nksip_sipapp_sample, [server], [registrar, {transport, {udp, {0,0,0,0}, 5060}}, {transport, {tls, {0,0,0,0}, 5061}}]).
ok
```

server's callback module includes a synchronous call, let's test it:
```erlang
nksip:call(server, get_started).
{ok, ...}
```

From now on, you could start tracing to see all SIP messages on the console: `nksip_trace:start()'

Let's try now to ping from client1 to client1 and to the server:
```erlang
4> nksip_uac:options(client2, "sip:127.0.0.1:5070", []).
{ok, 200}
5> nksip_uac:options(client1, "sip:127.0.0.1", []).
{ok, 407}
```

Ops, the server didn't accept the request. In the callback module for the client, there is no 
authentication related callback function implemented, so every request is accepted. For the server, in its callback module, requests must be authenticated:

```erlang
%% @doc Called to check user's password.
%% If the incoming user's realm is "nksip", the password for any user is "1234". 
%% For other realms, no password is valid.get_user_pass(_User, <<"nksip">>, _From, State) -> 
    {reply, <<"1234">>, State};
get_user_pass(_User, _Realm, _From, State) -> 
    {reply, false, State}.


%% @doc Called to check if a request should be authorized.
%%
%% 1) We first check to see if the request is an in-dialog request, coming from 
%%    the same ip and port of a previously authorized request.</li>
%% 2) If not, we check if we have a previous authorized REGISTER request from 
%%    the same ip and port.
%% 3) Next, we check if the request has a valid authentication header with realm 
%%    "nksip". If `{{digest, <<"nksip">>}, true}' is present, the user has 
%%    provided a valid password and it is authorized. 
%%    If `{{digest, <<"nksip">>}, false}' is present, we have presented 
%%    a challenge, but the user has failed it. We send 403.</li>
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

Lets try again with a password:
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

Lets check the server has stored the registration. If we send a _REGISTER_ request with no _Contact_ header, the server will include one for each stored registration:

```erlang
10> {reply, Resp1} = nksip_uac:register(client2, "sip:127.0.0.1;transport=tls", [{pass, "1234"}, full_response]).
{reply, ...}
11> nksip_response:code(Resp1).
200
12> nksip_response:headers(<<"Contact">>, Resp1).
[<<"<sips:client2@...">>]
```

We have used the option `full_response` to tell NkSIP to send as the full response in the return, instead of only the code. 

Now we can send the same _OPTIONS_ as before without the authentication, because the origin of the requests are already registered:

```erlang
13> nksip_uac:options(client1, "sip:127.0.0.1", []).
{ok, 200}
14> nksip_uac:options(client2, "sip:127.0.0.1;transport=tls", []).
{ok, 200}
```

Now let's send and _OPTIONS_ from client1 to client2 through the proxy. As it is already registered, we can use it registered name. We use the option `route` to send the request to the proxy. You usually include this option in the call to `nksip:start/4`, to send _every_ request to the proxy automatically.


```erlang
15> nksip_uac:options(client1, "sips:client2@nksip", [{route, "sip:127.0.0.1;lr"}]).
{ok, 407}
16> {reply, Resp2} = nksip_uac:options(client1, "sips:client2@nksip", 
										[{route, "sip:127.0.0.1;lr"}, full_response,
										 {pass, "1234"}]).
{reply, ...}
17> nksip_response:code(Resp2).
200
18> nksip_response:headers(<<"Nksip-Id">>, Resp2).
[<<"client2">>]
19> {reply, Resp3} = nksip_uac:options(client2, "sip:client1@nksip", 
										[{route, "sips:127.0.0.1;lr"}, full_response]),
{reply, ...}
20> nksip_response:code(Resp3).
200
21> nksip_response:headers(<<"Nksip-Id">>, Resp3),
[<<"client1">>]
```

The first request is not authorized. The reason is that we are using a sips uri as a target, so NkSIP must use tls. But the origin port is then different from the one we registered, so we 
must authenticate.

The callback `options/3` is called for every client, which includes the custom header:

```erlang
options(_ReqId, _From, #state{id=Id}=State) ->
    Headers = [{"NkSip-Id", Id}],
    Opts = [make_contact, make_allow, make_accept, make_supported],
    {reply, {ok, Headers, <<>>, Opts}, State}.
```

Now let's try a _INVITE_ from client2 to client1 through the proxy. NkSIP will call the callback `invite/4` in client1's callback module:

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

In the first call, since we don't include a body, client1 will reply `not_acceptable` (code 488).
In the second, we spawn a new process, reply a provisional 180 Ringing, wait two seconds and reply a 200 OK with the same body. After receiving each 2xx response to an _INVITE_, we must send an _ACK_ inmediatly.

```erlang
22> nksip_uac:invite(client2, "sip:client1@nksip", [{route, "sips:127.0.0.1;lr"}]).
{ok, 488, ...}
23> {ok, 200, Dialog1} = nksip_uac:invite(client2, "sip:client1@nksip", 
					[{route, "sips:127.0.0.1;lr"}, {body, nksip_sdp:new()}]),
	ok = nksip_uac:ack(Dialog1, []).
ok
```

We have started a dialog:
24> nksip_dialog:field(local_sdp, Dialog1).
...
25> nksip_uac:bye(Dialog1).
ok
26> nksip:stop_all().
ok
```




















