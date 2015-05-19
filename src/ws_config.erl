-module(ws_config).

-author('Pankaj Soni<pankajsoni@softwarejoint.com>').

-include("wschat.hrl").

-export([start/0,
         add_global_option/2, add_local_option/2, add_persistant_option/2,
         get_global_option/1, get_local_option/1, get_persistant_option/1,
         get_incremented_persistant_option_counter/1]).

start() ->
  Env = application:get_all_env(wschat),
  RemoteNode = proplists:get_value(clustering, Env),
  start(RemoteNode, Env).

start(RemoteNode, Env) ->
    case RemoteNode of
      undefined ->
        db_init();
      {master, Node} ->
        join_as_master(Node);
      {slave, Node} ->
        join(Node);
      _ ->
        ?ERROR_MSG("incorrect remote node name  ~p ~n" , [RemoteNode])
    end,
    create_config_tables(),
    lists:foreach(fun({Key, Val}) -> add_local_option(Key, Val) end, Env).

create_config_tables() ->
    mnesia:create_table(config_persistant, [{disc_copies, [node()]},
                                 {attributes, record_info(fields, config_persistant)}]),
    mnesia:create_table(config,
                    [{ram_copies, [node()]},
                     {attributes, record_info(fields, config)}]),
    mnesia:add_table_copy(config, node(), ram_copies),
    mnesia:create_table(local_config,
                     [{ram_copies, [node()]},
                       {local_content, true},
                       {attributes, record_info(fields, local_config)}]),
    mnesia:add_table_copy(local_config, node(), ram_copies).

add_global_option(Key, Val) ->
    mnesia:dirty_write(config, #config{key = Key, val = Val}).

add_local_option(Key, Val) ->
    mnesia:dirty_write(local_config, #local_config{key = Key, val = Val}).

add_persistant_option(Opt, Val) ->
    mnesia:transaction(fun() -> mnesia:write(#config_persistant{key = Opt, val = Val}) end).

get_global_option(Key) ->
    case mnesia:dirty_read(config, Key) of
      [#config{val = Value}] -> Value;
      _ -> undefined
    end.

get_local_option(Key) ->
    case mnesia:dirty_read(local_config, Key) of
      [#local_config{val = Value}] -> Value;
      _ -> undefined
    end.

get_persistant_option(Opt) ->
    case mnesia:dirty_read(config_persistant, Opt) of
      [#config_persistant{val = Val}] -> Val;
      _ -> undefined
    end.

get_incremented_persistant_option_counter(Opt) ->
    F = 
      fun() ->
        NVal =
          case mnesia:read(config_persistant, Opt) of
            [] -> 1;
            [#config_persistant{val = Val}] -> Val + 1
          end,
        mnesia:write(#config_persistant{key = Opt, val = NVal}),
        NVal
      end,
    case mnesia:transaction(F) of
     {aborted, _Reason} -> -1;
     {atomic, Res} -> Res
    end.

join(NodeName) ->
    mnesia:stop(),
    mnesia:delete_schema([node()]),
    mnesia:start(),
    mnesia:change_config(extra_db_nodes, [NodeName]),
    mnesia:change_table_copy_type(schema, node(), disc_copies).

join_as_master(NodeName) ->
    mnesia:stop(),
    mnesia:delete_schema([node()]),
    mnesia:start(),
    mnesia:change_config(extra_db_nodes, [NodeName]),
    mnesia:change_table_copy_type(schema, node(), disc_copies),
    sync_node(NodeName).

sync_node(NodeName) ->
    lists:foreach(fun(Table) ->
        case mnesia:table_info(Table, where_to_commit) of
          [{NodeName, Type}] -> mnesia:add_table_copy(Table, node(), Type);
          _ -> ok
        end
    end, mnesia:system_info(tables)).

db_init() ->
    case mnesia:system_info(extra_db_nodes) of
        [] ->
            %application:stop(mnesia),
            mnesia:create_schema([node()]);
            %application:start(mnesia, permanent);
        _ ->
            ok
    end,
    mnesia:wait_for_tables(mnesia:system_info(local_tables), infinity).
