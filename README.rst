MQTTl
=====

Embedable MQTT protocol handler for Erlang applications.

This is meant to be a library you get as a dependency for your app and you
provide the callbacks to do whatever you need your app to do.

Some kind of webmachine for MQTT.

We provide a "reference" implementation so you can see how it's used and
play with it, maybe it even becomes a simple MQTT Server.

Note
----

This library uses modules from `RabbitMQ's MQTT Gateway <https://github.com/rabbitmq/rabbitmq-mqtt>`_
in particular:

* rabbit_mqtt_frame.hrl
* rabbit_mqtt.hrl
* rabbit_mqtt_frame.erl

Those modules are distributed under MPL 1.1

Author
------

Mariano Guerra

License
-------

MPL 2.0, see LICENSE
