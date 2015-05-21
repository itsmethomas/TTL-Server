-module(cass_queries).

%% wschat cass query api exports

-export([store_offline/3,
		 cass_test/3,
         get_offline_msgs/1,
         remove_offline_msg/2,
         set_default_data/2,
         is_user_exists/1,
         update_account/4,
         update_account/6,
         check_password/2,
         update_last_seen/1,
         change_password/2,
         get_user_registeration_number/1,
         get_user_registered_info/1,
         get_friends/1,
         block_user_from_profile/2,
         get_blocked_users/1,
         unblock_user_from_profile/2,
         create_profile/7,
         store_profile/7,
         check_is_profile_admin/2,
         update_profile/6,
         update_profile_avatar/2,
         add_users_to_profile/2,
         remove_member_from_profile/2,
         leave_profile/2,
         save_contacts/2,
         update_post/6,
         update_post_timeline/6,
         update_tagged_post/7,
         comment_on_post/4,
         like_post/4,
         get_post_details/2,
         get_profile_posts/2,
         get_random_posts/1,
         get_profile_posts_by_hash_tag/2,
         get_user_profiles/1,
         get_profile_members/1,
         delete_post/2,
         mark_post_read/3,
         get_post_read_reciepts/2,
         update_referral_count/1]).

%% cass gen api exports

-export([get_cass_query_result/1,
         get_cass_prep_query_result/2,
         send_cass_query/1,
         send_cass_prep_query/2,
         send_cass_batch_queries/1]).

%% maybe used later
-export([store_conversation_to/7]).

-include_lib("cqerl/include/cqerl.hrl").
-include("wschat.hrl").

%% wschat cassandra query exports

cass_test(User, Id, Msg) ->
	Q = <<"INSERT into offline(username, msg_id, msg) VALUES(?, ?, ?) ;">>,
    Vals = [{username, User},
            {msg_id, Id},
            {msg, Msg}],
    send_cass_prep_query(Q, Vals).

store_conversation_to(User, OtherID, Ts, Msg, Type, MsgId, Direction) ->
    Q = <<"INSERT INTO conversation(username, other_id, ts, msg, type, msg_id, direction) VALUES(?, ?, ?, ?, ?, ?, ?);">>,
    Vals = [{username, User},
            {other_id, OtherID},
            {ts, Ts},
            {msg, Msg},
            {type, Type},
            {msg_id, MsgId},
            {direction, Direction}],
    send_cass_prep_query(Q, Vals).

store_offline(User, Msg, Id) ->
    Q = <<"INSERT into offline(username, msg_id, msg) VALUES(?, ?, ?) ;">>,
    Vals = [{username, User},
            {msg_id, Id},
            {msg, Msg}],
    send_cass_prep_query(Q, Vals).

get_offline_msgs(User) ->
    Q = <<"SELECT msg from offline WHERE username = ? ;">>,
    Vals = [{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      Msgs -> lists:map(fun([{msg, Msg}]) -> Msg end, Msgs)
    end.

remove_offline_msg(User, MsgId) ->
    Q = <<"DELETE FROM offline WHERE username = ? AND msg_id = ? ;">>,
    Vals = [{username, User},
            {msg_id, MsgId}],
    send_cass_prep_query(Q, Vals).

set_default_data(User, Avatar) ->
    Q = <<"UPDATE user_data SET avatar = ?, updated_at = ? WHERE username = ? ;">>,
    Vals = [{username, User},
            {avatar, Avatar},
            {updated_at, now}],
    send_cass_prep_query(Q, Vals).

is_user_exists(User) ->
    Q = <<"SELECT username FROM user_data WHERE username = ? ;">>,
    Vals = [{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{username, User}]] -> true;
      _ -> false
    end.

update_account(User, Pass, DeviceId, Number) ->
    Q = <<"UPDATE user_data SET password = ?, number = ?, last_seen = ?, device_id = ? WHERE username = ? ;">>,
    Vals = [{password, Pass},
            {number, Number},
            {last_seen, now},
            {device_id, DeviceId},
            {username, User}],
    send_cass_prep_query(Q, Vals).

update_account(Username, Password, DeviceId, RegNo, CRegNo, Number) ->
    Q = <<"UPDATE user_data SET password = ?, number = ?, last_seen = ?, reg_no = ?, creg_no = ?, device_id = ? WHERE username = ? ;">>,
    Vals = [{password, Password},
            {number, Number},
            {last_seen, now},
            {reg_no, RegNo},
            {creg_no, CRegNo},
            {device_id, DeviceId},
            {username, Username}],
    send_cass_prep_query(Q, Vals).

check_password(Username, Password) ->
    Q = <<"SELECT password FROM user_data WHERE username = ? ;">>,
    Vals =[{username, Username}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{password, Password}]] -> true;
      _ -> false
    end.

update_last_seen(Username) ->
    Q = <<"UPDATE user_data SET last_seen = ? WHERE username = ? ;">>,
    Vals =[{last_seen, now},
           {username, Username}],
    send_cass_prep_query(Q, Vals).

change_password(Username, Password) ->
    Q = <<"UPDATE user_data SET password = ? WHERE username = ? ;">>,
    Vals =[{password, Password},
           {username, Username}],
    send_cass_prep_query(Q, Vals).

get_user_registeration_number(User) ->
    Q = <<"SELECT reg_no FROM user_data WHERE username = ? ;">>,
    Vals =[{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{reg_no, RegNo}]] -> RegNo;
      _ -> not_exist
    end.

get_user_registered_info(User) ->
    Q = <<"SELECT device_id, number FROM user_data WHERE username = ? ;">>,
	?INFO_MSG("get_user_registered_info query ~p ~n",[Q]),
    Vals =[{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{device_id, D}, {number, N}]] -> {D, N};
      _ -> not_exist
    end.

get_friends(User) ->
    Q = <<"SELECT friends FROM user_data WHERE username = ? ;">>,
    Vals =[{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{friends, Friends}]] -> Friends;
      _ -> []
    end.

block_user_from_profile(ProfileId, User) ->
    Q = <<"UPDATE profile SET blocked = blocked + ? WHERE profile_id = ? ;">>,
    Vals = [{blocked, [User]},
            {profile_id, ProfileId}],
    send_cass_prep_query(Q, Vals).

get_blocked_users(ProfileId) ->
    Q = <<"SELECT blocked FROM profile WHERE profile_id = ? ;">>,
    Vals = [{profile_id, ProfileId}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{blocked, Blocked}]] -> Blocked;
      _ -> []
    end.

unblock_user_from_profile(ProfileId, User) ->
    Q = <<"UPDATE profile SET blocked = blocked - ? WHERE profile_id = ? ;">>,
    Vals = [{blocked, [User]},
            {profile_id, ProfileId}],
    send_cass_prep_query(Q, Vals).

create_profile(ProfileId, Avatar, Name, ProfileName, ProfileType, Status, User) ->
    Q = <<"INSERT INTO profile (profile_id, avatar, updated_at, name, profile_name, profile_type, status, created_by, users) VALUES (?, ?, ?, ?, ?, ?, ?, ?);">>,
    Vals =[{profile_id, ProfileId},
           {avatar, Avatar},
           {updated_at, now},
           {name, Name},
           {profile_name, ProfileName},
           {profile_type, ProfileType},
           {status, Status},
           {created_by, User},
           {users, [User]}],
    send_cass_prep_query(Q, Vals).

store_profile(User, ProfileId, ProfileName, ProfileAdmin, Avatar, Status, ProfileType) ->
    ValJ =
      [{<<"profile_name">>, ProfileName},
       {<<"admin">>, ProfileAdmin},
       {<<"avatar">>, Avatar},
       {<<"status">>, Status},
       {<<"profile_type">>, ProfileType},
       {<<"cbm">>, (User == ProfileAdmin)}],
    Val = jsx:encode(ValJ),
    Q = <<"UPDATE user_data SET profiles = profiles + ? WHERE username= ? ;">>,
    Vals = [{username, User},
            {profiles, [{ProfileId, Val}]}],
    send_cass_prep_query(Q, Vals).

check_is_profile_admin(ProfileId, User) ->
    Q = <<"SELECT created_by FROM profile WHERE profile_id = ? ;">>,
    Vals =[{profile_id, ProfileId}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{created_by, User}]] -> true;
      _ -> false
    end.

update_profile(ProfileId, Name, Avatar, Status, ProfileName, ProfileType) ->
    Q = <<"UPDATE profile SET name = ?, avatar = ?, updated_at = ?, status = ?, profile_name = ?, profile_type = ? where profile_id = ? ;">>,
    Vals = [{name, Name},
            {avatar, Avatar},
            {updated_at, now}, 
            {status, Status},
            {profile_name, ProfileName},
            {profile_type, ProfileType},
            {profile_id, ProfileId}],
    send_cass_prep_query(Q, Vals).

update_profile_avatar(ProfileId, Avatar) ->
    Q = <<"UPDATE profile SET avatar = ?, updated_at = ? where profile_id = ? ;">>,
    Vals = [{avatar, Avatar},
            {updated_at, now},
            {profile_id, ProfileId}],
    send_cass_prep_query(Q, Vals).

add_users_to_profile(ProfileId, UserL) ->
    Q = <<"UPDATE profile SET users = users + ? WHERE profile_id = ?;">>,
    Vals = [{profile_id, ProfileId},
            {users, UserL}],
    send_cass_prep_query(Q, Vals).

leave_profile(User, ProfileId) ->
    Q = <<"DELETE profiles[?] FROM user_data WHERE username = ? ;">>,
    Vals = [{username, User},
            {'key(profiles)', ProfileId}],
    send_cass_prep_query(Q, Vals).

save_contacts(User, ContactsR) ->
    Contacts = 
      lists:filtermap(fun(U) ->
         case get_user_def(U) of
           false -> false;
           D -> {true, [{contact, U} | D]}
         end
      end, ContactsR),
    Friends = lists:map(fun(Elem) -> proplists:get_value(contact, Elem) end, Contacts),
    Q = <<"UPDATE user_data SET friends = friends + ? WHERE username = ?;">>,
    Vals = [{username, User},
            {friends, Friends}],
    send_cass_prep_query(Q, Vals),
    Contacts.

get_user_def(User) ->
    Q = <<"SELECT avatar, updated_at FROM user_data WHERE username = ?;">>,
    Vals = [{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{avatar, null}, U]] -> [{avatar,<<>>}, U];
      [D] -> D;
      _ -> false
    end.

update_post(TTL, MType, User, ProfileId, Msg, PostId) ->
    Q1 = <<"UPDATE profile_post SET username = ?, msg = ?, mtype = ? WHERE profile_id = ? AND post_id = ?">>,
    Q =
      if (TTL == <<"null">>) or (TTL == <<"infinite">>) -> Q1;
         true -> <<Q1/binary, " USING TTL ", TTL/binary>>
      end,
    Vals = [{username, User},
            {msg, Msg},
            {mtype, MType},
            {profile_id, ProfileId},
            {post_id, PostId}],
    send_cass_prep_query(Q, Vals).

update_post_timeline(PostId, ProfileId, Msg, MType, User, TTL) ->
    Q1 = <<"INSERT INTO post_timeline(post_id, profile_id, msg, mtype, username) VALUES (?, ?, ?, ?, ?)">>,
    Q =
      if (TTL == <<"null">>) or (TTL == <<"infinite">>) -> Q1;
         true -> <<Q1/binary, " USING TTL ", TTL/binary>>
      end,
    Vals = [{post_id, PostId},
            {profile_id, ProfileId},
            {msg, Msg},
            {mtype, MType},
            {username, User}],
    send_cass_prep_query(Q, Vals).

update_tagged_post(ProfileId, Tag, PostId, Msg, MType, User, TTL) ->
    Q1 = <<"INSERT INTO post_tags(profile_id, tag, post_id, msg, mtype, username) VALUES (?, ?, ?, ?, ?, ?)">>,
    Q = 
       if (TTL == <<"null">>) or (TTL == <<"infinite">>) -> Q1;
         true -> <<Q1/binary, " USING TTL ", TTL/binary>>
       end,
    Vals = [{profile_id, ProfileId},
            {tag, Tag},
            {post_id, PostId},
            {msg, Msg},
            {mtype, MType},
            {username, User}],
    send_cass_prep_query(Q, Vals).

comment_on_post(ProfileId, PostId, CommentID, Comment) ->
    Q = <<"UPDATE profile_post SET comments = comments + ? WHERE profile_id = ? AND post_id = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId},
            {comments, [{CommentID, Comment}]}],
    send_cass_prep_query(Q, Vals).

like_post(ProfileId, PostId, User, Like) ->
    Q = <<"UPDATE profile_post SET likes = likes + ? WHERE profile_id = ? AND post_id = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId},
            {likes, [{User, Like}]}],
    send_cass_prep_query(Q, Vals).

get_post_details(ProfileId, PostId) ->
    Q = <<"SELECT comments, likes, read_reciepts FROM profile_post WHERE profile_id = ? AND post_id = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{comments, CMB},
       {likes, LMB},
       {read_reciepts, RRSB}]] -> {check_list(CMB), check_list(LMB), check_list(RRSB)};
      _ -> []
    end.

get_profile_posts(ProfileId, PostId) ->
    Q = <<"SELECT msg, mtype, post_id, username FROM profile_post WHERE profile_id = ? AND post_id < ? ORDER BY post_id ASC LIMIT 50;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      D -> D
    end.

get_random_posts(PostId) ->
    Q = <<"SELECT msg, mtype, post_id, profile_id, username FROM post_timeline WHERE post_id < ? ;">>,
    Vals = [{post_id, PostId}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      D -> D
    end.

get_profile_posts_by_hash_tag(ProfileId, Tag) ->
    Q = <<"SELECT msg, mtype, post_id, username FROM post_tags WHERE profile_id = ? AND tag = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {tag, Tag}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      D -> D
    end. 

get_user_profiles(User) ->
    Q = <<"SELECT profiles FROM user_data WHERE username = ? ;">>,
    Vals = [{username, User}],
    case get_cass_prep_query_result(Q, Vals) of
      [[{profiles, Profiles}]] when (Profiles /= null) -> Profiles;
      _ -> []
    end.

get_profile_members(ProfileId) ->
    Q = <<"SELECT users FROM profile WHERE profile_id = ? ;">>,
    Vals = [{profile_id, ProfileId}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      [[{users, U}]] -> U
    end.

remove_member_from_profile(ProfileId, User) ->
    Q = <<"UPDATE profile SET users = users - ? WHERE profile_id = ? ;">>,
    Vals = [{users, [User]},
            {profile_id, ProfileId}],
    send_cass_prep_query(Q, Vals).

delete_post(ProfileId, PostId) ->
    Q = <<"DELETE FROM profile_post WHERE profile_id = ? AND AND post_id = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId}],
    send_cass_prep_query(Q, Vals).

mark_post_read(ProfileId, PostId, User) ->
    Q = <<"UPDATE profile_post SET read_reciepts = read_reciepts + ? WHERE profile_id = ? AND post_id = ? ;">>,
    Vals = [{read_reciepts, [User]},
            {profile_id, ProfileId},
            {post_id, PostId}],
    send_cass_prep_query(Q, Vals).

get_post_read_reciepts(ProfileId, PostId) ->
    Q = <<"SELECT read_reciepts FROM profile_post WHERE profile_id = ? AND post_id = ? ;">>,
    Vals = [{profile_id, ProfileId},
            {post_id, PostId}],
    case get_cass_prep_query_result(Q, Vals) of
      empty_dataset -> [];
      [[{read_reciepts, RR}]] -> RR
    end.

update_referral_count(User) ->
    Q = <<"SELECT ref_count FROM counts WHERE username = ? ;">>,
    Vals = [{username, User}],
    Count =
      case get_cass_prep_query_result(Q, Vals) of
        empty_dataset -> 1;
        [[{ref_count, C}]] -> C  + 1
      end,    
    Q1 = <<"UPDATE counts SET ref_count = ref_count + 1 WHERE username = ? ;">>,
    Vals1 = [{username, User}],
    send_cass_prep_query(Q1, Vals1),
    Count.

%% cassandra query api exports

get_cass_query_result(Q) ->
    io:format("~p ~n",[Q]),
    {ok, Client} = cqerl:new_client({"127.0.0.1", 9042}, [{keyspace, "ttl"}]),
    {ok, Result} = cqerl:run_query(Client, Q),
    cqerl:all_rows(Result).

get_cass_prep_query_result(Q, Vals) ->
    {ok, Client} = cqerl:new_client({"127.0.0.1", 9042}, [{keyspace, "ttl"}]),
    {ok, Result} = cqerl:run_query(Client, #cql_query{statement = Q, values = Vals}),
    cqerl:all_rows(Result).

send_cass_query(Q) ->
    io:format("~p ~n",[Q]),
    {ok, Client} = cqerl:new_client({"127.0.0.1", 9042}, [{keyspace, "ttl"}]),
    cqerl:send_query(Client, Q),
    cqerl:close_client(Client).

send_cass_prep_query(Q, Vals) ->
    {ok, Client} = cqerl:new_client({"127.0.0.1", 9042}, [{keyspace, "ttl"}]),
    cqerl:run_query(Client, #cql_query{statement = Q, values = Vals}),
    cqerl:close_client(Client).

send_cass_batch_queries(Queries) ->
   {ok, Client} = cqerl:new_client({"127.0.0.1", 9042}, [{keyspace, "ttl"}]),
   cqerl:run_query(Client, #cql_query_batch{mode = ?CQERL_BATCH_UNLOGGED, queries = Queries}),
   cqerl:close_client(Client).

check_list(null) -> [];
check_list(Val) -> Val.
