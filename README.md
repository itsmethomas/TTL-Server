# Building/Running


1. Check out code
2. Download/Compile dependencies with `make deps`
3. Compile application with `make app`
4. Update `conf/sys.config` as needed (eg with update Cassandra information)
5. Create Erlang release with `make rel`
6. Run application with `./_rel/wschat/bin/wschat start`



# Example API Calls


{
 "type" : "get_post_details",
 "profile_id" : "fp",
 "post_id" : 1414391772901,
 "id" : "pd"
}

{
    "type": "get_post_details",
    "profile_id": "fp",
    "post_id": 1414391772901,
    "code": 0,
    "comments": [
        {
            "timestamp": "asd",
            "comment": "asd"
        }
    ],
    "likes": [
        {
            "username": "user1",
            "ltype": 123
        }
    ],
    "read_reciepts": [
        "user2",
        "user1"
    ],
    "id": "pd"
}


{
 "type" : "get_board",
 "t" : "leader",
 "id" : "board_id"
}

{
    "type": "get_board",
    "t": "leader",
    "data": {
        "user_ref": 2
    },
    "code": 0,
    "id": "board_id"
}

