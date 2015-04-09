# Logging Options

Although [Lager](https://github.com/basho/lager) is specified as dependency, NkSIP only uses the standard `error_logger` for its internal logging. This means that NkSIP does not enforce a certain logging framework. However, `lager` is used for all `samples` as well as the unit tests.

NkSIP allows adjusting a log level per `SipApp` (also at runtime) using the `log_level` option described in the [configuration](configuration.md) section.

To get SIP message tracing, activate the [nksip_trace](../plugins/trace.md) plugin.
