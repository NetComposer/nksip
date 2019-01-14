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

To be done. See example plugins.

