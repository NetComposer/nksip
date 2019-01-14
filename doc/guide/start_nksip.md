# Starting NkSIP

There are two main ways to start NkSIP:
* Embedded in your own Erlang application
* Starting it in a development environment

### Embedding NkSIP

If you want to embed NkSIP in your own Erlang application, and you are using _rebar_, all you have to do is include it in the list of dependencies in your `rebar.config` file:

```erlang
{deps, [
  {nksip, {git, "git://github.com/kalta/nksip", {branch, "master"}}}
]}.
```
 
You can then start NkSIP starting all dependencies (see [nksip.app.src](../../src/nksip.app.src)) and finally start `nksip` Erlang application.



### Start NkSIP in a development environment

You can start NkSIP stand alone in the following way. First you will need to download and compile it:
```
> git clone https://github.com/NetComposer/nksip
> cd nksip
> make
```

Of course, select the _tag_ version you want (type `git checkout v.. -q` to use a specific verion)

Then you can start a Erlang shell that automatically starts NkSIP and its dependencies:
```
> make shell
```

NkSIP will use the environment from file [shell.config](../../config/shell.config).
