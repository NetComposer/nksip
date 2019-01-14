# Starting NkSIP

There are two main ways to start NkSIP:
* Embedded in your own Erlang application
* Starting it in a development environment

### Embedding NkSIP

If you want to embed NkSIP in your own Erlang application, and you are using _rebar_, all you have to do is include it in the list of dependencies in your `rebar.config` file:

```erlang
{deps, [
  {nksip, ".*", {git, "git://github.com/kalta/nksip", {branch, "master"}}}
]}.
```
 
Then you will have to setup in your erlang environment any [configuration parameter](../reference/configuration.md) you want to change from NkSIP's defaults (usually in your `app.config` file), for `nksip` but also some dependant applications like `nkservice`, `nkpacket` or `lager`. You can then start NkSIP starting all dependencies (see [nksip.app.src](../../src/nksip.app.src)) and finally start `nksip` Erlang application.



### Start NkSIP in a development environment

You can start NkSIP stand alone in the following way. First you will need to download and compile it:
```
> git clone https://github.com/kalta/nksip
> cd nksip
> make
```

Of course, select the _tag_ version you want (type `git checkout v.. -q` to use a specific verion)

Then you can start a Erlang shell that automatically starts NkSIP and its dependencies:
```
> make shell
```

NkSIP will use the environment from file `app.config` and the Erlang virtual machine parameters from file `vm.args`, both on the `priv` directory. Update any [configuration parameter](../reference/configuration.md) you want to change from NkSIP's defaults in the `app.config` file before starting.

