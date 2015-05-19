-module(http_gen_handler).

-behaviour(cowboy_http_handler).

%% cowboy_http_handler callbacks
-export([init/3,
         handle/2,
         terminate/3]).

init(_Type, Req, _Opts) ->
    io:format("incoming request ~p ~n",[Req]),
    {ok, Req, no_state}.

handle(Req, _State) ->
    {Method, _} = cowboy_req:method(Req),
    {ok, Reply} = handle_req(Method, Req),
    {ok, Reply, _State}.

handle_req(<<"POST">>, Req) ->
    reply_nok(Req);

handle_req(<<"GET">>, Req) ->
    case cowboy_req:path(Req) of
        {<<"/ons3upload">>, _} ->
          {Params, _} = cowboy_req:qs_vals(Req),
          ReqId = proplists:get_value(<<"reqid">>, Params),
          JsonR = 
            [{<<"type">>, <<"file_upload">>},
             {<<"key">>, proplists:get_value(<<"key">>, Params)},
             {<<"bucket">>,  proplists:get_value(<<"bucket">>, Params)},
             {<<"id">>, ReqId}],
          ws_handler:route_custom(proplists:get_value(<<"user">>, Params), JsonR, ReqId),
          reply_ok(Req);
        _ ->
          reply_nok(Req)
    end;


handle_req(_, Req) -> reply_nok(Req).

terminate(_Reason, _Req, _State) ->
    ok.

%%reply(Req, D) -> cowboy_req:reply(200,[{<<"content-type">>, <<"text/plain">>}], D, Req).
reply_ok(Req) -> cowboy_req:reply(200, [{<<"content-type">>, <<"text/plain">>}], <<"0">>, Req).
reply_nok(Req) -> cowboy_req:reply(200, [{<<"content-type">>, <<"text/plain">>}], <<"-1">>, Req).
