-module(random_token).

-author('pankajsoni@softwarejoint.com').

-export([get_token/0]).

-export([start/0, init/0, stop/0]).

start() ->
    register(register_random_token_generator, spawn(?MODULE, init, [])).

stop() -> register_random_token_generator ! stop_now.

init() ->
    {A1, A2, A3} = now(), random:seed(A1, A2, A3), loop().

loop() ->
    receive
      {From, get_random} ->
          From ! {random, integer_to_binary(random:uniform(999) + (random:uniform(9) * 1000)) }, loop();
        stop_now ->
           stopped;
      _ -> loop()
    end.

get_token() ->
    register_random_token_generator ! {self(), get_random},
    receive
      {random, R} -> R
    end.
