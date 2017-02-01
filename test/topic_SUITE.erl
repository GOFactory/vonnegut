-module(topic_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    [creation, write].

init_per_suite(Config) ->
    PrivDir = ?config(priv_dir, Config),
    lager:start(),
    application:load(vonnegut),
    application:set_env(vonnegut, log_dirs, [filename:join(PrivDir, "data")]),
    {ok, _} = application:ensure_all_started(vonnegut),
    Config.

end_per_suite(Config) ->
    application:stop(vonnegut),
    Config.

init_per_testcase(_, Config) ->
    ok = vg_client_pool:start(),
    Topic = vg_test_utils:create_random_name(<<"topic_SUITE_default_topic">>),
    vg:create_topic(Topic),
    [{topic, Topic} | Config].

end_per_testcase(_, Config) ->
    vg_client_pool:stop(),
    Config.


creation(_Config) ->
    Topic = vg_test_utils:create_random_name(<<"creation_test_topic">>),
    Partition = 0,
    TopicPartitionDir = vg_utils:topic_dir(Topic, Partition),
    vg:create_topic(Topic),
    ?assert(filelib:is_dir(TopicPartitionDir)).

write(Config) ->
    Topic = ?config(topic, Config),
    Anarchist = <<"no gods no masters">>,
    [begin
         R = vg_client:produce(Topic, Anarchist),
         ct:pal("reply: ~p", [R])
     end
     || _ <- lists:seq(1, rand:uniform(20))],
    Communist =  <<"from each according to their abilities, to "
                   "each according to their needs">>,
    #{topic := Topic, offset := R1} = vg_client:produce(Topic, Communist),
    ct:pal("reply: ~p", [R1]),
    #{partitions := [#{record_set := Reply}]} = vg_client:fetch(Topic, R1),
    ?assertMatch([#{record := Communist}], Reply),

    #{partitions := [#{record_set := Reply1}]} = vg_client:fetch(Topic, R1 - 1),
    ?assertMatch([#{record := Anarchist}, #{record := Communist}], Reply1).
