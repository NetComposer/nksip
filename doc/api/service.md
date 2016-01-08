# NkSIP Services' API

This document describes the API that NkSIP makes available to Services.<br/>
Then SIP-specific functions are available in the [nksip.erl](../../src/nksip.erl) module, while other functions are available in the [nkservice_server](https://github.com/Nekso/nkservice/blob/master/src/nkservice_server.erl) module.<br/>
See [Starting a Service](../guide/start_a_service.md) for a general overview.


https://github.com/jbgledy/nksip/blob/k-dev-edoc-makefile/doc/api/service.md#get_all_services0
Function|Description
---|---
[start/2](#start4)|Starts a new Service
[stop/1](#stop1)|Stops a started Service
[stop_all/0](#stop_all0)|Stops all started Services
[update/2](#update2)|Updates the configuration of a started Service
[get_all_services/0](#get_all_services0)|Gets all currenty started Services
[get/2](#get2)|Gets a value for a Service variable
[get/3](#get3)|Gets a value for a Service variable, with a default
[put/3](#put3)|Saves a vaule for a Service variable
[del/2](#del2)|Deletes a Service variable
[get_srv_id/1](#get_srv_id1)|Finds the _internal name_ for a currently started Service
[call/2](#call2)|Synchronous call to the Service's gen_server process
[call/3](#call3)|Synchronous call to the Service's gen_server process with timeout
[cast/2](#call3)|Asynchronous call to the Service's gen_server process
[get_uuid/1](#get_uuid1)|Get the current _UUID_ for a stared Service


## Functions list

### start/4
Starts a new Service. 

NkSIP returns the _internal name_ of the application. In most API calls you can use the _user defined name_ `ServiceName` or the _internal generated id_ `srv_id()`.

For now `OptionsMapOrList` can either be a list of tuples (which is the old way of doing things) or a `map()` which is the new way.  Maps are preferred.

```erlang
-spec start( ServiceName, OptionsMapOrList ) -> Result when 
            ServiceName      :: srv_name(), 
            OptionsMapOrList     :: optslist(),
            Result          :: {ok, srv_id()} 
                | {error, term()}.
```

***Example(s):***
> 
```erlang
nksip:start(test_server_1, #{
        sip_local_host => "localhost",
        callback => nksip_tutorial_server_callbacks,
        plugins => [nksip_registrar],
        sip_listen => "sip:all:5060, <sip:all:5061;transport=tls>"
    }).
{ok,armejl7}
```
or
```erlang
nksip:start(client5, []).    %% Note the list() options.  See also Configuration notes below for options
{ok,bvdc609}
```
or
```erlang
nksip:start(me2, #{}).     %% Note the map() options.  See also Configuration notes below for options
{ok,bbkj953}
```

***See Also:***
* [Tutorial](../guide/tutorial.md) For more examples of start and other options
* [Starting a Service](../guide/start_a_service.md)
* [Configuration Options](../reference/configuration.md) for a list of available configuration options. 

***Note:***
> The `srv_id()` returned by this function is both the id, but it is also a real (compiled on the fly) name of an Erlang module.  While you should not use it as a module, for developers it can be useful to know about this.
<br>
An example of the functions availble for the `bbkj953` module (also the `srv_id()`) are listed below:
```erlang
(nksip_shell@127.0.0.1)5> bbkj953:
class/0                          config/0                         
config_nkservice/0               config_nksip/0                   
id/0                             listen/0                         
listen_ids/0                     log_level/0                      
module_info/0                    module_info/1                    
name/0                           nks_sip_authorize_data/3         
nks_sip_call/3                   nks_sip_connection_recv/4        
nks_sip_connection_sent/2        nks_sip_debug/3                  
nks_sip_dialog_update/3          nks_sip_make_uac_dialog/4        
nks_sip_method/2                 nks_sip_parse_uac_opts/2         
nks_sip_parse_uas_opt/3          nks_sip_route/4                  
nks_sip_transport_uac_headers/6  nks_sip_transport_uas_sent/1     
nks_sip_uac_pre_request/4        nks_sip_uac_pre_response/3       
nks_sip_uac_proxy_opts/2         nks_sip_uac_reply/3              
nks_sip_uac_response/4           nks_sip_uas_dialog_response/4    
nks_sip_uas_method/4             nks_sip_uas_process/2            
nks_sip_uas_send_reply/3         nks_sip_uas_sent_reply/1         
nks_sip_uas_timer/3              plugins/0                        
service_code_change/3            service_handle_call/3            
service_handle_cast/2            service_handle_info/2            
service_init/2                   service_terminate/2              
sip_ack/2                        sip_authorize/3                  
sip_bye/2                        sip_cancel/3                     
sip_dialog_update/3              sip_get_user_pass/4              
sip_info/2                       sip_invite/2                     
sip_message/2                    sip_notify/2                     
sip_options/2                    sip_publish/2                    
sip_refer/2                      sip_register/2                   
sip_reinvite/2                   sip_resubscribe/2                
sip_route/5                      sip_session_update/3             
sip_subscribe/2                  sip_update/2                     
timestamp/0                      uuid/0                           
```


### stop/1
Stops a currently started Service.

Notice that the parameter for stop is either the _user defined name_ `ServiceName` used with the `nksip:start/2` function or the _internal generated id_ `srv_id()` which was generated and returned with `nksip:start/2`

```erlang
-spec stop( ServiceNameOrId ) -> Result when 
        ServiceNameOrId     :: srv_name()  
            | srv_id(),
        Result              :: ok 
            |  {error, not_running}.
```

***Example(s):***
> 
```erlang
(nksip_shell@127.0.0.1)7> nksip:stop(me2).    
11:04:18.384 [info] Plugin nksip stopped for service me2
ok
```

### stop_all/0
Stops all currently started SIP Services.

```erlang
-spec stop_all() -> 
    ok.
```


### update/2
Updates the callback module or options of a running Service, on the fly.

You can change any configuration parameter on the fly, even for transports. See [Configuration Options](../reference/configuration.md) for a list of available configuration options. 

See [Configuration](../reference/configuration.md).
```erlang
-spec update( ServiceNameOrId, OptionsMapOrList ) -> Result when 
            ServiceNameOrId     :: srv_name()
                | srv_id(),
            OptionsMapOrList         :: optslist(),
            Result              ::  {ok, srv_id()} 
                | {error, term()}.
```

***Example(s):***
>
```erlang
> nksip:update(me, #{log_level => debug}).     %% NOTE: Using map() for options
11:31:39.701 [info] Skipping started transport {udp,{0,0,0,0},0}
11:31:39.734 [info] Added config: #{log_level => 8}
11:31:39.734 [info] Removed config: #{log_level => notice}
ok
```
or
```erlang
> nksip:update(me, [{log_level, notice}]). 
11:32:16.524 [info] Skipping started transport {udp,{0,0,0,0},0}
11:32:16.555 [info] Added config: #{log_level => 6}
11:32:16.555 [info] Removed config: #{log_level => 8}
ok
``` 




***See Also:***
* [Configuration Options](../reference/configuration.md) for a list of available configuration options. 


### get_all_services/0
Gets Id, Name, Class and Pid of all started SIP Services.

```erlang
-spec get_all_services() -> Result when 
    Result          :: [ ServiceData ],
    ServiceData     :: { Id, Name, Class, Pid },
    Id              :: nkservice:id(),
    Name            :: nkservice:name(),
    Class           :: nkservice:class(),
    Pid             :: nkservice:pid().
```
***Example(s):***
> 
```erlang
(nksip_shell@127.0.0.1)11> nksip:get_all_services().   
[{bo4yxv5,foo4,nksip,<0.1188.0>},
 {bvdc609,me,nksip,<0.168.0>}]
```


### get/2
Get the Value into of a Key from the data storage.  Each service has data storage options (See [saving state information](../guide/start_a_service.md#saving-state-information) ) for storing things they want to store and get back. 

*NOTE:* This is a convienance function for nkservice:get(ServiceNameOrId, Key)

```erlang
-spec get(ServiceNameOrId, Key ) -> Result when 
            ServiceNameOrId     :: srv_name()
                | srv_id(),
            Key                 :: term(),
            Result              :: term().
```

***Example(s):***
> 
```erlang
> nksip:get(m2, hello_world).                    
  "Hello World"
``` 

***See Also:***
* [Saving State Information](../guide/start_a_service.md#saving-state-information).


### get/3
Get the Value of a Key from the data storage or `DefaultValue' if there is no stored value.  Each service has data storage options (See [saving state information](../guide/start_a_service.md#saving-state-information) ) for storing things they want to store and get back. 

NOTE: This is a convienance function for nkservice:get(ServiceNameOrId, Key, DefaultValue)

```erlang
-spec get(ServiceNameOrId, Key, DefaultValue ) -> Result when 
            ServiceNameOrId     :: srv_name()
                | srv_id(),
            Key                 :: term(),
            DefaultValue        :: term(),
            Result              :: term().
```


%% > nksip:get(m2, hello_jim, "Hello there, Jim!").                    
%%   "Hello there, Jim!"

***Example(s):***
> 
```erlang
> nksip:get(m2, hello_jim, "Hello there, Jim!").                    
  "Hello there, Jim!"
``` 

***See Also:***
* [Saving State Information](../guide/start_a_service.md#saving-state-information).


### put/3
```erlang
nkservice_server:put(nksip:srv_name()|nksip:srv_id(), term(), term()) ->
    ok | {error, term()}.
```
Inserts a value in Service's store.
See [saving state information](../guide/start_a_service.md#saving-state-information).

### del/2
```erlang
nkservice_server:del(nksip:srv_name()|nksip:srv_id(), term()) ->
    ok | {error, term()}.
```
Deletes a value from Service's store.
See [saving state information](../guide/start_a_service.md#saving-state-information).


### find_srv_id/1
```erlang
nkservice_server:get_srv_id(term()) ->
    {ok, srv_id()} | not_found.
```
Finds the _internal name_ of an existing Service.


### call/2
```erlang
nkservice_server:call(nksip:srv_name()|nksip:srv_id(), term()) ->
    term().
```
Synchronous call to the Service's gen_server process. It is a simple `gen_server:call/2` but allowing Service names.


### call/3
```erlang
nkservice_server:call(nksip:srv_name()|nksip:srv_id(), term(), pos_integer()|infinity) ->
    term().
```
Synchronous call to the Service's gen_server process. It is a simple `gen_server:call/3` but allowing Service names.


### cast/2
```erlang
nkservice_server:cast(nksip:srv_name()|nksip:srv_id(), term()) ->
    term().
```
Asynchronous call to the Service's gen_server process. It is a simple `gen_server:cast/2` but allowing Service names.


### get_uuid/1
Gets the Service's _UUID_.

```erlang
-spec get_uuid( ServiceNameOrId ) -> Result when 
            ServiceNameOrId     :: srv_name()
                | srv_id(),
            Result              :: binary().
```

***Example(s):***
> 
```erlang
nksip:get_uuid(bbkj953). 	%% srv_id()
<<"<urn:uuid:545f1233-28d4-e321-93d7-28cfe9192deb>">>
```
or
```erlang
nksip:get_uuid(me2).    	%% srv_name()
<<"<urn:uuid:545f1233-28d4-e321-93d7-28cfe9192deb>">>
```
