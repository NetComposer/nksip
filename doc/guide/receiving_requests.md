# Receiving Requests

Once started a SipApp and listening on a set of transports, ips and ports, it can start receiving requests from other SIP endpoints. 

When a new request is received, NkSIP will launch a new Erlang process to manage the request and its response. It will start calling specific functions in the callback module defined when the SipApp was started. See `nksip_sipapp` for a detailed description of available callback functions.

Many of the functions in the callback module allow to send a response to the incoming request. NkSIP allows you to use easy response codes like `busy`, `redirect`, etc. Specific responses like `authenticate` are used to send an authentication request to the other party. In case you need to, you can also reply any response code, headers, and body. 

It is also possible to send _reliable provisional responses_, that the other party will acknoledge with a _PRACK_ request. All of it is handled by NkSIP automatically.

The full list of recognized responses is a available in [Sending Responses](sending_responses.md)


