# Plugin architecture

## Overall picture

NkSIP features a sophisticated plugin system, based on the NkSERVICE (https://github.com/Nekso/nkservice) platform. It allows a developer to modify its behaviour without having to modify its core, while having nearly zero overhead. NkSIP itself is a plugin in the NkSERVICE plugin tree. NkSIP Services are top-level plugins.

NkSERVICE defines the lowest possible level of plugin [callbacks](https://github.com/Nekso/nkservice/blob/master/src/nkservice_callbacks.erl), and NkSIP defines its own [_callbacks_](callbacks.md) that defined plugins can override to modify NkSIP standard behaviour or make new functionality available upper plugins (or services). 

They have the concept of _dependency_, so that, if a _pluginA_ implements callback _callback1_, and another plugin _pluginB_ also implements _callback1_:
* If _pluginA_ depends on _pluginB_, the _callback1_ version of _pluginB_ is the one that will be called first, and only if it returns `continue` or `{continue, list()}` the version of `pluginA` would be called.
* If none of them depend on the other, the order in which the callbacks are called is not defined.

Any plugin can have any number of dependant plugins. NkSERVICE will ensure that versions of plugin callbacks on higher order plugins are called first, calling the next only in case it returns `continue` or `{continue, NewArgs}`, and so on, until reaching the default NkSIP's or, eventually, NkSERVICE implementation of the callbackif all defined callbacks decide to continue, or no plugin has implemented this callback). If no plugin has implemented a callback, and no default implementation is found in NkSIP or NkSERVICE, the call will fail.

Plugin callbacks must be implemented in a module called with the same name as the plugin plus _"_callbacks"_ (for example `nksip_registrar_callbacks.erl`).

This callback chain behaviour is implemented in Erlang and **compiled on the fly**, into the generated runtime application callback module (see [run time configuration](runtime_configuration.md)). This way, any call to any plugin callback function is blazing fast, nearly the same as if it were hard-coded from the beginning. 

Each Service can have **different set of plugins**, and it can **it be changed in real time** as any other Service configuration value.



## Plugin configuration


When a Service starts, [you can configure it](../guide/start_a_service.md) to activate any number of the currently installed plugins. For each defined plugin NkSIP will perform a serie of actions (`nksip_registrar` is used as an example plugin): 

1. Find the module `nksip_registrar` that must be loaded.
1. Call `nksip_registrar:deps()` to get the list of dependant modules. Its type is `[Plugin::atom()]`. NkSIP will then include this plugin as if we had included it also in the application configuration, before the dependant plugin, and checking that the version is correct.
1. Possible callback implementations defined in the Service callback module, other plugins and default implementation in NkSIP and NkSERVICE are added to the list.
1. After the sorted list of plugins is complete, implemented callbacks on each of them are extracted as described above, and the corresponding Erlang code is generated.
1. All of it is compiled _on the fly_ in the runtime application callbacks module (called with the same name as the _internal name_ of the Service) 

