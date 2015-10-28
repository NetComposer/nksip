# Configuration

* [Global configuration options](#global-configuration-options).
* [Service configuration options](#service-configuration-options).
* [Reconfiguration](#reconfiguration)

Keep in mind that installed plugins can add specific configuration options. See the [plugins documentation](../plugins/README.md).


## Global configuration options

They are defined as standard Erlang environment variables for each of dependant Erlang applications, along with nksip application itself:

### nkpacket

Name|Type|Default|Comments
---|---|---|---
max_connections|`integer()`|1024|Maximum number of simultaneous connections
dns_cache_ttl|`integer()`|30000|DNS cache TTL (See `nkpacket_dns`) (msecs)
udp_timeout|`integer()`|30000|Default UDP timeout (msecs)
tcp_timeout|`integer()`|180000|Default TCP timeout (msecs)
sctp_timeout|`integer()`|180000|Default SCTP timeout (msecs)
ws_timeout|`integer()`|180000|Default WS timeout (msecs)
connect_timeout|`integer()`|30000|Default connect timeout (msecs)
tls_opts|`nkpacket:tls_opts`||See nkpacket.erl

### nkservice

Name|Type|Default|Comments
---|---|---|---
log_path|`string`|"./log"|Directory for NkSERVICE files (you must configure lager also)
log_level|`debug`&#124;`info`&#124;`notice`&#124;`warning`&#124;`error`|`notice`|Current global log level


### nksip

Name|Type|Default|Comments
---|---|---|---
sync_call_time|`integer()`|30000|Timeout for internal synchronous calls
global_max_calls|`integer()`|100000|Maximum number of simultaneous calls (for all services)
msg_routers|`integer()`|16|Number of parallel SIP processors
sip_allow|`string()`&#124;`binary()`|"INVITE,ACK,CANCEL,BYE,OPTIONS,INFO,UPDATE,SUBSCRIBE,NOTIFY,REFER,MESSAGE"|Default _Allow_ header
sip_supported|`string()`&#124;`binary()`|"path"|Default _Supported_ header
sip_timer_t1|`integer()`|500|Standar SIP T1 timer (msecs)
sip_timer_t2|`integer()`|4000|Standar SIP T2 timer (msecs)
sip_timer_t4|`integer()`|5000|Standar SIP T4 timer (msecs)
sip_timer_c|`integer()`|180|Standar SIP C timer (secs)
sip_trans_timeout|`integer()`|900|Time to timeout non-refreshed dialogs (secs)
sip_dialog_timeout|`integer()`|1800|Time to timeout non-refreshed dialogs (secs)
sip_event_expires|`integer()`|60|Default Expires for events (secs)
sip_event_expires_offset|`integer()`|5|Additional time to add to Expires header (secs)
sip_nonce_timeout|`integer()`|30|Time a new `nonce` in an authenticate header will be usable (secs)
sip_from|`nklib:user_uri()`|"NkSIP App <sip:user@nksip>"|Default _From_ to use in the requests
sip_accept|`string()`&#124;`binary()`|"*/*"|If defined, this value will be used instead of default when option `accept` is used
sip_events|`string()`&#124;`binary()`|""|Lists the Event Packages this Service supports
sip_route|`user_uri()`|[]|Route (outbound proxy) to use. Generates one or more `Route` headers in every request, for example `<sip:1.2.3.4;lr>, <sip:abcd;lr>` (you will usually append the `lr` option to use _loose routing_)
sip_no_100|`boolean()`|false|If true, forbids the generation of automatic `100-type` responses for INVITE requests
sip_max_calls|`integer()`|100000|Maximum number of simultaneous calls (for each service)
sip_local_host|auto&#124;`string()`&#124;`binary()`&#124;|auto|Default host or IP to use in headers like _Via_, _Contact_ and _Record-Route_. If set to `auto` NkSIP will use the IP of the transport selected in every case. If that transport is listening on all addresses NkSIP will try to find the best IP using the first valid IP among the network interfaces `ethX` and `enX`, or localhost if none is found
sip_local_host6|auto&#124;`string()`&#124;`binary()`|auto|Default host or IP to use in headers like _Via_, _Contact_ and _Record-Route_ for IPv6 transports. See `local_host` option.


### lager

See specific lager configuration


## Service Configuration

When starting each service, many configuration options can be changed:






## Reconfiguration

Any Service can be reconfigured on the fly. 

Any of the previous parameters can be changed (currently, except for `transports`), and the new options will be used fot the next call.

You can even change the plugin list on the fly, but you must be sure of the effects of such a change.
