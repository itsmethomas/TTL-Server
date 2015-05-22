-module(mod_push).

-author('pankajsoni@softwarejoint.com').

-export([start/0,
         stop/0,
         register_device/2,
         deregister_device/3,
         push_message/4,
         push/2,
         feedback/1,
		 push_apple/2,
		 push_test/0]).

-include("wschat.hrl").

-define(CLEAN_UP_TIME, 3600000).

-define(DEVICE_TOKEN,
        "a449ecfdf08a07c2776a8c3083763b462b0d33189e02c62729c61da074e321c9").

-define(TEST_CONNECTION, 'test-connection').

-record(user_token, {user, token}).
-record(token_user, {token, timestamp, user}).

start() ->
%% ex_apns:start(apple, ws_config:get_local_option(ios_profile), 
%%                 {ws_config:get_local_option(ios_push_cert), ws_config:get_local_option(ios_cert_pass)}),

    ex_apns:start(apple, ws_config:get_local_option(ios_profile), 
                  ws_config:get_local_option(ios_push_cert)),
  nexmo_push:start(),
  register(apple_token_cleaner, spawn(?MODULE, feedback, [undefined])),
  mnesia:create_table(user_token, [{disc_copies, [node()]},
                               {attributes, record_info(fields, user_token)}]),
  mnesia:create_table(token_user, [{disc_copies, [node()]},
                               {attributes, record_info(fields, token_user)}]),
  ok.

stop() ->
  nexmo_push:stop(),
  apple_token_cleaner ! stop,
  ex_apns:stop(apple),
  ok.

register_device(Token, User) ->
  Timestamp = get_timestamp_for_device_token(),
  mnesia:dirty_write(token_user, #token_user{token = Token, timestamp = Timestamp, user = User}),
  mnesia:dirty_write(user_token, #user_token{user = User, token = Token}),
  registered.

feedback(Timer) ->
  TimerRef =
  case Timer of
    undefined ->
      erlang:send_after(?CLEAN_UP_TIME, self(), clean);
    _ ->
      case erlang:read_timer(Timer) of
        false ->
          erlang:send_after(?CLEAN_UP_TIME, self(), clean);
        _ ->
          Timer
     end
  end,
  receive
    clean ->
      case ex_apns:feedback(apple) of
        Tokens when is_list(Tokens) ->
          lists:foreach(fun({TokenInt, Ts}) ->
            TokenU = ex_apns:token_to_binary(TokenInt),
            Token = << <<(string:to_lower(X))>> || <<X>> <= TokenU >> ,
            deregister_device(apple, Token, Ts)
          end, Tokens);
         _ -> ok
      end,
      feedback(TimerRef);
    stop ->
      ok;
    _ ->
      feedback(TimerRef)
  end.

deregister_device(apple, Token, DelTs) ->
    case mnesia:dirty_read(token_user, Token) of
      [#token_user{timestamp = TS, user = User}] when DelTs > TS ->
         mnesia:dirty_delete({token_user, Token}),
         mnesia:dirty_delete({user_token, User}),
         deregistered;
      _ -> 
	reregistered
    end.	

push_message(From, User, <<"msg">>, Msg) ->
    push(User, <<From/binary, " says ", Msg/binary>>);

push_message(From, User, <<"room_msg">>, Msg) ->
   push(User, <<From/binary, " says ", Msg/binary>>);

push_message(_, _, _ , _) -> ok.

push(User, Msg) ->
    case mnesia:dirty_read(user_token, User) of
       [#user_token{token = Token}] when (Token /= <<>>) ->
         push_apple(Token, Msg);
       _ -> 
           ok
    end.

%% internal functions.

push_apple(Token, Msg) when (Token /= <<>>) ->
    Payload = jsx:encode([{<<"aps">>, [{<<"alert">>, Msg}, {<<"badge">>, 0}, {<<"sound">>, <<"default">>}]}]),
	?INFO_MSG ("Payload : ~p ~n", [Payload, Token]),
    ex_apns:send(apple, Token, Payload).

get_timestamp_for_device_token() ->
    SecondsNow = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(now())),
    SecondsInit = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    SecondsNow - SecondsInit.

push_test() ->
  Now = lists:flatten(io_lib:format("~p", [calendar:local_time()])),
  ok = apns:start(),
  {ok, Pid} =
    apns:connect(?TEST_CONNECTION, fun log_error/2, fun log_feedback/1),
  Ref = erlang:monitor(process, Pid),
  ok =
    apns:send_message(
      ?TEST_CONNECTION, ?DEVICE_TOKEN,
      Now ++ " - Test Alert", random:uniform(10), "chime"),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg ->
      throw(DownMsg);
    DownMsg ->
      throw(DownMsg)
    after 1000 ->
      ok
  end,
  ok =
    apns:send_message(
      ?TEST_CONNECTION,
      ?DEVICE_TOKEN,
      #loc_alert{ action = "ACTION",
                  args   = ["arg1", "arg2"],
                  body   = Now ++ " - Localized Body",
                  image  = none,
                  key    = "KEY"},
      random:uniform(10),
      "chime"),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg2 ->
      throw(DownMsg2);
    DownMsg2 ->
      throw(DownMsg2)
    after 1000 ->
      ok
  end,
  ok =
    apns:send_message(
      ?TEST_CONNECTION, ?DEVICE_TOKEN, #loc_alert{key = "EMPTY"},
      random:uniform(10), "chime"),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg3 ->
      throw(DownMsg3);
    DownMsg3 ->
      throw(DownMsg3)
    after 1000 ->
      ok
  end,
  ok =
    apns:send_message(
      ?TEST_CONNECTION, ?DEVICE_TOKEN, Now ++ " - Test Alert",
      random:uniform(10), "chime",
      apns:expiry(86400), [{<<"acme1">>, 1}]),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg4 ->
      throw(DownMsg4);
    DownMsg4 ->
      throw(DownMsg4)
    after 1000 ->
      ok
  end,
  ok =
    apns:send_message(
      ?TEST_CONNECTION, ?DEVICE_TOKEN,
      #loc_alert{ action = "ACTION",
                  args   = ["arg1", "arg2"],
                  body   = Now ++ " - Localized Body",
                  image  = none,
                  key    = "KEY"},
      random:uniform(10), "chime",
      apns:expiry(86400),
      [ {<<"acme2">>, <<"x">>},
        {<<"acme3">>, {[{<<"acme4">>, false}]}}]),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg5 ->
      throw(DownMsg5);
    DownMsg5 ->
      throw(DownMsg5)
    after 1000 ->
      ok
  end,
  ok = apns:send_message(?TEST_CONNECTION, #apns_msg{device_token = ?DEVICE_TOKEN,
                                 sound = "chime",
                                 badge = 12,
                                 expiry = apns:expiry(86400),
                                 alert = "Low Priority alert",
                                 priority = 0}),
  receive
    {'DOWN', Ref, _, _, _} = DownMsg6 ->
      throw(DownMsg6);
    DownMsg6 ->
      throw(DownMsg6)
    after 1000 ->
      ok
  end.

log_error(MsgId, Status) ->
  error_logger:error_msg("Error on msg ~p: ~p~n", [MsgId, Status]).

log_feedback(Token) ->
  error_logger:warning_msg("Device with token ~p removed the app~n", [Token]).

%% get_expiration_time_in_secs() ->
%%     SecondsNow = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(now())),
%%     SecondsInit = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
%%     (SecondsNow - SecondsInit) + 86400.
