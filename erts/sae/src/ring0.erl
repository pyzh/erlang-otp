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
-module(ring0).

%% Purpose : Start up of erlang system.

-export([start/2]).

start(Env, Argv0) ->
    {Ms,{M,F}} = binary_to_term(Env),
    Loaded = load(Ms, []),
    Argv = [binary_to_list(B) || B <- Argv0],
    run(M,F,Argv).

run(M, F, A) ->
    case erlang:function_exported(M, F, 1) of
	false ->
	    erlang:display({fatal,error,module,M,'does not export',F,'/1'}),
	    halt(1);
	true ->
	    apply(M, F, [A])
    end.

load([{Mod,Code}|T], Loaded) ->
    case erlang:load_module(Mod, Code) of
	{module,Mod} ->
	    load(T, [Mod|Loaded]);
	Other ->
	    erlang:display({bad_module,Mod}),
	    erlang:halt(-1)
    end;
load([], L) -> L.
