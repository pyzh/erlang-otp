-module(win_browse).

-include("erl_com.hrl").

-export([open/1, example/0]).
open(Url) ->
    {ok, Pid}= erl_com:start_process(),
    T= erl_com:new_thread(Pid),
    Obj= erl_com:create_dispatch(T, "InternetExplorer.Application", ?CLSCTX_LOCAL_SERVER),
    erl_com:invoke(Obj, "Navigate", [Url]),
    erl_com:property_put(Obj, "Visible", true),
    Obj.

example() ->
    open("www.erlang.org").
