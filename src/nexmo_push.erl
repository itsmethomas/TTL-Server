-module(nexmo_push).

-export([start/0,
         stop/0,
         push_sms/2]).

-include("wschat.hrl").

-define(DEF_POOL_SIZE, 2).

start() ->
    random_token:start(),
    inets:start(),
    inets:start(httpc, [{profile, push_sms}]),
    httpc:set_options([{pipeline_timeout, 30000}, {max_sessions, ?DEF_POOL_SIZE}]),
    Key = ws_config:get_local_option(nexmo_push_secret),
    ws_config:add_local_option(nexmo_push_secret, list_to_binary(Key)),
    ok.

push_sms(PN, Pin) ->
    {CC, PhoneNumber} = processed_number(PN),
    case ws_config:get_local_option(nexmo_push_secret) of
        undefined ->
          ?ERROR_MSG("NEXMO URL UNDEFINED", []),
          error;
        Key -> 
               URL = get_nexmo_push_url(Key, CC, PhoneNumber, Pin),
               io:format("Sending nexmo query to ~p ~n",[URL]),
               case httpc:request(get, {URL, [{"User-Agent", "Mozilla/5.0"}]}, [], [{body_format, binary}], push_sms) of
                  {ok, {{"HTTP/1.1",200,"OK"}, _, Response}} ->
	  	    case catch jsx:decode(Response) of
		      [_MCount, {<<"messages">>, MReply}] ->
		    	lists:foldl(fun(S, Acc) ->
                                     case Acc of
                                       error -> error;
                                       ok ->
                                         case proplists:get_value(<<"status">>, S) of
                                           <<"0">> -> ok;
                                           _ -> error
                                         end
                                     end
                        end, ok, MReply);
		      _ -> error
	            end;
                  {error, Reason} ->
                    ?ERROR_MSG("error while sending push message to ~p~n reason ~p~n",[URL, Reason]),
                    error
               end
    end.

get_nexmo_push_url(Key, CC, PhoneNumber, 1) ->
   Data = <<"This%20number%20has%20been%20replaced%20by%20a%20new%20number%20in%20TTL%2C%20please%20contact%20help%40ttl.today%20if%20you%20think%20this%20is%20wrong.">>,
   if CC == 1 ->
      binary_to_list(<<"https://rest.nexmo.com/sc/us/alert/json?"
                         , Key/binary
                         , "&to="
                         , PhoneNumber/binary>>);
   true ->
      binary_to_list(<<"https://rest.nexmo.com/sms/json?"
                         , Key/binary
                         , "&to="
                         , PhoneNumber/binary
                         , "&from=TTL&text="
                         , Data/binary>>)
  end;
 
get_nexmo_push_url(Key, CC, PhoneNumber, Pin) ->
  if CC == 1 ->
      binary_to_list(<<"https://rest.nexmo.com/sc/us/2fa/json?"
                         , Key/binary
                         , "&to="
                         , PhoneNumber/binary
                         , "&pin="
                         , Pin/binary>>);
   true ->
      binary_to_list(<<"https://rest.nexmo.com/sms/json?"
                         , Key/binary
                         , "&to="
                         , PhoneNumber/binary
                         , "&from=TTL&text=Your%20TTL%20code%20is%20"
                         , Pin/binary
                         , ".">>)
  end.

processed_number(Num) ->
    [CC, Num1] = binary:split(Num, <<"-">>),
    {binary_to_integer(CC), <<CC/binary, Num1/binary>>}.

stop() -> 
   inets:stop(httpc, push_sms),
   ok.
