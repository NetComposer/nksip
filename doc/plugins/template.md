# nksip_uac_auto plugin

## Description

This plugin...


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


