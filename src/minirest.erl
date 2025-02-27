%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(minirest).

-include_lib("kernel/include/file.hrl").

-export([ start_http/3
        , start_https/3
        , stop_http/1
        ]).

-export([handler/1]).

-export([ return/0
        , return/1
        , return_file/1
        ]).

%% Cowboy callback
-export([init/2]).

-define(SUCCESS, 0).

-define(LOG(Level, Format, Args), logger:Level("Minirest(Handler): " ++ Format, Args)).

-type(option() :: {authorization, fun()}).
-type(handler() :: {string(), mfa()} | {string(), mfa(), list(option())}).

-export_type([ option/0
             , handler/0
             ]).

%%------------------------------------------------------------------------------
%% Start/Stop Http
%%------------------------------------------------------------------------------

-spec(start_http(atom(), list(), list()) -> {ok, pid()}).
start_http(ServerName, Options, Handlers) ->
    Dispatch = cowboy_router:compile([{'_', handlers(Handlers)}]),
    case cowboy:start_clear(ServerName, Options, #{env => #{dispatch => Dispatch}}) of 
        {ok, _}  -> ok;
        {error, {already_started, _}} -> ok;
        {error, eaddrinuse} ->
            ?LOG(error, "Start ~s listener on ~p unsuccessfully: the port is occupied", [ServerName, get_port(Options)]),
            error(eaddrinuse);
        {error, Any} ->
            ?LOG(error, "Start ~s listener on ~p unsuccessfully: ~0p", [ServerName, get_port(Options), Any]),
            error(Any)
    end,
    io:format("Start ~s listener on ~p successfully.~n", [ServerName, get_port(Options)]).

-spec(start_https(atom(), list(), list()) -> {ok, pid()}).
start_https(ServerName, Options, Handlers) ->
    Dispatch = cowboy_router:compile([{'_', handlers(Handlers)}]),
    case cowboy:start_tls(ServerName, Options, #{env => #{dispatch => Dispatch}}) of 
        {ok, _}  -> ok;
        {error, eaddrinuse} ->
            ?LOG(error, "Start ~s listener on ~p unsuccessfully: the port is occupied", [ServerName, get_port(Options)]),
            error(eaddrinuse);
        {error, Any} ->
            ?LOG(error, "Start ~s listener on ~p unsuccessfully: ~0p", [ServerName, get_port(Options), Any]),
            error(Any)
    end,
    io:format("Start ~s listener on ~p successfully.~n", [ServerName, get_port(Options)]).

-spec(stop_http(atom()) -> ok | {error, any()}).
stop_http(ServerName) ->
    cowboy:stop_listener(ServerName).

get_port(#{socket_opts := SocketOpts}) ->
    proplists:get_value(port, SocketOpts, 18083).

map({Prefix, MFArgs}) ->
    map({Prefix, MFArgs, []});
map({Prefix, MFArgs, Options}) ->
    #{prefix => Prefix, mfargs => MFArgs, options => maps:from_list(Options)}.

handlers(Handlers) ->
    lists:map(fun
        ({Prefix, minirest, HHs}) -> {Prefix, minirest, [map(HH) || HH <- HHs]};
        (Handler) -> Handler
    end, Handlers).

%%------------------------------------------------------------------------------
%% Handler helper
%%------------------------------------------------------------------------------

-spec(handler(minirest_handler:config()) -> handler()).
handler(Config) -> minirest_handler:init(Config).

%%------------------------------------------------------------------------------
%% Cowboy callbacks
%%------------------------------------------------------------------------------

init(Req, Opts) ->
    Req1 = handle_request(Req, Opts),
    {ok, Req1, Opts}.

%% Callback
handle_request(Req, Handlers) ->
    case match_handler(binary_to_list(cowboy_req:path(Req)), Handlers) of
        {ok, Path, Handler} ->
            try
                apply_handler(Req, Path, Handler)
            catch _:Error:Stacktrace ->
                internal_error(Req, Error, Stacktrace)
            end;
        not_found ->
            cowboy_req:reply(400, #{<<"content-type">> => <<"text/plain">>}, <<"Not found.">>, Req)
    end.

match_handler(_Path, []) ->
    not_found;
match_handler(Path, [Handler = #{prefix := Prefix} | Handlers]) ->
    case string:prefix(Path, Prefix) of
        nomatch -> match_handler(Path, Handlers);
        RelPath -> {ok, add_slash(RelPath), Handler}
    end.

add_slash("/" ++ _ = Path) -> Path;
add_slash(Path) -> "/" ++ Path.

apply_handler(Req, Path, #{mfargs := MFArgs, options := #{authorization := AuthFun}}) ->
    case AuthFun(Req) of
        true  -> apply_handler(Req, Path, MFArgs);
        false ->
            cowboy_req:reply(401, #{<<"WWW-Authenticate">> => <<"Basic Realm=\"minirest-server\"">>},
                             <<"UNAUTHORIZED">>, Req)
    end;

apply_handler(Req, Path, #{mfargs := MFArgs}) ->
    apply_handler(Req, Path, MFArgs);

apply_handler(Req, Path, {M, F, Args}) ->
    erlang:apply(M, F, [Path, Req | Args]).

internal_error(Req, Error, Stacktrace) ->
    error_logger:error_msg("~s ~s error: ~p, stacktrace:~n~p",
                           [cowboy_req:method(Req), cowboy_req:path(Req), Error, Stacktrace]),
    cowboy_req:reply(500, #{<<"content-type">> => <<"text/plain">>}, <<"Internal Error">>, Req).

%%------------------------------------------------------------------------------
%% Return
%%------------------------------------------------------------------------------

return_file(File) ->
    {ok, #file_info{size = Size}} = file:read_file_info(File),
    Headers = #{
      <<"content-type">> => <<"application/octet-stream">>,
      <<"content-disposition">> => iolist_to_binary("attachment; filename=" ++ filename:basename(File))
    },
    {file, Headers, {sendfile, 0, Size, File}}.

return() ->
    {ok, #{code => ?SUCCESS}}.

return(ok) ->
    {ok, #{code => ?SUCCESS}};
return({ok, #{data := Data, meta := Meta}}) ->
    {ok, #{code => ?SUCCESS,
           data => to_map(Data),
           meta => to_map(Meta)}};
return({ok, Data}) ->
    {ok, #{code => ?SUCCESS,
           data => to_map(Data)}};
return({ok, Code, Message}) when is_integer(Code) ->
    {ok, #{code => Code,
           message => format_msg(Message)}};
return({ok, Data, Meta}) ->
    {ok, #{code => ?SUCCESS,
           data => to_map(Data),
           meta => to_map(Meta)}};
return({error, Message}) ->
    {ok, #{message => format_msg(Message)}};
return({error, Code, Message}) ->
    {ok, #{code => Code,
           message => format_msg(Message)}}.

%% [{a, b}]           => #{a => b}
%% [[{a,b}], [{c,d}]] => [#{a => b}, #{c => d}]
%%
%% [{a, #{b => c}}]   => #{a => #{b => c}}
%% #{a => [{b, c}]}   => #{a => #{b => c}}

to_map([[{_,_}|_]|_] = L) ->
    [to_map(E) || E <- L];
to_map([{_, _}|_] = L) ->
    lists:foldl(
      fun({Name, Value}, Acc) ->
        Acc#{Name => to_map(Value)}
      end, #{}, L);
to_map([M|_] = L) when is_map(M) ->
    [to_map(E) || E <- L];
to_map(M) when is_map(M) ->
    maps:map(fun(_, V) -> to_map(V) end, M);
to_map(T) -> T.

format_msg(Message)
  when is_atom(Message);
       is_binary(Message) -> Message;

format_msg(Message) when is_tuple(Message) ->
    iolist_to_binary(io_lib:format("~p", [Message])).

%%====================================================================
%% EUnits
%%====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

to_map_test() ->
    #{a := b} = to_map([{a, b}]),
    [#{a := b, c := d}, #{e := f}] = to_map([[{a, b}, {c, d}], [{e, f}]]),
    #{a := #{b := c}} = to_map([{a, #{b => c}}]),
    #{a := #{b := c}} = to_map(#{a => [{b, c}]}).

-endif.
