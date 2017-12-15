-module(vg_protocol).

-export([encode_fetch/4,
         encode_produce/3,
         encode_replicate/6,
         encode_request/4,
         encode_metadata_response/2,
         encode_metadata_request/1,
         encode_chains/1,

         encode_array/1,
         encode_log/2,
         encode_kv/1,
         encode_string/1,
         encode_bytes/1,
         encode_produce_response/1,
         encode_replicate_response/1,
         encode_fetch_topic_response/4,
         decode_array/2,
         decode_record_set/1,

         decode_metadata_request/1,
         decode_string/1,

         decode_produce_request/1,
         decode_replicate_request/1,
         decode_fetch_response/1,
         decode_response/1,
         decode_response/2,
         decode_record_set/2]).

-include("vg.hrl").

%% encode requests

encode_fetch(ReplicaId, MaxWaitTime, MinBytes, Topics) ->
    [<<ReplicaId:32/signed-integer, MaxWaitTime:32/signed-integer, MinBytes:32/signed-integer>>, encode_topics(Topics)].

encode_produce(Acks, Timeout, TopicData) when Acks =:= -1
                                            ; Acks =:= 0
                                            ; Acks =:= 1 ->
    [<<Acks:16/signed-integer, Timeout:32/signed-integer>>, encode_topic_data(TopicData)].

encode_replicate(Acks, Timeout, Topic, Partition, ExpectedId, Data) when Acks =:= -1
                                                                         ; Acks =:= 0
                                                                         ; Acks =:= 1 ->
    [<<Acks:16/signed-integer, Timeout:32/signed-integer>>, encode_replicate_topic_data(Topic, Partition, ExpectedId, Data)].

encode_replicate_topic_data(Topic, Partition, ExpectedId, RecordSet) ->
    RecordSetEncoded = encode_replicate_record_set(RecordSet),
    [encode_string(Topic), <<Partition:32/signed-integer, ExpectedId:64/signed-integer,
                             (iolist_size(RecordSetEncoded)):32/signed-integer>>, RecordSetEncoded].

encode_topic_data(TopicData) ->
    encode_array([[encode_string(Topic), encode_data(Data)] || {Topic, Data} <- TopicData]).

encode_data(Data) ->
    encode_array([begin
                      RecordSetEncoded = encode_record_set(RecordSet),
                      [<<Partition:32/signed-integer, (iolist_size(RecordSetEncoded)):32/signed-integer>>, RecordSetEncoded]
                  end || {Partition, RecordSet} <- Data]).

encode_topics(Topics) ->
    encode_array([[encode_string(Topic), encode_partitions(Partitions)] || {Topic, Partitions} <- Topics]).

encode_partitions(Partitions) ->
    encode_array([case PartitionTuple of
                      {Partition, Offset, MaxBytes} ->
                          <<Partition:32/signed-integer, Offset:64/signed-integer, MaxBytes:32/signed-integer>>;
                      {Partition, Offset, MaxBytes, Limit} ->
                          <<Partition:32/signed-integer, Offset:64/signed-integer,
                            MaxBytes:32/signed-integer, Limit:32/signed-integer>>
                  end || PartitionTuple <- Partitions]).

encode_request(ApiKey, CorrelationId, ClientId, Request) ->
    [<<ApiKey:16/signed-integer, ?API_VERSION:16/signed-integer, CorrelationId:32/signed-integer>>,
     encode_string(ClientId), Request].

encode_metadata_request(Topics) ->
    encode_array([encode_string(Topic) || Topic <- Topics]).

encode_chains(Chains) ->
    encode_array([begin
                      Start = maybe_convert(Start0),
                      End = maybe_convert(End0),
                      <<HeadPort:16/unsigned-integer,
                        TailPort:16/unsigned-integer,
                        (iolist_to_binary(
                           encode_array([encode_string(to_binary(Name)),
                                         encode_string(Start),
                                         encode_string(End),
                                         encode_string(HeadHost),
                                         encode_string(TailHost)])))/binary>>
                  end
                  || #chain{name = Name,
                            nodes = _Nodes,
                            topics_start = Start0,
                            topics_end = End0,
                            head = {HeadHost, HeadPort},
                            tail = {TailHost, TailPort}} <- Chains]).

%% generic encode functions

to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(Atm) when is_atom(Atm) ->
    atom_to_binary(Atm, utf8).

encode_string(undefined) ->
    <<-1:16/signed-integer>>;
encode_string(Data) when is_binary(Data) ->
    [<<(size(Data)):16/signed-integer>>, Data];
encode_string(Data) ->
    [<<(length(Data)):16/signed-integer>>, Data].

encode_array(Array) ->
    [<<(length(Array)):32/signed-integer>>, Array].

encode_bytes(undefined) ->
    <<-1:32/signed-integer>>;
encode_bytes(Data) ->
    [<<(size(Data)):32/signed-integer>>, Data].

encode_record_set([]) ->
    [];
encode_record_set(Record) when is_binary(Record) ->
    Record2 = encode_record(Record),
    [<<0:64/signed-integer, (iolist_size(Record2)):32/signed-integer>>, Record2];
encode_record_set([Record | T]) ->
    Record2 = encode_record(Record),
    [<<0:64/signed-integer, (iolist_size(Record2)):32/signed-integer>>, Record2 | encode_record_set(T)].

encode_replicate_record_set([]) ->
    [];
encode_replicate_record_set(#{record := Record,
                              crc := Crc}) ->
    Record2 = <<Crc:32/unsigned-integer, Record/binary>>,
    [<<0:64/signed-integer, (iolist_size(Record2)):32/signed-integer>>, Record2];
encode_replicate_record_set([#{record := Record,
                               crc := Crc} | T]) ->
    Record2 = <<Crc:32/unsigned-integer, Record/binary>>,
    [<<0:64/signed-integer, (iolist_size(Record2)):32/signed-integer>>, Record2 | encode_replicate_record_set(T)].

encode_record(Record) ->
    Record2 = [<<?MAGIC:8/signed-integer, 0:8/signed-integer>>, encode_kv(Record)],
    [<<(erlang:crc32(Record2)):32/unsigned-integer>>, Record2].

%% <<Id:64, RecordSize:32, Crc:32, MagicByte:8, Attributes:8, Key/Value>>
-spec encode_log(Id, Value) -> EncodedLog when
      Id :: integer(),
      Value :: vg:record(),
      EncodedLog :: {pos_integer(), pos_integer(), iolist()} | {error, bad_checksum}.
%% if we have an id, we're coming in from write repair and have to handle the checksum differently
encode_log(Id, #{crc := CRC, id := LogID, record := Record}) ->
    case LogID of
        Id ->
            Record2 = [<<?MAGIC:8/signed-integer, 0:8/signed-integer>>, encode_kv(Record)],
            case erlang:crc32(Record2) of
                CRC ->
                    RecordIoList = [<<CRC:32/unsigned-integer>>, Record2],
                    RecordSize = erlang:iolist_size(RecordIoList),
                    {Id+1, RecordSize+12, [<<Id:64/signed-integer, RecordSize:32/signed-integer>>, RecordIoList]};
                BadChecksum ->
                    lager:error("checksums don't match crc1=~p crc2=~p", [CRC, BadChecksum]),
                    {error, bad_checksum}
            end;
        _ ->
            lager:error("ids don't match on write repair id1=~p id2=~p", [Id, LogID]),
            {error, bad_id}
    end;
%% here we're coming from a decoded produce request.
encode_log(Id, #{crc := CRC, record := Record}) ->
    case erlang:crc32(Record) of
        CRC ->
            RecordIoList = [<<CRC:32/unsigned-integer>>, Record],
            RecordSize = erlang:iolist_size(RecordIoList),
            {Id+1, RecordSize+12, [<<Id:64/signed-integer, RecordSize:32/signed-integer>>, RecordIoList]};
        BadChecksum ->
            lager:error("checksums don't match crc1=~p crc2=~p", [CRC, BadChecksum]),
            {error, bad_checksum}
    end;
%% not sure if anything uses this code path
encode_log(Id, #{record := Record}) ->
    EncodedRecord = encode_record(Record),
    RecordSize = erlang:iolist_size(EncodedRecord),
    {Id+1, RecordSize+12, [<<Id:64/signed-integer, RecordSize:32/signed-integer>>, EncodedRecord]}.

encode_kv({Key, Value}) ->
    [encode_bytes(Key), encode_bytes(Value)];
encode_kv(Value) ->
    [encode_bytes(undefined), encode_bytes(Value)].

%% encode responses

encode_produce_response(TopicPartitions) ->
    encode_produce_response(TopicPartitions, []).

encode_produce_response([], Acc) ->
    encode_array(Acc);
encode_produce_response([{Topic, Partitions} | T], Acc) ->
    encode_produce_response(T, [[encode_string(Topic), encode_produce_response_partitions(Partitions)] | Acc]).

encode_produce_response_partitions(Partitions) ->
    encode_array([<<Partition:32/signed-integer, ErrorCode:16/signed-integer, Offset:64/signed-integer>>
                      || {Partition, ErrorCode, Offset} <- Partitions]).

encode_replicate_response({Partition, ?WRITE_REPAIR, RecordSet}) ->
    Records = [Record || {_, Record} <- RecordSet],
    [<<Partition:32/signed-integer, ?WRITE_REPAIR:16/signed-integer, (iolist_size(Records)):32/signed-integer>>, Records];
encode_replicate_response({Partition, ErrorCode, Offset}) ->
    <<Partition:32/signed-integer, ErrorCode:16/signed-integer, Offset:64/signed-integer>>.

encode_fetch_topic_response(Partition, ErrorCode, HighWaterMark, Bytes) ->
    <<Partition:32/signed-integer, ErrorCode:16/signed-integer, HighWaterMark:64/signed-integer, Bytes:32/signed-integer>>.

encode_metadata_response(Brokers, TopicMetadata) ->
    [encode_brokers(Brokers), encode_topic_metadata(TopicMetadata)].

encode_brokers(Brokers) ->
    encode_array([[<<NodeId:32/signed-integer>>, encode_string(Host), <<Port:32/signed-integer>>]
                 || {NodeId, {Host, Port}} <- Brokers]).

encode_topic_metadata(TopicMetadata) ->
    encode_array([[<<TopicErrorCode:16/signed-integer>>, encode_string(Topic), encode_partition_metadata(PartitionMetadata)]
                    || {TopicErrorCode, Topic, PartitionMetadata} <- TopicMetadata]).

encode_partition_metadata(PartitionMetadata) ->
    encode_array([[<<PartitionErrorCode:16/signed-integer, PartitionId:32/signed-integer, Leader:32/signed-integer>>,
                    encode_array([<<Replica:32/signed-integer>> || Replica <- Replicas]),
                    encode_array([<<I:32/signed-integer>> || I <- Isr])]
                     || {PartitionErrorCode, PartitionId, Leader, Replicas, Isr} <- PartitionMetadata]).

%% decode generic functions

decode_array(DecodeFun, <<Length:32/signed-integer, Rest/binary>>) ->
    decode_array(DecodeFun, Length, Rest, []);
decode_array(_, _) ->
    more.

decode_array(_, 0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
decode_array(DecodeFun, N, Rest, Acc) ->
    case DecodeFun(Rest) of
        {Element, Rest1} ->
            decode_array(DecodeFun, N-1, Rest1, [Element | Acc]);
        more -> more
    end.

decode_int32(<<I:32/signed-integer, Rest/binary>>) ->
    {I, Rest}.

decode_string(<<Size:16/signed-integer, String:Size/bytes, Rest/binary>>) ->
    {String, Rest}.

decode_record_set(<<>>) ->
    [];
decode_record_set(<<_:64/signed-integer, Size:32/signed-integer, Record:Size/binary, Rest/binary>>) ->
    [decode_record(Record) | decode_record_set(Rest)].

%% <<?MAGIC:8/signed-integer, Compression:8/signed-integer, -1:32/signed-integer, Size:32/signed-integer, Data:Size/binary>>
decode_record(<<CRC:32/unsigned-integer, Record/binary>>) ->
    #{crc => CRC,
      record => Record}.

%% decode requests

decode_metadata_request(Msg) ->
    {Topics, _rest} = decode_array(fun decode_topics/1, Msg),
    Topics.

decode_topics(<<Size:16/signed-integer, Topic:Size/bytes, Rest/binary>>) ->
    {Topic, Rest}.

decode_produce_request(<<Acks:16/signed-integer, Timeout:32/signed-integer, Topics/binary>>) ->
    {TopicsDecode, _} = decode_array(fun decode_produce_topics_request/1, Topics),
    {Acks, Timeout, TopicsDecode}.

decode_produce_topics_request(<<Size:16/signed-integer, Topic:Size/binary, Rest/binary>>) ->
    {TopicData, Rest1} = decode_array(fun decode_produce_partitions_request/1, Rest),
    {{Topic, TopicData}, Rest1}.

decode_produce_partitions_request(<<Partition:32/signed-integer, Size:32/signed-integer,
                                    RecordSet:Size/binary, Rest/binary>>) ->
    {{Partition, decode_record_set(RecordSet)}, Rest}.

%% decode replicate

decode_replicate_request(<<Acks:16/signed-integer, Timeout:32/signed-integer, TopicSize:16/signed-integer,
                           Topic:TopicSize/binary, Partition:32/signed-integer, ExpectedId:64/signed-integer,
                           RecordSetSize:32/signed-integer, RecordSet:RecordSetSize/binary, _Rest/binary>>) ->
    {Acks, Timeout, {Topic, Partition, ExpectedId, decode_record_set(RecordSet)}}.

%% decode responses

decode_response(<<Size:32/signed-integer, Record:Size/binary, Rest/binary>>) ->
    <<CorrelationId:32/signed-integer, Response/binary>> = Record,
    {CorrelationId, Response, Rest};
decode_response(<<Size:32/signed-integer, Rest/binary>>) ->
    {more, Size - byte_size(Rest)};
decode_response(_) ->
    more.

decode_response(?FETCH_REQUEST, Response) ->
    decode_fetch_response(Response);
decode_response(?PRODUCE_REQUEST, Response) ->
    decode_produce_response(Response);
decode_response(?REPLICATE_REQUEST, Response) ->
    decode_replicate_response(Response);
decode_response(?TOPICS_REQUEST, Response) ->
    decode_topics_response(Response);
decode_response(?METADATA_REQUEST, Response) ->
    decode_metadata_response(Response).

decode_metadata_response(Response) ->
    {Brokers, Rest} = decode_array(fun decode_metadata_response_brokers/1, Response),
    {TopicMetadata, _}= decode_array(fun decode_metadata_response_topic_metadata/1, Rest),

    %% The response will use leader as the head node and the first element in isrs as the tail
    %% We use the head host node as the name of the chain
    {Chains, Topics} = lists:foldl(fun(#{topic := Topic,
                                         partitions := [#{leader := HeadId,
                                                          isrs := [TailId | _]} | _]}, Acc) ->
                                       update_chains_and_topics(Brokers, Topic, HeadId, TailId, Acc)
                                   end, {#{}, #{}}, TopicMetadata),

    {Chains, Topics}.

update_chains_and_topics(Brokers, Topic, HeadId, TailId, {ChainsAcc, TopicsAcc}) ->
    {_, {HeadHost, HeadPort}} = lists:keyfind(HeadId, 1, Brokers),
    {_, {TailHost, TailPort}} = lists:keyfind(TailId, 1, Brokers),
    ChainName = <<HeadHost/binary, "-", (integer_to_binary(HeadPort))/binary>>,
    {maps:put(ChainName, #chain{name = ChainName,
                                head = {binary_to_list(HeadHost), HeadPort},
                                tail = {binary_to_list(TailHost), TailPort}}, ChainsAcc),
     maps:put(Topic, ChainName, TopicsAcc)}.


decode_metadata_response_brokers(<<NodeId:32/signed-integer, HostSize:16/signed-integer,
                                   Host:HostSize/binary, Port:32/signed-integer, Rest/binary>>) ->
    {{NodeId, {binary:copy(Host), Port}}, Rest}.

decode_metadata_response_topic_metadata(<<_ErrorCode:16/signed-integer, TopicSize:16/signed-integer,
                                          Topic:TopicSize/binary, PartitionMetadataRest/binary>>) ->
    {PartitionMetadata, Rest} = decode_array(fun decode_partition_metadata/1, PartitionMetadataRest),
    {#{topic => binary:copy(Topic),
       partitions => PartitionMetadata}, Rest}.

decode_partition_metadata(<<_PartitionErrorCode:16/signed-integer, PartitionId:32/signed-integer,
                            Leader:32/signed-integer, Rest/binary>>) ->
    {Isrs, Rest1}= decode_array(fun decode_int32/1, Rest),
    {Replicas, Rest2}= decode_array(fun decode_int32/1, Rest1),

    {#{partition_id => PartitionId,
       leader => Leader,
       isrs => Isrs,
       replicas => Replicas}, Rest2}.

decode_produce_response(Response) ->
    case decode_array(fun decode_produce_response_topics/1, Response) of
        {TopicResults, _Rest} ->
            maps:from_list(TopicResults);
        more -> more
    end.

decode_produce_response_topics(<<Size:16/signed-integer, Topic:Size/binary, PartitionsRaw/binary>>) ->
    case decode_array(fun decode_produce_response_partitions/1, PartitionsRaw) of
        {Partitions, Rest} ->
            {{Topic, maps:from_list(Partitions)}, Rest};
        more -> more
    end;
decode_produce_response_topics(_) ->
    more.

decode_produce_response_partitions(<<Partition:32/signed-integer, ErrorCode:16/signed-integer,
                                     Offset:64/signed-integer, Rest/binary>>) ->
    {{Partition, #{error_code => ErrorCode,
                   offset => Offset}}, Rest};
decode_produce_response_partitions(_) ->
    more.

decode_replicate_response(<<Partition:32/signed-integer, ?WRITE_REPAIR:16/signed-integer,
                            Size:32/signed-integer, RecordSet:Size/binary, _Rest/binary>>) ->
    {Partition, #{error_code => ?WRITE_REPAIR, records => decode_record_set(RecordSet, [])}};
decode_replicate_response(<<Partition:32/signed-integer, ErrorCode:16/signed-integer,
                            Offset:64/signed-integer, _Rest/binary>>) ->
    {Partition, #{error_code => ErrorCode, offset => Offset}};
decode_replicate_response(_) ->
    more.

decode_topics_response(<<TopicsCount:32/signed-integer, Msg/binary>>) ->
    {Chains, _Rest} = decode_array(fun decode_chain/1, Msg),
    {TopicsCount, Chains}.

decode_chain(<<HeadPort:16/unsigned-integer,
               TailPort:16/unsigned-integer,
               Array/binary>>) ->
    {[Name, Start0, End0, HeadHost, TailHost], Rest} = decode_array(fun decode_string/1, Array),
    Start = maybe_deconvert(Start0),
    End = maybe_deconvert(End0),
    {#{name => Name,
       topics_start => Start,
       topics_end => End,
       head => {HeadHost, HeadPort},
       tail => {TailHost, TailPort}},
     Rest}.

maybe_convert(start_space) ->
    <<"$$start_space">>;
maybe_convert(end_space) ->
    <<"$$end_space">>;
maybe_convert(B) when is_binary(B) ->
    B.

%% split these to unconfuse dialyzer
maybe_deconvert(<<"$$start_space">>) ->
    start_space;
maybe_deconvert(<<"$$end_space">>) ->
    end_space;
maybe_deconvert(B) when is_binary(B) ->
    B.

decode_fetch_response(Msg) ->
    case decode_array(fun decode_fetch_topic/1, Msg) of
        {Topics, _Rest} ->
            maps:from_list(Topics);
        more -> more
    end.

decode_fetch_topic(<<Sz:16/signed-integer, Topic:Sz/binary, Partitions/binary>>) ->
    case decode_array(fun decode_fetch_partition/1, Partitions) of
        {DecPartitions, Rest} ->
            {{Topic, maps:from_list(DecPartitions)}, Rest};
        more -> more
    end;
decode_fetch_topic(_) ->
    more.

decode_fetch_partition(<<Partition:32/signed-integer, ErrorCode:16/signed-integer,
                         HighWaterMark:64/signed-integer, Bytes:32/signed-integer, RecordSet:Bytes/bytes,
                         Rest/binary>>) ->
    %% there are a number of fields that we're not including currently:
    %% - throttle time
    %% - topic name
    {{Partition, #{high_water_mark => HighWaterMark,
                   record_set_size => Bytes,
                   error_code => ErrorCode,
                   record_set => decode_record_set(RecordSet, [])}}, Rest};
decode_fetch_partition(_) ->
    more.

%% TODO: validate recordsize
decode_record_set(End, Set) when End =:= eof orelse End =:= <<>> ->
    lists:reverse(Set);
decode_record_set(<<Id:64/signed-integer, _RecordSize:32/signed-integer, Crc:32/unsigned-integer,
                    ?MAGIC:8/signed-integer, Attributes:8/signed-integer, -1:32/signed-integer,
                    ValueSize:32/signed-integer, Value:ValueSize/binary, Rest/binary>>, Set) ->
    case ?COMPRESSION(Attributes) of
        ?COMPRESS_NONE ->
            decode_record_set(Rest, [#{id => Id,
                                       crc => Crc,
                                       record => binary:copy(Value)} | Set]);
        ?COMPRESS_GZIP ->
            decode_record_set(Rest, decode_record_set(zlib:gunzip(Value), Set));
        ?COMPRESS_SNAPPY ->
            decode_record_set(Rest, decode_record_set(snappyer:decompress(Value), Set));
        ?COMPRESS_LZ4 ->
            decode_record_set(Rest, decode_record_set(lz4:unpack(Value), Set))
    end;
%% compression only allowed if key is null
decode_record_set(<<Id:64/signed-integer, _RecordSize:32/signed-integer, Crc:32/unsigned-integer,
                    ?MAGIC:8/signed-integer, _Attributes:8/signed-integer,
                    KeySize:32/signed-integer, Key:KeySize/binary, ValueSize:32/signed-integer,
                    Value:ValueSize/binary, Rest/binary>>, Set) ->
    decode_record_set(Rest, [#{id => Id,
                               crc => Crc,
                               record => {binary:copy(Key), binary:copy(Value)}} | Set]);
decode_record_set(<<_/binary>>, Set) ->
    %% ignore partial records
    decode_record_set(<<>>, Set).
