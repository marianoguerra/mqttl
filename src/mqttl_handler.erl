-module(mqttl_handler).
-behaviour(gen_server).

-include("rabbit_mqtt_frame.hrl").
-include("mqttl.hrl").

-export([start_link/1, handle_message/2, handle_error/2, stop/1]).

-export([behaviour_info/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-ignore_xref([behaviour_info/1]).

-record(state, {proc_state=init, handler, handler_state, will_msg,
                timeout=30000, send}).

behaviour_info(callbacks) ->
    [{init, 1},
     {stop, 1},
     {terminate, 2},
     {ping, 1},
     {connect, 1},
     {disconnect, 1},
     {error, 2},
     {publish, 2},
     {subscribe, 2},
     {unsubscribe, 2},
     {timeout, 2},
     {info, 2},
     {login, 2}];

behaviour_info(_Other) ->
    undefined.

%% Public API

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

handle_message(Pid, Msg) ->
    gen_server:call(Pid, {msg, Msg}).

handle_error(Pid, Error) ->
    gen_server:call(Pid, {error, Error}).

stop(Module) ->
    gen_server:call(Module, stop).


%% Server implementation, a.k.a.: callbacks

init([Opts]) ->
    {handler, Handler} = proplists:lookup(handler, Opts),
    HandlerOpts = proplists:get_value(user_handler_opts, []),
    {mqttl_send, Send} = proplists:lookup(mqttl_send, Opts),
    Timeout = proplists:get_value(inactive_timeout_ms, Opts, 30000),
    UserHandlerOpts = [{mqttl_send, Send}|HandlerOpts],
    {ok, HandlerState} = Handler:init(UserHandlerOpts),
    State = #state{handler=Handler, handler_state=HandlerState,
                   timeout=Timeout, send=Send},
    {ok, State}.

handle_call({msg, Msg}, _From, State) ->
    lager:debug("received ~p", [Msg]),
    {Reply, NewState} = process_message(Msg, State),
    {reply, Reply, NewState, NewState#state.timeout};

handle_call({error, Error}, _From, State=#state{handler=Handler, handler_state=HState}) ->
    lager:debug("error receiving data ~p", [Error]),
    {ok, NewHState} = Handler:error(HState, Error),
    NewState = State#state{handler_state=NewHState},
    {reply, ok, NewState, NewState#state.timeout};

handle_call(stop, _From, State=#state{handler=Handler, handler_state=HState}) ->
    lager:debug("stopping handler"),
    {ok, NewHState} = Handler:stop(HState),
    NewState = State#state{handler_state=NewHState},
    {stop, normal, stopped, NewState};

handle_call(Msg, _From, State) ->
    io:format("Unexpected handle call message: ~p~n",[Msg]),
    {reply, {error, unexpected_message}, State, State#state.timeout}.

handle_cast(Msg, State) ->
    io:format("Unexpected handle cast message: ~p~n",[Msg]),
    {noreply, State}.

handle_info(timeout, State=#state{handler=Handler, handler_state=HState}) ->
    {ok, NewHState} = Handler:timeout(HState, State#state.timeout),
    NewState = State#state{handler_state=NewHState},
    {noreply, NewState};

handle_info(Msg, State=#state{handler=Handler, handler_state=HState}) ->
    {ok, NewHState} = Handler:info(HState, Msg),
    NewState = State#state{handler_state=NewHState},
    {noreply, NewState}.

terminate(Reason, #state{handler=Handler, handler_state=HState}) ->
    Handler:terminate(HState, Reason),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% private api

process_message(#mqtt_frame{fixed=#mqtt_frame_fixed{type=Type}},
                State=#state{proc_state=init}) when Type /= ?CONNECT ->
    {{disconnect, connect_expected}, State};
process_message(#mqtt_frame{fixed=#mqtt_frame_fixed{type=Type}}=Msg, State) ->
    process_request(Type, Msg, State).

process_request(?CONNECT, #mqtt_frame{variable=#mqtt_frame_connect{
                                          username   = _Username,
                                          password   = _Password,
                                          proto_ver  = ProtoVersion,
                                          clean_sess = CleanSess,
                                          client_id  = ClientId0,
                                          keep_alive = _Keepalive}=Var},
                State=#state{handler=Handler, handler_state=HandlerState}) ->

    InvalidId = ClientId0 =:= [] andalso CleanSess =:= false,
    ProtocolSupported = ProtoVersion == ?MQTT_3_1_1_VERSION,

    if ProtocolSupported ->
           ReplyMsg = conn_ack_msg(?CONNACK_ACCEPT),
           {ok, NewHState} = Handler:connect(HandlerState),
           WillMsg = make_will_msg(Var),
           {{send, ReplyMsg},
            State#state{proc_state=connected, handler_state=NewHState,
                       will_msg=WillMsg}};

       InvalidId ->
           ReplyMsg = conn_ack_msg(?CONNACK_INVALID_ID),
           State1 = State#state{proc_state=error},
           Reason = {invalid_id, {ClientId0, CleanSess}},
           {{send_and_disconnect, ReplyMsg, Reason}, State1};
       true ->
           ReplyMsg = conn_ack_msg(?CONNACK_PROTO_VER),
           State1 = State#state{proc_state=error},
           Reason = {unknown_protocol, ProtoVersion},
           {{send_and_disconnect, ReplyMsg, Reason}, State1}
    end;

process_request(?PINGREQ, #mqtt_frame{},
                State=#state{handler=Handler, handler_state=HandlerState}) ->
    {ok, NewHState} = Handler:ping(HandlerState),
    Msg = #mqtt_frame{fixed=#mqtt_frame_fixed{type=?PINGRESP}},
    {{send, Msg}, State#state{handler_state=NewHState}};

process_request(?SUBSCRIBE,
                #mqtt_frame{variable=#mqtt_frame_subscribe{message_id=MessageId,
                                                           topic_table=Topics},
                            payload=undefined},
                State=#state{handler=Handler, handler_state=HandlerState}) ->

    TupleTopics = to_tuple_topics(Topics),
    {ok, QosResponse, NewHState} = Handler:subscribe(HandlerState, TupleTopics),
    Msg = sub_ack_msg(MessageId, QosResponse),
    {{send, Msg}, State#state{handler_state=NewHState}};

process_request(?UNSUBSCRIBE,
                #mqtt_frame{variable=#mqtt_frame_subscribe{message_id=MessageId,
                                                           topic_table=Topics},
                            payload=undefined},
                State=#state{handler=Handler, handler_state=HandlerState}) ->

    TopicNames = to_topic_names(Topics),
    {ok, NewHState} = Handler:unsubscribe(HandlerState, TopicNames),
    Msg = unsub_ack_msg(MessageId),
    {{send, Msg}, State#state{handler_state=NewHState}};

process_request(?PUBLISH,
                #mqtt_frame{fixed=#mqtt_frame_fixed{qos=Qos, retain=Retain,
                                                    dup=Dup},
                            variable=#mqtt_frame_publish{topic_name=Topic,
                                                         message_id=MessageId},
                            payload=Payload},
                State=#state{handler=Handler, handler_state=HandlerState}) ->
    Args = {Topic, Qos, Dup, Retain, MessageId, Payload},
    {ok, NewHState} = Handler:publish(HandlerState, Args),
    {ok, State#state{handler_state=NewHState}};

process_request(?DISCONNECT, #mqtt_frame{},
                State=#state{handler=Handler, handler_state=HandlerState}) ->
    {ok, NewHState} = Handler:disconnect(HandlerState),
    {{disconnect, client_disconnect}, State#state{handler_state=NewHState}}.

conn_ack_msg(ReturnCode) ->
    #mqtt_frame{fixed=#mqtt_frame_fixed{type=?CONNACK},
                variable=#mqtt_frame_connack{return_code=ReturnCode}}.

sub_ack_msg(MessageId, QosResponse) ->
    #mqtt_frame{fixed=#mqtt_frame_fixed{type=?SUBACK},
                variable=#mqtt_frame_suback{message_id=MessageId,
                                            qos_table=QosResponse}}.

unsub_ack_msg(MessageId) ->
    #mqtt_frame{fixed=#mqtt_frame_fixed{type=?UNSUBACK},
                variable=#mqtt_frame_suback{message_id=MessageId}}.

to_tuple_topics(Topics) ->
    lists:map(fun (#mqtt_topic{name=TopicName, qos=Qos}) -> {TopicName, Qos} end,
              Topics).

to_topic_names(Topics) ->
    lists:map(fun (#mqtt_topic{name=TopicName}) -> TopicName end, Topics).

make_will_msg(#mqtt_frame_connect{will_flag=false}) ->
    undefined;
make_will_msg(#mqtt_frame_connect{will_retain=Retain, will_qos=Qos,
                                  will_topic=Topic, will_msg=Msg}) ->

    #mqtt_msg{retain=Retain, qos=Qos, topic=Topic, dup=false, payload= Msg}.
