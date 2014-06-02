# nksip_registrar plugin

## Description

This plugin implemts includes a full registrar implementation according to RFC3261. _Path_ is also supported according to RFC3327.

It uses by default the buil-in, RAM-only store, but can be configured to use any other database implementing callback [sip_registrar_store/3](#sip_registrar_store3).

Each started SipApp maintains its fully independent set of registrations.

When a new _REGISTER_ request arrives at a SipApp, and if you order to `process` the request in `sip_route/6` callback, NkSIP will try to call `sip_register/3` callback if it is defined. If it is not defined, NkSIP will process the request automatically. If you implement `sip_register/3` to customize the registration process you should call [request/1](#request1) directly.

Use [find/4](#find4) or [qfind/4](qfind4) to search for a specific registration's 
contacts, and [is_registered/1](is_registered1) to check if the _Request-URI_ of a 
specific request is registered.


## Dependant plugins

None


## Configuration values

Option|Default|Description
---|---|---





## API functions

### start_register/5 

```erlang
nksip_uac_auto:start_register(nksip:app_name()|nksip:app_id(), Id::term(), Uri::nksip:user_uri(), 
								    Time::pos_integer(), Opts::nksip:optslist()) -> 
    {ok, boolean()} | {error, invalid_uri|sipapp_not_found}.
```



## Callback functions

You can implement any of these callback functions in your SipApp callback module.



### sip_uac_auto_register_update/3

```erlang
-spec sip_uac_auto_register_update(AppId::nksip:app_id(), 
	                               RegId::term(), OK::boolean()) ->
    ok.
```

If implemented, it will called each time a registration serie changes its state.


