# NkSIP SipApps` API

Function|Description
---|---
[start/4](#start4)|Starts a new SipApp


### new/2
```erlang
nksip_sdp:new(Host::string()|binary(), MediaSpecs::[nksip_sdp:media_spec()]) -> 
    nksip_sdp:sdp().
```
    
Generates a simple base SDP record. 

It will use the indicated `Host` and a `MediaSpecs` description to generate a new `nksip_sdp:sdp()` record, having several `m` sections, one for each media. 

Each media must define a `Media` (like `<<"audio">>` or `<<"video">>`), a `Port` and a list of `Attributes`. Each attributes can have the form `{rtpmap, Pos, Data}` to define a codec (like `{rtpmap, 0, <<"PCMU/8000">>}`) or a standard SDP `a` attribute (like `<<"inactive">>` or `<<"ptime:30">>`). The class will be `RTP/AVP`.

If `Host` is `"auto.nksip"`, NkSIP it will be changed to the current local address
before sending.

See [sdp3_test/0](../../src/nksip_sdp.erl) for an example.


### new/0
```erlang
nksip_sdp:new() ->
    nksip_sdp:sdp().
```

Generates a simple base SDP record (see [new/2](#new2), using host `"auto.nksip"`, port `1080`, codec `"PCMU"`, and `inactive`.


### empty/0
```erlang
nksip_sdp:empty() ->
    nksip_sdp:sdp().
```

Generates an empty SDP record, using host `"local.nksip"` (see [new/2](#new2)).
Equivalent to `new(<<"auto.nksip">>, [])`.


### increment/1
```erlang
nksip_sdp:increment(nksip_sdp:sdp()) ->
    nksip_sdp:sdp().
```

Increments the SDP version by one.


### update/2
```erlang
nksip_sdp:update(nksip_sdp:sdp(), inactive | recvonly | sendonly | sendrecv) ->
    nksip_sdp:sdp().
```

Updates and SDP changing all medias to `inactive`, `recvonly`, `sendonly` or `sendrecv` and incrementing the SDP version.


### is_sdp/1
```erlang
nksip_sdp:is_sdp(term()) ->
    boolean().
```

Checks if term is an valid SDP.


### is_new/2
```erlang
nksip_sdp:is_new(SDP2::undefined|nksip_sdp:sdp(), SDP1::undefined|nksip_sdp:sdp()) ->
    boolean().
```

Checks if `SDP2` is newer than `SDP1`.
If any of them are `undefined`, returns `false`.

### parse/1
```erlang
nksip_sdp:parse(binary()) -> 
    nksip_sdp:sdp() | error.
```

Parses a binary SDP packet into a `nksip_sdp:sdp()` record or `error`.

### unparse/1
```erlang
nksip_sdp:unparse(nksip_sdp:sdp()) -> 
    binary().
```

Generates a binary SDP packet from an `nksip_sdp:sdp()` record.


