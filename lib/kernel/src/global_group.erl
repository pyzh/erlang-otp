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
-module(global_group).

%% Groups nodes into global groups with an own global name space.

-behaviour(gen_server).

%% External exports
-export([start/0, start_link/0, stop/0, init/1]).
-export([handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export([global_groups/0]).
-export([monitor_nodes/1]).
-export([own_nodes/0]).
-export([registered_names/1]).
-export([send/2]).
-export([send/3]).
-export([whereis_name/1]).
-export([whereis_name/2]).
-export([global_groups_changed/1]).
-export([global_groups_added/1]).
-export([global_groups_removed/1]).
-export([sync/0]).
-export([ng_add_check/2]).

-export([info/0]).
-export([registered_names_test/1]).
-export([send_test/2]).
-export([whereis_name_test/1]).
-export([get_own_nodes/0]).


-export([config_scan/1]).


%% Internal exports
-export([sync_init/3]).


-define(cc_vsn, 1).

%%%====================================================================================
%%% The state of the global_group process
%%% 
%%% sync_state =  no_conf (global_groups not defined, inital state) |
%%%               synced 
%%% group_name =  Own global group name
%%% nodes =       Nodes in the own global group
%%% no_contact =  Nodes which we haven't had contact with yet
%%% sync_error =  Nodes which we haven't had contact with yet
%%% other_grps =  list of other global group names and nodes, [{otherName, [Node]}]
%%% node_name =   Own node 
%%% monitor =     List of Pids requesting nodeup/nodedown
%%%====================================================================================
-record(state, {sync_state = no_conf, connect_all, group_name = [], 
		nodes = [], no_contact = [], sync_error = [], other_grps = [], 
		node_name = node(), monitor = []}).




%%%====================================================================================
%%% External exported
%%%====================================================================================
global_groups() ->
    request(global_groups).

monitor_nodes(Flag) -> 
    case Flag of
	true -> request({monitor_nodes, Flag});
	false -> request({monitor_nodes, Flag});
	_ -> {error, not_boolean}
    end.

own_nodes() ->
    request(own_nodes).

registered_names(Arg) ->
    request({registered_names, Arg}).

send(Name, Msg) ->
    request({send, Name, Msg}).

send(Group, Name, Msg) ->
    request({send, Group, Name, Msg}).

whereis_name(Name) ->
    request({whereis_name, Name}).

whereis_name(Group, Name) ->
    request({whereis_name, Group, Name}).

global_groups_changed(NewPara) ->
    request({global_groups_changed, NewPara}).

global_groups_added(NewPara) ->
    request({global_groups_added, NewPara}).

global_groups_removed(NewPara) ->
    request({global_groups_removed, NewPara}).

sync() ->
    request(sync).

ng_add_check(Node, OthersNG) ->
    request({ng_add_check, Node, OthersNG}).



info() ->
    request(info, 3000).

%% ==== ONLY for test suites ====
registered_names_test(Arg) ->
    request({registered_names_test, Arg}).
send_test(Name, Msg) ->
    request({send_test, Name, Msg}).
whereis_name_test(Name) ->
    request({whereis_name_test, Name}).
%% ==== ONLY for test suites ====


request(Req) ->
    request(Req, infinity).

request(Req, Time) ->
    case whereis(global_group) of
	P when pid(P) ->
	    gen_server:call(global_group, Req, Time);
	Other -> 
	    {error, global_group_not_runnig}
    end.



%%%====================================================================================
%%% gen_server start
%%%
%%% The first thing to happen is to read if the global_groups key is defined in the
%%% .config file. If not defined, the whole system is started as one global_group, 
%%% and the services of global_group are superfluous.
%%% Otherwise a sync process is started to check that all nodes in the own global
%%% group have the same configuration. This is done by sending 'conf_check' to all
%%% other nodes and requiring 'conf_check_result' back.
%%% If the nodes are not in agreement of the configuration the global_group process 
%%% will remove these nodes from the #state.nodes list. This can be a normal case
%%% at release upgrade when all nodes are not yet upgraded.
%%%
%%% It is possible to manually force a sync of the global_group. This is done for 
%%% instance after a release upgrade, after all nodes in the group beeing upgraded.
%%% The nodes are not synced automatically because it would cause the node to be
%%% disconnected from those not yet beeing upgraded.
%%%
%%% The three process dictionary variables (registered_names, send, and whereis_name) 
%%% are used to store information needed if the search process crashes. 
%%% The search process is a help process to find registered names in the system.
%%%====================================================================================
start() -> gen_server:start({local, global_group}, global_group, [], []).
start_link() -> gen_server:start_link({local, global_group}, global_group,[],[]).
stop() -> gen_server:call(global_group, stop, infinity).

init([]) ->
    process_flag(priority, max),
    put(registered_names, [undefined]),
    put(send, [undefined]),
    put(whereis_name, [undefined]),
    process_flag(trap_exit, true),
    Ca = case init:get_argument(connect_all) of
	     {ok, [["false"]]} ->
		 false;
	     _ ->
		 true
	 end,

    global:sync(), %% Moved here from kernel_config.erl
    case application:get_env(kernel, global_groups) of
	undefined ->
	    {ok, #state{connect_all = Ca}};
	{ok, []} ->
	    {ok, #state{connect_all = Ca}};
	{ok, NodeGrps} ->
	    {DefGroupName, DefNodes, DefOther} = 
		case catch config_scan(NodeGrps) of
		    {error, Error2} ->
			exit({error, {'invalid global_groups definition', NodeGrps}});
		    {DefGroupNameT, DefNodesT, DefOtherT} ->
			%% First disconnect any nodes not belonging to our own group
			disconnect_nodes(nodes() -- DefNodesT),
			lists:foreach(fun(Node) ->
					      erlang:monitor_node(Node, true)
				      end,
				      DefNodesT),
			{DefGroupNameT, lists:delete(node(), DefNodesT), DefOtherT}
		end,
	    {ok, #state{sync_state = synced, group_name = DefGroupName, 
			no_contact = lists:sort(DefNodes), 
			other_grps = DefOther}}
    end.


%%%====================================================================================
%%% sync() -> ok 
%%%
%%% An operator ordered sync of the own global group. This must be done after
%%% a release upgrade. It can also be ordered if somthing has made the nodes
%%% to disagree of the global_groups definition.
%%%====================================================================================
handle_call(sync, From, S) ->
%    io:format("~p sync ~p~n",[node(), application:get_env(kernel, global_groups)]),
    case application:get_env(kernel, global_groups) of
	undefined ->
	    {reply, ok, S};
	{ok, []} ->
	    {reply, ok, S};
	{ok, NodeGrps} ->
	    {DefGroupName, DefNodes, DefOther} = 
		case catch config_scan(NodeGrps) of
		    {error, Error2} ->
			exit({error, {'invalid global_groups definition', NodeGrps}});
		    {DefGroupNameT, DefNodesT, DefOtherT} ->
			%% First inform global on all nodes not belonging to our own group
			disconnect_nodes(nodes() -- DefNodesT),
			%% Sync with the nodes in the own group
			kill_global_group_check(),
			Pid = spawn_link(?MODULE, sync_init, 
					 [sync, DefGroupNameT, DefNodesT]),
			register(global_group_check, Pid),
			{DefGroupNameT, lists:delete(node(), DefNodesT), DefOtherT}
		end,
	    {reply, ok, S#state{sync_state = synced, group_name = DefGroupName, 
				no_contact = lists:sort(DefNodes), 
				other_grps = DefOther}}
    end;



%%%====================================================================================
%%% global_groups() -> {OwnGroupName, [OtherGroupName]} | undefined
%%%
%%% Get the names of the global groups
%%%====================================================================================
handle_call(global_groups, From, S) ->
    Result = case S#state.sync_state of
		 no_conf ->
		     undefined;
		 synced ->
		     Other = lists:foldl(fun({N,L}, Acc) -> Acc ++ [N]
					 end,
					 [], S#state.other_grps),
		     {S#state.group_name, Other}
	     end,
    {reply, Result, S};



%%%====================================================================================
%%% monitor_nodes(bool()) -> ok 
%%%
%%% Monitor nodes in the own global group. 
%%%   True => send nodeup/nodedown to the requesting Pid
%%%   False => stop sending nodeup/nodedown to the requesting Pid
%%%====================================================================================
handle_call({monitor_nodes, Flag}, {Pid, _}, StateIn) ->
%    io:format("***** handle_call ~p~n",[monitor_nodes]),
    {Res, State} = monitor_nodes(Flag, Pid, StateIn),
    {reply, Res, State};


%%%====================================================================================
%%% own_nodes() -> [Node] 
%%%
%%% Get a list of nodes in the own global group
%%%====================================================================================
handle_call(own_nodes, From, S) ->
    Nodes = case S#state.sync_state of
		no_conf ->
		    [node() | nodes()];
		synced ->
		    get_own_nodes()
%		    S#state.nodes
	    end,
    {reply, Nodes, S};



%%%====================================================================================
%%% registered_names({node, Node}) -> [Name] | {error, ErrorMessage}
%%% registered_names({group, GlobalGroupName}) -> [Name] | {error, ErrorMessage}
%%%
%%% Get the registered names from a specified Node, or GlobalGroupName.
%%%====================================================================================
handle_call({registered_names, {group, Group}}, From, S) when Group == S#state.group_name ->
    Res = global:registered_names(),
    {reply, Res, S};
handle_call({registered_names, {group, Group}}, From, S) ->
    case lists:keysearch(Group, 1, S#state.other_grps) of
	false ->
	    {reply, [], S};
	{value, {Group, []}} ->
	    {reply, [], S};
	{value, {Group, Nodes}} ->
	    Pid = global_search:start(names, {group, Nodes, From}),
	    Wait = get(registered_names),
	    put(registered_names, [{Pid, From} | Wait]),
	    {noreply, S}
    end;
handle_call({registered_names, {node, Node}}, From, S) when Node == node() ->
    Res = global:registered_names(),
    {reply, Res, S};
handle_call({registered_names, {node, Node}}, From, S) ->
    Pid = global_search:start(names, {node, Node, From}),
%    io:format(">>>>> registered_names Pid ~p~n",[Pid]),
    Wait = get(registered_names),
    put(registered_names, [{Pid, From} | Wait]),
    {noreply, S};




%%%====================================================================================
%%% send(Name, Msg) -> Pid | {badarg, {Name, Msg}}
%%% send({node, Node}, Name, Msg) -> Pid | {badarg, {Name, Msg}}
%%% send({group, GlobalGroupName}, Name, Msg) -> Pid | {badarg, {Name, Msg}}
%%%
%%% Send the Msg to the specified globally registered Name in own global group,
%%% in specified Node, or GlobalGroupName.
%%% But first the receiver is to be found, the thread is continued at
%%% handle_cast(send_res)
%%%====================================================================================
%% Search in the whole known world, but check own node first.
handle_call({send, Name, Msg}, From, S) ->
    case global:whereis_name(Name) of
	undefined ->
	    Pid = global_search:start(send, {any, S#state.other_grps, Name, Msg, From}),
	    Wait = get(send),
	    put(send, [{Pid, From, Name, Msg} | Wait]),
	    {noreply, S};
	Found ->
	    Found ! Msg,
	    {reply, Found, S}
    end;
%% Search in the specified global group, which happens to be the own group.
handle_call({send, {group, Grp}, Name, Msg}, From, S) when Grp == S#state.group_name ->
    case global:whereis_name(Name) of
	undefined ->
	    {reply, {badarg, {Name, Msg}}, S};
	Pid ->
	    Pid ! Msg,
	    {reply, Pid, S}
    end;
%% Search in the specified global group.
handle_call({send, {group, Group}, Name, Msg}, From, S) ->
    case lists:keysearch(Group, 1, S#state.other_grps) of
	false ->
	    {reply, {badarg, {Name, Msg}}, S};
	{value, {Group, []}} ->
	    {reply, {badarg, {Name, Msg}}, S};
	{value, {Group, Nodes}} ->
	    Pid = global_search:start(send, {group, Nodes, Name, Msg, From}),
	    Wait = get(send),
	    put(send, [{Pid, From, Name, Msg} | Wait]),
	    {noreply, S}
    end;
%% Search on the specified node.
handle_call({send, {node, Node}, Name, Msg}, From, S) ->
    Pid = global_search:start(send, {node, Node, Name, Msg, From}),
    Wait = get(send),
    put(send, [{Pid, From, Name, Msg} | Wait]),
    {noreply, S};



%%%====================================================================================
%%% whereis_name(Name) -> Pid | undefined
%%% whereis_name({node, Node}, Name) -> Pid | undefined
%%% whereis_name({group, GlobalGroupName}, Name) -> Pid | undefined
%%%
%%% Get the Pid of a globally registered Name in own global group,
%%% in specified Node, or GlobalGroupName.
%%% But first the process is to be found, 
%%% the thread is continued at handle_cast(find_name_res)
%%%====================================================================================
%% Search in the whole known world, but check own node first.
handle_call({whereis_name, Name}, From, S) ->
    case global:whereis_name(Name) of
	undefined ->
	    Pid = global_search:start(whereis, {any, S#state.other_grps, Name, From}),
	    Wait = get(whereis_name),
	    put(whereis_name, [{Pid, From} | Wait]),
	    {noreply, S};
	Found ->
	    {reply, Found, S}
    end;
%% Search in the specified global group, which happens to be the own group.
handle_call({whereis_name, {group, Group}, Name}, From, S) 
  when Group == S#state.group_name ->
    Res = global:whereis_name(Name),
    {reply, Res, S};
%% Search in the specified global group.
handle_call({whereis_name, {group, Group}, Name}, From, S) ->
    case lists:keysearch(Group, 1, S#state.other_grps) of
	false ->
	    {reply, undefined, S};
	{value, {Group, []}} ->
	    {reply, undefined, S};
	{value, {Group, Nodes}} ->
	    Pid = global_search:start(whereis, {group, Nodes, Name, From}),
	    Wait = get(whereis_name),
	    put(whereis_name, [{Pid, From} | Wait]),
	    {noreply, S}
    end;
%% Search on the specified node.
handle_call({whereis_name, {node, Node}, Name}, From, S) ->
    Pid = global_search:start(whereis, {node, Node, Name, From}),
    Wait = get(whereis_name),
    put(whereis_name, [{Pid, From} | Wait]),
    {noreply, S};


%%%====================================================================================
%%% global_groups parameter changed
%%% The node is not resynced automatically because it would cause this node to
%%% be disconnected from those nodes not yet been upgraded.
%%%====================================================================================
handle_call({global_groups_changed, NewPara}, From, S) ->
    {NewGroupName, NewNodes, NewOther} = 
	case catch config_scan(NewPara) of
	    {error, Error2} ->
		exit({error, {'invalid global_groups definition', NewPara}});
	    {DefGroupName, DefNodes, DefOther} ->
		{DefGroupName, DefNodes, DefOther}
	end,

    %% #state.nodes is the common denominator of previous and new definition
    NN = NewNodes -- (NewNodes -- S#state.nodes),
    %% rest of the nodes in the new definition are marked as not yet contacted
    NNC = (NewNodes -- S#state.nodes) --  S#state.sync_error,
    %% remove sync_error nodes not belonging to the new group
    NSE = NewNodes -- (NewNodes -- S#state.sync_error),

    %% Disconnect the connection to nodes which are not in our old global group.
    %% This is done because if we already are aware of new nodes (to our global
    %% group) global is not going to be synced to these nodes. We disconnect instead
    %% of connect because upgrades can be done node by node and we cannot really
    %% know what nodes these new nodes are synced to. The operator can always 
    %% manually force a sync of the nodes after all nodes beeing uppgraded.
    %% We must disconnect also if some nodes to which we have a connection
    %% will not be in any global group at all.
    force_nodedown(nodes() -- NewNodes),

    NewS = S#state{group_name = NewGroupName, 
		   nodes = lists:sort(NN), 
		   no_contact = lists:sort(lists:delete(node(), NNC)), 
		   sync_error = lists:sort(NSE), 
		   other_grps = NewOther},
    {reply, ok, NewS};



%%%====================================================================================
%%% global_groups parameter added
%%% The node is not resynced automatically because it would cause this node to
%%% be disconnected from those nodes not yet been upgraded.
%%%====================================================================================
handle_call({global_groups_added, NewPara}, From, S) ->
%    io:format("### global_groups_changed, NewPara ~p ~n",[NewPara]),
    {NewGroupName, NewNodes, NewOther} = 
	case catch config_scan(NewPara) of
	    {error, Error2} ->
		exit({error, {'invalid global_groups definition', NewPara}});
	    {DefGroupName, DefNodes, DefOther} ->
		{DefGroupName, DefNodes, DefOther}
	end,
    %% disconnect from those nodes which are not going to be in our global group
    force_nodedown(nodes() -- NewNodes),

    %% Check which nodes are already updated
    OwnNG = get_own_nodes(),
    {NN, NNC, NSE} = 
	lists:foldl(fun(Node, {NN_acc, NNC_acc, NSE_acc}) -> 
			    case rpc:call(Node, global_group, ng_add_check, 
					  [node(), OwnNG]) of
				{badrpc, _} ->
				    {NN_acc, [Node | NNC_acc], NSE_acc};
				agreed ->
				    {[Node | NN_acc], NNC_acc, NSE_acc};
				not_agreed ->
				    {NN_acc, NNC_acc, [Node | NSE_acc]}
			    end
		    end,
		    {[], [], []}, lists:delete(node(), NewNodes)),

    NewS = S#state{sync_state = synced, group_name = NewGroupName, nodes = lists:sort(NN), 
		   sync_error = lists:sort(NSE), no_contact = lists:sort(NNC), 
		   other_grps = NewOther},
    {reply, ok, NewS};


%%%====================================================================================
%%% global_groups parameter removed
%%%====================================================================================
handle_call({global_groups_removed, NewPara}, From, S) ->
%    io:format("### global_groups_removed, NewPara ~p ~n",[NewPara]),

    NewS = S#state{sync_state = no_conf, group_name = [], nodes = [], 
		   sync_error = [], no_contact = [], 
		   other_grps = []},
    {reply, ok, NewS};


%%%====================================================================================
%%% global_groups parameter added to some other node which thinks that we
%%% belong to the same global group.
%%% It could happen that our node is not yet updated with the new node_group parameter
%%%====================================================================================
handle_call({ng_add_check, Node, OthersNG}, From, S) ->
    %% Check which nodes are already updated
    OwnNG = get_own_nodes(),
    case OwnNG of
	OthersNG ->
	    NN = [Node | S#state.nodes],
	    NSE = lists:delete(Node, S#state.sync_error),
	    NNC = lists:delete(Node, S#state.no_contact),
	    NewS = S#state{nodes = lists:sort(NN), 
			   sync_error = NSE, 
			   no_contact = NNC},
	    {reply, agreed, NewS};
	_ ->
	    {reply, not_agreed, S}
    end;


%%%====================================================================================
%%% Misceleaneous help function to read some variables
%%%====================================================================================
handle_call(info, From, S) ->    
    Reply = [{state,          S#state.sync_state},
	     {own_group_name, S#state.group_name},
	     {own_group_nodes, get_own_nodes()},
%	     {"nodes()",      lists:sort(nodes())},
	     {synced_nodes,   S#state.nodes},
	     {sync_error,     S#state.sync_error},
	     {no_contact,     S#state.no_contact},
	     {other_groups,   S#state.other_grps},
	     {monitoring,     S#state.monitor}],

    {reply, Reply, S};

handle_call(get, From, S) ->
    {reply, get(), S};


%%%====================================================================================
%%% Only for test suites. These tests when the search process exits.
%%%====================================================================================
handle_call({registered_names_test, {node, 'test3844zty'}}, From, S) ->
    Pid = global_search:start(names_test, {node, 'test3844zty'}),
    Wait = get(registered_names),
    put(registered_names, [{Pid, From} | Wait]),
    {noreply, S};
handle_call({registered_names_test, {node, Node}}, From, S) ->
    {reply, {error, illegal_function_call}, S};
handle_call({send_test, Name, 'test3844zty'}, From, S) ->
    Pid = global_search:start(send_test, 'test3844zty'),
    Wait = get(send),
    put(send, [{Pid, From, Name, 'test3844zty'} | Wait]),
    {noreply, S};
handle_call({send_test, Name, Msg }, From, S) ->
    {reply, {error, illegal_function_call}, S};
handle_call({whereis_name_test, 'test3844zty'}, From, S) ->
    Pid = global_search:start(whereis_test, 'test3844zty'),
    Wait = get(whereis_name),
    put(whereis_name, [{Pid, From} | Wait]),
    {noreply, S};
handle_call({whereis_name_test, Name}, From, S) ->
    {reply, {error, illegal_function_call}, S};




handle_call(Call, From, S) ->
%    io:format("***** handle_call ~p~n",[Call]),
    {reply, {illegal_message, Call}, S}.
    




%%%====================================================================================
%%% registered_names({node, Node}) -> [Name] | {error, ErrorMessage}
%%% registered_names({group, GlobalGroupName}) -> [Name] | {error, ErrorMessage}
%%%
%%% Get a list of nodes in the own global group
%%%====================================================================================
handle_cast({registered_names, User}, S) ->
%    io:format(">>>>> registered_names User ~p~n",[User]),
    Res = global:registered_names(),
    User ! {registered_names_res, Res},
    {noreply, S};

handle_cast({registered_names_res, Result, Pid, From}, S) ->
%    io:format(">>>>> registered_names_res Result ~p~n",[Result]),
    unlink(Pid),
    exit(Pid, normal),
    Wait = get(registered_names),
    NewWait = lists:delete({Pid, From},Wait),
    put(registered_names, NewWait),
    gen_server:reply(From, Result),
    {noreply, S};



%%%====================================================================================
%%% send(Name, Msg) -> Pid | {error, ErrorMessage}
%%% send({node, Node}, Name, Msg) -> Pid | {error, ErrorMessage}
%%% send({group, GlobalGroupName}, Name, Msg) -> Pid | {error, ErrorMessage}
%%%
%%% The registered Name is found; send the message to it, kill the search process,
%%% and return to the requesting process.
%%%====================================================================================
handle_cast({send_res, Result, Name, Msg, Pid, From}, S) ->
%    io:format("~p>>>>> send_res Result ~p~n",[node(), Result]),
    case Result of
	{badarg,{Name, Msg}} ->
	    continue;
	ToPid ->
	    ToPid ! Msg
    end,
    unlink(Pid),
    exit(Pid, normal),
    Wait = get(send),
    NewWait = lists:delete({Pid, From, Name, Msg},Wait),
    put(send, NewWait),
    gen_server:reply(From, Result),
    {noreply, S};



%%%====================================================================================
%%% A request from a search process to check if this Name is registered at this node.
%%%====================================================================================
handle_cast({find_name, User, Name}, S) ->
    Res = global:whereis_name(Name),
%    io:format(">>>>> find_name Name ~p   Res ~p~n",[Name, Res]),
    User ! {find_name_res, Res},
    {noreply, S};

%%%====================================================================================
%%% whereis_name(Name) -> Pid | undefined
%%% whereis_name({node, Node}, Name) -> Pid | undefined
%%% whereis_name({group, GlobalGroupName}, Name) -> Pid | undefined
%%%
%%% The registered Name is found; kill the search process
%%% and return to the requesting process.
%%%====================================================================================
handle_cast({find_name_res, Result, Pid, From}, S) ->
%    io:format(">>>>> find_name_res Result ~p~n",[Result]),
%    io:format(">>>>> find_name_res get() ~p~n",[get()]),
    unlink(Pid),
    exit(Pid, normal),
    Wait = get(whereis_name),
    NewWait = lists:delete({Pid, From},Wait),
    put(whereis_name, NewWait),
    gen_server:reply(From, Result),
    {noreply, S};


%%%====================================================================================
%%% The node is synced successfully
%%%====================================================================================
handle_cast({synced, NoContact}, S) ->
%    io:format("~p>>>>> synced ~p  ~n",[node(), NoContact]),
    kill_global_group_check(),
    Nodes = get_own_nodes() -- [node() | NoContact],
    {noreply, S#state{nodes = lists:sort(Nodes),
		      sync_error = [],
		      no_contact = NoContact}};    


%%%====================================================================================
%%% The node could not sync with some other nodes.
%%%====================================================================================
handle_cast({sync_error, NoContact, ErrorNodes}, S) ->
%    io:format("~p>>>>> sync_error ~p ~p ~n",[node(), NoContact, ErrorNodes]),
    Txt = io_lib:format("Global group: Could not synchronize with these nodes ~p~n"
			"because global_groups were not in agreement. ~n", [ErrorNodes]),
    error_logger:error_report(Txt),
    kill_global_group_check(),
    Nodes = (get_own_nodes() -- [node() | NoContact]) -- ErrorNodes,
    {noreply, S#state{nodes = lists:sort(Nodes), 
		      sync_error = ErrorNodes,
		      no_contact = NoContact}};


%%%====================================================================================
%%% Another node is checking this node's group configuration
%%%====================================================================================
handle_cast({conf_check, Vsn, Node, From, sync, CCName, CCNodes}, S) ->
    CurNodes = S#state.nodes,
%    io:format(">>>>> conf_check,sync  Node ~p~n",[Node]),
    %% Another node is syncing, 
    %% done for instance after upgrade of global_groups parameter
    NS = 
	case application:get_env(kernel, global_groups) of
	    undefined ->
		%% We didn't have any node_group definition
		disconnect_nodes([Node]),
		{global_group_check, Node} ! {config_error, Vsn, From, node()},
		S;
	    {ok, []} ->
		%% Our node_group definition was empty
		disconnect_nodes([Node]),
		{global_group_check, Node} ! {config_error, Vsn, From, node()},
		S;
	    %%---------------------------------
	    %% global_groups defined
	    %%---------------------------------
	    {ok, NodeGrps} ->
		case catch config_scan(NodeGrps) of
		    {error, Error2} ->
			%% Our node_group definition was erroneous
			disconnect_nodes([Node]),
			{global_group_check, Node} ! {config_error, Vsn, From, node()},
			S#state{nodes = lists:delete(Node, CurNodes)};

		    {CCName, CCNodes, _OtherDef} ->
			%% OK, add the node to the #state.nodes if it isn't there
			global_name_server ! {nodeup, Node},
			{global_group_check, Node} ! {config_ok, Vsn, From, node()},
			case lists:member(Node, CurNodes) of
			    false ->
				NewNodes = lists:sort([Node | CurNodes]),
				NSE = lists:delete(Node, S#state.sync_error),
				NNC = lists:delete(Node, S#state.no_contact),
				S#state{nodes = NewNodes, 
				        sync_error = NSE,
				        no_contact = NNC};
			    true ->
				S
			end;
		    _ ->
			%% node_group definitions were not in agreement
			disconnect_nodes([Node]),
			{global_group_check, Node} ! {config_error, Vsn, From, node()},
			NN = lists:delete(Node, S#state.nodes),
			NSE = lists:delete(Node, S#state.sync_error),
			NNC = lists:delete(Node, S#state.no_contact),
			S#state{nodes = NN,
				sync_error = NSE,
				no_contact = NNC}
		end
	end,
    {noreply, NS};


handle_cast(Cast, S) ->
%    io:format("***** handle_cast ~p~n",[Cast]),
    {noreply, S}.
    


%%%====================================================================================
%%% A node went down. If no global group configuration inform global;
%%% if global group configuration inform global only if the node is one in
%%% the own global group.
%%%====================================================================================
handle_info({nodeup, Node}, S) when S#state.sync_state == no_conf ->
%    io:format("~p>>>>> nodeup, Node ~p ~n",[node(), Node]),
    send_monitor(S#state.monitor, {nodeup, Node}, S#state.sync_state),
    global_name_server ! {nodeup, Node},
    {noreply, S};
handle_info({nodeup, Node}, S) ->
%    io:format("~p>>>>> nodeup, Node ~p ~n",[node(), Node]),
    OthersNG = case S#state.sync_state of
		   synced ->
		       X = (catch rpc:call(Node, global_group, get_own_nodes, [])),
		       case X of
			   X when list(X) ->
			       lists:sort(X);
			   _ ->
			       []
		       end;
		   no_conf ->
		       []
	       end,

    NNC = lists:delete(Node, S#state.no_contact),
    NSE = lists:delete(Node, S#state.sync_error),
    OwnNG = get_own_nodes(),
    case OwnNG of
	OthersNG ->
	    send_monitor(S#state.monitor, {nodeup, Node}, S#state.sync_state),
	    global_name_server ! {nodeup, Node},
	    case lists:member(Node, S#state.nodes) of
		false ->
		    NN = lists:sort([Node | S#state.nodes]),
		    {noreply, S#state{nodes = NN, 
				      no_contact = NNC,
				      sync_error = NSE}};
		true ->
		    {noreply, S#state{no_contact = NNC,
				      sync_error = NSE}}
	    end;
	_ ->
	    case {lists:member(Node, get_own_nodes()), 
		  lists:member(Node, S#state.sync_error)} of
		{true, false} ->
		    NSE2 = lists:sort([Node | S#state.sync_error]),
		    {noreply, S#state{no_contact = NNC,
				      sync_error = NSE2}};
		_ ->
		    {noreply, S}
	    end
    end;

%%%====================================================================================
%%% A node has crashed. 
%%% nodedown must always be sent to global; this is a security measurement
%%% because during release upgrade the global_groups parameter is upgraded
%%% before the node is synced. This means that nodedown may arrive from a
%%% node which we are not aware of.
%%%====================================================================================
handle_info({nodedown, Node}, S) when S#state.sync_state == no_conf ->
%    io:format("~p>>>>> nodedown, no_conf Node ~p~n",[node(), Node]),
    send_monitor(S#state.monitor, {nodedown, Node}, S#state.sync_state),
    global_name_server ! {nodedown, Node},
    {noreply, S};
handle_info({nodedown, Node}, S) ->
%    io:format("~p>>>>> nodedown, Node ~p  ~n",[node(), Node]),
    send_monitor(S#state.monitor, {nodedown, Node}, S#state.sync_state),
    global_name_server ! {nodedown, Node},
    NN = lists:delete(Node, S#state.nodes),
    NSE = lists:delete(Node, S#state.sync_error),
    NNC = case {lists:member(Node, get_own_nodes()), 
		lists:member(Node, S#state.no_contact)} of
	      {true, false} ->
		  [Node | S#state.no_contact];
	      _ ->
		  S#state.no_contact
	  end,
    {noreply, S#state{nodes = NN, no_contact = NNC, sync_error = NSE}};


%%%====================================================================================
%%% A node has changed its global_groups definition, and is telling us that we are not
%%% included in his group any more. This could happen at release upgrade.
%%%====================================================================================
handle_info({disconnect_node, Node}, S) ->
%    io:format("~p>>>>> disconnect_node Node ~p CN ~p~n",[node(), Node, S#state.nodes]),
    case {S#state.sync_state, lists:member(Node, S#state.nodes)} of
	{synced, true} ->
	    send_monitor(S#state.monitor, {nodedown, Node}, S#state.sync_state);
	_ ->
	    cont
    end,
    global_name_server ! {nodedown, Node}, %% nodedown is used to inform global of the
                                           %% disconnected node
    NN = lists:delete(Node, S#state.nodes),
    NNC = lists:delete(Node, S#state.no_contact),
    NSE = lists:delete(Node, S#state.sync_error),
    {noreply, S#state{nodes = NN, no_contact = NNC, sync_error = NSE}};




handle_info({'EXIT', ExitPid, Reason}, S) ->
    check_exit(ExitPid, Reason),
    {noreply, S};


handle_info(Info, S) ->
%    io:format("***** handle_info = ~p~n",[Info]),
    {noreply, S}.



terminate(_Reason, S) ->
    ok.
    





%%%====================================================================================
%%% Check the global group configuration.
%%%====================================================================================
config_scan(NodeGrps) ->
    Sname = init:get_argument(sname),
    Lname = init:get_argument(name),
    MyNode = case {Sname, Lname} of
		 {{ok,[[MyNode1]]}, error} ->
		     list_to_atom(MyNode1);
		 {error, {ok,[[MyNode1]]}} ->
		     list_to_atom(MyNode1);
		 _ ->
		     node()
	     end,
    config_scan(node(), NodeGrps, no_name, [], []).

config_scan(MyNode, [], Own_name, OwnNodes, OtherNodeGrps) ->
    {Own_name, lists:sort(OwnNodes), lists:reverse(OtherNodeGrps)};
config_scan(MyNode, [{Name, Nodes}|NodeGrps], Own_name, OwnNodes, OtherNodeGrps) ->
    case lists:member(MyNode, Nodes) of
	true ->
	    case Own_name of
		no_name ->
		    config_scan(MyNode, NodeGrps, Name, Nodes, OtherNodeGrps);
		_ ->
		    {error, {'node defined twice', {Own_name, Name}}}
	    end;
	false ->
	    config_scan(MyNode, NodeGrps, Own_name, OwnNodes, [{Name, Nodes}|OtherNodeGrps])
    end.


    

    
%%%====================================================================================
%%% The special process which checks that all nodes in the own global group
%%% agrees on the configuration.
%%%====================================================================================
sync_init(Type, Cname, Nodes) ->
    {Up, Down} = sync_check_node(lists:delete(node(), Nodes), [], []),
    sync_check_init(Type, Up, Cname, Nodes, Down).

sync_check_node([], Up, Down) ->
    {Up, Down};
sync_check_node([Node|Nodes], Up, Down) ->
    case net_adm:ping(Node) of
	pang ->
	    sync_check_node(Nodes, Up, [Node|Down]);
	pong ->
	    sync_check_node(Nodes, [Node|Up], Down)
    end.



%%%-------------------------------------------------------------
%%% Check that all nodes are in agreement of the global
%%% group configuration.
%%%-------------------------------------------------------------
sync_check_init(Type, Up, Cname, Nodes, Down) ->
    sync_check_init(Type, Up, Cname, Nodes, 3, [], Down).

sync_check_init(Type, NoContact, Cname, Nodes, 0, ErrorNodes, Down) ->
    case ErrorNodes of
	[] -> 
	    gen_server:cast(global_group, {synced, lists:sort(NoContact ++ Down)});
	_ ->
	    gen_server:cast(global_group, {sync_error, lists:sort(NoContact ++ Down),
					   ErrorNodes})
    end,
    receive
	kill ->
	    exit(normal)
    after 5000 ->
	    exit(normal)
    end;

sync_check_init(Type, Up, Cname, Nodes, N, ErrorNodes, Down) ->
    lists:foreach(fun(Node) -> 
			  gen_server:cast({global_group, Node}, 
					  {conf_check, ?cc_vsn, node(), self(), Type, Cname, Nodes})  
		  end, Up),
    case sync_check(Up, Up) of
	{ok, synced} ->
	    sync_check_init(Type, [], Cname, Nodes, 0, ErrorNodes, Down);
	{error, NewErrorNodes} ->
	    sync_check_init(Type, [], Cname, Nodes, 0, ErrorNodes ++ NewErrorNodes, Down);
	{more, Rem, NewErrorNodes} ->
	    %% Try again to reach the global_group, 
	    %% obviously the node is up but not the global_group process.
	    sync_check_init(Type, Rem, Cname, Nodes, N-1, ErrorNodes ++ NewErrorNodes, Down)
    end.

sync_check(Up, Up) ->
    sync_check(Up, Up, []).

sync_check([], Up, []) ->
    {ok, synced};
sync_check([], Up, ErrorNodes) ->
    {error, ErrorNodes};
sync_check(Rem, Up, ErrorNodes) ->
    receive
	{config_ok, ?cc_vsn, Pid, Node} when Pid == self() ->
	    global_name_server ! {nodeup, Node},
	    sync_check(Rem -- [Node], Up, ErrorNodes);
	{config_error, ?cc_vsn, Pid, Node} when Pid == self() ->
	    sync_check(Rem -- [Node], Up, [Node | ErrorNodes]);
	{no_global_group_configuration, ?cc_vsn, Pid, Node} when Pid == self() ->
	    sync_check(Rem -- [Node], Up, [Node | ErrorNodes]);
	%% Ignore, illegal vsn or illegal Pid
	_ ->
	    sync_check(Rem, Up, ErrorNodes)
    after 2000 ->
	    %% Try again, the previous conf_check message  
	    %% apparently disapared in the magic black hole.
	    {more, Rem, ErrorNodes}
    end.


%%%====================================================================================
%%% A process wants to toggle monitoring nodeup/nodedown from nodes.
%%%====================================================================================
monitor_nodes(true, Pid, State) ->
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

delete_all(From, [From |Tail]) -> delete_all(From, Tail);
delete_all(From, [H|Tail]) ->  [H|delete_all(From, Tail)];
delete_all(_, []) -> [].

%% do unlink if we have no more references to Pid.
do_unlink(Pid, State) ->
    case lists:member(Pid, State#state.monitor) of
	true ->
	    false;
	_ ->
%	    io:format("unlink(Pid) ~p~n",[Pid]),
	    unlink(Pid)
    end.



%%%====================================================================================
%%% Send a nodeup/down messages to monitoring Pids in the own global group.
%%%====================================================================================
send_monitor([P|T], M, no_conf) -> safesend_nc(P, M), send_monitor(T, M, no_conf);
send_monitor([P|T], M, SyncState) -> safesend(P, M), send_monitor(T, M, SyncState);
send_monitor([], _, _) -> ok.

safesend(Name, {Msg, Node}) when atom(Name) ->
    case lists:member(Node, get_own_nodes()) of
	true ->
	    case whereis(Name) of 
		undefined ->
		    {Msg, Node};
		P when pid(P) ->
		    P ! {Msg, Node}
	    end;
	false ->
	    not_own_group
    end;
safesend(Pid, {Msg, Node}) -> 
    case lists:member(Node, get_own_nodes()) of
	true ->
	    Pid ! {Msg, Node};
	false ->
	    not_own_group
    end.

safesend_nc(Name, {Msg, Node}) when atom(Name) ->
    case whereis(Name) of 
	undefined ->
	    {Msg, Node};
	P when pid(P) ->
	    P ! {Msg, Node}
    end;
safesend_nc(Pid, {Msg, Node}) -> 
    Pid ! {Msg, Node}.






%%%====================================================================================
%%% Check which user is associated to the crashed process.
%%%====================================================================================
check_exit(ExitPid, Reason) ->
%    io:format("===EXIT===  ~p ~p ~n~p   ~n~p   ~n~p ~n~n",[ExitPid, Reason, get(registered_names), get(send), get(whereis_name)]),
    check_exit_reg(get(registered_names), ExitPid, Reason),
    check_exit_send(get(send), ExitPid, Reason),
    check_exit_where(get(whereis_name), ExitPid, Reason).


check_exit_reg(undefined, ExitPid, Reason) ->
    ok;
check_exit_reg(Reg, ExitPid, Reason) ->
    case lists:keysearch(ExitPid, 1, lists:delete(undefined, Reg)) of
	{value, {ExitPid, From}} ->
	    NewReg = lists:delete({ExitPid, From}, Reg),
	    put(registered_names, NewReg),
	    gen_server:reply(From, {error, Reason});
	false ->
	    not_found_ignored
    end.


check_exit_send(undefined, ExitPid, Reason) ->
    ok;
check_exit_send(Send, ExitPid, Reason) ->
    case lists:keysearch(ExitPid, 1, lists:delete(undefined, Send)) of
	{value, {ExitPid, From, Name, Msg}} ->
	    NewSend = lists:delete({ExitPid, From, Name, Msg}, Send),
	    put(send, NewSend),
	    gen_server:reply(From, {badarg, {Name, Msg}});
	false ->
	    not_found_ignored
    end.


check_exit_where(undefined, ExitPid, Reason) ->
    ok;
check_exit_where(Where, ExitPid, Reason) ->
    case lists:keysearch(ExitPid, 1, lists:delete(undefined, Where)) of
	{value, {ExitPid, From}} ->
	    NewWhere = lists:delete({ExitPid, From}, Where),
	    put(whereis_name, NewWhere),
	    gen_server:reply(From, {error, Reason});
	false ->
	    not_found_ignored
    end.



%%%====================================================================================
%%% Kill any possible global_group_check processes
%%%====================================================================================
kill_global_group_check() ->
    case whereis(global_group_check) of
	undefined ->
	    ok;
	Pid ->
	    unlink(Pid),
	    global_group_check ! kill,
	    unregister(global_group_check)
    end.


%%%====================================================================================
%%% Disconnect nodes not belonging to own global_groups
%%%====================================================================================
disconnect_nodes(DisconnectNodes) ->
    lists:foreach(fun(Node) ->
			  {global_group, Node} ! {disconnect_node, node()},
			  global:node_disconnected(Node)
		  end,
		  DisconnectNodes).


%%%====================================================================================
%%% Disconnect nodes not belonging to own global_groups
%%%====================================================================================
force_nodedown(DisconnectNodes) ->
    lists:foreach(fun(Node) ->
			  erlang:disconnect_node(Node),
			  global:node_disconnected(Node)
		  end,
		  DisconnectNodes).


%%%====================================================================================
%%% Get the current global_groups definition
%%%====================================================================================
get_own_nodes() ->
    case application:get_env(kernel, global_groups) of
	undefined ->
	    [];
	{ok, []} ->
	    [];
	{ok, NodeGrps} ->
	    case catch config_scan(NodeGrps) of
		{error, Error2} ->
		    [];
		{Group_NameDef, NodesDef, OtherDef} ->
		    lists:sort(NodesDef)
	    end
    end.
