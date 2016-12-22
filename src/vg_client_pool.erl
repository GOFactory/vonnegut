-module(vg_client_pool).

-export([
         start/0, start/1,
         stop/0
        ]).

start() ->
    %% an experiment, tell me if you hate it
    start(#{ip => "127.0.0.1",
            port => 5555}).

start(Opts) ->
    ClientPoolSize = application:get_env(vonnegut, client_pool_size, 2),
    SocketOpts = [binary,
                  {buffer, 65535},
                  {nodelay, true},
                  {packet, raw},
                  {send_timeout, 5000},
                  {send_timeout_close, true}],
    shackle_pool:start(vg_client_pool, vg_client,
                       maps:to_list(Opts) ++
                           [{reconnect, true},
                            {reconnect_time_max, 120000},
                            {reconnect_time_min, none},
                            {socket_options, SocketOpts}],
                       [{backlog_size, 1024},
                        {pool_size, ClientPoolSize},
                        {pool_strategy, random}]).

stop() ->
    shackle_pool:stop(vg_client_pool).