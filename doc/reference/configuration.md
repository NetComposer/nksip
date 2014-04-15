# Configuration

There are two types of configuration options:
* Global configuration options. They are defined as standard Erlang environment variables for `nksip` application, and all of them has a default value. SipApps can override most of them.
* SiApp configuration options. They are defined when starting the SipApp calling `nksip:start/4`

## Global configuration options

Name|Default|Comments
---|---|---
timer_t1|500|Standar SIP T1 timer (msecs)
timer_t2|4000|Standar SIP T2 timer (msecs)
timer_t4|5000|Standar SIP T4 timer (msecs)
timer_c|180|Standar SIP C timer (secs)
siapp_timer|5|Interval to process timer in SipApp process (secs)
session_expires|1800|(secs)
min_session_expires|90|(secs)
udp_timeout|180|Time to remove UDP association if no message has been received (secs)
tcp_timeout|180|Time to disconnect TCP/SSL connection if no message has been received (secs)
sctp_timeout|180|Time to disconnect SCTP associations if no message has been received (secs)
ws_timeout|180|Time to disconnect WS/WSS connections if no message has been received (secs)
nonce_timeout|30|Time a new `nonce` in an authenticate header will be usable (secs)
siapp_timeout|32|Time to wait for SipApp responses (secs)
max_calls|100000|Maximum number of simultaneous calls
max_connections|1024|Maximum number of simultaneous TCP/TLS connections NkSIP will accept in each transport belonging to each SipApp
registrar_default_time|3600|Registrar default time (secs)
registrar_min_time|60|Registrar minimum allowed time (secs)
registrar_max_time|86400|Registrar maximum allowed time (secs)
outbound_time_all_fail|30|Time to retry outbound if all connections have failed (secs)
outbound_time_any_ok|90|Time to retry outbound if not all connections have failed (secs)
outbound_max_time|1800|Maximum outbound reconnect time (secs)
dns_cache_ttl|3600|DNS cache TTL (See `nksip_dns`) (secs) (SipApp cannot override)
local_data_path|"log"|Path to store UUID files (SipApps cannot override)


## SipApp configuration options

Key|Type|Default|Description
---|---|---|---
from|`user_uri()`|"NkSIP App <sip:user@nksip>"|Default _From_ to use in the requests
pass|Pass&#124;{Pass, Realm}&#124;[Pass&#124;{Pass, Realm}], Pass::`binary()`, Realm::`binary()`|[]|Passwords to use in case of receiving an _authenticate_ response using `nksip_uac` functions. The first password matching the response´s realm will be used, or the first without any realm if none matches. A hash of the password can be used instead (see `nksip_auth:make_ha1/3`)
register|`user_uri()`|none|NkSIP will try to _REGISTER_ the SipApp with this registrar server or servers (i.e. "sips:sip2sip.info,sips:other.com"). If the SipApp supports outbound (RFC5626), a new reg_id will be generated for each one, a flow will be stablished, and, if the remote party also supports outbound, keep alive messages will be sent over each flow. See `nksip_sipapp_auto:get_registers/1` and `nksip_sipapp:register_update/3`
register_expires|`integer()`|300|In case of register, registration interval (secs)
transports|[{Proto, Ip, Port}&#124;{Proto, Ip, Port, Opts}], Proto::`protocol()`, Ip::`inet:ip_address()`&#124;`string()`&#124;`binary()`&#124;all&#124;all6, Port::`inet:port_number()`&#124;any|[{udp, any, all}, {tls, any, all}]`|The SipApp can start any number of transports. If an UDP transport is started, a TCP transport on the same IP and port will be started automatically. Use `all` to use _all_ available IPv4 addresses and `all6` for all IPv6 addresses, and `any` to use any available port
listeners|`integer()`|1|Number of pre-started listeners for TCP, TLS, WS and WSS (see [Ranch's](http://ninenines.eu/docs/en/ranch/HEAD/guide/introduction) documentation)
certfile|`string()`|"(privdir)/cert.pem"|Path to the certificate file for TLS
keyfile|`string()`|"(privdir)/key.pem"|Path to the key file for TLS
route|`user_uri()`|[]|Route (outbound proxy) to use. Generates one or more `Route` headers in every request, for example `<sip:1.2.3.4;lr>, <sip:abcd;lr>` (you will usually append the `lr` option to use _loose routing_)
registrar|||If present, allows the automatic processing _REGISTER_ requests, even if no `register/3` callback is defined, using `nksip_sipapp:register/3`. The word _REGISTER_ will also be present in all _Allow_ headers.
no_100|||If present, forbids the generation of automatic `100-type` responses for INVITE requests
supported|`string()`&#124;`binary()`|(installed plugins)|If present, these tokens will be used in _Supported_ headers instead of the default supported list, for example "my_token1, mytoken2, 100rel"
event|`string()`&#124;`binary()`|""|Lists the Event Packages this SipApp supports
accept|`string()`&#124;`binary()`|"*/*"|If defined, this value will be used instead of default when option `accept` is used
local_host|auto&#124;`string()`&#124;`binary()`&#124|auto|Default host or IP to use in headers like _Via_, _Contact_ and _Record-Route_. If set to `auto` NkSIP will use the IP of the transport selected in every case. If that transport is listening on all addresses NkSIP will try to find the best IP using the first valid IP among the network interfaces `ethX` and `enX`, or localhost if none is found
local_host6|auto&#124;`string()`&#124;`binary()`|auto|Default host or IP to use in headers like _Via_, _Contact_ and _Record-Route_ for IPv6 transports. See `local_host` option.


