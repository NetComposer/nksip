# Plugin writer guide

Please have a look at [runtime configuration](run_time_configuration.md) and [plugin architecture](plugin_architecture.md) before reading this guide.


 Each pluig callback can return:
	* `continue`: continue calling the next plugin callback, or the default NkSIP implementation if no other is available.
	* `{continue, Args::list()}`: continue calling the next plugin, but changing the called parameters
	* AnyOther: finish the callback chain, the effect depend on each specific callback (see [_plugin callbacks_](plugin_callbacks.md)) 

