%% @private
-module(wschat_app).
-behaviour(application).

%% API.
-export([start/2,
         stop/1,
         upgrade_handler/1]).

-include("wschat.hrl").

%% API

start(_Type, _Args) -> 
    ws_config:start(),
    aws_s3:start(),
    mod_push:start(),
    mnesia:create_table(session, [{ram_copies, [node()]},
                                  {attributes, record_info(fields, session)}]),
    mnesia:create_table(muc_room, [{disc_copies, [node()]},
                                   {attributes, record_info(fields, muc_room)}]),
    mnesia:create_table(reg_tokens, [{ram_copies, [node()]},
                                     {attributes, record_info(fields, reg_tokens)}]),
    mnesia:create_table(board, [{disc_copies, [node()]},
                                {attributes, record_info(fields, board)}]),
	
	?INFO_MSG("WSChat app is started... ~p ~n", [node()]),
  	mod_push:push_apple(<<"a449ecfdf08a07c2776a8c3083763b462b0d33189e02c62729c61da074e321c9">>, <<"Erlang Message Test">>),
    upgrade_handler(ws_handler),
    websocket_sup:start_link().

upgrade_handler(M) ->
    case ws_config:get_local_option(cowboy_ref) of
        undefined -> ok;
        CR -> cowboy:stop_listener(CR)
    end,
    Dispatch = get_dispatch(M),
    WsPort = ws_config:get_local_option(server_port),
    {ok, CowboyRef} = cowboy:start_https(https, 100,
                                           [{port, WsPort},
                                            {certfile, ws_config:get_local_option(server_cert)},
                                            {cacertfile, ws_config:get_local_option(server_ca_cert)},
                                            {keyfile, ws_config:get_local_option(server_priv_key)},
                                            {password, ws_config:get_local_option(server_priv_key_pass)}],
                                           [{env, [{dispatch, Dispatch}]}]),
    ws_config:add_local_option(cowboy_ref, CowboyRef),
    ok.

get_dispatch(M) when is_binary(M) ->
   get_dispatch(binary_to_atom(M, utf8));

get_dispatch(M) ->
   cowboy_router:compile([
              {'_', [ {"/", cowboy_static, {priv_file, wschat, "index.html"}},
                      {"/websocket", M, []},
                      {"/static/[...]", cowboy_static, {priv_dir, wschat, "static"}}
                    ]}
   ]).

stop(_State) ->
    case ws_config:get_local_option(cowboy_ref) of
        undefined -> ok;
        CowboyRef -> cowboy:stop_listener(CowboyRef)
    end,
    mod_push:stop(),
    ok.
