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
-module(release_handler_1).

%% External exports
-export([eval_script/3, eval_script/4, check_script/2]).
-export([get_vsn/1]). %% exported because used in a test case

-record(eval_state, {bins = [], stopped = [], suspended = [], apps = [],
		     libdirs, unpurged = [], vsns = [], newlibs = [],
		     opts = []}).
%%-----------------------------------------------------------------
%% bins      = [{Mod, Binary, FileName}]
%% stopped   = [{Mod, [pid()]}] - list of stopped pids for each module
%% suspended = [{Mod, [pid()]}] - list of suspended pids for each module
%% apps      = [app_spec()] - list of all apps in the new release
%% libdirs   = [{Lib, LibVsn, LibDir}] - Maps Lib to Vsn and Directory
%% unpurged  = [{Mod, soft_purge | brutal_purge}]
%% vsns      = [{Mod, OldVsn, NewVsn}] - remember the old vsn of a mod
%%                  before it is removed/a new vsn is loaded; the new vsn
%%                  is kept in case of a downgrade, where the code_change
%%                  function receives the vsn of the module to downgrade
%%                  *to*.
%% newlibs   = [{Lib, Dir}] - list of all new libs; used to change
%%                            the code path
%% opts      = [{Tag, Value}] - list of options
%%-----------------------------------------------------------------


%%%-----------------------------------------------------------------
%%% This is a low-level release handler.
%%%-----------------------------------------------------------------
check_script(Script, LibDirs) ->
    case catch check_old_processes(Script) of
	ok ->
	    {Before, After} = split_instructions(Script),
	    case catch lists:foldl(fun(Instruction, EvalState1) ->
					   eval(Instruction, EvalState1)
				   end,
				   #eval_state{libdirs = LibDirs},
				   Before) of
		EvalState2 when record(EvalState2, eval_state) -> ok;
		{error, Error} -> {error, Error};
		Other -> {error, Other}
	    end;
	{error, Mod} ->
	    {error, {old_processes, Mod}}
    end.

eval_script(Script, Apps, LibDirs) ->
    eval_script(Script, Apps, LibDirs, []).

eval_script(Script, Apps, LibDirs, Opts) ->
    case catch check_old_processes(Script) of
	ok ->
	    {Before, After} = split_instructions(Script),
	    case catch lists:foldl(fun(Instruction, EvalState1) ->
					   eval(Instruction, EvalState1)
				   end,
				   #eval_state{apps = Apps, 
					       libdirs = LibDirs,
					       opts = Opts},
				   Before) of
		EvalState2 when record(EvalState2, eval_state) ->
		    case catch lists:foldl(fun(Instruction, EvalState3) ->
						   eval(Instruction, EvalState3)
					   end,
					   EvalState2,
					   After) of
			EvalState4 when record(EvalState4, eval_state) ->
			    {ok, EvalState4#eval_state.unpurged};
			restart_new_emulator ->
			    restart_new_emulator;
			Error ->
			    {'EXIT', Error}
		    end;
		{error, Error} -> {error, Error};
		Other -> {error, Other}
	    end;
	{error, Mod} ->
	    {error, {old_processes, Mod}}
    end.

%%%-----------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------
split_instructions(Script) ->
    split_instructions(Script, []).
split_instructions([point_of_no_return | T], Before) ->
    {Before, [point_of_no_return | T]};
split_instructions([H | T], Before) ->
    split_instructions(T, [H | Before]);
split_instructions([], Before) ->
    {[], Before}.

%%-----------------------------------------------------------------
%% Func: check_old_processes/1
%% Args: Script = [instruction()]
%% Purpose: Check if there is any process that runs an old version
%%          of a module that should be soft_purged, (i.e. not purged
%%          at all if there is any such process).  Returns {error, Mod}
%%          if so, ok otherwise.
%% Returns: ok | {error, Mod}
%%          Mod = atom()  
%%-----------------------------------------------------------------
check_old_processes(Script) ->
    lists:foreach(fun({load, {Mod, soft_purge, _PostPurgeMethod}}) ->
			  check_old_code(Mod);
		     ({remove, {Mod, soft_purge, _PostPurgeMethod}}) ->
			  check_old_code(Mod);
		     (_) -> ok
		  end,
		  Script).

check_old_code(Mod) ->
    lists:foreach(fun(Pid) ->
			  case erlang:check_process_code(Pid, Mod) of
			      false -> ok;
			      true -> throw({error, Mod})
			  end
		  end,
		  erlang:processes()).

%%-----------------------------------------------------------------
%% An unpurged module is a module for which there exist an old
%% version of the code.  This should only be the case if there are
%% processes running the old version of the code.
%%
%% This functions evaluates each instruction.  Note that the
%% instructions here are low-level instructions.  e.g. lelle's
%% old synchronized_change would be translated to
%%   {load_object_code, Modules},
%%   {suspend, Modules}, [{load, Module}],
%%   {resume, Modules}, {purge, Modules}
%% Or, for example, if we want to do advanced external code change 
%% on two modules that depend on each other, by killing them and
%% then restaring them, we could do:
%%   {load_object_code, [Mod1, Mod2]},
%%   % delete old version
%%   {remove, {Mod1, brutal_purge}}, {remove, {Mod2, brutal_purge}},
%%   % now, some procs migth be running prev current (now old) version
%%   % kill them, and load new version
%%   {load, {Mod1, brutal_purge}}, {load, {Mod2, brutal_purge}}
%%   % now, there is one version of the code (new, current)
%%
%% NOTE: All load_object_code must be first in the script,
%%       a point_of_no_return must be present (if load_object_code
%%       is present).
%%
%% {load_object_code, {Lib, LibVsn, [Mod]} 
%%    read the files as binarys. do not make code out of them
%% {load, {Module, PrePurgeMethod, PostPurgeMethod}}
%%    Module must have been load_object_code:ed.  make code out of it
%%    old procs && soft_purge => no new release
%%    old procs && brutal_purge => old procs killed
%%    The new old code will be gc:ed later on, if PostPurgeMethod =
%%    soft_purge.  If it is brutal_purge, the code is purged when
%%    the release is made permanent.
%% {remove, {Module, PrePurgeMethod, PostPurgeMethod}}
%%    make current version old.  no current left.
%%    old procs && soft_purge => no new release
%%    old procs && brutal_purge => old procs killed
%%    The new old code will be gc:ed later on, if PostPurgeMethod =
%%    soft_purge.  If it is brutal_purge, the code is purged when
%%    the release is made permanent.
%% {purge, Modules}
%%    kill all procs running old code, delete old code
%% {suspend, [Module | {Module, Timeout}]}
%%    If a process doesn't repsond - never mind.  It will be killed
%%    later on (if a purge is performed).
%%    Hmm, we must do something smart here... we should probably kill it,
%%    but we cant, because its supervisor will restart it directly!  Maybe
%%    we should keep a list of those, call supervisor:terminate_child()
%%    when all others are suspended, and call sup:restart_child() when the
%%    others are resumed.
%% {code_change, [{Module, Extra}]}
%% {code_change, Mode, [{Module, Extra}]}  Mode = up | down
%%    Send code_change only to suspended procs running this code
%% {resume, [Module]}
%%    resume all previously suspended processes
%% {stop, [Module]}
%%    stop all procs running this code
%% {start, [Module]}
%%    starts the procs that were previously stopped for this code.
%%    Note that this will start processes in exactly the same place
%%    in the suptree where there were procs previously.
%% {sync_nodes, Id, [Node]}
%% {sync_nodes, Id, {M, F, A}}
%%    Synchronizes with the Nodes (or apply(M,F,A) == Nodes).  All Nodes
%%    must also exectue the same line.  Waits for all these nodes to get
%%    to this line.
%% point_of_no_return
%% restart_new_emulator
%% {stop_application, Appl}     - Impl with apply
%% {unload_application, Appl}   - Impl with {remove..}
%% {load_application, Appl}     - Impl with {load..}
%% {start_application, Appl}    - Impl with apply
%%-----------------------------------------------------------------
eval({load_object_code, {Lib, LibVsn, Modules}}, EvalState) ->
    case lists:keysearch(Lib, 1, EvalState#eval_state.libdirs) of
	{value, {Lib, LibVsn, LibDir}} ->
	    Ebin = filename:join(LibDir, "ebin"),
	    Ext = code:objfile_extension(),
	    ModVsns = get_mod_vsns(Lib, EvalState#eval_state.apps),
	    {NewBins, NewVsns} = 
		lists:foldl(fun(Mod, {Bins, Vsns}) ->
				    File = lists:concat([Mod, Ext]),
				    FName = filename:join(Ebin, File),
				    NVsns = add_new_vsn(Mod, ModVsns, Vsns),
				    case erl_prim_loader:get_file(FName) of
					{ok, Bin, FName2} ->
					    {[{Mod, Bin, FName2} | Bins],NVsns};
					error ->
					    throw({error, {no_such_file,FName}})
				    end
			    end,
			    {EvalState#eval_state.bins,
			     EvalState#eval_state.vsns},
			    Modules),
	    NewLibs = [{Lib, Ebin} | EvalState#eval_state.newlibs],
	    EvalState#eval_state{bins = NewBins,
				 newlibs = NewLibs,
				 vsns = NewVsns};
	{value, {Lib, LibVsn2, _LibDir}} ->
	    throw({error, {bad_lib_vsn, Lib, LibVsn2}})
    end;
eval(point_of_no_return, EvalState) ->
    lists:foreach(fun({Lib, Path}) -> code:replace_path(Lib, Path) end,
		  EvalState#eval_state.newlibs),
    EvalState;
eval({load, {Mod, _PrePurgeMethod, PostPurgeMethod}}, EvalState) ->
    Bins = EvalState#eval_state.bins,
    {value, {_Mod, Bin, File}} = lists:keysearch(Mod, 1, Bins),
    % load_binary kills all procs running old code
    % if soft_purge, we know that there are no such procs now
    Vsns = EvalState#eval_state.vsns,
    NewVsns = add_old_vsn(Mod, Vsns),
    code:load_binary(Mod, File, Bin),
    % Now, the prev current is old.  There might be procs
    % running it.  Find them.
    Unpurged = do_soft_purge(Mod,PostPurgeMethod,EvalState#eval_state.unpurged),
    EvalState#eval_state{bins = lists:keydelete(Mod, 1, Bins),
			 unpurged = Unpurged,
			 vsns = NewVsns};
eval({remove, {Mod, _PrePurgeMethod, PostPurgeMethod}}, EvalState) ->
    % purge kills all procs running old code
    % if soft_purge, we know that there are no such procs now
    Vsns = EvalState#eval_state.vsns,
    NewVsns = add_old_vsn(Mod, Vsns),
    code:purge(Mod),
    code:delete(Mod),
    % Now, the prev current is old.  There might be procs
    % running it.  Find them.
    Unpurged =
	case code:soft_purge(Mod) of
	    true -> EvalState#eval_state.unpurged;
	    false -> [{Mod, PostPurgeMethod} | EvalState#eval_state.unpurged]
	end,
    Bins = EvalState#eval_state.bins,
    EvalState#eval_state{bins = lists:keydelete(Mod, 1, Bins),
			 unpurged = Unpurged,
			 vsns = NewVsns};
eval({application_remove, Appl}, EvalState) ->
    case application:get_key(Appl, modules) of
	{ok, ModsT} ->
	    Mods = remove_vsn(ModsT),
	    lists:foreach(fun(Mod) -> code:purge(Mod) end, Mods),
	    lists:foreach(fun(Mod) -> code:delete(Mod) end, Mods);
	_ ->
	    ok
    end,
    EvalState;
eval({purge, Modules}, EvalState) ->
    % Now, if there are any processes still executing old code, OR
    % if some new processes started after suspend but before load,
    % these are killed.
    lists:foreach(fun(Mod) -> code:purge(Mod) end, Modules),
    EvalState;
eval({suspend, Modules}, EvalState) ->
    Procs = get_supervised_procs(),
    NewSuspended =
	lists:foldl(fun(ModSpec, Suspended) ->
			    {Module, Def} = case ModSpec of 
						{Mod, ModTimeout} ->
						    ModSpec;
						Mod ->
						    {Mod, default}
					    end,
			    Timeout = get_opt(suspend_timeout, EvalState, Def),
			    Pids = suspend(Module, Procs, Timeout),
			    [{Module, Pids} | Suspended]
		    end,
		    EvalState#eval_state.suspended,
		    Modules),
    EvalState#eval_state{suspended = NewSuspended};
eval({resume, Modules}, EvalState) ->
    NewSuspended =
	lists:foldl(fun(Mod, Suspended) ->
			    lists:filter(fun({Mod2, Pids}) when Mod2 == Mod ->
						 resume(Pids),
						 false;
					    (_) ->
						 true
					 end,
					 Suspended)
		    end,
		    EvalState#eval_state.suspended,
		    Modules),
    EvalState#eval_state{suspended = NewSuspended};
eval({code_change, Modules}, EvalState) ->
    eval({code_change, up, Modules}, EvalState);
eval({code_change, Mode, Modules}, EvalState) ->
    Suspended = EvalState#eval_state.suspended,
    Vsns = EvalState#eval_state.vsns,
    Timeout = get_opt(code_change_timeout, EvalState, default),
    lists:foreach(fun({Mod, Extra}) ->
			  Vsn =
			      case lists:keysearch(Mod, 1, Vsns) of
				  {value, {Mod, OldVsn, NewVsn}}
				    when Mode == up -> OldVsn;
				  {value, {Mod, OldVsn, NewVsn}}
				    when Mode == down -> {down, NewVsn};
				  _ when Mode == up -> undefined;
				  _ -> {down, undefined}
			      end,
			  case lists:keysearch(Mod, 1, Suspended) of
			      {value, {_Mod, Pids}} ->
				  change_code(Pids, Mod, Vsn, Extra, Timeout);
			      _ -> ok
			  end
		  end,
		  Modules),
    EvalState;
eval({stop, Modules}, EvalState) ->
    Procs = get_supervised_procs(),
    NewStopped =
	lists:foldl(fun(Mod, Stopped) ->
			    Procs2 = stop(Mod, Procs),
			    [{Mod, Procs2} | Stopped]
		    end,
		    EvalState#eval_state.stopped,
		    Modules),
    EvalState#eval_state{stopped = NewStopped};
eval({start, Modules}, EvalState) ->
    NewStopped =
	lists:foldl(fun(Mod, Stopped) ->
			    lists:filter(fun({Mod2, Procs}) when Mod2 == Mod ->
						 start(Procs),
						 false;
					    (_) ->
						 true
					 end,
					 Stopped)
		    end,
		    EvalState#eval_state.stopped,
		    Modules),
    EvalState#eval_state{stopped = NewStopped};
eval({sync_nodes, Id, {M, F, A}}, EvalState) ->
    sync_nodes(Id, apply(M, F, A)),
    EvalState;
eval({sync_nodes, Id, Nodes}, EvalState) ->
    sync_nodes(Id, Nodes),
    EvalState;
eval({apply, {M, F, A}}, EvalState) ->
    apply(M, F, A),
    EvalState;
eval(restart_new_emulator, EvalState) ->
    throw(restart_new_emulator).

get_opt(Tag, EvalState, Default) ->
    case lists:keysearch(Tag, 1, EvalState#eval_state.opts) of
	{value,  {_Tag, Value}} -> Value;
	false                   -> Default
    end.

%%-----------------------------------------------------------------
%% This is a first approximation.  Unfortunately, we might end up
%% with the situation that after this suspendation, some new
%% processes start *before* we have loaded the new code, and these
%% will execute the old code.  These processes could be terminated
%% later on (if the prev current version is purged).  The same
%% goes for processes that didn't respond to the suspend message.
%%-----------------------------------------------------------------
suspend(Mod, Procs, Timeout) ->
    lists:zf(fun({_Sup, _Name, Pid, Mods}) -> 
		     case lists:member(Mod, Mods) of
			 true ->
			     case catch sys_suspend(Pid, Timeout) of
				 ok -> {true, Pid};
				 _ -> 
				     % If the proc hangs, make sure to
				     % resume it when it gets suspended!
				     catch sys:resume(Pid),
				     false
			     end;
			 false ->
			     false
		     end
	     end,
	     Procs).

sys_suspend(Pid, default) ->
    sys:suspend(Pid);
sys_suspend(Pid, Timeout) ->
    sys:suspend(Pid, Timeout).

resume(Pids) ->
    lists:foreach(fun(Pid) -> catch sys:resume(Pid) end, Pids).

change_code(Pids, Mod, Vsn, Extra, Timeout) ->
    Fun = fun(Pid) -> 
		  case Timeout of
		      default ->
			  ok = sys:change_code(Pid, Mod, Vsn, Extra);
		      _Else ->
			  ok = sys:change_code(Pid, Mod, Vsn, Extra, Timeout)
		  end
	  end,
    lists:foreach(Fun, Pids).

stop(Mod, Procs) ->
    lists:zf(fun({undefined, _Name, _Pid, _Mods}) ->
		     false;
		({Sup, Name, Pid, Mods}) -> 
		     case lists:member(Mod, Mods) of
			 true ->
			     case catch supervisor:terminate_child(
					  Sup, Name) of
				 ok -> {true, {Sup, Name}};
				 _ -> false
			     end;
			 false -> false
		     end
	     end,
	     Procs).

start(Procs) ->
    lists:foreach(fun({Sup, Name}) -> 
			  catch supervisor:restart_child(Sup, Name)
		  end,
		  Procs).

%%-----------------------------------------------------------------
%% Func: get_supervised_procs/0
%% Purpose: This is the magic function.  It finds all process in
%%          the system and which modules they execute as a call_back or
%%          process module.
%%          This is achieved by asking the main supervisor for the
%%          applications for all children and their modules
%%          (recursively).
%% NOTE: If a supervisor is suspended, it isn't possible to call
%%       which_children.  Code change on a supervisor should be
%%       done in another way; the only code in a supervisor is
%%       code for starting children.  Therefore, to change a
%%       supervisor module, we should load the new version, and then
%%       delete the old.  Then we should perform the start changes
%%       manually, by adding/deleting children.
%% Returns: [{SuperPid, ChildName, ChildPid, Mods}]
%%-----------------------------------------------------------------
get_supervised_procs() ->
    lists:foldl(
      fun(Application, Procs) ->
	      case application_controller:get_master(Application) of
		  Pid when pid(Pid) ->
		      {Root, Mod} = application_master:get_child(Pid),
		      get_procs(supervisor:which_children(Root), Root) ++
			  [{undefined, undefined, Root, [Mod]} | Procs];
		  _ -> Procs
	      end
      end,
      [],
      lists:map(fun({Application, _Name, _Vsn}) ->
			Application
		end,
		application:which_applications())).

get_procs([{Name, Pid, worker, dynamic} | T], Sup) when pid(Pid) ->
    Mods = get_dynamic_mods(Name),
    [{Sup, Name, Pid, Mods} | get_procs(T, Sup)];
get_procs([{Name, Pid, worker, Mods} | T], Sup) when pid(Pid), list(Mods) ->
    [{Sup, Name, Pid, Mods} | get_procs(T, Sup)];
get_procs([{Name, Pid, supervisor, Mods} | T], Sup) when pid(Pid) ->
    [{Sup, Name, Pid, Mods} | get_procs(T, Sup)] ++ 
	get_procs(supervisor:which_children(Pid), Pid);
get_procs([_H | T], Sup) ->
    get_procs(T, Sup);
get_procs(_, _Sup) ->
    [].

get_dynamic_mods(Pid) ->
    {ok,Res} = gen:call(Pid, self(), get_modules),
    Res.

%%-----------------------------------------------------------------
%% Func: do_soft_purge/3
%% Args: Mod = atom()
%%       PostPurgeMethod = soft_purge | brutal_purge
%%       Unpurged = [{Mod, PostPurgeMethod}]
%% Purpose: Check if there are any processes left running this code.
%%          If so, make sure Mod is a member in the returned list.
%%          Otherwise, make sure Mod isn't a member in the returned
%%          list.
%% Returns: An updated list of unpurged modules.
%%-----------------------------------------------------------------
do_soft_purge(Mod, PostPurgeMethod, Unpurged) ->
    IsNoOldProcsLeft = code:soft_purge(Mod),
    case lists:keymember(Mod, 1, Unpurged) of
	true when IsNoOldProcsLeft == true -> lists:keydelete(Mod, 1, Unpurged);
	true -> Unpurged;
	false when IsNoOldProcsLeft == true -> Unpurged;
	false -> [{Mod, PostPurgeMethod} | Unpurged]
    end.

%%-----------------------------------------------------------------
%% Func: sync_nodes/2
%% Args: Id = term()
%%       Nodes = [atom()]
%% Purpose: Synchronizes with all nodes.
%%-----------------------------------------------------------------
sync_nodes(Id, Nodes) ->
    NNodes = lists:delete(node(), Nodes),
    lists:foreach(fun(Node) ->
			  {release_handler, Node} ! {sync_nodes, Id, node()}
		  end,
		  NNodes),
    lists:foreach(fun(Node) ->
			  receive
			      {sync_nodes, Id, Node} ->
				  ok;
			      {nodedown, Node} ->
				  throw({sync_error, {nodedown, Node}})
			  end
		  end,
		  NNodes).

add_old_vsn(Mod, Vsns) ->
    case lists:keysearch(Mod, 1, Vsns) of
	{value, {Mod, undefined, NewVsn}} ->
	    OldVsn = get_vsn(Mod),
	    lists:keyreplace(Mod, 1, Vsns, {Mod, OldVsn, NewVsn});
	{value, {Mod, OldVsn, NewVsn}} ->
	    Vsns;
	false ->
	    OldVsn = get_vsn(Mod),
	    [{Mod, OldVsn, undefined} | Vsns]
    end.

add_new_vsn(Mod, ModVsns, Vsns) ->
    case lists:keysearch(Mod, 1, Vsns) of
	{value, {Mod, OldVsn, _}} ->
	    NewVsn = get_new_vsn(Mod, ModVsns),
	    lists:keyreplace(Mod, 1, Vsns, {Mod, OldVsn, NewVsn});
	false ->
	    NewVsn = get_new_vsn(Mod, ModVsns),
	    [{Mod, undefined, NewVsn} | Vsns]
    end.

get_new_vsn(Mod, [{Mod, Vsn} | _]) ->
    Vsn;
get_new_vsn(Mod, [H | T]) ->
    get_new_vsn(Mod, T);
get_new_vsn(Mod, []) ->
    undefined.

get_mod_vsns(Lib, Apps) ->
    case lists:keysearch(Lib, 2, Apps) of
	{value, {application, _Lib, Attributes}} ->
	    case lists:keysearch(modules, 1, Attributes) of
		{value, {modules, Modules}} ->
		    Modules;
		false ->
		    []
	    end;
	_ ->
	    []
    end.



%%-----------------------------------------------------------------
%% Func: get_vsn/1
%% Args: Mod = atom()
%% Purpose: Finds the version attribute of the current version of
%%          the module.
%% Returns: Vsn | undefined
%%          Vsn = term()
%%-----------------------------------------------------------------
get_vsn(Mod) ->
    case code:is_loaded(Mod) of
	{file, _} ->
	    case lists:keysearch(attributes, 1, Mod:module_info()) of
		{value, {attributes, Attributes}} ->
		    case lists:keysearch(vsn, 1, Attributes) of
			{value, {vsn, Vsn}} -> 
			    %% OTP-2740.  
			    %% If vsn is a string module_info returns: "the string", but if
			    %% vsn is something else it returns: [atom | tuple | numeric | list ...]
			    case catch [V] = Vsn of
				{'EXIT', {{badmatch, _}, _}} -> Vsn;
				_ -> 
				    [Vsn2] = Vsn,
				    Vsn2
			    end;
			_ -> undefined
		    end;
		_ -> undefined
	    end;
	false ->
	    undefined
    end.


remove_vsn(Mods) ->
    remove_vsn(Mods, []).
remove_vsn([], Res) ->
    Res;
remove_vsn([H|Mods], Res) ->
    case H of
	{Mod, Vsn} ->
	    remove_vsn(Mods, [Mod | Res]);
	Mod ->
	    remove_vsn(Mods, [Mod | Res])
    end.





