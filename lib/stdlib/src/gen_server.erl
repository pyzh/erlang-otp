%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Initial Developer of the Original Code is Ericsson Utvecklings AB.
%% Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
%% AB. All Rights Reserved.''
%% 
%%     $Id$
%%
-module(gen_server).

%%% ---------------------------------------------------
%%%
%%% The idea behind THIS server is that the user module
%%% provides (different) functions to handle different
%%% kind of inputs. 
%%% If the Parent process terminates the Module:terminate/2
%%% function is called.
%%%
%%% The user module should export:
%%%
%%%   init(Args)  
%%%     ==> {ok, State}
%%%         {ok, State, Timeout}
%%%         ignore
%%%         {stop, Reason}
%%%
%%%   handle_call(Msg, {From, Tag}, State)
%%%
%%%    ==> {reply, Reply, State}
%%%        {reply, Reply, State, Timeout}
%%%        {noreply, State}
%%%        {noreply, State, Timeout}
%%%        {stop, Reason, Reply, State}  
%%%              Reason = normal | shutdown | Term terminate(State) is called
%%%
%%%   handle_cast(Msg, State)
%%%
%%%    ==> {noreply, State}
%%%        {noreply, State, Timeout}
%%%        {stop, Reason, State} 
%%%              Reason = normal | shutdown | Term terminate(State) is called
%%%
%%%   handle_info(Info, State) Info is e.g. {'EXIT', P, R}, {nodedown, N}, ...
%%%
%%%    ==> {noreply, State}
%%%        {noreply, State, Timeout}
%%%        {stop, Reason, State} 
%%%              Reason = normal | shutdown | Term, terminate(State) is called
%%%
%%%   terminate(Reason, State) Let the user module clean up
%%%        always called when server terminates
%%%
%%%    ==> ok
%%%
%%%
%%% The work flow (of the server) can be described as follows:
%%%
%%%   User module                          Generic
%%%   -----------                          -------
%%%     start            ----->             start
%%%     init             <-----              .
%%%
%%%                                         loop
%%%     handle_call      <-----              .
%%%                      ----->             reply
%%%
%%%     handle_cast      <-----              .
%%%
%%%     handle_info      <-----              .
%%%
%%%     terminate        <-----              .
%%%
%%%                      ----->             reply
%%%
%%%
%%% ---------------------------------------------------

-export([start/3, start/4,
	 start_link/3, start_link/4,
	 call/2, call/3,
	 cast/2, reply/2,
	 abcast/2, abcast/3,
	 multi_call/2, multi_call/3, multi_call/4,
	 %% safe_multi_call/2, safe_multi_call/3, safe_multi_call/4,
	 system_continue/3,
	 system_terminate/4,
	 system_code_change/4,
	 format_status/2]).

%% Internal exports
-export([init_it/6, print_event/3
	 %%, safe_send/2
	]).

-import(error_logger , [format/2]).

%%% ---------------------------------------------------
%%% Interface functions.
%%% ---------------------------------------------------

%%% ---------------------------------------------------
%%% Starts a generic server.
%%% start(Mod, Args, Options)
%%% start(Name, Mod, Args, Options)
%%% start_link(Mod, Args, Options)
%%% start_link(Name, Mod, Args, Options) where:
%%%    Name ::= {local, atom()} | {global, atom()}
%%%    Mod  ::= atom(), callback module implementing the 'real' server
%%%    Args ::= term(), init arguments (to Mod:init/1)
%%%    Options ::= [{timeout, Timeout} | {debug, [Flag]}]
%%%      Flag ::= trace | log | {logfile, File} | statistics | debug
%%%          (debug == log && statistics)
%%% Returns: {ok, Pid} |
%%%          {error, {already_started, Pid}} |
%%%          {error, Reason}
%%% ---------------------------------------------------
start(Mod, Args, Options) ->
    gen:start(gen_server, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
    gen:start(gen_server, nolink, Name, Mod, Args, Options).

start_link(Mod, Args, Options) ->
    gen:start(gen_server, link, Mod, Args, Options).

start_link(Name, Mod, Args, Options) ->
    gen:start(gen_server, link, Name, Mod, Args, Options).


%
% Make a call to a generic server.
% If the server is located at another node, that node will
% be monitored.
% If the client is trapping exits and is linked server termination
% is handled here (? Shall we do that here (or rely on timeouts) ?).
%
call(Name, Request) ->
    case catch gen:call(Name, '$gen_call', Request) of
	{ok,Res} ->
	    Res;
	{'EXIT',Reason} ->
	    exit({Reason, {gen_server, call, [Name, Request]}})
    end.

call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
	{ok,Res} ->
	    Res;
	{'EXIT',Reason} ->
	    exit({Reason, {gen_server, call, [Name, Request, Timeout]}})
    end.



%
% Make a cast to a generic server.
%
cast(Name, Request) ->
    catch do_cast(Name, Request),
    ok.

do_cast(Name, Request) when atom(Name) ->
    Name ! {'$gen_cast', Request};
do_cast(Pid, Request) when pid(Pid) ->
    Pid ! {'$gen_cast', Request};
do_cast({global, Name}, Request) ->
    catch global:send(Name, {'$gen_cast', Request});
do_cast({Name, Node}, Request) ->
    {Name, Node} ! {'$gen_cast', Request}.

%
% Send a reply to the client.
%
reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply}.

%
% Asyncronous broadcast, returns nothing, it's just send'n prey
%
abcast(Name, Mess) ->
    abcast([node() | nodes()], Name, Mess).
abcast([Node|Tail], Name, Mess) ->
    catch do_cast({Name,Node},Mess),
    abcast(Tail, Name, Mess);
abcast([], _,_) -> abcast.


%%%
%%% Make a call to servers at several nodes.
%%% Returns: {[Replies],[BadNodes]}
%%% A Timeout can be given
%%% 
multi_call(Name, Req) ->
    multi_call([node() | nodes()], Name, Req, infinity).

multi_call(Nodes, Name, Req) 
  when list(Nodes), atom(Name) ->
    Tag = make_ref(),
    Monitors = send_nodes(Nodes, Name, Tag, Req, []),
    rec_nodes(Tag, Monitors, Name, undefined).

multi_call(Nodes, Name, Req, infinity) ->
    multi_call(Nodes, Name, Req);
multi_call(Nodes, Name, Req, Timeout) 
  when list(Nodes), atom(Name), integer(Timeout), Timeout >= 0 ->
    Tag = make_ref(),
    Monitors = send_nodes(Nodes, Name, Tag, Req, []),
    TimerId = erlang:start_timer(Timeout, self(), ok),
    rec_nodes(Tag, Monitors, Name, TimerId).


send_nodes([Node|Tail], Name, Tag, Req, Monitors)
  when atom(Node) ->
    Monitor = start_monitor(Node, Name),
    %% Handle non-existing names in rec_nodes.
    catch {Name, Node} ! {'$gen_call', {self(), {Tag, Node}}, Req},
    send_nodes(Tail, Name, Tag, Req, [Monitor | Monitors]);
send_nodes([Node|Tail], Name, Tag, Req, Monitors) ->
    %% Skip non-atom Node
    send_nodes(Tail, Name, Tag, Req, Monitors);
send_nodes([], _Name, _Tag, _Req, Monitors) -> 
    Monitors.

start_monitor(Node, Name) when atom(Node), atom(Name) ->
    if node() == nonode@nohost, Node /= nonode@nohost ->
	    Ref = make_ref(),
	    self() ! {'DOWN', Ref, process, Name, noconnection},
	    {Node, Ref};
       true ->
	    case catch erlang:monitor(process, {Name, Node}) of
		{'EXIT', _} ->
		    %% Remote node is R6
		    monitor_node(Node, true),
		    Node;
		Ref when reference(Ref) ->
		    {Node, Ref}
	    end
    end.

%% Cancels a monitor started with Ref=erlang:monitor(_, _).
unmonitor(Ref) when reference(Ref) ->
    erlang:demonitor(Ref),
    receive
	{'DOWN', Ref, _, _, _} ->
	    true
    after 0 ->
	    true
    end.


%% Against old nodes:
%% If no reply has been delivered within 2 secs. (per node) check that
%% the server really exists and wait for ever for the answer.
%%
%% Against contemporary nodes:
%% Wait for reply, server 'DOWN', or timeout from TimerId.


rec_nodes(Tag, Nodes, Name, TimerId) -> 
    rec_nodes(Tag, Nodes, Name, [], [], 2000, TimerId).

rec_nodes(Tag, [{N,R}|Tail], Name, Badnodes, Replies, Time, TimerId ) ->
    receive
	{'DOWN', R, _, _, _} ->
	    rec_nodes(Tag, Tail, Name, [N|Badnodes], Replies, Time, TimerId);
	{{Tag, N}, Reply} ->  %% Tag is bound !!!
	    unmonitor(R), 
	    rec_nodes(Tag, Tail, Name, Badnodes, 
		      [{N,Reply}|Replies], Time, TimerId);
	{timeout, TimerId, _} ->	
	    unmonitor(R),
	    %% Collect all replies that already have arrived
	    rec_nodes_rest(Tag, Tail, Name, [N|Badnodes], Replies)
    end;
rec_nodes(Tag, [N|Tail], Name, Badnodes, Replies, Time, TimerId) ->
    %% R6 node
    receive
	{nodedown, N} ->
	    monitor_node(N, false),
	    rec_nodes(Tag, Tail, Name, [N|Badnodes], Replies, 2000, TimerId);
	{{Tag, N}, Reply} ->  %% Tag is bound !!!
	    receive {nodedown, N} -> ok after 0 -> ok end,
	    monitor_node(N, false),
	    rec_nodes(Tag, Tail, Name, Badnodes,
		      [{N,Reply}|Replies], 2000, TimerId);
	{timeout, TimerId, _} ->	
	    receive {nodedown, N} -> ok after 0 -> ok end,
	    monitor_node(N, false),
	    %% Collect all replies that already have arrived
	    rec_nodes_rest(Tag, Tail, Name, [N | Badnodes], Replies)
    after Time ->
	    case rpc:call(N, erlang, whereis, [Name]) of
		Pid when pid(Pid) -> % It exists try again.
		    rec_nodes(Tag, [N|Tail], Name, Badnodes,
			      Replies, infinity, TimerId);
		_ -> % badnode
		    receive {nodedown, N} -> ok after 0 -> ok end,
		    monitor_node(N, false),
		    rec_nodes(Tag, Tail, Name, [N|Badnodes],
			      Replies, 2000, TimerId)
	    end
    end;
rec_nodes(_, [], _, Badnodes, Replies, _, TimerId) ->
    case catch erlang:cancel_timer(TimerId) of
	false ->  % It has already sent it's message
	    receive
		{timeout, TimerId, _} -> ok
	    after 0 ->
		    ok
	    end;
	_ -> % Timer was cancelled, or TimerId was 'undefined'
	    ok
    end,
    {Replies, Badnodes}.

%% Collect all replies that already have arrived
rec_nodes_rest(Tag, [{N,R}|Tail], Name, Badnodes, Replies) ->
    receive
	{'DOWN', R, _, _, _} ->
	    rec_nodes_rest(Tag, Tail, Name, [N|Badnodes], Replies);
	{{Tag, N}, Reply} -> %% Tag is bound !!!
	    unmonitor(R),
	    rec_nodes_rest(Tag, Tail, Name, Badnodes, [{N,Reply}|Replies])
    after 0 ->
	    unmonitor(R),
	    rec_nodes_rest(Tag, Tail, Name, [N|Badnodes], Replies)
    end;
rec_nodes_rest(Tag, [N|Tail], Name, Badnodes, Replies) ->
    %% R6 node
    receive
	{nodedown, N} ->
	    monitor_node(N, false),
	    rec_nodes_rest(Tag, Tail, Name, [N|Badnodes], Replies);
	{{Tag, N}, Reply} ->  %% Tag is bound !!!
	    receive {nodedown, N} -> ok after 0 -> ok end,
	    monitor_node(N, false),
	    rec_nodes_rest(Tag, Tail, Name, Badnodes, [{N,Reply}|Replies])
    after 0 ->
	    receive {nodedown, N} -> ok after 0 -> ok end,
	    monitor_node(N, false),
	    rec_nodes_rest(Tag, Tail, Name, [N|Badnodes], Replies)
    end;
rec_nodes_rest(Tag, [], Name, Badnodes, Replies) ->
    {Replies, Badnodes}.


%%% ---------------------------------------------------
%%% Initiate the new process.
%%% Register the name using the Rfunc function
%%% Calls the Mod:init/Args function.
%%% Finally an acknowledge is sent to Parent and the main
%%% loop is entered.
%%% ---------------------------------------------------
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name, Mod, Args, Options) ->
    Debug = debug_options(Name, Options),
    case catch apply(Mod, init, [Args]) of
	{ok, State} ->
	    proc_lib:init_ack(Starter, {ok, self()}), 	    
	    loop(Parent, Name, State, Mod, infinity, Debug);
	{ok, State, Timeout} ->
	    proc_lib:init_ack(Starter, {ok, self()}), 	    
	    loop(Parent, Name, State, Mod, Timeout, Debug);
	{stop, Reason} ->
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	ignore ->
	    proc_lib:init_ack(Starter, ignore),
	    exit(normal);
	{'EXIT', Reason} ->
	    proc_lib:init_ack(Starter, {error, Reason}),
	    exit(Reason);
	Else ->
	    Error = {bad_return_value, Else},
	    proc_lib:init_ack(Starter, {error, Error}),
	    exit(Error)
    end.

%%% ---------------------------------------------------
%%% The MAIN loop.
%%% ---------------------------------------------------

loop(Parent, Name, State, Mod, Time, Debug) ->
    Msg = receive
	      Input ->
		    Input
	  after Time ->
		  timeout
	  end,
    case Msg of
	{system, From, Req} ->
	    sys:handle_system_msg(Req, From, Parent, gen_server, Debug,
				  [Name, State, Mod, Time]);
	{'EXIT', Parent, Reason} ->
	    terminate(Reason, Name, Msg, Mod, State, Debug);
	_Msg when Debug == [] ->
	    handle_msg(Msg, Parent, Name, State, Mod, Time);
	_Msg ->
	    Debug1 = sys:handle_debug(Debug, {gen_server, print_event}, 
				      Name, {in, Msg}),
	    handle_msg(Msg, Parent, Name, State, Mod, Time, Debug1)
    end.

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(Parent, Debug, [Name, State, Mod, Time]) ->
    loop(Parent, Name, State, Mod, Time, Debug).

system_terminate(Reason, Parent, Debug, [Name, State, Mod, Time]) ->
    terminate(Reason, Name, [], Mod, State, Debug).

system_code_change([Name, State, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Extra) of
	{ok, NewState} -> {ok, [Name, NewState, Mod, Time]};
	Else -> Else
    end.

%%-----------------------------------------------------------------
%% Format debug messages.  Print them as the call-back module sees
%% them, not as the real erlang messages.  Use trace for that.
%%-----------------------------------------------------------------
print_event(Dev, {in, Msg}, Name) ->
    case Msg of
	{'$gen_call', {From, _Tag}, Call} ->
	    io:format(Dev, "*DBG* ~p got call ~p from ~w~n",
		      [Name, Call, From]);
	{'$gen_cast', Cast} ->
	    io:format(Dev, "*DBG* ~p got cast ~p~n",
		      [Name, Cast]);
	_ ->
	    io:format(Dev, "*DBG* ~p got ~p~n", [Name, Msg])
    end;
print_event(Dev, {out, Msg, To, State}, Name) ->
    io:format(Dev, "*DBG* ~p sent ~p to ~w, new state ~w~n", 
	      [Name, Msg, To, State]);
print_event(Dev, {noreply, State}, Name) ->
    io:format(Dev, "*DBG* ~p new state ~w~n", [Name, State]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).


dispatch({'$gen_cast', Msg}, Mod, State) ->
    apply(Mod, handle_cast, [Msg, State]);
dispatch(Info, Mod, State) ->
    apply(Mod, handle_info, [Info, State]).

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod, Time) ->
    case catch apply(Mod, handle_call, [Msg, From, State]) of
	{reply, Reply, NState} ->
	    reply(From, Reply),
	    loop(Parent, Name, NState, Mod, infinity, []);
	{reply, Reply, NState, Time1} ->
	    reply(From, Reply),
	    loop(Parent, Name, NState, Mod, Time1, []);
	{noreply, NState} ->
	    loop(Parent, Name, NState, Mod, infinity, []);
	{noreply, NState, Time1} ->
	    loop(Parent, Name, NState, Mod, Time1, []);
	{stop, Reason, Reply, NState} ->
	    {'EXIT', R} = 
		(catch terminate(Reason, Name, Msg, Mod, NState, [])),
	    reply(From, Reply),
	    exit(R);
	Other -> handle_common_reply(Other, Parent, Name, Msg, Mod, State)
    end;
handle_msg(Msg, Parent, Name, State, Mod, Time) ->
    Reply = (catch dispatch(Msg, Mod, State)),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State).

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Mod, Time, Debug) ->
    case catch apply(Mod, handle_call, [Msg, From, State]) of
	{reply, Reply, NState} ->
	    Debug1 = reply(Name, From, Reply, NState, Debug),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{reply, Reply, NState, Time1} ->
	    Debug1 = reply(Name, From, Reply, NState, Debug),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{noreply, NState} ->
	    Debug1 = sys:handle_debug(Debug, {gen_server, print_event}, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{noreply, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, {gen_server, print_event}, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{stop, Reason, Reply, NState} ->
	    {'EXIT', R} = 
		(catch terminate(Reason, Name, Msg, Mod, NState, Debug)),
	    reply(Name, From, Reply, NState, Debug),
	    exit(R);
	Other ->
	    handle_common_reply(Other, Parent, Name, Msg, Mod, State, Debug)
    end;
handle_msg(Msg, Parent, Name, State, Mod, Time, Debug) ->
    Reply = (catch dispatch(Msg, Mod, State)),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Debug).

handle_common_reply(Reply, Parent, Name, Msg, Mod, State) ->
    case Reply of
	{noreply, NState} ->
	    loop(Parent, Name, NState, Mod, infinity, []);
	{noreply, NState, Time1} ->
	    loop(Parent, Name, NState, Mod, Time1, []);
	{stop, Reason, NState} ->
	    terminate(Reason, Name, Msg, Mod, NState, []);
	{'EXIT', What} ->
	    terminate(What, Name, Msg, Mod, State, []);
	_ ->
	    terminate({bad_return_value, Reply}, Name, Msg, Mod, State, [])
    end.

handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Debug) ->
    case Reply of
	{noreply, NState} ->
	    Debug1 = sys:handle_debug(Debug, {gen_server, print_event}, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, infinity, Debug1);
	{noreply, NState, Time1} ->
	    Debug1 = sys:handle_debug(Debug, {gen_server, print_event}, Name,
				      {noreply, NState}),
	    loop(Parent, Name, NState, Mod, Time1, Debug1);
	{stop, Reason, NState} ->
	    terminate(Reason, Name, Msg, Mod, NState, Debug);
	{'EXIT', What} ->
	    terminate(What, Name, Msg, Mod, State, Debug);
	_ ->
	    terminate({bad_return_value, Reply}, Name, Msg, Mod, State, Debug)
    end.


reply(Name, {To, Tag}, Reply, State, Debug) ->
    reply({To, Tag}, Reply),
    sys:handle_debug(Debug, {gen_server, print_event}, Name, 
		     {out, Reply, To, State} ).

%%% ---------------------------------------------------
%%% Terminate the server.
%%% ---------------------------------------------------

terminate(Reason, Name, Msg, Mod, State, Debug) ->
    case catch apply(Mod, terminate, [Reason, State]) of
	{'EXIT', R} ->
	    error_info(R, Name, Msg, State, Debug),
	    exit(R);
	_ ->
	    case Reason of
		normal ->
		    exit(normal);
		shutdown ->
		    exit(shutdown);
		_ ->
		    error_info(Reason, Name, Msg, State, Debug),
		    exit(Reason)
	    end
    end.

%% Maybe we shouldn't do this?  We have the crash report...
error_info(Reason, Name, Msg, State, Debug) ->
    format("** Generic server ~p terminating \n"
           "** Last message in was ~p~n"
           "** When Server state == ~p~n"
           "** Reason for termination == ~n** ~p~n",
	   [Name, Msg, State, Reason]),
    sys:print_log(Debug),
    ok.

%%% ---------------------------------------------------
%%% Misc. functions.
%%% ---------------------------------------------------

opt(Op, [{Op, Value}|Options]) ->
    {ok, Value};
opt(Op, [_|Options]) ->
    opt(Op, Options);
opt(_, []) ->
    false.

debug_options(Name, Opts) ->
    case opt(debug, Opts) of
	{ok, Options} -> dbg_options(Name, Options);
	_ -> dbg_options(Name, [])
    end.

dbg_options(Name, []) ->
    Opts = 
	case init:get_argument(generic_debug) of
	    error ->
		[];
	    _ ->
		[log, statistics]
	end,
    dbg_opts(Name, Opts);
dbg_options(Name, Opts) ->
    dbg_opts(Name, Opts).

dbg_opts(Name, Opts) ->
    case catch sys:debug_options(Opts) of
	{'EXIT',_} ->
	    format("~p: ignoring erroneous debug options - ~p~n",
		   [Name, Opts]),
	    [];
	Dbg ->
	    Dbg
    end.

%%-----------------------------------------------------------------
%% Status information
%%-----------------------------------------------------------------
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [Name, State, Mod, _Time]] = StatusData,
    Header = lists:concat(["Status for generic server ", Name]),
    Log = sys:get_debug(log, Debug, []),
    Specfic = 
	case erlang:function_exported(Mod, format_status, 2) of
	    true ->
		case catch apply(Mod, format_status, [Opt, [PDict, State]]) of
		    {'EXIT', _} -> [{data, [{"State", State}]}];
		    Else -> Else
		end;
	    _ ->
		[{data, [{"State", State}]}]
	end,
    [{header, Header},
     {data, [{"Status", SysState},
	     {"Parent", Parent},
	     {"Logged events", Log}]} |
     Specfic].