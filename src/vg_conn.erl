-module(vg_conn).

-behaviour(acceptor).
-behaviour(gen_server).

%% acceptor api

-export([acceptor_init/3,
         acceptor_continue/3,
         acceptor_terminate/2]).

%% gen_server api

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-include("vg.hrl").

-type topic_partition() :: {binary(), [partition()]}.
-type partition() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}.

-record(state, {socket :: inets:socket(),
                role   :: head | tail, %% middle disconnects
                ref    :: reference(),
                buffer :: binary()}).

acceptor_init(_SockName, LSocket, []) ->
    % monitor listen socket to gracefully close when it closes
    MRef = monitor(port, LSocket),
    {ok, MRef}.

acceptor_continue(_PeerName, Socket, MRef) ->
    case vg_chain_state:role() of
        middle ->
            lager:debug("at=new_connection error=client_middle node=~p peer=~p",
                        [node(), _PeerName]),
            {error, no_valid_client_operations};
        Role ->
            lager:debug("at=new_connection node=~p role=~p peer=~p",
                        [node(), Role, _PeerName]),
            gen_server:enter_loop(?MODULE, [], #state{socket = Socket, ref = MRef,
                                                      role = Role, buffer = <<>>})
    end.

acceptor_terminate(Reason, _) ->
    % Something went wrong. Either the acceptor_pool is terminating or the
    % accept failed.
    exit(Reason).

%% gen_server api

init(_) ->
    {stop, acceptor}.

handle_call(Req, _, State) ->
    {stop, {bad_call, Req}, State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({tcp, Socket, Data}, State=#state{socket=Socket,
                                              role=Role,
                                              buffer=Buffer}) ->
    case handle_data(<<Buffer/binary, Data/binary>>, Role, Socket) of
        {ok, NewBuffer} ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State#state{buffer=NewBuffer}};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_info({tcp_error, Socket, Reason}, State=#state{socket=Socket}) ->
    {stop, Reason, State};
handle_info({tcp_closed, Socket}, State=#state{socket=Socket}) ->
    {stop, normal, State};
handle_info({'DOWN', MRef, port, _, _}, State=#state{socket=Socket,
                                                     ref=MRef}) ->
    %% Listen socket closed, receive all pending data then stop. In more
    %% advanced protocols will likely be able to do better.
    lager:info("Gracefully closing ~p~n", [Socket]),
    {stop, flush_socket(Socket), State};
handle_info(_, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

%% internal

%% If a record can be fully read from the data then handle the request
%% else return the data to be kept in the buffer
-spec handle_data(binary(), head | solo | tail, inets:socket()) ->
                         {ok, binary()} | {error, any()}.
handle_data(<<Size:32/signed-integer, Message:Size/binary, Rest/binary>>,
            Role, Socket) ->
    case handle_request(Message, Role, Socket) of
        {error, Reason} ->
            {error, Reason};
        _ ->
            {ok, Rest}
    end;
handle_data(Data, _Role, _Socket) ->
    {ok, Data}.

%% Parse out the type of request (apikey) and the request data
handle_request(<<ApiKey:16/signed-integer, _ApiVersion:16/signed-integer, CorrelationId:32/signed-integer,
                 ClientIdSize:16/signed-integer, _ClientId:ClientIdSize/binary, Request/binary>>,
               Role, Socket) ->
    handle_request(ApiKey, Role, Request, CorrelationId, Socket).

handle_request(?METADATA_REQUEST, _, Data, CorrelationId, Socket) ->
    Topics0 = vg_protocol:decode_metadata_request(Data),
    Topics = case Topics0 of
                 [] -> vg_topics:all();
                 _ -> [vg:ensure_topic(T) || T <- Topics0], Topics0
             end,
    lager:info("at=metadata_request topics=~p", [Topics]),
    %% need to return all nodes and start giving nodes an integer id
    {_, Chains, _} = vg_cluster_mgr:get_map(),
    {_, Nodes} = maps:fold(fun(_Name, #chain{head={HeadHost, HeadPort},
                                             tail={TailHost, TailPort}}, {Id, Acc}) ->
                               HeadNode = {Id, {HeadHost, HeadPort}},
                               case {TailHost, TailPort} of
                                   {HeadHost, HeadPort} ->
                                       %% same as head node
                                       TailNode = {Id, {TailHost, TailPort}},
                                       {Id+1, [HeadNode, TailNode | Acc]};
                                   _ ->
                                       TailNode = {Id+1, {TailHost, TailPort}},
                                       {Id+2, [HeadNode, TailNode | Acc]}
                               end
                        end, {0, []}, Chains),
    TopicMetadata = [begin
                         #chain{head=Head,
                                tail=Tail} = vg_topics:get_chain(Topic),
                         {HeadId, _} = lists:keyfind(Head, 2, Nodes),
                         {TailId, _} = lists:keyfind(Tail, 2, Nodes),
                         {0, Topic, [{0, HeadId, 0, [TailId], []}]}
                     end || Topic <- Topics],
    Response = vg_protocol:encode_metadata_response(Nodes, TopicMetadata),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]);
handle_request(?FETCH_REQUEST, Role, <<_ReplicaId:32/signed-integer, _MaxWaitTime:32/signed-integer,
                                       _MinBytes:32/signed-integer, Rest/binary>>,
               CorrelationId, Socket) when Role =:= tail orelse Role =:= solo ->
    {[{Topic, [{Partition, Offset, _MaxBytes} | _]} | _], _} = vg_protocol:decode_array(fun decode_topic/1, Rest),
    {SegmentId, Position} = vg_log_segments:find_segment_offset(Topic, Partition, Offset),

    lager:info("at=fetch_request topic=~s partition=~p offset=~p segment_id=~p position=~p",
              [Topic, Partition, Offset, SegmentId, Position]),

    File = vg_utils:log_file(Topic, Partition, SegmentId),
    {ok, Fd} = file:open(File, [read, binary, raw]),
    try
        Bytes = filelib:file_size(File) - Position,
        ErrorCode = 0,
        HighWaterMark = vg_topics:lookup_hwm(Topic, Partition),
        Response = vg_protocol:encode_fetch_response(Topic, Partition, ErrorCode, HighWaterMark, Bytes),
        gen_tcp:send(Socket, [<<(Bytes + 4 + iolist_size(Response)):32/signed-integer,
                                CorrelationId:32/signed-integer>>, Response]),
        {ok, _} = file:sendfile(Fd, Socket, Position, Bytes, [])
        %% maybe catch any errors here and report them?
    after
        file:close(Fd)
    end;
handle_request(?FETCH_REQUEST, _ , <<_ReplicaId:32/signed, _MaxWaitTime:32/signed,
                                     _MinBytes:32/signed, Rest/binary>>,
               CorrelationId, Socket) ->
    {[{Topic, [{Partition, _Offset, _MaxBytes} | _]} | _], _} = vg_protocol:decode_array(fun decode_topic/1, Rest),
    lager:info("at=fetch_request error=request_disallowed topic=~s partition=~p", [Topic, Partition]),
    Response = vg_protocol:encode_fetch_response(Topic, Partition, ?FETCH_DISALLOWED_ERROR, 0, 0),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, Response]),
    {error, request_disallowed};
handle_request(?PRODUCE_REQUEST, Role, Data, CorrelationId, Socket) when Role =:= head orelse Role =:= solo ->
    {_Acks, _Timeout, TopicData} = vg_protocol:decode_produce_request(Data),
    lager:info("at=produce_request", []),
    Results = [{Topic, [begin
                            lager:info("at=produce_request_write topic=~s partition=~p", [Topic, Partition]),
                            {ok, Offset} = vg_active_segment:write(Topic, Partition, MessageSet),
                            {Partition, ?NONE_ERROR, Offset}
                        end || {Partition, MessageSet} <- PartitionData]}
              || {Topic, PartitionData} <- TopicData],
    ProduceResponse = vg_protocol:encode_produce_response(Results),
    Size = erlang:iolist_size(ProduceResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, ProduceResponse]);
handle_request(?PRODUCE_REQUEST, _, Data, CorrelationId, Socket) ->
    {_Acks, _Timeout, TopicData} = vg_protocol:decode_produce_request(Data),
    Results = [{Topic, [{Partition, ?PRODUCE_DISALLOWED_ERROR, 0}
                        || {Partition, _MessageSet} <- PartitionData]}
              || {Topic, PartitionData} <- TopicData],
    lager:info("at=produce_request error=request_disallowed", []),
    ProduceResponse = vg_protocol:encode_produce_response(Results),
    Size = erlang:iolist_size(ProduceResponse) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed, CorrelationId:32/signed>>, ProduceResponse]),
    {error, request_disallowed};
handle_request(?TOPICS_REQUEST, _Role, <<>>, CorrelationId, Socket) ->
    Children = vg_topics:all(),
    Topics = [vg_protocol:encode_string(T) || T <- Children],
    Response = vg_protocol:encode_array(Topics),
    Size = erlang:iolist_size(Response) + 4,
    gen_tcp:send(Socket, [<<Size:32/signed-integer, CorrelationId:32/signed-integer>>, Response]).

-spec decode_topic(binary()) -> {topic_partition(), binary()}.
decode_topic(<<Size:16/signed-integer, Topic:Size/binary, PartitionsRaw/binary>>) ->
    {Partitions, Rest} = vg_protocol:decode_array(fun decode_partition/1, PartitionsRaw),
    {{Topic, Partitions}, Rest}.

-spec decode_partition(binary()) -> {partition(), binary()}.
decode_partition(<<Partition:32/signed-integer, FetchOffset:64/signed-integer, MaxBytes:32/signed-integer, Rest/binary>>) ->
    {{Partition, FetchOffset, MaxBytes}, Rest}.

%%

flush_socket(Socket) ->
    receive
        {tcp, Socket, Data}         -> flush_send(Socket, Data);
        {tcp_error, Socket, Reason} -> Reason;
        {tcp_closed, Socket}        -> normal
    after
        0                           -> normal
    end.

flush_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok              -> flush_recv(Socket);
        {error, closed} -> normal;
        {error, Reason} -> Reason
    end.

flush_recv(Socket) ->
    case gen_tcp:recv(Socket, 0, 0) of
        {ok, Data}       -> flush_send(Socket, Data);
        {error, timeout} -> normal;
        {error, closed}  -> normal;
        {error, Reason}  -> Reason
end.
