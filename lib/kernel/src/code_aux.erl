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
-module(code_aux).

%%-compile(export_all).
-export([
	 to_atom/1,
	 to_list/1,
	 objfile_extension/0,
	 sticky/2,
	 do_purge/1]).



objfile_extension() ->
    case erlang:info(machine) of
	"JAM" -> ".jam";
	"VEE" -> ".vee";
	"BEAM" -> ".beam"
    end.


to_list(X) when list(X) -> X;
to_list(X) when atom(X) -> atom_to_list(X).


to_atom(X) when atom(X) -> X;
to_atom(X) when list(X) -> list_to_atom(X).



%% The idea here is that we shall sucseed in loading 
%% a lib module the first time and then never be able reload it !!!!!
sticky(Mod, Db) ->
    case erlang:module_loaded(Mod) of
	true ->
	    case ets:lookup(Db, {sticky, Mod}) of
		[] -> false;
		_  -> true
	    end;
	_ -> false
    end.




%% do_purge(Module)
%%  Kill all processes running code from *old* Module, and then purge the
%%  module. Return true if any processes killed, else false.

do_purge(Mod) ->
    M = code_aux:to_atom(Mod),
    do_purge(processes(), M, false).

do_purge([P|Ps], Mod, Purged) ->
    case erlang:check_process_code(P, Mod) of
	true ->
	    exit(P, kill),
	    do_purge(Ps, Mod, true);
	false ->
	    do_purge(Ps, Mod, Purged)
    end;
do_purge([], Mod, Purged) ->
    catch erlang:purge_module(Mod),
    Purged.
