# Dialogs API

This document describes the API NkSIP makes available to extract information from Dialogs.

Most functions in the API allows two ways to refer to the dialogs:
* From a full *dialog object* (`nksip:dialog()`). In some specific _callback functions_ like [sip_dialog_update/3](../reference/callback_functions.md#sip_dialog_update3) you receive a full dialog object. You can use these API functions inside the function call. 

	You can also get a full dialog object calling [get_dialog/2](#nksip_dialogget_dialog2) using a request or subscription object and a call object (received in callback functions like [sip_invite/2](../reference/callback_functions.md#sip_invite2), [sip_options/2](../reference/callback_functions.md#sip_options2), etc.

* From a *dialog handle* (`nksip:handle()`). You can get a dialog handle from a dialog object, request or response objects or handles for dialogs, request, responses or subscriptions, calling [get_handle/1](#nksip_dialogget_handle/1). You can then use the handle to call most functions in this API. 
    
    In this case, the API function must contact with the corresponding call process to get the actual dialog, so you cannot use this method _inside_ the same call process (like in the callback functions). This method is useful to refer to the dialog from a _spawned_ process, avoiding the need to copy the full object. Please notice that the dialog object may not exists any longer at the moment that the handle is used. Most functions return `error` in this case.


<br/>


Function|Description
---|---
[get_handle/1](#nksip_dialogget_handle1)|Grabs a dialog's handle
[app_id/1](#nksip_dialogapp_id1)|Gets then SipApp's _internal name_
[app_name/1](#nksip_dialogapp_name1)|Gets the SipApp's _user name_
[call_id/1](#nksip_dialogcall_id1)|Gets the Call-ID header of the dialog
[meta/2](#nksip_dialogmeta2)|Gets specific metadata from the dialog
[get_dialog/2](#nksip_dialogget_dialog2)|Gets a dialog object from a request and a call objects
[get_all/0](#nksip_dialogget_all0)|Get the handles of all started dialogs
[get_all/2](#nksip_dialogget_all2)Gets all current started dialog handles belonging to App and having Call-ID
[bye_all/0](#nksip_dialogbye_all0)|Sends an in-dialog BYE to all existing dialogs
[stop/1](#nksip_dialogstop1)|Stops an existing dialog from its handle (remove it from memory)
[stop_all/0](#nksip_dialogstop_all0)|Stops (removes from memory) all current dialogs


## Functions List

### nksip_dialog:get_handle/1
```erlang
-spec get_id(nksip:dialog()|nksip:request()|nksip:response()|nksip:id()) ->
    nksip:id().
```
Grabs a dialog's handle.


### nksip_dialog:app_id/1
```erlang
-spec app_id(nksip:dialog()|nksip:id()) -> 
    nksip:app_id().
```
Gets then SipApp's _internal name_.


### nksip_dialog:app_name/1
```erlang
-spec app_name(nksip:dialog()|nksip:id()) -> 
    term().
```
Gets the SipApp's _user name_


### nksip_dialog:call_id/1
```erlang
-spec call_id(nksip:dialog()|nksip:id()) ->
    nksip:call_id().
```
Gets the Call-ID header of the dialog.


### nksip_dialog:meta/2
```erlang
-spec meta(nksip_dialog:field()|[nksip_dialog:field()], nksip:dialog()|nksip:id()) -> 
    term() | [{field(), term()}] | error.
```
Gets specific metadata from the dialog.

See [Metadata Fields](../reference/metadata.md) for a description of available fields.
If `Meta` is simple term, its value is returned. If it is a list, it will return a list of tuples, where the first element is the field name and the second is the value.


### nksip_dialog:get_dialog/2
```erlang
-spec get_dialog(nksip:request()|nksip:response()|nksip:subscription(), nksip:call()) ->
    nksip:dialog()|error.
```
Gets a dialog object from a request and a call objects.


### nksip_dialog:get_all/0
```erlang
-spec get_all() ->
    [nksip:id()].
```
Get the handles of all started dialogs.


### nksip_dialog:get_all/2
```erlang
-spec get_all(App::nksip:app_id(), CallId::nksip:call_id()) ->
    [nksip:id()].
```
Gets all current started dialog handles belonging to App and having Call-ID.


### nksip_dialog:bye_all/0
```erlang
-spec bye_all() ->
    ok.
```
Sends an in-dialog BYE to all existing dialogs.


### nksip_dialog:stop/1
```erlang
-spec stop(nksip:id()) ->
    ok.
```
Stops an existing dialog from its handle (remove it from memory).


### nksip_dialog:stop_all/0
```erlang
-spec stop_all() ->
    ok.
```
Stops (deletes) all current dialogs.
