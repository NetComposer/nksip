# Configuration

* [Global configuration options](#global-configuration-options).
* [Service configuration options](#service-configuration).
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
sctp_out_streams|`integer()`|10|Default SCTP out streams
sctp_in_streams|`integer()`|10|Default SCTP in streams
tls_certfile|`string()`|-|Custom certificate file
tls_keyfile|`string()`|-|Custom key file
tls_cacertfile|`string()`|-|Custom CA certificate file
tls_password|`string()`|-|Password fort the certificate
tls_verify|`boolean()`|false|If we must check certificate
tls_depth|`integer()`|0|TLS check depth


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
sip_local_host6|auto&#124;`string()`&#124;`binary()`|auto|Default host or IP to use in headers like _Via_, _Contact_ and _Record-Route_ for IPv6 transports. See `local_host` option
sip_udp_max_size|`integer()`|65507|Maximum UDP packet size. Bigger packets will be sent using TCP

### lager

See specific lager configuration


## Service Configuration

When starting each service, all sip_-class global configuration options can be used, and also:

Name|Type|Default|Comments
---|---|---|---
plugins|`atom`|[]|List of plugins to use
sip_listen|`atom`|"sip:all"|List of transports to use.
service_idle_timeout|`integer()`|(depends on transport)|Default connection idle timeout
service_connect_timeout|(global)|Default outbound connection idle timeout
service_sctp_out_streams|`integer()`|10|Default SCTP out streams
service_sctp_in_streams|`integer()`|10|Default SCTP in streams
tcp_listeners|`integer()`|10|Default number of TCP listenersº
tls_certfile|`string()`|-|Custom certificate file
tls_keyfile|`string()`|-|Custom key file
tls_cacertfile|`string()`|-|Custom CA certificate file
tls_password|`string()`|-|Password fort the certificate
tls_verify|`boolean()`|false|If we must check certificate
tls_depth|`integer()`|0|TLS check depth


See [NkPACKET documentation](https://github.com/Nekso/nkpacket) for a description of allowed transports.
Some examples are:

```erlang
"<sip:127.0.0.1;transport=ws>;idle_timeout=5000"
"<sip:localhost:5060>, <sips:localhost:5061>;tls_password=pass"
```

All transport-related options above are allowed in URLs.

# Reconfiguration

Any Service can be reconfigured on the fly. 

Any of the previous parameters can be changed and the new options will be used fot the next call. 

You can even change the plugin list on the fly, but you must be sure of the effects of such a change.

You can add transports at any time, but must stop manually any transport you don't want to use any more.
