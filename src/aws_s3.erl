-module(aws_s3).

-export([start/0,
         get_s3_policy/1,
         get_signed_link/2,
         url_encode/1,
         url_encode_loose/1]).

start() ->
    AWSKey = ws_config:get_local_option(aws_key),
    AWSSecret = ws_config:get_local_option(aws_secret),
    ws_config:add_local_option(aws_key, list_to_binary(AWSKey)),
    ws_config:add_local_option(aws_secret, list_to_binary(AWSSecret)),
    ws_config:add_local_option(aws_key_url_encoded, url_encode(AWSKey)),
    ok.

get_s3_policy(Category) ->
    AWSKey = ws_config:get_local_option(aws_key),
    AWSSecret = ws_config:get_local_option(aws_secret),
    BucketName = get_bucket_name(Category),
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_universal_time(os:timestamp()),
    InputPattern = "~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0BZ",
    Ts = list_to_binary(lists:flatten(io_lib:format(InputPattern, [Year, Month, (Day + 1), Hour, Minute, Second]))),
    Policy = <<"{\"expiration\":\"", Ts/binary , "\",\"conditions\": [{\"bucket\":\"", BucketName/binary, "\"}, [\"starts-with\", \"$key\", \"\"],{\"acl\": \"private\"},{\"success_action_status\": \"201\"},[\"starts-with\", \"$Content-Type\", \"\"],[\"content-length-range\", 0, 5000000000]]}">>,
    Base64Policy = re:replace(base64:encode(Policy), "\n", "", [global]),
    SignedPolicy = base64:encode(crypto:hmac(sha, AWSSecret, Base64Policy)),
    {Base64Policy, SignedPolicy, BucketName, AWSKey}.

get_signed_link(Key, Category) ->
    URLEncodedAWSKey = ws_config:get_local_option(aws_key_url_encoded),
    AWSSecret = ws_config:get_local_option(aws_secret),
    BucketName = get_bucket_name(Category),
    {Sig, Expires} = sign_get(BucketName, Key, AWSSecret),
    <<"https://", BucketName/binary, ".s3.amazonaws.com/", Key/binary
        , "?AWSAccessKeyId=", URLEncodedAWSKey/binary
        , "&Signature=", Sig/binary
        , "&Expires=", Expires/binary>>.

get_bucket_name(Category) ->
    if (Category == <<"1">>) or (Category == 1) -> <<"ttl-post-audio">>;
       (Category == <<"2">>) or (Category == 2) -> <<"ttl-post-image">>;
       (Category == <<"3">>) or (Category == 3) -> <<"ttl-post-video">>;
       (Category == <<"4">>) or (Category == 4) -> <<"ttl-profileimage">>;
       (Category == <<"5">>) or (Category == 5) -> <<"ttl-userimage">>;
      true -> <<"ttl-post-general">>
    end.
    
sign_get(BucketName, Key, AWSSecret) ->
    Expire_time = 86400,
    {Mega, Sec, _Micro} = os:timestamp(),
    Datetime = (Mega * 1000000) + Sec,
    Expires = integer_to_binary(Expire_time + Datetime),
    To_sign = <<"GET\n\n\n", Expires/binary, "\n/", BucketName/binary, "/", Key/binary>>,
    Sig = url_encode(base64:encode(sha_mac(AWSSecret, To_sign))),
    {Sig, Expires}.	

url_encode(Binary) when is_binary(Binary) ->
    url_encode(binary_to_list(Binary));
url_encode(String) ->
    url_encode(String, []).
url_encode([], Accum) ->
    list_to_binary(lists:reverse(Accum));
url_encode([Char|String], Accum)
  when Char >= $A, Char =< $Z;
       Char >= $a, Char =< $z;
       Char >= $0, Char =< $9;
       Char =:= $-; Char =:= $_;
       Char =:= $.; Char =:= $~ ->
    url_encode(String, [Char|Accum]);
url_encode([Char|String], Accum)
  when Char >=0, Char =< 255 ->
    url_encode(String, [hex_char(Char rem 16), hex_char(Char div 16),$%|Accum]).

url_encode_loose(Binary) when is_binary(Binary) ->
    url_encode_loose(binary_to_list(Binary));
url_encode_loose(String) ->
    url_encode_loose(String, []).
url_encode_loose([], Accum) ->
    lists:reverse(Accum);
url_encode_loose([Char|String], Accum)
  when Char >= $A, Char =< $Z;
       Char >= $a, Char =< $z;
       Char >= $0, Char =< $9;
       Char =:= $-; Char =:= $_;
       Char =:= $.; Char =:= $~;
       Char =:= $/; Char =:= $: ->
    url_encode_loose(String, [Char|Accum]);
url_encode_loose([Char|String], Accum)
  when Char >=0, Char =< 255 ->
    url_encode_loose(String, [hex_char(Char rem 16), hex_char(Char div 16),$%|Accum]).

hex_char(C) when C >= 0, C =< 9 -> $0 + C;
hex_char(C) when C >= 10, C =< 15 -> $A + C - 10.

sha_mac(K, S) ->
    try
        crypto:hmac(sha, K, S)
    catch
        error:undef ->
            R0 = crypto:hmac_init(sha, K),
            R1 = crypto:hmac_update(R0, S),
            crypto:hmac_final(R1)
    end.
