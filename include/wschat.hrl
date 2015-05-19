%% records

-record(session, {user, pids = []}).
-record(muc_room, {room_id, name , admins = [], members = [], to_join = [] }). 
-record(reg_tokens, {user, token}).
-record(board, {t, data}).

-record(config, {key, val}).
-record(local_config, {key, val}).
-record(config_persistant, {key, val}).

%% constants
-define(DEF_STREAM_TIMEOUT, 30 * 1000). %% 30 seconds same as tcp
-define(DEF_MAX_QUEUE_SIZE, 40).
-define(DIRECTION_IN, <<"i">>).
-define(DIRECTION_OUT, <<"o">>).
-define(HTTP_REQ_TIMEOUT, 30 * 1000). %% same as ajax timeout

%% logging callbacks

-define(PRINT(Format, Args), io:format(Format, Args)).

-define(DEBUG(Format, Args), lager:log(debug, self(), Format, Args)).

-define(INFO_MSG(Format, Args), lager:log(info, self(), Format, Args)).

-define(WARNING_MSG(Format, Args), lager:log(warning, self(), Format, Args)).

-define(ERROR_MSG(Format, Args), lager:log(error, self(), Format, Args)).

-define(CRITICAL_MSG(Format, Args), lager:log(critical, self(), Format, Args)).

