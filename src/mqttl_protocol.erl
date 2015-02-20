-module(mqttl_protocol).
-behaviour(ranch_protocol).

-export([start_link/4]).
-export([init/4]).

-record(state, {parse_state, rest, timeout=180000, pid}).

-include("rabbit_mqtt_frame.hrl").

start_link(Ref, Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
	{ok, Pid}.

init(Ref, Socket, Transport, Opts) ->
	ok = ranch:accept_ack(Ref),
    ParseState = rabbit_mqtt_frame:initial_state(),
    HandlerOpts = proplists:get_value(handler_opts, Opts, []),
    Send = fun(MsgId, Topic, Data) ->
                   Msg = make_pub_msg(MsgId, Topic, Data),
                   send(Socket, Transport, Msg)
           end,
    HandlerOptsAndSend = [{mqttl_send, Send}|HandlerOpts],
    {ok, Pid} = mqttl_handler:start_link(HandlerOptsAndSend),
    State = #state{parse_state=ParseState, rest= <<>>, pid=Pid},
	loop(Socket, Transport, State).

loop(Socket, Transport, State=#state{rest= <<>>, timeout=Timeout, pid=Pid}) ->
	case Transport:recv(Socket, 0, Timeout) of
		{ok, Data} ->
            handle(Socket, Transport, State, Data);
		Other ->
            handle_error(Pid, Socket, Transport, Other)
	end;

loop(Socket, Transport, State=#state{rest=Rest}) ->
    handle(Socket, Transport, State, Rest).

handle(Socket, Transport, State=#state{parse_state=ParseState, pid=Pid}, Data) ->
    case rabbit_mqtt_frame:parse(Data, ParseState) of
        {more, ParseState1} ->
            State1 = State#state{parse_state=ParseState1},
            loop(Socket, Transport, State1);
        {ok, Frame, Rest} ->
            State1 = State#state{rest= Rest},
            case mqttl_handler:handle_message(Pid, Frame) of
                ok -> 
                    loop(Socket, Transport, State1);
                {send, Msg} ->
                    lager:debug("replying ~p", [Msg]),
                    send(Socket, Transport, Msg),
                    loop(Socket, Transport, State1);
                {send_and_disconnect, Msg, Reason} ->
                    lager:debug("replying and disconnecting ~p, reason ~p", [Msg, Reason]),
                    send(Socket, Transport, Msg),
                    stop(Pid, Socket, Transport);
                {disconnect, Reason} ->
                    lager:debug("handler requested disconnection ~p", [Reason]),
                    stop(Pid, Socket, Transport)
            end;
        {error, _Reason}=Error ->
            lager:error("MQTT detected framing error '~p' for connection", [Error]),
            handle_error(Pid, Socket, Transport, Error)
    end.

handle_error(Pid, Socket, Transport, Error) ->
    mqttl_handler:handle_error(Pid, Error),
    stop(Pid, Socket, Transport).

stop(Pid, Socket, Transport) ->
    mqttl_handler:stop(Pid),
    ok = Transport:close(Socket).

%% private api

send(Socket, Transport, Msg) ->
    Bin = rabbit_mqtt_frame:serialise(Msg),
    Transport:send(Socket, Bin).

make_pub_msg(MsgId, Topic, Payload) ->
    Qos = 0,
    #mqtt_frame{fixed=#mqtt_frame_fixed{type=?PUBLISH, qos=Qos},
                variable=#mqtt_frame_publish{topic_name=Topic, message_id=MsgId},
                payload=Payload}.
