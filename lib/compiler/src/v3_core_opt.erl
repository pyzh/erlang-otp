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
%% Purpose : Main Core optimisation file.

%% We run the optimiations in a very simple manor by just listing
%% them.  They should probably return if they have done anything and
%% we then run them until we reach a fixed point.  Constant folding
%% should probably be done often.

-module(v3_core_opt).


-export([module/2]).

-import(lists, [foldl/3]).

module(Mod0, Options) ->
    %% List optimisations to done.
    Opts = [%% fun(M, Opts) -> sys_core_inline:module(M, Opts) end,
	    %% fun(M, Opts) -> sys_core_fold:module(M, Opts) end,
	    %% fun(M, Opts) -> sys_core_case:module(M, Opts) end,
	    fun(M, Opts) -> sys_core_fold:module(M, Opts) end],
    Mod1 = fold_opt(Opts, Mod0, Options),
    {ok,Mod1}.

fold_opt(Os, Mod, Options) ->
    foldl(fun (O, M0) ->
		  {ok,M1} = O(M0, Options),
		  M1
	  end, Mod, Os).
