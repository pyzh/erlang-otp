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
-module(net_kernel).

-behaviour(gen_server).

-define(nodedown(N, State), verbose({?MODULE, ?LINE, nodedown, N}, 1, State)).
-define(nodeup(N, State), verbose({?MODULE, ?LINE, nodeup, N}, 1, State)).

%%-define(dist_debug, true).

%-define(DBG,erlang:display([?MODULE,?LINE])).

-ifdef(dist_debug).
-define(debug(Term), erlang:display(Term)).
-else.
-define(debug(Term), ok).
-endif.

%% User Interface Exports
-export([start/1, start_link/1, stop/0,
	 kernel_apply/3,
	 monitor_nodes/1,
	 longnames/0,
	 allow/1,
	 protocol_childspecs/0,
	 epmd_module/0]).

-export([connect/1, disconnect/1, hidden_connect/1]).
-export([connect_node/1, hidden_connect_node/1]). %% explicit connect

-export([node_info/1, node_info/2, nodes_info/0,
	 connecttime/0,
	 i/0, i/1, verbose/1]).

%% Internal Exports 
-export([do_spawn_link/5, 
	 ticker/2,
	 do_nodeup/2]).

-export([init/1,handle_call/3,handle_cast/2,handle_info/2,
	 terminate/2]).

-import(error_logger,[error_msg/2]).

-record(state, {
	  name,         %% The node name
	  node,         %% The node name including hostname
	  type,         %% long or short names
	  ticktime,     %% tick other nodes regularly
	  connecttime,  %% the connection setuptime.
	  connections,  %% table of connections
	  conn_owners = [], %% List of connection owner pids,
	  pend_owners = [], %% List of potential owners 
	  conn_pid    = [], %% All pending and up connection pids
	  %% used for cleanup of really crashed
	  %% (e.g. exit(Owner, kill)) connections !!
	  listen,       %% list of  #listen
	  monitor,      %% list of monitors for nodeup/nodedown
	  pending_nodeup = [],
	  allowed,       %% list of allowed nodes in a restricted system
	  verbose = 0   %def_verb()    %% level of verboseness
	 }).

-record(listen, {
		 listen,     %% listen pid
		 accept,     %% accepting pid
		 address,    %% #net_address
		 module      %% proto module
		}).

-define(LISTEN_ID, #listen.listen).
-define(ACCEPT_ID, #listen.accept).

-record(pend_nodeup, {node,
		      pid}).

-record(connection, {
		     node,          %% remote node name
		     state,         %% pending | up | up_pending
		     owner,         %% owner pid
	             pending_owner, %% possible new owner
		     address,       %% #net_address
		     waiting = [],  %% queued processes
		     type           %% normal | hidden
		    }).

-record(barred_connection, {
	  node %% remote node name
	 }).


%% Default connection setup timeout in milliseconds.
%% This timeout is set for every distributed action during
%% the connection setup.
-define(SETUPTIME, 7000). 

-include("net_address.hrl").

%% Interface functions

kernel_apply(M,F,A) ->         request({apply,M,F,A}).
allow(Nodes) ->                request({allow, Nodes}).
monitor_nodes(Flag) ->         request({monitor_nodes, Flag}).
longnames() ->                 request(longnames).
stop() ->                      erl_distribution:stop().

node_info(Node) ->             get_node_info(Node).
node_info(Node, Key) ->        get_node_info(Node, Key).
nodes_info() ->                get_nodes_info().
i() ->                         print_info().
i(Node) ->                     print_info(Node).

verbose(Level) when integer(Level) ->
    request({verbose, Level}).

%% Called though BIF's

connect(Node) ->               connect(Node, normal).
disconnect(Node) ->            request({disconnect, Node}).

%% connect but not seen
hidden_connect(Node) ->        connect(Node, hidden).

%% explicit connects
connect_node(Node) when atom(Node) ->
    request({connect, normal, Node}).
hidden_connect_node(Node) when atom(Node) ->
    request({connect, hidden, Node}).

connect(Node, Type) -> %% Type = normal | hidden
    case ets:lookup(sys_dist, Node) of
	[#barred_connection{}] ->
	    false;
	_ ->
	    case application:get_env(kernel, dist_auto_connect) of
		{ok, never} ->
		    false;
		_ ->
		    request({connect, Type, Node})
	    end
    end.

%% If the net_kernel isn't running we ignore all requests to the 
%% kernel, thus basically accepting them :-)
request(Req) ->
    case whereis(net_kernel) of
	P when pid(P) ->
	    gen_server:call(net_kernel,Req,infinity);
	Other -> ignored
    end.

%% This function is used to dynamically start the
%% distribution.

start(Args) ->
    erl_distribution:start(Args).

%% This is the main startup routine for net_kernel
%% The defaults are longnames and a ticktime of 15 secs to the tcp_drv.

start_link([Name]) ->
    start_link([Name, longnames]);

start_link([Name, LongOrShortNames]) ->
    start_link([Name, LongOrShortNames, 15000]);

start_link([Name, LongOrShortNames, Ticktime]) ->
    case gen_server:start_link({local, net_kernel}, net_kernel, 
			       {Name, LongOrShortNames, Ticktime}, []) of
	{ok, Pid} ->
	    {ok, Pid};
	{error, {already_started, Pid}} ->
	    {ok, Pid};
	Error ->
	    exit(nodistribution)
    end.

init({Name, LongOrShortNames, Ticktime}) ->
    process_flag(trap_exit,true),
    case init_node(Name, LongOrShortNames) of
	{ok, Node, Listeners} ->
	    process_flag(priority, max),
	    spawn_link(net_kernel, ticker, [self(), Ticktime]),
	    case auth:get_cookie(Node) of
		Cookie when atom(Cookie) ->
		    Monitor = std_monitors(),
		    send_list(Monitor, {nodeup, Node}),
		    {ok, #state{name = Name,
				node = Node,
				type = LongOrShortNames,
				ticktime = Ticktime,
				connecttime = connecttime(),
				connections =
				    ets:new(sys_dist,[named_table,
						      protected,
						      {keypos, 2}]),
				listen = Listeners,
				monitor = Monitor,
				allowed = [],
				verbose = 0
			       }};
		_ELSE ->
		    {stop, {error,{bad_cookie, Node}}}
	    end;
	Error ->

	    {stop, Error}
    end.


%% ------------------------------------------------------------
%% handle_call.
%% ------------------------------------------------------------

%%
%% Set up a connection to Node.
%% The response is delayed until the connection is up and
%% running.
%%
handle_call({connect, _, Node}, From, State) when Node == node() ->
    {reply, true, State};
handle_call({connect, Type, Node}, From, State) ->
    verbose({connect, Type, Node}, 1, State),
    case ets:lookup(sys_dist, Node) of
	[Conn] when Conn#connection.state == up ->
	    {reply, true, State};
	[Conn] when Conn#connection.state == pending ->
	    Waiting = Conn#connection.waiting,
	    ets:insert(sys_dist, Conn#connection{waiting = [From|Waiting]}),
	    {noreply, State};
	[Conn] when Conn#connection.state == up_pending ->
	    Waiting = Conn#connection.waiting,
	    ets:insert(sys_dist, Conn#connection{waiting = [From|Waiting]}),
	    {noreply, State};
	_ ->
	    case setup(Node,Type,From,State) of
		{ok, SetupPid} ->
		    Owners = [{SetupPid, Node} | State#state.conn_owners],
		    Conn = [SetupPid | State#state.conn_pid],
		    {noreply, State#state{conn_owners = Owners,
					  conn_pid = Conn}};
		_  ->
		    {reply, false, State}
	    end
    end;

%%
%% Close the connection to Node.
%%
handle_call({disconnect, Node}, From, State) when Node == node() ->
    {reply, false, State};
handle_call({disconnect, Node}, From, State) ->
    verbose({disconnect, Node}, 1, State),
    {Reply, State1} = do_disconnect(Node, State),
    {reply, Reply, State1};

%% 
%% The spawn/4 BIF ends up here.
%% 
handle_call({spawn,M,F,A,Gleader}, {From,Tag}, State) when pid(From) ->
    Pid = (catch spawn(M,F,A)),
    group_leader(Gleader,Pid),
    {reply,Pid,State};

%% 
%% The spawn_link/4 BIF ends up here.
%% 
handle_call({spawn_link,M,F,A,Gleader}, {From,Tag}, State) when pid(From) ->
    catch spawn(net_kernel,do_spawn_link,[{From,Tag},M,F,A,Gleader]),
    {noreply,State};

%% 
%% Only allow certain nodes.
%% 
handle_call({allow, Nodes}, _From, State) ->
    case all_atoms(Nodes) of
	true ->
	    Allowed = State#state.allowed,
	    {reply,ok,State#state{allowed = Allowed ++ Nodes}};  
	false ->
	    {reply,error,State}
    end;

%% 
%% Toggle monitor of all nodes. Pid receives {nodeup, Node}
%% and {nodedown, Node} whenever a node appears/disappears.
%% 
handle_call({monitor_nodes, Flag}, {Pid, _}, State0) ->
    {Res, State} = monitor_nodes(Flag, Pid, State0),
    {reply,Res,State};

%% 
%% authentication, used by auth. Simply works as this:
%% if the message comes through, the other node IS authorized.
%% 
handle_call({is_auth, Node}, _From, State) ->
    {reply,yes,State};

%% 
%% Not applicable any longer !?
%% 
handle_call({apply,Mod,Fun,Args}, {From,Tag}, State) when pid(From),
                                                         node(From) == node() ->
    gen_server:reply({From,Tag}, not_implemented),
%    Port = State#state.port,
%    catch apply(Mod,Fun,[Port|Args]),
    {noreply,State};

handle_call(longnames, _From, State) ->
    {reply, get(longnames), State};

handle_call({verbose, Level}, _From, State) ->
    {reply, State#state.verbose, State#state{verbose = Level}}.
    

%% ------------------------------------------------------------
%% handle_cast.
%% ------------------------------------------------------------

handle_cast(_, State) ->
    {noreply,State}.

%% ------------------------------------------------------------
%% terminate.
%% ------------------------------------------------------------

terminate(no_network, State) ->
    lists:foreach(
      fun(Node) ->
	      ?nodedown(Node, State),
	      send_list(State#state.monitor, {nodedown,Node})
      end, get_nodes(up) ++ [node()]);
terminate(_Reason, State) ->
    lists:foreach(
      fun(#listen {listen = Listen,module = Mod}) ->
	      Mod:close(Listen)
      end, State#state.listen),
    lists:foreach(
      fun(Node) ->
	      ?nodedown(Node, State),
	      send_list(State#state.monitor, {nodedown,Node})
      end, get_nodes(up) ++ [node()]).


%% ------------------------------------------------------------
%% handle_info.
%% ------------------------------------------------------------

%%
%% accept a new connection.
%%
handle_info({accept,AcceptPid,Socket,Family,Proto}, State) ->
    MyNode = State#state.node,
    case get_proto_mod(Family,Proto,State#state.listen) of
	{ok, Mod} ->
	    Pid = Mod:accept_connection(AcceptPid,
					Socket,
					MyNode,
					State#state.allowed,
					State#state.connecttime),
	    AcceptPid ! {self(), controller, Pid},
	    {noreply, State#state { conn_pid = [Pid | State#state.conn_pid] }};
	_ ->
	    AcceptPid ! {self(), unsupported_protocol},
	    {noreply, State}
    end;

%%
%% A node has successfully been connected.
%%
handle_info({SetupPid, {nodeup,Node,Address,Type,Immediate}}, 
	    State) ->
    case ets:lookup(sys_dist, Node) of
	[Conn] when Conn#connection.state == pending,
	            Conn#connection.owner == SetupPid ->
	    ets:insert(sys_dist, Conn#connection{state = up,
						 address = Address,
						 waiting = [],
						 type = Type}),
	    SetupPid ! {self(), inserted},
	    reply_waiting(Conn#connection.waiting, true),
	    case Type of
		normal ->
		    case Immediate of
			true ->
			    send_list(State#state.monitor, 
				      {nodeup, Node}),
			    {noreply, State};
			_ ->
			    Pid = spawn_link(net_kernel, 
					     do_nodeup, [self(),
							 Node]),
			    Pending = State#state.pending_nodeup,
			    {noreply, 
			     State#state{pending_nodeup =
					 [#pend_nodeup{node = Node,
						       pid = Pid} |
					  Pending]}}
		    end;
		hidden ->
		    {noreply, State}
	    end;
	_ ->
	    SetupPid ! {self(), bad_request},
	    {noreply, State}
    end;

handle_info({From,nodeup,Node}, State) ->
    Pending = State#state.pending_nodeup,
    case lookup_pend(Node, Pending) of
        {ok, NodeUp} when NodeUp#pend_nodeup.pid == From ->
            ?nodeup(Node, State),
            send_list(State#state.monitor, {nodeup, Node}),
            {noreply, State#state{pending_nodeup = del_pend(Node, Pending)}};
        _ ->
            {noreply,State}
    end;

%%
%% Mark a node as pending (accept) if not busy.
%%
handle_info({AcceptPid, {accept_pending,Node,Address,Type}}, State) ->
    case ets:lookup(sys_dist, Node) of
	[Conn] when Conn#connection.state == pending ->

	    AcceptPid ! {self(), {accept_pending, pending}},
	    {noreply, State};
	[Conn] when Conn#connection.state == up ->
	    AcceptPid ! {self(), {accept_pending, up_pending}},
	    ets:insert(sys_dist, Conn#connection { pending_owner = AcceptPid,
						  state = up_pending }),
	    Pend = [{AcceptPid, Node} | State#state.pend_owners ],
	    {noreply, State#state { pend_owners = Pend }};
	[Conn] when Conn#connection.state == up_pending ->
	    AcceptPid ! {self(), {accept_pending, already_pending}},
	    {noreply, State};
	_ ->
	    ets:insert(sys_dist, #connection{node = Node,
					     state = pending,
					     owner = AcceptPid,
					     address = Address,
					     type = Type}),
	    AcceptPid ! {self(), {accept_pending, ok}},
	    Owners = [{AcceptPid, Node} | State#state.conn_owners],
	    {noreply, State#state{conn_owners = Owners}}
    end;

%%
%% A simultaneous connect has been detected and we want to
%% change pending process.
%%
handle_info({AcceptPid, {remark_pending, Node}}, State) ->
    case ets:lookup(sys_dist, Node) of
	[Conn] when Conn#connection.state == pending ->
	    OldOwner = Conn#connection.owner,
	    ?debug({net_kernel, remark, old, OldOwner, new, AcceptPid}),
	    exit(OldOwner, remarked),
	    receive
		{'EXIT', OldOwner, _} ->
		    true
	    end,
	    Owners = lists:keyreplace(OldOwner,
				      1,
				      State#state.conn_owners,
				      {AcceptPid, Node}),
	    ets:insert(sys_dist, Conn#connection{owner = AcceptPid}),
	    AcceptPid ! {self(), {remark_pending, ok}},
	    State1 = remove_conn_pid(OldOwner,
				     State#state{conn_owners = Owners}),
	    {noreply, State1};
	_ ->
	    AcceptPid ! {self(), {remark_pending, bad_request}},
	    {noreply, State}
    end;

handle_info({SetupPid, {is_pending, Node}}, State) ->
    Reply = lists:member({SetupPid,Node},State#state.conn_owners),
    SetupPid ! {self(), {is_pending, Reply}},
    {noreply, State};


%%
%% Handle different types of process terminations.
%%
handle_info({'EXIT', From, Reason}, State) when pid(From) ->
    verbose({'EXIT', From, Reason}, 1, State),
    handle_exit(From, State);

%%
%% Handle badcookie and badname messages !
%%
handle_info({From,registered_send,To,Mess},State) ->
    send(From,To,Mess),
    {noreply,State};

%% badcookies SHOULD not be sent 
%% (if someone does erlang:set_cookie(node(),foo) this may be)
handle_info({From, badcookie, To ,Mess}, State) ->
    error_logger:error_msg("~n** Got OLD cookie from ~w~n",
			   [getnode(From)]),
    {_Reply, State1} = do_disconnect(getnode(From), State),
    {noreply,State1};

%%
%% Tick all connections.
%%
handle_info(tick, State) ->
    lists:foreach(fun({Pid,_Node}) -> Pid ! {self(), tick} end,
		  State#state.conn_owners),
    {noreply,State};

handle_info({From, {set_monitors, L}}, State) ->
    From ! {net_kernel, done},
    {noreply,State#state{monitor = L}};

handle_info(X, State) ->
    error_msg("Net kernel got ~w~n",[X]),
    {noreply,State}.

%% -----------------------------------------------------------
%% Handle exit signals.
%% We have 5 types of processes to handle.
%%
%%    1. The Listen process.
%%    2. The Accept process.
%%    3. Connection owning processes.
%%    4. Pending check nodeup processes.
%%    5. Processes monitoring nodeup/nodedown.
%%    (6. Garbage pid.)
%%
%% The process type function that handled the process throws 
%% the handle_info return value !
%% -----------------------------------------------------------

handle_exit(Pid, State) ->
    catch do_handle_exit(Pid, State).

do_handle_exit(Pid, State) ->
    State1 = remove_conn_pid(Pid, State),
    listen_exit(Pid, State1),
    accept_exit(Pid, State1),
    conn_own_exit(Pid, State1),
    nodeup_exit(Pid, State1),
    monitor_exit(Pid, State1),
    pending_own_exit(Pid, State1),
    {noreply, State1}.

remove_conn_pid(Pid, State) ->
    State#state { conn_pid = State#state.conn_pid -- [Pid] }.

listen_exit(Pid, State) ->
    case lists:keysearch(Pid, ?LISTEN_ID, State#state.listen) of
	{value, _} ->
	    error_msg("** Netkernel terminating ... **\n", []),
	    throw({stop,no_network,State});
	_ ->
	    false
    end.

accept_exit(Pid, State) ->
    Listen = State#state.listen,
    case lists:keysearch(Pid, ?ACCEPT_ID, Listen) of
	{value, ListenR} ->
	    ListenS = ListenR#listen.listen,
	    Mod = ListenR#listen.module,
	    AcceptPid = Mod:accept(ListenS),
	    L = lists:keyreplace(Pid, ?ACCEPT_ID, Listen,
				 ListenR#listen{accept = AcceptPid}),
	    throw({noreply, State#state{listen = L}});
	_ ->
	    false
    end.

conn_own_exit(Pid, State) ->
    Owners = State#state.conn_owners,
    case lists:keysearch(Pid, 1, Owners) of
	{value, {Pid, Node}} ->
	    throw({noreply, nodedown(Pid, Node, State)});
	_ ->
	    false
    end.

nodeup_exit(Pid, State) ->
    Pending = State#state.pending_nodeup,
    case del_pend(Pid, Pending) of
	Pending ->
	    false;
	NewPend ->
	    throw({noreply, State#state{pending_nodeup = NewPend}})
    end.

monitor_exit(Pid, State) ->
    Monitor = State#state.monitor,
    case delete_all(Pid, Monitor) of
	Monitor ->
	    false;
	NewMonitor ->
	    throw({noreply, State#state{monitor = NewMonitor}})
    end.

pending_own_exit(Pid, State) ->
    Pend = State#state.pend_owners,
    case lists:keysearch(Pid, 1, Pend) of
	{value, {Pid, Node}} ->
	    NewPend = lists:keydelete(Pid, 1, Pend),
	    State1 = State#state { pend_owners = NewPend },
	    case get_conn(Node) of
		{ok, Conn} when Conn#connection.state == up_pending ->
		    reply_waiting(Conn#connection.waiting, true),
		    Conn1 = Conn#connection { state = up,
					      waiting = [],
					      pending_owner = undefined },
		    ets:insert(sys_dist, Conn1);
		_ ->
		    ok
	    end,
	    throw({noreply, State1});
	_ ->
	    false
    end.
%% -----------------------------------------------------------
%% A node has gone down !!
%% nodedown(Owner, Node, State) -> State'
%% -----------------------------------------------------------

nodedown(Owner, Node, State) ->
    case get_conn(Node) of
	{ok, Conn} ->
	    nodedown(Conn, Owner, Node, Conn#connection.type, State);
	_ ->
	    State
    end.

get_conn(Node) ->
    case ets:lookup(sys_dist, Node) of
	[Conn = #connection{}] -> {ok, Conn};
	_      -> error
    end.

nodedown(Conn, Owner, Node, Type, OldState) ->
    Owners = lists:keydelete(Owner, 1, OldState#state.conn_owners),
    State = OldState#state{conn_owners = Owners},
    case Conn#connection.state of
	pending when Conn#connection.owner == Owner ->
	    pending_nodedown(Conn, Node, Type, State);
	up when Conn#connection.owner == Owner ->
	    up_nodedown(Conn, Node, Type, State);
	up_pending when Conn#connection.owner == Owner ->
	    up_pending_nodedown(Conn, Node, Type, State);
	_ ->
	    OldState
    end.

pending_nodedown(Conn, Node, Type, State) ->
    mark_sys_dist_nodedown(Node),
    reply_waiting(Conn#connection.waiting, false),
    case Type of
	normal ->
	    ?nodedown(Node, State),
	    %% Tony says: 
	    %% Do not send any nodedown to monitors in this case !
	    %% But that affected application_SUITE:start_phases 
	    %% and others, so I reinserted the send_list below.
	    %% (uabrani)
 	    send_list(State#state.monitor, {nodedown, Node});
	_      ->
	    ok
    end,
    State.

up_pending_nodedown(Conn, Node, Type, State) ->
    AcceptPid = Conn#connection.pending_owner,
    Owners = State#state.conn_owners,
    Pend = lists:keydelete(AcceptPid, 1, State#state.pend_owners),
    case Type of
	normal ->
	    send_list(State#state.monitor, {nodedown, Node});
	_ ->
	    ok
    end,
    Conn1 = Conn#connection { owner = AcceptPid,
			      pending_owner = undefined,
			      state = pending },
    ets:insert(sys_dist, Conn1),
    AcceptPid ! {self(), pending},
    State#state{conn_owners = [{AcceptPid,Node}|Owners], pend_owners = Pend}.


up_nodedown(Conn, Node, Type, State) ->
    mark_sys_dist_nodedown(Node),
    case Type of
	normal ->
	    ?nodedown(Node, State),
	    send_list(State#state.monitor, {nodedown, Node}),
	    Pending = State#state.pending_nodeup,
	    case lookup_pend(Node, Pending) of
		{ok, NodeUp} ->
		    Pid = NodeUp#pend_nodeup.pid, 
		    unlink(Pid),
		    exit(Pid, kill),
		    State#state{pending_nodeup =
				del_pend(Pid, Pending)};
		_ ->
		    State
	    end;
	_ ->
	    State
    end.

mark_sys_dist_nodedown(Node) ->
    case application:get_env(kernel, dist_auto_connect) of
	{ok, once} ->
	    ets:insert(sys_dist, #barred_connection{node = Node});
	_ ->
	    ets:delete(sys_dist, Node)
    end.

%% -----------------------------------------------------------
%% End handle_exit/2 !!
%% -----------------------------------------------------------

%% A process wants to toggle monitoring nodeup/nodedown from nodes.

monitor_nodes(true, Pid, State) ->
    %% Used to monitor all changes in the nodes list
    link(Pid),
    Monitor = State#state.monitor,
    {ok, State#state{monitor = [Pid|Monitor]}};
monitor_nodes(false, Pid, State) ->
    Monitor = State#state.monitor,
    State1 = State#state{monitor = delete_all(Pid,Monitor)},
    do_unlink(Pid, State1),
    {ok, State1};
monitor_nodes(_, _, State) ->
    {error, State}.

%% do unlink if we have no more references to Pid.
do_unlink(Pid, State) ->
    case lists:member(Pid, State#state.monitor) of
	true ->
	    false;
	_ ->
	    unlink(Pid)
    end.
do_disconnect(Node, State) ->
    case ets:lookup(sys_dist, Node) of
	[Conn] when Conn#connection.state == up ->
	    disconnect_pid(Conn#connection.owner, State);
	[Conn] when Conn#connection.state == up_pending ->
	    disconnect_pid(Conn#connection.owner, State);
	_ ->
	    {false, State}
    end.

disconnect_pid(Pid, State) ->
    exit(Pid, disconnect),
    %% Sync wait for connection to die!!!
    receive
	{'EXIT', Pid, Reason} ->
	    {_,State1} = handle_exit(Pid, State),
	    {true, State1}
    end.

%%
%%
%%
get_nodes(Which) ->
    get_nodes(ets:first(sys_dist), Which).

get_nodes('$end_of_table', _) ->
    [];
get_nodes(Key, Which) ->
    case ets:lookup(sys_dist, Key) of
	[Conn = #connection{state = up}] ->
	    [Conn#connection.node | get_nodes(ets:next(sys_dist, Key),
					      Which)];
	[Conn = #connection{}] when Which == all ->
	    [Conn#connection.node | get_nodes(ets:next(sys_dist, Key),
					      Which)];
	_ ->
	    get_nodes(ets:next(sys_dist, Key), Which)
    end.

-ifdef(NOTUSED).
stop_dist([], _) -> ok;
stop_dist([Node|Nodes], Monitor) ->
    send_list(Monitor, {nodedown, Node}),
    stop_dist(Nodes, Monitor).
-endif.

ticker(Kernel, Tick) ->
    process_flag(priority, max),
    ticker1(Kernel, to_integer(Tick)).

to_integer(T) when integer(T) -> T;
to_integer(T) when atom(T) -> 
    list_to_integer(atom_to_list(T)).

ticker1(Kernel, Tick) ->
    receive
	after Tick -> 
		Kernel ! tick,
		ticker1(Kernel, Tick)
    end.

send(From,To,Mess) ->
    case whereis(To) of
	undefined ->
	    Mess;
	P when pid(P) ->
	    P ! Mess
    end.

safesend(Name,Mess) when atom(Name) ->
    case whereis(Name) of 
	undefined ->
	    Mess;
	P when pid(P) ->
	    P ! Mess
    end;
safesend(Pid, Mess) -> Pid ! Mess.

send_list([P|T], M) -> safesend(P, M), send_list(T, M);
send_list([], _) -> ok.

%% This code is really intricate. The link will go first and then comes
%% the pid, This means that the client need not do a network link.
%% If the link message would not arrive, the runtime system  shall
%% generate a nodedown message

do_spawn_link({From,Tag},M,F,A,Gleader) ->
    link(From),
    gen_server:reply({From,Tag},self()),  %% ahhh
    group_leader(Gleader,self()),
    apply(M,F,A).

%% -----------------------------------------------------------
%% Set up connection to a new node.
%% -----------------------------------------------------------

setup(Node,Type,From,State) ->
    Allowed = State#state.allowed,
    case lists:member(Node, Allowed) of
	false when Allowed /= [] ->
	    error_msg("** Connection attempt with "
		      "disallowed node ~w ** ~n", [Node]),
	    {error, bad_node};
	_ ->
	    case select_mod(Node, State#state.listen) of
		{ok, L} ->
		    Mod = L#listen.module,
		    LAddr = L#listen.address,
		    MyNode = State#state.node,
		    Pid = Mod:setup(Node,
				    Type,
				    MyNode,
				    State#state.type,
				    State#state.connecttime),
		    Addr = LAddr#net_address {
					      address = undefined,
					      host = undefined },
		    ets:insert(sys_dist, #connection{node = Node,
						     state = pending,
						     owner = Pid,
						     waiting = [From],
						     address = Addr,
						     type = normal}),
		    {ok, Pid};
		Error ->
		    Error
	    end
    end.

%%
%% Find a module that is willing to handle connection setup to Node
%%
select_mod(Node, [L|Ls]) ->
    Mod = L#listen.module,
    case Mod:select(Node) of
	true -> {ok, L};
	false -> select_mod(Node, Ls)
    end;
select_mod(Node, []) ->
    {error, {unsupported_address_type, Node}}.


get_proto_mod(Family,Protocol,[L|Ls]) ->
    A = L#listen.address,
    if A#net_address.family == Family,
       A#net_address.protocol == Protocol ->
	    {ok, L#listen.module};
       true ->
	    get_proto_mod(Family,Protocol,Ls)
    end;
get_proto_mod(Family,Protocol,[]) ->    
    error.

%% -----------------------------------------------------------
%% Check if we are authorized after a second.
%% -----------------------------------------------------------

do_nodeup(Kernel, Node) ->
    receive
	after 1000 -> ok   %% sleep a sec, 
    end,
    case lists:member(Node, nodes()) of
	false -> exit(normal);
	true -> ok
    end,
%    We will certainly be authenticated if the node is up.
%    case auth:is_auth(Node) of
%	yes ->   Kernel ! {self(), nodeup, Node};
%	Other -> exit(normal)
%    end.
    Kernel ! {self(), nodeup, Node}.

lookup_pend(Node, [NodeUp|_]) when NodeUp#pend_nodeup.node == Node ->
    {ok, NodeUp};
lookup_pend(Node, [_|Pending]) ->
    lookup_pend(Node, Pending);
lookup_pend(Node, []) ->
    false.

del_pend(Node, [NodeUp|T]) when NodeUp#pend_nodeup.node == Node ->
    T;
del_pend(Pid, [NodeUp|T]) when NodeUp#pend_nodeup.pid == Pid ->
    T;
del_pend(Key, [NodeUp|T]) ->
    [NodeUp|del_pend(Key, T)];
del_pend(_, []) ->
    [].

%% -------- Initialisation functions ------------------------

%% never called could be removed!
%% was intended to be used to set default value for verbos in the
%% state record
%%def_verb() ->
%%    case init:get_argument(net_kernel_verbose) of
%%	{ok, [[Level]]} ->
%%	    case catch list_to_integer(Level) of
%%		Int when integer(Int) -> Int;
%%		_ -> 0
%%	    end;
%%	_ ->
%%	    0
%%    end.

init_node(Name, LongOrShortNames) ->
    {NameWithoutHost,Host} = lists:splitwith(fun($@)->false;(_)->true end,
				  atom_to_list(Name)),
    case create_name(Name, LongOrShortNames) of
	{ok,Node} ->
	    case start_protos(list_to_atom(NameWithoutHost),Node) of
		{ok, Ls} -> 
		    {ok, Node, Ls};
		Error -> 
		    Error
	    end;
	Error ->
 	    Error
    end.

%% Create the node name
create_name(Name, LongOrShortNames) ->
    put(longnames, case LongOrShortNames of 
		       shortnames -> false; 
		       longnames -> true 
		   end),
    {Head,Host1} = create_hostpart(Name,LongOrShortNames),
    case Host1 of
	{ok, HostPart} ->
	    {ok,list_to_atom(Head ++ HostPart)};
	{error,Type} ->
	    error_logger:info_msg(
	      lists:concat(["Can\'t set ",
			    Type,
			    " node name!\n"
			    "Please check your configuration\n"])),
	    {error,badarg}
    end;

create_name(Name, _) ->
    {error, badarg}.

create_hostpart(Name,LongOrShortNames) ->
    {Head,Host} = lists:splitwith(fun($@)->false;(_)->true end,
				  atom_to_list(Name)),
    Host1 = case {Host,LongOrShortNames} of
		{[$@,_|_],longnames} ->
		    {ok,Host};
		{[$@,_|_],shortnames} ->
		    case lists:member($.,Host) of
			true -> {error,short};
			_ -> {ok,Host}
		    end;
		{_,shortnames} ->
		    case inet_db:gethostname() of
			H when list(H), length(H)>0 ->
			    {ok,"@" ++ H};
			_ ->
			    {error,short}
		    end;
		{_,longnames} ->
		    case {inet_db:gethostname(),inet_db:res_option(domain)} of
			{H,D} when list(D),list(H),length(D)> 0, length(H)>0 ->
			    {ok,"@" ++ H ++ "." ++ D};
			_ ->
			    {error,long}
		    end
	    end,
    {Head,Host1}.

%%
%% 
%%
protocol_childspecs() ->
    case init:get_argument(proto_dist) of
	{ok, [Protos]} ->
	    protocol_childspecs(Protos);
	_ ->
	    protocol_childspecs(["inet_tcp"])
    end.

protocol_childspecs([]) ->    
    [];
protocol_childspecs([H|T]) ->
    Mod = list_to_atom(H ++ "_dist"),
    case (catch Mod:childspecs()) of
	{ok, Childspecs} when list(Childspecs) ->
	    Childspecs ++ protocol_childspecs(T);
	_ ->
	    protocol_childspecs(T)
    end.
    
	
%%
%% epmd_module() -> module_name of erl_epmd or similar gen_server_module.
%%

epmd_module() ->
    case init:get_argument(epmd_module) of
	{ok,[[Module]]} -> 
	    Module;
	_ ->
	    erl_epmd
    end.

%%
%% Start all protocols
%%

start_protos(Name,Node) ->
    case init:get_argument(proto_dist) of
	{ok, [Protos]} ->
	    start_protos(Name,Protos, Node);
	_ ->
	    start_protos(Name,["inet_tcp"], Node)
    end.

start_protos(Name,Ps, Node) ->
    case start_protos(Name, Ps, Node, []) of
	[] -> {error, badarg};
	Ls -> {ok, Ls}
    end.

start_protos(Name, [Proto | Ps], Node, Ls) ->
    Mod = list_to_atom(Proto ++ "_dist"),
    case Mod:listen(Name) of
	{ok, {Socket, Address, Creation}} ->
	    AcceptPid = Mod:accept(Socket),
	    (catch erlang:setnode(Node, Creation)), %% May fail.
	    auth:sync_cookie(),
	    L = #listen {
	      listen = Socket,
	      address = Address,
	      accept = AcceptPid,
	      module = Mod },
	    start_protos(Name,Ps, Node, [L|Ls]);
	{'EXIT', {undef,_}} ->
	    error_logger:info_msg("Protocol: ~p: not supported~n", [Proto]),
	    start_protos(Name,Ps, Node, Ls);
	{'EXIT', Reason} ->
	    error_logger:info_msg("Protocol: ~p: register error: ~p~n", 
				  [Proto, Reason]),
	    start_protos(Name,Ps, Node, Ls);
	{error, duplicate_name} ->
	    error_logger:info_msg("Protocol: ~p: the name " ++
				  atom_to_list(Node) ++
				  " seems to be in use by another Erlang node",
				  [Proto]),
	    start_protos(Name,Ps, Node, Ls);
	{error, Reason} ->
	    error_logger:info_msg("Protocol: ~p: register/listen error: ~p~n", 
				  [Proto, Reason]),
	    start_protos(Name,Ps, Node, Ls)
    end;
start_protos(_,[], Node, Ls) ->
    Ls.

%std_monitors() -> [global_name_server].
std_monitors() -> [global_group].

connecttime() ->
    case application:get_env(kernel, net_setuptime) of
	{ok, Time} when integer(Time), Time > 0, Time < 120 ->
	    Time * 1000;
	_ ->
	    ?SETUPTIME
    end.

%% -------- End initialisation functions --------------------

%% ------------------------------------------------------------
%% Node informaion.
%% ------------------------------------------------------------

get_node_info(Node) ->
    case ets:lookup(sys_dist, Node) of
	[Conn = #connection{owner = Owner, state = State}] ->
	    case get_status(Owner, Node, State) of
		{ok, In, Out} ->
		    {ok, [{owner, Owner},
			  {state, State},
			  {address, Conn#connection.address},
			  {type, Conn#connection.type},
			  {in, In},
			  {out, Out}]};
		_ ->
		    {error, bad_node}
	    end;
	_ ->
	    {error, bad_node}
    end.

%%
%% We can't do monitor_node here incase the node is pending,
%% the monitor_node/2 call hangs until the connection is ready.
%% We will not ask about in/out information either for pending
%% connections as this also would block this call awhile.
%%
get_status(Owner, Node, up) ->
    monitor_node(Node, true),
    Owner ! {self(), get_status},
    receive
	{Owner, get_status, Res} ->
	    monitor_node(Node, false),
	    Res;
	{nodedown, Node} ->
	    error
    end;
get_status(_, _, _) ->
    {ok, 0, 0}.

get_node_info(Node, Key) ->
    case get_node_info(Node) of
	{ok, Info} ->
	    case lists:keysearch(Key, 1, Info) of
		{value, {Key, Value}} -> {ok, Value};
		_                     -> {error, invalid_key}
	    end;
	Error ->
	    Error
    end.

get_nodes_info() ->
    get_nodes_info(get_nodes(all), []).

get_nodes_info([Node|Nodes], InfoList) ->
    case get_node_info(Node) of
	{ok, Info} -> get_nodes_info(Nodes, [{Node, Info}|InfoList]);
	_          -> get_nodes_info(Nodes, InfoList)
    end;
get_nodes_info([], InfoList) ->
    {ok, InfoList}.

%% ------------------------------------------------------------
%% Misc. functions
%% ------------------------------------------------------------

reply_waiting(Waiting, Rep) ->
    reply_waiting1(lists:reverse(Waiting), Rep).

reply_waiting1([From|W], Rep) ->
    gen_server:reply(From, Rep),
    reply_waiting1(W, Rep);
reply_waiting1([], _) ->
    ok.

delete_all(From, [From |Tail]) -> delete_all(From, Tail);
delete_all(From, [H|Tail]) ->  [H|delete_all(From, Tail)];
delete_all(_, []) -> [].

all_atoms([]) -> true;
all_atoms([N|Tail]) when atom(N) ->
    all_atoms(Tail);
all_atoms(_) -> false.

%% ------------------------------------------------------------
%% Print status information.
%% ------------------------------------------------------------

print_info() ->
    nformat("Node", "State", "Type", "In", "Out", "Address"),
    {ok, NodesInfo} = nodes_info(),
    {In,Out} = lists:foldl(fun display_info/2, {0,0}, NodesInfo),
    nformat("Total", "", "",
	    integer_to_list(In), integer_to_list(Out), "").

display_info({Node, Info}, {I,O}) ->
    State = atom_to_list(fetch(state, Info)),
    In = fetch(in, Info),
    Out = fetch(out, Info),
    Type = atom_to_list(fetch(type, Info)),
    Address = fmt_address(fetch(address, Info)),
    nformat(atom_to_list(Node), State, Type,
	    integer_to_list(In), integer_to_list(Out), Address),
    {I+In,O+Out}.

fmt_address(undefined) -> 
    "-";
fmt_address(A) ->
    case A#net_address.family of
	inet ->
	    case A#net_address.address of
		{IP,Port} ->
		    inet_parse:ntoa(IP) ++ ":" ++ integer_to_list(Port);
		_ -> "-"
	    end;
	inet6 ->
	    case A#net_address.address of
		{IP,Port} ->
		    inet_parse:ntoa(IP) ++ "/" ++ integer_to_list(Port);
		_ -> "-"
	    end;
	_ ->
	    lists:flatten(io_lib:format("~p", [A#net_address.address]))
    end.


fetch(Key, Info) ->
    case lists:keysearch(Key, 1, Info) of
	{value, {_, Val}} -> Val;
	false -> 0
    end.

nformat(A1, A2, A3, A4, A5, A6) ->
    io:format("~-20s ~-7s ~-6s ~8s ~8s ~s~n", [A1,A2,A3,A4,A5,A6]).

print_info(Node) ->
    case node_info(Node) of
	{ok, Info} ->
	    State = fetch(state, Info),
	    In = fetch(in, Info),
	    Out = fetch(out, Info),
	    Type = fetch(type, Info),
	    Address = fmt_address(fetch(address, Info)),
	    io:format("Node     = ~p~n"
		      "State    = ~p~n"
		      "Type     = ~p~n"
		      "In       = ~p~n"
		      "Out      = ~p~n"
		      "Address  = ~s~n",
		      [Node, State, Type, In, Out, Address]);
	Error ->
	    Error
    end.

verbose(Term, Level, #state{verbose = Verbose}) when Verbose >= Level ->
    error_logger:info_report({net_kernel, Term});
verbose(_, _, _) ->
    ok.

getnode(P) when pid(P) -> node(P);
getnode(P) -> P.