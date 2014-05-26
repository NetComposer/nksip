# Run-time configurarion

NkSIP implements and advanced and very efficient run-time configuration system. As explained in [the reference guide](../reference/configuration.md), it has two types of configuration options:
* Global configuration options. They are defined as standard Erlang environment variables for `nksip` application, and all of them has a default value. Any started SipApp can override most of them.
* SiApp configuration options. They are defined when starting the SipApp calling `nksip:start/4`

Upon starting NkSIP, the functions in module [nksip_config.erl](../../src/nksip.config.erl) read the global configuration from the `nksip` application environment variables, defining defaults for missing values, and store them in a ETS table, accesible using `nksip_config:get/1,2`.

It also generates and compiles _on the fly_ the module `nksip_config_cache`,  copying commonly used values as functions in this module, as `nksip_config_cache:global_id/0`. The on-disk file `nksip_config_cache.erl` is only a mockup to make it easier to understand the process.


