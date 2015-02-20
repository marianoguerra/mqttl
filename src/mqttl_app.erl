-module(mqttl_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    Acceptors = 100,
    MaxConnections = 1024,
    Port = 1883,
	{ok, _} = ranch:start_listener(mqttl, Acceptors, ranch_tcp,
                                   [{port, Port},
                                    {max_connections, MaxConnections}],
                                   mqttl_protocol,
                                   [{handler_opts, [{handler, mqttl_dummy_handler_impl}]}]),
    mqttl_sup:start_link().

stop(_State) ->
    ok.
