# Plugin writer guide

Please have a look at [runtime configuration](runtime_configuration.md) and [plugin architecture](plugin_architecture.md) before reading this guide.


* [Plugins or Services](#plugins-or-services)
* [Plugin main module description](#plugin-main-module-description)
* [Plugin callbacks module description](#plugin-callbacks-module-description)
* [Application callbacks module description](#application-callbacks-module-description)
* [How to write a plugin](#how-to-write-a-plugin)


## Plugins or Services

Sometimes the doubt about writing a specific functionality as a Service or a plugin may arise. As a rule of thumb, plugins should implement functionality useful to a broad range of Services.

Examples of plugins could be:
* New RFCs implementation.
* Event packages.
* New authentication algorithms.
* Connection to standard external databases or services.

Some differences of Services and plugins are:

Concept|Service Callbacks|Plugin Callbacks
---|---|---
Language|Erlang currently (in the future other languages will be available)|Erlang only
Diffculty|Low|High (must understand how NkSIP works)
Flexibility|Medium|High (full access to NkSIP structures)
Dependency on NkSIP version|Low|High
Speed|Very High (if Erlang)|Very High



## Plugin main module description

### Mandatory functions
A plugin must have a _main_ Erlang module, that **must implement** the following functions:

#### deps/0
```erlang
deps() ->
    [atom()].
```

Must return the list of dependant plugins. Its type is `[{Plugin::atom(), VersionRE::string()|binary()}]`. NkSIP will find the requested plugins and make sure their version is correct. `VersionRE` is a regular expression that will be applied againts found dependant plugins.


#### plugin_start/1
```erlang
plugin_start(nkservice:spec()) ->
	{ok, nkservice:spec()} | {stop, term()}.
```

Once created the service gen_server process, this function will be called on each configured plugin, and also when updating the configuration. It must read any configuration option from the service specification and add any needed parsed configuration.


#### plugin_stop/1
```erlang
plugin_stop(nkservice:spec()) ->
	{ok, nkservice:spec()} | {stop, term()}.
```

Called when the service is stopped, or the plugin is disconnected.


## Plugin callbacks module description

Then plugin can also include an Erlang module called after the main module, but ending in `_callbacks` (for example `nksip_registrar_callbacks`). 

In this case, any function exported in this module is considered as a _plugin callback_ by NkSIP:

* If NkSIP has a _plugin callback_ with the same name and arity, this function is included in the plugin chain as described in [plugin architecture](plugin_architecture.md).
* If there is no _plugin callback_ with the same name and arity, it is a new _plugin callback_ that other plugins can overload.

The [nksip_registrar](../plugins/registrar.md) plugin is an example of plugin that exports _plugin callback_ functions for other plugins to overload.


# How to write a plugin

To write a new plugin:

1. Create a module with the name of your plugin (for example `my_plugin.erl`).
1. Define the function `my_plugin:deps()` returning a list of dependant plugins and required versions, plugin_start/1 and plugin_stop/2.
1. Put in this module any other public API function you want to make available to Services. 
1. Create a module with the same name as the main module but ending in "_callbacks" (for example `my_plugin_callbacks.erl`), and implement in it the [plugin callbacks functions](plugin_callbacks.md) you want to override. Each plugin callback can return:
	* `continue`: continue calling the next plugin callback, or the default NkSIP implementation if no other is available.
	* `{continue, Args::list()}`: continue calling the next plugin, but changing the calling parameters on the way.
	* `AnyOther`: finish the callback chain, return this value to NkSIP. The effect depends on each specific callback (see [_plugin callbacks_](plugin_callbacks.md)).
1. Service can now request to use your plugin using the `plugins` configuration option.

NkSIP's official core plugins are found in the `nksip_core_plugins` repository. You can place new plugins wherever you want, as long as they are compiled and available in the Erlang code path. They can be standard Erlang applications or not, whatever makes more sense for each specific plugin.



### Contribute a plugin

If you think your plugin is interesting for many users, and it meets NkSIP code quality standards, please send a pull request to be included as a standard plugin.
