# Event State Compositor

NkSIP includes full support to receive PUBLISH requests and store the the publisher state, according to RFC3903.

It uses by default the buil-in, RAM-only store, but can be configured to use any other database implementing callback `publish_store/3`.


