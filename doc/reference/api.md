# NkSIP SipApps' API

NkSIP offers an Erlang API to SipApps, in order to easy the processing of SIP requests and responses and to offer utility functions available to any SipApp.

These functions are divided in several groups:

**SipApp generic functions**

Function|Description
---|---
[start/4](#start4)|Starts a new SipApp
[stop/1](#stop1)|Stops a started SipApp
[stop_all/0](#stop_all/0)|Stops all started SipApps
[update/2](#update/2)|Updates the configuration of a started SipApp
[get_all/0](#get_all0)|Gets all currenty started SipApps
[get/2](#get2)|Gets a value for a SipApp variable
[get/3](#get3)|Gets a value for a SipApp variable, with a default
[put/3](#put3)|Saves a vaule for a SipApp variable
[del/2](#del2)|Deletes a SipApp variable
[get_port/3](#get_port3)|Gets the listening port for a specific transport
[find_app/1](#find_app1)|Finds the _internal name_ for a currently started SipApp
[get_uuid/1](#get_uuid/1)|Get the current _UUID_ for a stared SipApp
[get_gruu_pub/1](#get_gruu_pub1)|The the current public _GRUU_ of a SipApp, if one has been received.
[get_gruu_temp/1](#get_gruu_temp1)|The the current temporary _GRUU_ of a SipApp, if one has been received.
[reply/2](#reply/2)|Sends a response from a synchronous callback function.
[call/2](#call2)|Sends a synchronous message to the SipApp's process, similar to `gen_server:call/2'.
[call/3](#call2)|Sends a synchronous message to the SipApp's process, similar to `gen_server:call/3'.
[cast/2](#call2)|Sends an asynchronous message to the SipApp's process, similar to `gen_server:cast/2'.
[get_pid/1](#pid1)|Gets the `pid()` of a currently started SipApp

