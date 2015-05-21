-module(ws_handler).
-behaviour(cowboy_websocket_handler).

%% ws callbacks
-export([init/3,
	websocket_init/3,
	websocket_handle/3,
	websocket_info/3,
	websocket_terminate/3]).

-export([route_custom/3]).

%%-compile(export_all).

-include("wschat.hrl").

-record(state, {authenticated = false,
                user = <<>>,
                reg_attempts = 0, 
                dict = dict:new(), 
                tref = na}).

-record(dv, {json, ts}).

-define(MAX_REG_ATTEMPTS, 7).

-define(DEF_FLUSH_TIMEOUT, 10000).

init({ssl, http}, Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket, Req, []};

init({tcp, http}, Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket, Req, []}.

websocket_init(_TransportName, Req, _Opts) ->
      {ok, Req, #state{}}.

%% handle login/registration to our server

websocket_handle({text, Msg}, Req, State) when State#state.authenticated == false ->
    case process_unauthenticated(Msg, State) of
        shutdown -> {shutdown, Req, State};
        {noreply, NewState} -> {ok, Req, NewState};
        {JsonR , NewState} -> handle_response(JsonR, Req, NewState)
    end;

websocket_handle({text, Msg}, Req, State) when State#state.authenticated == true ->
    case process_authenticated(Msg, State) of
        shutdown -> {shutdown, Req, State};
        {noreply, NewState} ->  {ok, Req, NewState};
        {JsonR, NewState} ->  handle_response(JsonR, Req, NewState)
    end;

websocket_handle(_Data, Req, State) ->
    ?INFO_MSG("Got unexpected data from client~p ~n", [_Data]),
    {ok, Req, State}.

websocket_info({flush_now, JsonR}, Req, State) ->
    {reply, {text, jsx:encode(JsonR)}, Req, State};

websocket_info({push_to_client, JsonR}, Req, State) ->
    handle_response(JsonR, Req, State);

websocket_info({timeout, _TimerRef, flush_now}, Req, State) ->
    Len = dict:size(State#state.dict),
    if Len > 0 ->
        {Mega,Sec,Micro} = os:timestamp(),
        CurrTs = trunc(((Mega*1000000+Sec)*1000000+Micro)/1000),
        dict:map(fun(_, #dv{json = JsonR, ts = Ts})->
           Duration = CurrTs - Ts,
           if Duration > (?DEF_FLUSH_TIMEOUT) -> 
                 self() ! {flush_now, JsonR};
             true -> ok
           end
        end, State#state.dict),
        TRef = start_timer(State), 
        {ok, Req, State#state{tref = TRef}};
    true ->
        cancel_timer(State),
        {ok, Req, State#state{tref = na}}
    end;

websocket_info(Info, Req, State) ->
    ?ERROR_MSG("Process got something unexpected ~p ~n",[Info]),
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, #state{user = User} = State) ->
    ?INFO_MSG("closing connection for ~p ~n because ~p ~n at pid: ~p ~n",[User, _Reason, self()]),
    cancel_timer(State),
    case User of
        undefined -> ok;
        User ->
            dict:map(fun(_, #dv{json = JsonR})->
                MsgId = proplists:get_value(<<"id">>, JsonR),
                store_offline(User, JsonR, MsgId)
            end, State#state.dict),
            case mnesia:dirty_read(session, User) of
                [] -> ok;
                [#session{pids = Pids} = Sess] when is_list(Pids) ->
                case lists:subtract(Pids, [self()]) of
                     [] -> mnesia:dirty_delete(session, User);
                     NewPids -> mnesia:dirty_write(session, Sess#session{ pids = NewPids })
               end
	 end
    end.

handle_response(JsonR, Req, State) ->
   io:format("Sending reply ~p ~n to user ~p ~n",[JsonR, State#state.user]),
   case proplists:get_value(<<"ack">>, JsonR) of
      true ->
          Len = dict:size(State#state.dict),
          if Len > (?DEF_MAX_QUEUE_SIZE) ->
             cancel_timer(State),
             MsgId = proplists:get_value(<<"id">>, JsonR),
             Dict = dict:store(MsgId
                                 , #dv{json = JsonR, ts = get_timestamp()}
                                 , State#state.dict),
             {shutdown, Req,  State#state{dict = Dict}};
          true ->
             MsgId = proplists:get_value(<<"id">>, JsonR),
             Dict = dict:store(MsgId
		                 , #dv{json = JsonR, ts = get_timestamp()}
                	         , State#state.dict),
             TRef = start_timer(State),
             {reply, {text, jsx:encode(JsonR)}, Req, State#state{dict = Dict, tref = TRef}}
          end;
      _ ->
          {reply, {text, jsx:encode(JsonR)}, Req, State}
   end.
 
process_unauthenticated(Msg, State) ->
    io:format("received unauthenticated stanza ~p ~n",[jsx:decode(Msg)]),
    case catch jsx:decode(Msg) of
     [{<<"type">>, <<"auth">> = Type},
      {<<"username">>, UsernameNB},
      {<<"password">>, Password},
      {<<"id">>, MsgId}] ->
        Username = get_binary(UsernameNB),
        check_and_login(Type, Username, Password, State, MsgId);
     [{<<"type">>, <<"reg">> = Type},
      {<<"username">>, Username},
      {<<"phone_number">>, PN},
      {<<"device_id">>, DeviceId},
      {<<"id">>, MsgId}] ->
         try_register(Type, Username, PN, DeviceId, State, MsgId);
     [{<<"type">>, <<"verify">> = Type}, 
      {<<"username">>, Username}, 
      {<<"phone_number">>, PN},
      {<<"device_id">>, DeviceId},
      {<<"password">>, Pass},
      {<<"token">>, Token}, 
      {<<"id">>, MsgId }] ->
         verify_account(Type, Username, PN, DeviceId, Pass, Token, State, MsgId);
     Json ->
          process_general(Json, State, not_authorized)
    end.

process_authenticated(Json, State) ->
   io:format("received authenticated stanza ~p ~n",[jsx:decode(Json)]),
   MyName = State#state.user,
   case catch jsx:decode(Json) of
       [{<<"type">>, <<"ack">>}, 
        {<<"id">>, MsgId}] ->
            case dict:find(MsgId, State#state.dict) of
                error ->  {noreply, State};
                {ok, #dv{}} -> 
                     %%process_delivered_json(MsgId, JsonR, MyName),
                     DictNew = dict:erase(MsgId, State#state.dict),
                     Len = dict:size(DictNew),
                     if Len == 0 ->
                         cancel_timer(State),
                         {noreply, State#state{dict = DictNew, tref = na}};
                     true ->
                         {noreply, State#state{dict = DictNew}}
                     end
            end;
       [{<<"type">>, <<"change_pswd">> = Type},
        {<<"password">>, Password},
        {<<"id">>, MsgId}] ->
            cass_queries:change_password(MyName, Password),
            {make_response(Type, success, MsgId), State};
       [{<<"type">>, <<"get_s3_policy">> = Type},
        {<<"cat">>, Category},
        {<<"id">>, MsgId}] ->
          {Base64Policy, SignedPolicy, BucketName, AWSKey} = aws_s3:get_s3_policy(Category),
          JsonR =
             [{<<"type">>, Type},
             {<<"aws_key">>, AWSKey},
             {<<"bucket_name">>, BucketName},
             {<<"base64_policy">>, Base64Policy},
             {<<"signed_policy">>, SignedPolicy},
             {<<"code">>, code_map(success)},
             {<<"id">>, MsgId}],
          {JsonR, State};
       [{<<"type">>, <<"get_s3_url">> = Type},
        {<<"key">>, Key},
        {<<"cat">>, Category},
        {<<"id">>, MsgId}] ->
         URL = aws_s3:get_signed_link(Key, Category),
         JsonR =
             [{<<"type">>, Type},
              {<<"key">>, Key},
              {<<"url">>, URL},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
         {JsonR, State};
       [{<<"type">>, <<"set_def">> = Type},
        {<<"avatar">>, Avatar},
        {<<"id">>, MsgId}] ->
         cass_queries:set_default_data(MyName, Avatar),
         {make_response(Type, success, MsgId), State}; 
       %% ------------------------------------------ block api -------------------------------------
       [{<<"type">>, <<"block">> = Type}, 
        {<<"username">>, User},
        {<<"profile_id">>, ProfileId},
        {<<"id">>, MsgId}] ->
          cass_queries:block_user_from_profile(ProfileId, User),
          {make_response(Type, success, MsgId), State};
       [{<<"type">>, <<"get_blocked">> = Type},
        {<<"profile_id">>, ProfileId},
        {<<"id">>, MsgId}] ->
          BL = cass_queries:get_blocked_users(ProfileId),
          JsonR = [{<<"type">>, Type},
                   {<<"blocked">>, BL},
                   {<<"code">>, code_map(success)},
                   {<<"id">>, MsgId}],
          {JsonR, State};
       [{<<"type">>, <<"unblock">> = Type}, 
        {<<"username">>, User},
        {<<"profile_id">>, ProfileId},
        {<<"id">>, MsgId}] ->
          cass_queries:unblock_user_from_profile(ProfileId, User),
          {make_response(Type, success, MsgId), State};
       [{<<"type">>, <<"get_offline_msgs">> = Type},
        {<<"id">>, MsgID}] ->
           push_offline_json(Type, MsgID, MyName),
           {noreply, State};
        %% -------------------------------------- ttl specific functions ----------------------------
       [{<<"type">>, <<"create_profile">> = Type},
        {<<"name">>, Name},
        {<<"profile_name">>, ProfileName},
        {<<"avatar">>, _Av},
        {<<"status">>, Status},
        {<<"profile_type">>, ProfileType},
        {<<"id">>, MsgId}] ->
            ProfileId = make_random_id(),
            Avatar = <<ProfileId/binary, ".jpg">>,
            cass_queries:store_profile(MyName, ProfileId, ProfileName, MyName, Avatar, Status, ProfileType),
            cass_queries:create_profile(ProfileId, Avatar, Name, ProfileName, ProfileType, Status, MyName),
            JsonR = 
              [{<<"type">>, Type},
               {<<"code">>, code_map(success)},
               {<<"profile_id">>, ProfileId},
               {<<"ack">>, true},
               {<<"id">>, MsgId}],
           {JsonR, State};
        [{<<"type">>, <<"update_profile">> = Type},
         {<<"name">>, Name},
         {<<"profile_name">>, ProfileName},
         {<<"avatar">>, _Av},
         {<<"status">>, Status},
         {<<"profile_type">>, ProfileType},
         {<<"profile_id">>, ProfileId},
         {<<"id">>, MsgId}] ->
           Avatar = <<ProfileId/binary, ".jpg">>,
           case cass_queries:check_is_profile_admin(ProfileId, MyName) of
             true ->
               cass_queries:store_profile(MyName, ProfileId, ProfileName, MyName, Avatar, Status, ProfileType),
               Members = cass_queries:get_profile_members(ProfileId),
               lists:foreach(fun(Mem) ->
                 cass_queries:store_profile(Mem, ProfileId, ProfileName, MyName, Avatar, Status, ProfileType)
               end, Members),
               cass_queries:update_profile(ProfileId, Name, Avatar, Status, ProfileName, ProfileType),
               {make_response_ack(Type, success, MsgId), State};
             false ->
               {make_response_ack(Type, not_authorized, MsgId), State}
          end;
        [{<<"type">>, <<"set_profile_avatar">> = Type},
         {<<"profile_id">>, ProfileId},
         {<<"id">>, MsgId}] ->
           Avatar = <<ProfileId/binary, ".jpg">>,
           case cass_queries:check_is_profile_admin(ProfileId, MyName) of
             true ->
               cass_queries:update_profile_avatar(ProfileId, Avatar),
               {make_response_ack(Type, success, MsgId), State};
             _ ->
               {make_response_ack(Type, not_authorized, MsgId), State}
           end;           
        [{<<"type">>, <<"add_users_to_profile">> = Type},
         {<<"users">>, UserL},
         {<<"profile_id">>, ProfileId},
         {<<"profile_type">>, ProfileType},
         {<<"profile_name">>, ProfileName},
         {<<"status">>, Status},
         {<<"avatar">>, _Av},
         {<<"id">>, MsgId}] ->
           Avatar = <<ProfileId/binary, ".jpg">>,
           cass_queries:add_users_to_profile(ProfileId, UserL),
           lists:foreach(fun(U) ->
             cass_queries:store_profile(U, ProfileId, ProfileName, MyName, Avatar, Status, ProfileType)
           end, UserL),
          {make_response_ack(Type, success, MsgId), State};
       [{<<"type">>, <<"leave_profile">> = Type},
        {<<"username">>, User},
        {<<"profile_id">>, ProfileId},
        {<<"id">>, MsgId}] ->
          cass_queries:remove_member_from_profile(ProfileId, User),
          cass_queries:leave_profile(User, ProfileId),
          {make_response_ack(Type, success, MsgId), State};
       [{<<"type">>, <<"save_contacts">> = Type},
        {<<"contacts">>, ContactsR},
        {<<"id">>, MsgId}] ->
           Contacts = cass_queries:save_contacts(MyName, ContactsR),
           Status =  
             lists:map(fun(Elem) ->
               Url =
                 case proplists:get_value(avatar, Elem) of
                   <<>> -> <<>>;
                   Avatar -> aws_s3:get_signed_link(<<Avatar/binary>>, 4)
                 end,
               [{<<"url">>, Url} | Elem]
             end, Contacts),
           JsonR =
              [{<<"type">>, Type},
               {<<"contacts">>, Status},
               {<<"code">>, code_map(success)},
               {<<"id">>, MsgId}],
           { JsonR, State};
        [{<<"type">>, <<"get_contacts">> = Type},
         {<<"id">>, MsgId}] ->
            Friends = cass_queries:get_friends(State),
            Status = 
              lists:map(fun(User) ->
                Avatar = aws_s3:get_signed_link(<<User/binary, ".jpg">>, 4),
                [{<<"username">>, User},
                 {<<"avatar">>, Avatar}]
              end, Friends),
            JsonR = 
              [{<<"type">>, Type},
               {<<"contacts">>, Status},
               {<<"code">>, code_map(success)}, 
               {<<"id">>, MsgId}],
           { JsonR, State};
        [{<<"type">>, <<"get_user_profiles">> = Type},
         {<<"username">>, User},
         {<<"id">>, MsgId}] ->
           Profiles = 
             lists:map(fun({K, V}) -> 
               Val1 = jsx:decode(V),
               Avatar = proplists:get_value(<<"avatar">>, Val1),
               AvatarURL =  aws_s3:get_signed_link(Avatar, 4), 
               [{<<"profile_id">>, K}, {<<"url">>, AvatarURL} |  Val1]
             end, cass_queries:get_user_profiles(User)),
           JsonR = 
             [{<<"type">>, Type},
              {<<"ack">>, true},
              {<<"code">>, code_map(success)},
              {<<"profiles">>, Profiles},
              {<<"id">>, MsgId}],
           { JsonR, State};
        [{<<"type">>, <<"search_profile">> = Type},
         {<<"username">>, User},
         {<<"name">>, Name},
         {<<"id">>, MsgId}] ->
           Profiles = search_user_profiles(User, Name),
           JsonR =
             [{<<"type">>, Type},
              {<<"profiles">>, Profiles},
              {<<"ack">>, true},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           { JsonR, State};
        [{<<"type">>, <<"post">> = Type},
         {<<"ttl">>, TTL},
         {<<"msg">>, MsgI},
         {<<"mtype">>, MType},
         {<<"profile_id">>, ProfileId},
         {<<"hashtag">>, Tags},
         {<<"id">>, MsgId}] ->
           Msg = decode_profile_posts(MsgI, MType),
           PostId = process_post(TTL, MType, MyName, ProfileId, Msg, Tags),
           JsonR = [{<<"type">>, Type},
                    {<<"ttl">>, TTL},
                    {<<"msg">>, Msg},
                    {<<"mtype">>, MType},
                    {<<"profile_id">>, ProfileId},
                    {<<"hashtag">>, Tags},
                    {<<"post_id">>, PostId},
                    {<<"ack">>, true},
                    {<<"code">>, code_map(success)},
                    {<<"from">>, MyName},
                    {<<"id">>, MsgId}],
           route_to_profile(ProfileId, JsonR, MsgId),
           {noreply, State};
        [{<<"type">>, <<"comment">> = Type},
         {<<"profile_id">>, ProfileId},
         {<<"post_id">>, PostId},
         {<<"msg">>, Msg},
         {<<"id">>, MsgId}] ->
           Comment = [{<<"msg">>, Msg},
                      {<<"username">>, MyName}],
           cass_queries:comment_on_post(ProfileId, PostId, integer_to_binary(get_timestamp()), jsx:encode(Comment)),
           JsonR = 
             [{<<"type">>, Type},
              {<<"profile_id">>, ProfileId},
              {<<"post_id">>, PostId},
              {<<"msg">>, Msg},
              {<<"from">>, MyName},
              {<<"ack">>, true},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           route_to_profile(ProfileId, JsonR, MsgId),
           {noreply, State};
        [{<<"type">>, <<"likepost">> = Type},
         {<<"profile_id">>, ProfileId},
         {<<"post_id">>, PostId},
         {<<"ltype">>, LikeType},
         {<<"id">>, MsgId}] ->
           cass_queries:like_post(ProfileId, PostId, MyName, LikeType),
            JsonR =
             [{<<"type">>, Type},
              {<<"profile_id">>, ProfileId},
              {<<"post_id">>, PostId},
              {<<"ltype">>, LikeType},
              {<<"from">>, MyName},
              {<<"ack">>, true},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           route_to_profile(ProfileId, JsonR, MsgId),
           {noreply, State};
        [{<<"type">>, <<"get_post_details">> = Type},
         {<<"profile_id">>, ProfileId},
         {<<"post_id">>, PostId},
         {<<"id">>, MsgId}] ->
           {get_post_details(Type, ProfileId, PostId, MsgId) , State};
        [{<<"type">>, <<"get_profile_posts">> = Type},
         {<<"profile_id">>, ProfileId},
         {<<"from_post">>, PostId},
         {<<"id">>, MsgId}] ->
           Posts = cass_queries:get_profile_posts(ProfileId, PostId),
           PostsParsed = 
             lists:map(fun([{msg, Msg}, {mtype, MType}, {post_id, PID}, {username, User}]) ->
               [{<<"msg">>, decode_profile_posts(Msg, MType)},
                {<<"mtype">>, MType},
                {<<"post_id">>, PID},
                {<<"username">>, User}]
             end, Posts),
           Res =
             [{<<"type">>, Type},
              {<<"posts">>, PostsParsed},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           {Res, State};
         [{<<"type">>, <<"get_random_posts">> = Type},
          {<<"from_ts">>, PostId},
          {<<"id">>, MsgId}] ->
           Posts = cass_queries:get_random_posts(PostId),
           PostsParsed =
             lists:map(fun([{msg, Msg}, {mtype, MType}, {post_id, PID}, {profile_id, ProfileId}, {username, User}]) ->
               [{<<"msg">>, decode_profile_posts(Msg, MType)},
                {<<"mtype">>, MType},
                {<<"post_id">>, PID},
                {<<"profile_id">>, ProfileId},
                {<<"username">>, User}]
             end, Posts),
           Res =
             [{<<"type">>, Type},
              {<<"posts">>, PostsParsed},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           {Res, State};
         [{<<"type">>, <<"get_posts_by_hash_tag">> = Type},
          {<<"tag">>, Tag},
          {<<"profile_id">>, ProfileId},
          {<<"id">>, MsgId}] ->
           Posts = cass_queries:get_profile_posts_by_hash_tag(ProfileId, Tag),
           PostsParsed =
             lists:map(fun([{msg, Msg}, {mtype, MType}, {post_id, PID}, {username, User}]) ->
               [{<<"msg">>, decode_profile_posts(Msg, MType)},
                {<<"mtype">>, MType},
                {<<"post_id">>, PID},
                {<<"username">>, User}]
             end, Posts),   
           Res = 
             [{<<"type">>, Type},
              {<<"posts">>, PostsParsed},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           {Res, State};
         [{<<"type">>, <<"get_profile_members">> = Type},
          {<<"profile_id">>, ProfileId},
          {<<"id">>, MsgId}] ->
           JsonR = 
             [{<<"type">>, Type},
              {<<"members">>, cass_queries:get_profile_members(ProfileId)},
              {<<"code">>, code_map(success)},
              {<<"id">>, MsgId}],
           {JsonR, State};
         [{<<"type">>, <<"edit_profile_members">> = Type},
          {<<"profile_id">>, ProfileId},
          {<<"username">>, User},
          {<<"action">>, AType},
          {<<"id">>, MsgId}] ->
           if (AType == <<"add">>) ->
               cass_queries:add_users_to_profile(ProfileId, [User]);
              (AType == <<"remove">>) ->
               cass_queries:remove_member_from_profile(ProfileId, User);
              true -> ok
           end,
           {make_response_ack(Type, success, MsgId), State};
         [{<<"type">>, <<"delete_post">>},
          {<<"profile_id">>, ProfileId},
          {<<"post_id">>, PostId},
          {<<"id">>, MsgId}] = Data ->
           cass_queries:delete_post(ProfileId, PostId),
           JsonR = [{<<"ack">>, true},
                    {<<"code">>, code_map(success)},
                    {<<"from">>, MyName} | Data],
           route_to_profile(ProfileId, JsonR, MsgId),
           {noreply, State};
         [{<<"type">>, <<"mark_post_read">>},
          {<<"profile_id">>, ProfileId},
          {<<"post_id">>, PostId},
          {<<"id">>, MsgId}] = Data ->
           cass_queries:mark_post_read(ProfileId, PostId, MyName),
           JsonR = [{<<"ack">>, true},
                    {<<"code">>, code_map(success)},
                    {<<"from">>, MyName} | Data],
           route_to_profile(ProfileId, JsonR, MsgId),
           {noreply, State};
         [{<<"type">>, <<"get_read_reciepts">> = Type},
          {<<"profile_id">>, ProfileId},
          {<<"post_id">>, PostId},
          {<<"id">>, MsgId}] ->
            RR = cass_queries:get_post_read_reciepts(ProfileId, PostId), 
            JsonR = 
              [{<<"type">>, Type},
               {<<"read_reciepts">>, RR},
               {<<"profile_id">>, ProfileId},
               {<<"post_id">>, PostId},
               {<<"code">>, code_map(success)},
               {<<"id">>, MsgId}],
            {JsonR, State};
         [{<<"type">>, <<"refer_user">> = Type},
          {<<"username">>, User},
          {<<"id">>, MsgId}] ->
           update_referral_count(User),
           {make_response(Type, success, MsgId), State };
         [{<<"type">>, <<"get_board">> = Type},
          {<<"t">>, BT},
          {<<"id">>, MsgId}] ->
           {get_board(Type, BT, MsgId), State};
         %% ----------------------- register push notification --------------------------
         [{<<"type">>, <<"push_reg">> = Type},
          {<<"token">> , Token},
          {<<"device_type">>, _DType},
          {<<"id">>, MsgId}] ->
           Code = mod_push:register_device(Token, State#state.user),
           {make_response(Type, Code, MsgId) , State };
         %% ----------------------- send unchecked msg to another user -------------------
         [{<<"type">>, Type}, 
          {<<"username">> , ToUser},
          {<<"msg">>, Msg},
          {<<"id">>, MsgId}] ->
           Code = route(Type, ToUser, Msg, State, MsgId),
           {make_response(Type, Code, MsgId), State };
         DecodedJson ->  
           process_general(DecodedJson, State, invalid_syntax)
    end.

process_general(Json, State, Error) ->
    case Json of 
	[{<<"type">>, <<"ckur">> = Type},
         {<<"users">>, UserL},
         {<<"id">>, MsgId}] ->
           UserFL =
             lists:map(fun(User) -> 
               [{<<"username">>, User},
                {<<"exists">>, cass_queries:is_user_exists(User)}]
             end, UserL),
          Res = 
            [{<<"type">>, Type},
             {<<"users">>, UserFL},
             {<<"code">>, code_map(success)},
             {<<"id">>, MsgId}],
          { Res, State};
        [{<<"type">>, <<"logout">>}, _] ->
            shutdown;
        _ -> 
	  { make_response(<<"err">>, Error, <<>>) ,  State }
    end.

try_register(Type, LUser, PN, DeviceId, State, MsgId) ->
    case cass_queries:get_user_registered_info(LUser) of
      not_exist ->  %% new user account
        {send_reg_sms(Type, LUser, PN, processing, MsgId), State};
      {DeviceId, PN} -> %% same device same number, re-registeration
        {send_reg_sms(Type, LUser, PN, processing_exists, MsgId), State};
      {DeviceId, RegNum} when (RegNum /= PN) ->  %% same device new number
        %% notify the old number that its being replaced 
        %% nexmo_push:push_sms(RegNum, 1),  
        {send_reg_sms(Type, LUser, PN, processing_exists, MsgId), State};
      {NewDeviceId, PN} when (NewDeviceId /= DeviceId) -> %% new device id, old phone number
        {send_reg_sms(Type, LUser, PN, processing_exists, MsgId), State};
      {NewDeviceId, RegNum} when (NewDeviceId /= DeviceId) and (RegNum /= PN) -> %% new device and new phone number
         make_response(Type, contact_support, MsgId)
    end.

%send_reg_sms(Type, _, <<>>, _, MsgId) -> make_response(Type, invalid_syntax, MsgId);


send_reg_sms(Type, LUser, _PN, Resp, MsgId) ->
	?INFO_MSG("Process got something unexpected ~p ~n",[Type, LUser, _PN, Resp, MsgId]),
    Token = random_token:get_token(),
	cass_queries:save_pin_for_user(LUser, Token),
    make_response(Type, Resp, MsgId).

%%    Token = random_token:get_token(),
%%    case nexmo_push:push_sms(_PN, Token) of
%%      ok ->
%%        mnesia:dirty_write(reg_tokens, #reg_tokens{user = LUser, token = Token}),
%%        make_response(Type, Resp, MsgId);
%%      error ->
%%         make_response(Type, nexmo_push_error, MsgId)
%%    end.

verify_account(Type, LUser, PN, DeviceId, Pass, Token, State, MsgId) ->
    case mnesia:dirty_read(reg_tokens, LUser) of
        [#reg_tokens{token = Token}] when is_binary(Token) ->
            mnesia:dirty_delete(reg_tokens, LUser), 
            NState = State#state{user = LUser, authenticated = true},
            RegNum = 
              case cass_queries:get_user_registeration_number(LUser) of
                not_exist -> 
                  RN = integer_to_binary(ws_config:get_incremented_persistant_option_counter(reg_number)),
                  cass_queries:update_account(LUser, Pass, DeviceId, RN, RN, PN),
                  RN;
                SRN ->
                  cass_queries:update_account(LUser, Pass, DeviceId, PN),
                  SRN
              end,
            update_session(LUser),
            Res = [{<<"type">>, Type},
                   {<<"reg_no">>, RegNum},
                   {<<"ack">>, true},
                   {<<"code">>, code_map(success)},
                   {<<"id">>, MsgId}],
            {Res, NState};
        _ ->
            Attempts = State#state.reg_attempts + 1,
            if Attempts == (?MAX_REG_ATTEMPTS) ->
                   mnesia:dirty_delete(reg_tokens, LUser),
                   shutdown;
               true ->
                   { make_response(Type, token_does_not_match, MsgId), State#state{reg_attempts = Attempts}}
            end
    end.

check_and_login(Type, LUser, Password, State, MsgId) ->
    case cass_queries:check_password(LUser, Password) of
      true ->
        update_session(LUser),
        cass_queries:update_last_seen(LUser),
        {make_response(Type, success, MsgId),
          State#state{authenticated = true, user = LUser}};
      _ ->
        {make_response(Type, username_password_not_match, MsgId ), State }
    end.

process_post(TTL, MType, MyName, ProfileId, Msg, Tags) ->
    PostId = get_timestamp(),
    MsgB = jsx:encode(Msg),
    cass_queries:update_post(TTL, MType, MyName, ProfileId, MsgB, PostId),
    cass_queries:update_post_timeline(PostId, ProfileId, MsgB, MType, MyName, TTL),
    if (Tags /= <<"">>) ->
        lists:foreach(fun(Tag) ->
          cass_queries:update_tagged_post(ProfileId, Tag, PostId, MsgB, MType, MyName, TTL) 
        end, Tags);
      true ->
        ok
    end,
    PostId.

get_post_details(Type, ProfileId, PostId, MsgId) ->
    case cass_queries:get_post_details(ProfileId, PostId) of
      [] -> [{<<"type">>, Type},
             {<<"profile_id">>, ProfileId},
             {<<"post_id">>, PostId},
             {<<"code">>, code_map(empty)},
             {<<"id">>, MsgId}];
      {CM, LM, RRS} ->
          Comments = lists:map(fun({K, V}) -> [{<<"timestamp">>, K} |  jsx:decode(V)] end, CM),
          Likes = lists:map(fun({K, V}) -> 
                              [{<<"username">>, K}, 
                               {<<"ltype">> , V}] 
                            end, LM),
          [{<<"type">>, Type},
           {<<"profile_id">>, ProfileId},
           {<<"post_id">>, PostId},
           {<<"code">>, code_map(success)},
           {<<"comments">>, Comments},
           {<<"likes">>, Likes},
           {<<"read_reciepts">>, RRS},
           {<<"id">>, MsgId}]
    end.

get_board(Type, BT, MsgId) ->
    Key = binary_to_atom(BT, utf8),
    BD =
      case mnesia:dirty_read(board, Key) of
          [] -> [];
          [#board{data = Data}] -> Data
      end,
    [{<<"type">>, Type},
     {<<"t">>, BT},
     {<<"data">>, BD},
     {<<"ack">>, true},
     {<<"code">>, code_map(success)},
     {<<"id">>, MsgId}].

update_referral_count(User) ->
    Count = cass_queries:update_referral_count(User),
    F = fun() ->
          case mnesia:read(board, leader) of
            [] -> mnesia:write(#board{t = leader, data = [{User, Count}]});
            [#board{} = Board] ->
              ND1 = lists:keyreplace(User, 1, Board#board.data, {User, Count}),
              case lists:keymember(User, 1, ND1) of
                true ->
                  mnesia:write(#board{t = leader, data = ND1});
                false ->
                  ND2 = [{User, Count} | Board#board.data],
                  io:format("~p ~n ~p ~n",[ND2, lists:keysort(2, ND2)]),
                  Elems = lists:keysort(2, ND2),
                  if (length(Elems) > 10) ->
                      [_H | T]  = Elems,
                      mnesia:write(#board{t = leader, data = T});
                  true->
                      mnesia:write(#board{t = leader, data = Elems})
                  end
              end
          end
        end,
    mnesia:transaction(F).

search_user_profiles(LUser, Name) ->
    S = size(Name),
    lists:filter(fun({_K, V}) ->
      case proplists:get_value(<<"profile_name">>, V) of
        <<Name:S/binary, _R/binary>> -> true;
        _ -> false
      end
    end, cass_queries:get_user_profiles(LUser)).

push_offline_json(CurrReqType, MsgId, MyName) ->
    case cass_queries:get_offline_msgs(MyName) of
      [] -> self() ! {push_to_client, make_response(CurrReqType, empty, MsgId)};
      OFL ->
        lists:foreach(fun(JsonB) ->
          JsonR = jsx:decode(JsonB),
          self() ! {push_to_client, JsonR},
          SMsgId = proplists:get_value(<<"id">>, JsonR),
          cass_queries:remove_offline_msg(MyName, SMsgId)
        end, OFL),
        self() ! {push_to_client, make_response(CurrReqType, success, MsgId)}
    end.

route(Type, ToUser, Msg, State, MsgId) ->
    MyName = State#state.user,    
    Ts = get_timestamp(),
    JsonR  = make_response_ack(Type,  Msg, MsgId, MyName, Ts),
    case get_pids(ToUser) of
        false ->
	  user_does_not_exist;
        true ->
	  mod_push:push_message(State#state.user, ToUser, Type, Msg),
          store_offline(ToUser, JsonR, MsgId);
	Pids ->
          lists:foreach(fun(Pid) ->
            Pid ! {push_to_client, JsonR}
          end, Pids),
          success
    end. 

route_to_profile(ProfileId, Json, MsgId) ->
    Mems = cass_queries:get_profile_members(ProfileId),
    lists:foreach(fun(U) ->
      route_custom(U, Json, MsgId)
    end, Mems).

route_custom(ToUser, JsonR, MsgId) ->
    case get_pids(ToUser) of
      false ->
        user_does_not_exist;
      true ->
        store_offline(ToUser, JsonR, MsgId);
      Pids ->
        lists:foreach(fun(Pid) ->
          Pid ! {push_to_client, JsonR}
        end, Pids),
      success
    end.

update_session(LUser) ->
    case mnesia:dirty_read(session, LUser) of
        [] ->
            mnesia:dirty_write(session, #session{user = LUser, pids = [self()]});
        [#session{pids = Pids} = Sess] when is_list(Pids) ->
            NewPids = [self() | Pids],
            mnesia:dirty_write(session, Sess#session{ pids = NewPids })
    end.

get_pids(User) ->
    case mnesia:dirty_read(session, User) of
        [] -> cass_queries:is_user_exists(User);
        [Sess] ->  Sess#session.pids
    end.

store_offline(ToUser, JsonR, MsgId) ->
    case proplists:get_value(<<"ack">>, JsonR) of
        true ->
            JsonF = 
              case proplists:get_value(<<"off">>, JsonR) of
                  true -> JsonR;
                  _ -> [{<<"off">>, true}| JsonR]
              end,
            cass_queries:store_offline(ToUser, jsx:encode(JsonF), MsgId), 
            user_offline_delivered_later;
        _ ->
            user_offline_not_delivered
    end.

decode_profile_posts(P, MType) when is_binary(P) ->
  J = jsx:decode(P),
  decode_profile_posts(J, MType);

decode_profile_posts(J, MType) ->
  case proplists:get_value(<<"mediaName">>, J) of
    MN when is_binary(MN) -> [{<<"mediaURL">>, aws_s3:get_signed_link(MN, MType)} | J];
    undefined -> J
  end.

make_response(Type, Code, MsgId) ->
    CB = code_map(Code),
    [{<<"type">>, Type},
     {<<"code">>, CB},
     {<<"id">>, MsgId}].

make_response_ack(Type, Code, MsgId) ->
    CB = code_map(Code),
    [{<<"type">>, Type},
     {<<"code">>, CB},
     {<<"ack">>, true},
     {<<"id">>, MsgId}].

make_response_ack(Type, Msg, MsgId, From, Ts) ->
   [{<<"type">>, Type},
    {<<"username">>, From},
    {<<"msg">>, Msg},
    {<<"timestamp">>, Ts},
    {<<"ack">>, true}, 
    {<<"id">>, MsgId}].

cancel_timer(State) ->
    case State#state.tref of
       Timer when (Timer /= na) -> erlang:cancel_timer(Timer);
       _ -> ok
    end.

start_timer(State) ->
    case State#state.tref of
      na -> erlang:start_timer(?DEF_FLUSH_TIMEOUT, self(), flush_now);
      TimerRef -> 
         case erlang:read_timer(TimerRef) of
           false ->
               erlang:start_timer(?DEF_FLUSH_TIMEOUT, self(), flush_now);
           _ -> 
               TimerRef
         end
    end.

get_timestamp() ->
    {Mega,Sec,Micro} = os:timestamp(),
    trunc(((Mega*1000000+Sec)*1000000+Micro)/1000).

%binary_to_lower(D) ->
%    list_to_binary(string:to_lower(binary_to_list(D))).


get_binary(I) when is_integer(I) -> integer_to_binary(I);
get_binary(I) when is_list(I) -> list_to_binary(I);
get_binary(I) when is_binary(I) -> I.

make_random_id() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:rand_bytes(16),
    Str = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
                        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(Str).

%% success

code_map(success) -> 0;
code_map(fail) -> 1;
code_map(processing) -> 2;
code_map(registered) -> 3;
code_map(already_registered) -> 4;
code_map(joined) -> 5;
code_map(processing_exists) -> 6;
code_map(has_more) -> 7;

%% error
code_map(token_does_not_match) -> 51;
code_map(username_already_taken) -> 52;
code_map(username_password_not_match) -> 53;
code_map(invalid_syntax) -> 54;
code_map(nexmo_push_error) -> 55;
code_map(invalid_username) -> 56;
code_map(invalid_room_id) -> 57;
code_map(not_authorized) -> 58;
code_map(interal_room_jr) -> 59;
code_map(user_does_not_exist) -> 60;
code_map(user_offline) -> 61;
code_map(user_offline_delivered_later) -> 62;
code_map(user_offline_not_delivered) -> 63;
code_map(already_joined) -> 64;
code_map(empty) -> 65;
code_map(internal_error) -> 66;
code_map(phone_number_already_taken) -> 67;
code_map(ignored) -> 68;
code_map(single_number_registered) -> 69;
code_map(username_birthday_not_match) -> 70;
code_map(contact_support) -> 71;
code_map(_) -> 100.

