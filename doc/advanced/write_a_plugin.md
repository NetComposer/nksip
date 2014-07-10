# Plugin writer guide

Please have a look at [runtime configuration](runtime_configuration.md) and [plugin architecture](plugin_architecture.md) before reading this guide.


### Plugins or SipApps

Sometimes the doubt about writing a specific functionality as a SipApp or a plugin may arise. As a rule of thumb, plugins should implement functionality useful to a broad range of SipApps.

Examples of plugins could be:
* New RFCs implementation.
* Event packages.
* New authentication algorithms.
* Connection to standard external databases or services.

Some differences of SipApps and plugins are:

Concept|SipApp Callbacks|Plugin Callbacks
---|---|---
Language|Erlang currently (in the future other languages will be available)|Erlang only
Diffculty|Low|High (must understand how NkSIP works)
Flexibility|Medium|High (full access to NkSIP structures)
Dependency on NkSIP version|Low|High
Speed|Very High (if Erlang)|Very High



### How to write a plugin

To write a new plugin:

1. Create a module with the name of your plugin (for example `my_plugin`).
1. Define the function `my_plugin:version()` returning the current version of it (as a `string()` or `binary()`). Other plugins may request a dependency on a specific version of the plugin.
1. Define the function `my_plugin:deps()` returning a list of depatendant plugins and required versions. Its type is `[{Plugin::atom(), VersionRE::string()|binary()}]`. NkSIP will find the requested plugins and make sure their version is correct. `VsersionRE` is a regular expressio tha
t will be applied againts found dependant plugins.
1. Put in this module any other public API function you want to make available to SipApps. 
1. Create a module with the same name as the main module buandt ending in "_callbacks" (for example `my_plugin_callbacks.erl`), and implement in it the [plugin callbacks functions](plugin_callbacks.md) you want to override. Each pluig callback can return:
	* `continue`: continue calling the next plugin callback, or the default NkSIP implementation if no other is available.
	* `{continue, Args::list()}`: continue calling the next plugin, but changing the called parameters
	* AnyOther: finish the callback chain, the effect depend on each specific callback (see [_plugin callbacks_](plugin_callbacks.md)) 
1. If your plugin is going to offer new application-level callbacks to SipApps using this module, place them in a module with the same name as the main module but ending in "_sipapp" (for example `my_plugin_sipapp.erl`). Please notice that NkSIP will not allow two different pluigns implement the same application callback module, or reimplement a [standard NkSIP application callback](../reference/callback_functions.md). For this reason it is recomended that they are named after the name of the plugin (i.e. "my_plugin_callback1")
1. SipApp can now request to use your plugin using the `plugins` configuration option.

NkSIP's official plugins are found in the `plugins` directory of the distribution. You can place n
new plugins wherever you want, as long as they are compiled and available in the Erlang code path. They can be standard Erlang applications or not, whatever makes more sense for each specific plugin.

If you think your plugin is interesting for many users, and meets NkSIP code quality standards, please send a pull request to be included as a standard plugin.
