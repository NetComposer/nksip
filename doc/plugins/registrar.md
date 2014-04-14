# Registrar Server

NkSIP includes a full registrar implementation according to RFC3261. "Path" is also supported according to RFC3327.

It uses by default the buil-in, RAM-only store, but can be configured to use any other database implementing callback `registrar_store/3`.

Each started SipApp maintains its fully independent set of registrations.
When a new REGISTER request arrives at a SipApp, and if you order to `process` the request in `route/6` callback, NkSIP will try to call `register/3` callback if it is defined. If it is not defined, but `registrar` option was present in the SipApp's startup config, NkSIP will process the request automatically. 

If you implement `register/3` to customize the registration process you should call {@link `nksip_registrar:request/1` directly.

Use `nksip_registrar:find/4` or `nksip_registrar:qfind/4` to search for a specific registration's 
contacts, and `nksip_registrar:is_registered/1` to check if the `Request-URI' of a 
specific request is registered.
