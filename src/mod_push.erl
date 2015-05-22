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

%% get_expiration_time_in_secs() ->
%%     SecondsNow = calendar:datetime_to_gregorian_seconds(calendar:now_to_local_time(now())),
%%     SecondsInit = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
%%     (SecondsNow - SecondsInit) + 86400.
