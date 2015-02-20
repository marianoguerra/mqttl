-module(mqttl_dummy_handler_impl).
-behaviour(mqttl_handler).

-export([init/1, stop/1, terminate/2, info/2, timeout/2, ping/1, connect/1,
         disconnect/1, error/2, publish/2, subscribe/2, unsubscribe/2,
         login/2]).

-record(state, {}).

init([]) -> {ok, #state{}}.
ping(State=#state{}) -> {ok, State}.
connect(State=#state{}) -> {ok, State}.
disconnect(State=#state{}) -> {ok, State}.

error(State=#state{}, Error) ->
    lager:error("Error ~p", [Error]),
    {ok, State}.

publish(State=#state{}, {Topic, Qos, Dup, Retain, MessageId, Payload}) ->
    lager:info("Publish ~p ~p ~p ~p ~p ~p",
               [Topic, Qos, Dup, Retain, MessageId, Payload]),
    {ok, State}.

subscribe(State=#state{}, Topics) ->
    R = lists:foldl(fun ({TopicName, Qos}, {QosList, IState}) ->
                            OState = IState,
                            QosVal = Qos,
                            lager:info("Subscribe ~p ~p", [TopicName, Qos]),
                            {[QosVal|QosList], OState}
                    end, {[], State}, Topics),
    {QoSList, NewState} = R,
    {ok, QoSList, NewState}.

unsubscribe(State=#state{}, Topics) ->
    NewState = lists:foldl(fun (TopicName, IState) ->
                            OState = IState,
                            lager:info("Unsubscribe ~p", [TopicName]),
                            OState
                    end, State, Topics),
    {ok, NewState}.

timeout(State=#state{}, InactiveMs) ->
    lager:info("session was inactive for ~p ms", [InactiveMs]),
    {ok, State}.

info(State=#state{}, Msg) ->
    lager:info("received info message '~p'", [Msg]),
    {ok, State}.

stop(State=#state{}) ->
    lager:info("stop"),
    {ok, State}.

terminate(State=#state{}, Reason) ->
    lager:info("terminate ~p", [Reason]),
    {ok, State}.

login(State=#state{}, {Username, Password}) ->
    lager:info("login ~p", [Username, Password]),
    {ok, State}.
