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
-module(code_server).

%% This file holds the server part of the code_server.

-behaviour(gen_server).


%% gen_server callback exports

-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2]).



-include_lib("kernel/include/file.hrl").

-record(state,{root,
	       path,
	       moddb,
	       namedb,
	       ints=[],				%Interpreted modules
	       mode=interactive}).


%% -----------------------------------------------------------
%% Init the code_server process.
%% -----------------------------------------------------------

init([Root, Mode]) ->
    process_flag(trap_exit, true),
    IPath = case Mode of
		interactive ->
		    LibDir = filename:append(Root, "lib"),
		    {ok,Dirs} = file:list_dir(LibDir),
		    {Paths, Libs} = make_path(LibDir,Dirs),
		    ["."|Paths];
		_ ->
		    []
	    end,

    Path = add_loader_path(IPath,Mode),
    {ok,#state{root = Root,
	       path = Path,
	       moddb = init_db(),
	       namedb = init_namedb(Path),
	       mode = Mode}}.



%%
%% The gen_server call back functions.
%%
%handle_call(Req,{From,Tag},S) ->
%   case Req of

handle_call({stick_dir,Dir}, {From, Tag}, S) ->
    case file:list_dir(Dir) of
	{ok,Listing} ->
	    stick_library(Listing, S#state.moddb),
	    {reply,ok,S};
	Other ->
	    {reply,Other,S}
    end;

handle_call({unstick_dir,Dir}, {From,Tag}, S) ->
    case file:list_dir(Dir) of
	{ok,Listing} ->
	    unstick_library(Listing, S#state.moddb),
	    {reply,ok,S};
	Other ->
	    {reply,Other,S}
    end;

handle_call({dir,Dir},{From,Tag}, S) ->
    Root = S#state.root,
    Resp = do_dir(Root,Dir,S#state.namedb),
    {reply,Resp,S};


handle_call({load_file,Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,{error, badarg},S};
	_ ->
	    Path = S#state.path,
	    Int = S#state.ints,
	    Status = load_file(Mod, Path, S#state.moddb),
	    NewS = S#state{ints =
			   code_server_int:del_interpret(Status,Int)},
	    {reply,Status,NewS}
    end;


handle_call({add_path,Where,Dir},{From,Tag}, S) ->
    {Resp,Path} = add_path(Where,Dir,S#state.path,S#state.namedb),
    {reply,Resp,S#state{path = Path}};

handle_call({add_paths,Where,Dirs},{From,Tag}, S) ->
    {Resp,Path} = add_paths(Where,Dirs,S#state.path,S#state.namedb),
    {reply,Resp,S#state{path = Path}};

handle_call({set_path,PathList},{From,Tag}, S) ->
    Path = S#state.path,
    {Resp, NewPath,NewDb} = set_path(PathList, Path, S#state.namedb),
    {reply,Resp,S#state{path = NewPath, namedb=NewDb}};

handle_call({del_path,Name},{From,Tag}, S) ->
    {Resp,Path} = del_path(Name,S#state.path,S#state.namedb),
    {reply,Resp,S#state{path = Path}};

handle_call({replace_path,Name,Dir},{From,Tag}, S) ->
    {Resp,Path} = replace_path(Name,Dir,S#state.path,S#state.namedb),
    {reply,Resp,S#state{path = Path}};


handle_call(get_path,{From,Tag}, S) ->
    {reply,S#state.path,S};

%% Messages to load, delete and purge modules/files.
handle_call({load_abs,File},{From,Tag}, S) ->
    case modp(File) of
	false ->
	    {reply,{error,badarg},S};
	_ ->
	    Status = load_abs(File, S#state.moddb),
	    Int = S#state.ints,
	    NewS = S#state{ints =
			   code_server_int:del_interpret(Status,Int)},
	    {reply,Status,NewS}
    end;

handle_call({load_binary,Mod,File,Bin},{From,Tag}, S) ->
    Status = do_load_binary(Mod,File,Bin,S#state.moddb),
    Int = S#state.ints,
    NewS = S#state{ints = code_server_int:del_interpret(Status,Int)},
    {reply,Status,NewS};

handle_call({ensure_loaded,Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,{error,badarg},S};
	_ ->
	    case erlang:module_loaded(code_aux:to_atom(Mod)) of
		true ->
		    %% Should we check code_server's
		    %% internal database here?
		    {reply,{module,Mod},S};
		false ->
		    {reply,do_ensure(Mod,S),S}
	    end
    end;

handle_call({delete,Mod},{From,Tag}, S) ->
    {reply,do_delete(Mod,S),S};


handle_call({purge,Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,false,S};
	_ ->
	    {reply,code_aux:do_purge(Mod),S}
    end;

handle_call({soft_purge,Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,true,S};
	_ ->
	    {reply,do_soft_purge(Mod),S}
    end;

handle_call({is_loaded,Module},{From,Tag}, S) ->
    case modp(Module) of
	false ->
	    {reply,false,S};
	_ ->
	    %% compare ensure_loaded! (here we only check
	    %% internal struct)
	    Where = is_loaded(Module, S#state.moddb, S#state.ints),
	    {reply,Where,S}
    end;

handle_call(all_loaded,{From,Tag}, S) ->
    Db = S#state.moddb,
    Int = S#state.ints,
    {reply,all_loaded(Db,Int),S};

handle_call({rel_loaded_p,Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,false,S};
	_ ->
	    Db = S#state.moddb,
	    {reply,rel_loaded_p(Mod,Db),S}
    end;


%% Messages to handle interpretation of modules
handle_call({interpret,Module},{From,Tag}, S) ->
    Int = S#state.ints,
    {Status,Int1} =
	code_server_int:add_interpret(Module,Int,S#state.moddb),
    {reply,Status,S#state{ints = Int1}};

handle_call({interpreted,Module},{From,Tag}, S) ->
    case modp(Module) of
	false ->
	    {reply,false,S};
	_ ->
	    Int = S#state.ints,
	    {reply,lists:member(code_aux:to_atom(Module), Int),S}
    end;

handle_call({interpreted},{From,Tag}, S) ->
    {reply,S#state.ints,S};

handle_call({interpret_binary,Mod,File,Bin},{From,Tag}, S) ->
    {Status,Int1} =
	code_server_int:add_interpret(Mod,S#state.ints,S#state.moddb),
    NewS = S#state{ints = Int1},
    case Status of
	{error,_} ->
	    {reply,Status,NewS};
	_ ->
	    case modp(File) of
		true when binary(Bin) ->
		    %% The interpreter server acknowledges
		    %% the request.
		    case code_server_int:load_interpret({From,Tag},File,Mod,Bin) of
			ok ->
			    {noreply, NewS};
			Error ->
			    {reply,Error,S}
		    end;
		_ ->
		    {reply,{error,badarg},S}
	    end
    end;

handle_call({delete_int,Module},{From,Tag}, S) ->
    case modp(Module) of
	false ->
	    {reply,{error,badarg},S};
	_ ->
	    Int1 =
		code_server_int:delete_interpret(Module,S#state.ints),
	    {reply,ok,S#state{ints = Int1}}
    end;

handle_call({get_object_code, Mod},{From,Tag}, S) ->
    case modp(Mod) of
	false ->
	    {reply,error,S};
	_ ->
	    Path = S#state.path,
	    case mod_to_bin(Path, Mod) of
		{Mod, Bin, FName} ->
		    Rep = {Mod,Bin,filename:absname(FName)},
		    {reply,Rep,S};
		Error ->
		    {reply,Error,S}
	    end
    end;

handle_call(stop,{From,Tag}, S) ->
    {stop,normal,stopped,S};

handle_call(Other,{From,Tag}, S) ->			
    error_logger:error_msg(" ** Codeserver*** ignoring ~w~n ",[Other]),
    {noreply,S}.




handle_cast(_,S) ->
    {noreply,S}.

handle_info(_,S) ->
    {noreply,S}.

terminate(_Reason,_) ->
    ok.





do_ensure(Mod,S) ->
    Int = S#state.ints,
    Mode = S#state.mode,
    case lists:member(code_aux:to_atom(Mod),Int) of
	true ->
	    {interpret,Mod};
	_ when Mode == interactive ->
	    Path = S#state.path,
	    load_file(Mod, Path, S#state.moddb);
	_ ->
	    {error,embedded}
    end.

do_delete(Mod,S) when atom(Mod) ->
    case catch erlang:delete_module(Mod) of
	true ->
	    ets:delete(S#state.moddb, Mod),
	    true;
	_ ->
	    false
    end;
do_delete(Mod,S) when list(Mod) ->
    do_delete(list_to_atom(Mod),S);
do_delete(_,_) ->
    false.



init_db() ->
    Db = ets:new(code,[private]),
    Mods = init:fetch_loaded() ++ fix(erlang:pre_loaded()),
    init_insert(Db,Mods),
    Db.


fix([]) -> [];
fix([H|Tail]) -> [{H,preloaded}|fix(Tail)].



init_insert(Db,[{Mod,Info}|Mods]) ->
    add_module(Mod,Info,Db),
    init_insert(Db,Mods);
init_insert(_,[]) ->
    ok.

	    
add_module(Module, FileName, Db) when hd(FileName) == $. ->
    ets:insert(Db, {Module,filename:absname(FileName),true});
add_module(Module, FileName, Db) ->
    ets:insert(Db, {Module,FileName}).


%% --------------------------------------------------------------
%% Path handling functions.
%% --------------------------------------------------------------

%%
%% Create the initial path. 
%%
make_path(BundleDir,Bundles0) ->
    Bundles = choose_bundles(Bundles0),
    make_path(BundleDir,Bundles,[],[]).

choose_bundles(Bundles) ->
    Bs = lists:sort(lists:map(fun(B) -> cr_b(B) end,
			      Bundles)),
    lists:map(fun({Name,FullName}) -> FullName end,
	      choose(lists:reverse(Bs),[])).

cr_b(FullName) ->
    case split(lists:reverse(FullName)) of
	{ok,Name} ->
	    {Name,FullName};
	_ ->
	    {FullName,FullName}
    end.

split([$-|Name]) -> {ok,lists:reverse(Name)};
split([_|T])     -> split(T);
split(_)         -> false.

choose([{Name,FullName}|Bs],Ack) ->
    case lists:keymember(Name,1,Ack) of
	true ->
	    choose(Bs,Ack);
	_ ->
	    choose(Bs,[{Name,FullName}|Ack])
    end;
choose([],Ack) ->
    Ack.

make_path(_,[],Res,Bs) ->
    {Res,Bs};
make_path(BundleDir,[Bundle|Tail],Res,Bs) ->
    Dir = filename:append(BundleDir,Bundle),
    Bin = filename:append(Dir,"ebin"),
    %% First try with /ebin otherwise just add the dir
    case file:read_file_info(Bin) of
	{ok, #file_info{type=directory}} -> 
	    make_path(BundleDir,Tail,[Bin|Res],[Bundle|Bs]);
	_ ->
	    case file:read_file_info(Dir) of
		{ok,#file_info{type=directory}} ->
		    make_path(BundleDir,Tail,
			      [Dir|Res],[Bundle|Bs]);
		_ ->
		    make_path(BundleDir,Tail,Res,Bs)
	    end
    end.



%%
%% Add the erl_prim_loader path.
%% 
%%
add_loader_path(IPath,Mode) ->
    {ok,P0} = erl_prim_loader:get_path(),
    case Mode of
        embedded ->
            strip_path(P0,Mode);  %% i.e. only normalize
        _ ->
            Pa = get_arg(pa),
            Pz = get_arg(pz),
            P = exclude_pa_pz(P0,Pa,Pz),
            Path0 = strip_path(P,Mode),
            Path = add(Path0,IPath,[]),
            add_pa_pz(Path,Pa,Pz)
    end.

%% As the erl_prim_loader path includes the -pa and -pz
%% directories they have to be removed first !!
exclude_pa_pz(P0,Pa,Pz) ->
    P1 = excl(Pa, P0),
    P = excl(Pz, lists:reverse(P1)),
    lists:reverse(P).

excl([], P) -> 
    P;
excl([D|Ds], P) ->
    excl(Ds, lists:delete(D, P)).

%%
%% Keep only 'valid' paths in code server.
%% Only if mode is interactive, in an embedded
%% system we cant rely on file.
%%
strip_path([P0|Ps], embedded) ->
    P = filename:join([P0]), % Normalize
    [P|strip_path(Ps, embedded)];
strip_path([P0|Ps], I) ->
    P = filename:join([P0]), % Normalize
    case check_path([P]) of
	true ->
	    [P|strip_path(Ps, I)];
	_ ->
	    strip_path(Ps, I)
    end;
strip_path(_, _) ->
    [].
    
%%
%% Add only non-existing paths.
%% Also delete other versions of directories,
%% e.g. .../test-3.2/ebin should exclude .../test-*/ebin (and .../test/ebin).
%% Put the Path directories first in resulting path.
%%
add(Path,["."|IPath],Ack) ->
    RPath = add1(Path,IPath,Ack),
    ["."|lists:delete(".",RPath)];
add(Path,IPath,Ack) ->
    add1(Path,IPath,Ack).

add1([P|Path],IPath,Ack) ->
    case lists:member(P,Ack) of
	true ->
	    add1(Path,IPath,Ack); % Already added
	_ ->
	    IPath1 = exclude(P,IPath),
	    add1(Path,IPath1,[P|Ack])
    end;
add1(_,IPath,Ack) ->
    lists:reverse(Ack) ++ IPath.

add_pa_pz(Path0, Patha, Pathz) ->
    {_,Path1} = add_paths(first,Patha,Path0,false),
    {_,Path2} = add_paths(first,Pathz,lists:reverse(Path1),false),
    lists:reverse(Path2).

get_arg(Arg) ->
    case init:get_argument(Arg) of
	{ok, Values} ->
	    lists:append(Values);
	_ ->
	    []
    end.

%%
%% Exclude other versions of Dir or duplicates.
%% Return a new Path.
%%
exclude(Dir,Path) ->
    Name = get_name(Dir),
    lists:filter(fun(D) when D == Dir ->
			 false;
		    (D) ->
			 case get_name(D) of
			     Name ->
				 false; % exclude this dir !
			     _ ->
				 true
			 end
		 end, Path).

%%
%% Get the "Name" of a directory. A directory in the code server path
%% have the following form: .../Name-Vsn or .../Name
%% where Vsn is any sortable term (the newest directory is sorted as
%% the greatest term).
%%
%%
get_name(Dir) ->
    get_name2(get_name1(Dir), []).

get_name1(Dir) ->
    case lists:reverse(filename:split(Dir)) of
	["ebin",DirName|_] -> DirName;
	[DirName|_]        -> DirName;
	_                  -> ""        % No name !
    end.

get_name2([$-|_],Ack) -> lists:reverse(Ack);
get_name2([H|T],Ack)  -> get_name2(T,[H|Ack]);
get_name2(_,Ack)      -> lists:reverse(Ack).

check_path([]) -> 
    true;
check_path([Dir |Tail]) ->
    case catch file:read_file_info(Dir) of
	{ok, #file_info{type=directory}} -> 
	    check_path(Tail);
	_ -> 
	    {error, bad_directory}
    end;
check_path(_) ->
    {error, bad_path}.


%%
%% Add new path(s).
%%
add_path(Where,Dir,Path,NameDb) when atom(Dir) ->
    add_path(Where,atom_to_list(Dir),Path,NameDb);
add_path(Where,Dir0,Path,NameDb) when list(Dir0) ->
    case int_list(Dir0) of
	true ->
	    Dir = filename:join([Dir0]), % Normalize
	    case check_path([Dir]) of
		true ->
		    {true, do_add(Where,Dir,Path,NameDb)};
		Error ->
		    {Error, Path}
	    end;
	_ ->
	    {{error, bad_directory}, Path}
    end;
add_path(_,_,Path,_) ->
    {{error, bad_directory}, Path}.


%%
%% If the new directory is added first or if the directory didn't exist
%% the name-directory table must be updated.
%% If NameDb is false we should NOT update NameDb as it is done later
%% then the table is created :-)
%%
do_add(first,Dir,Path,NameDb) ->
    update(Dir,NameDb),
    [Dir|lists:delete(Dir,Path)];
do_add(last,Dir,Path,NameDb) ->
    case lists:member(Dir,Path) of
	true ->
	    Path;
	_ ->
	    maybe_update(Dir,NameDb),
	    Path ++ [Dir]
    end.

%% Do not update if the same name already exists !
maybe_update(Dir,NameDb) ->
    case lookup_name(get_name(Dir),NameDb) of
        false -> update(Dir,NameDb);
        _     -> false
    end.

update(Dir,false) ->
    ok;
update(Dir,NameDb) ->
    replace_name(Dir,NameDb).



%%
%% Set a completely new path.
%%
set_path(NewPath0, OldPath, NameDb) ->
    NewPath = normalize(NewPath0),
    case check_path(NewPath) of
	true ->
	    ets:delete(NameDb),
	    NewDb = init_namedb(NewPath),
	    {true, NewPath, NewDb};
	Error ->
	    {Error, OldPath, NameDb}
    end.

%%
%% Normalize the given path.
%% The check_path function catches erroneous path,
%% thus it is ignored here.
%%
normalize([P|Path]) when atom(P) ->
    normalize([atom_to_list(P)|Path]);
normalize([P|Path]) when list(P) ->
    case int_list(P) of
	true -> [filename:join([P])|normalize(Path)];
	_    -> [P|normalize(Path)]
    end;
normalize([P|Path]) ->
    [P|normalize(Path)];
normalize([]) ->
    [];
normalize(Other) ->
    Other.

%% Handle a table of name-directory pairs.
%% The priv_dir/1 and lib_dir/1 functions will have
%% an O(1) lookup.
init_namedb(Path) ->
    Db = ets:new(code_names,[private]),
    init_namedb(lists:reverse(Path), Db),
    Db.
    
init_namedb([P|Path], Db) ->
    insert_name(P, Db),
    init_namedb(Path, Db);
init_namedb([], _) ->
    ok.

-ifdef(NOTUSED).
clear_namedb([P|Path], Db) ->
    delete_name_dir(P, Db),
    clear_namedb(Path, Db);
clear_namedb([], _) ->
    ok.
-endif.

insert_name(Dir, Db) ->
    case get_name(Dir) of
	Dir  -> false;
	Name -> insert_name(Name, Dir, Db)
    end.

insert_name(Name, Dir, Db) ->
    ets:insert(Db, {Name, del_ebin(Dir)}),
    true.



%%
%% Delete a directory from Path.
%% Name can be either the the name in .../Name[-*] or
%% the complete directory name.
%%
del_path(Name0,Path,NameDb) ->
    case catch code_aux:to_list(Name0)of
	{'EXIT',_} ->
	    {{error,bad_name},Path};
	Name ->
	    case del_path1(Name,Path,NameDb) of
		Path -> % Nothing has changed
		    {false,Path};
		NewPath ->
		    {true,NewPath}
	    end
    end.

del_path1(Name,[P|Path],NameDb) ->
    case get_name(P) of
	Name ->
	    delete_name(Name, NameDb),
	    insert_old_shadowed(Name, Path, NameDb),
	    Path;
	_ when Name == P ->
	    case delete_name_dir(Name, NameDb) of
		true -> insert_old_shadowed(get_name(Name), Path, NameDb);
		false -> ok
	    end,
	    Path;
	_ ->
	    [P|del_path1(Name,Path,NameDb)]
    end;
del_path1(_,[],_) ->
    [].

insert_old_shadowed(Name, [P|Path], NameDb) ->
    case get_name(P) of
	Name -> insert_name(Name, P, NameDb);
	_    -> insert_old_shadowed(Name, Path, NameDb)
    end;
insert_old_shadowed(_, [], _) ->
    ok.

%%
%% Replace an old occurrence of an directory with name .../Name[-*].
%% If it does not exist, put the new directory last in Path.
%%
replace_path(Name,Dir,Path,NameDb) ->
    case catch check_pars(Name,Dir) of
	{ok,N,D} ->
	    {true,replace_path1(N,D,Path,NameDb)};
	{'EXIT',_} ->
	    {{error,{badarg,[Name,Dir]}},Path};
	Error ->
	    {Error,Path}
    end.

replace_path1(Name,Dir,[P|Path],NameDb) ->
    case get_name(P) of
	Name ->
	    delete_name(Name,NameDb),
	    insert_name(Name, Dir, NameDb),
	    [Dir|Path];
	_ ->
	    [P|replace_path1(Name,Dir,Path,NameDb)]
    end;
replace_path1(_,Dir,[],_) ->
    [Dir].

check_pars(Name,Dir) ->
    N = code_aux:to_list(Name),
    D = filename:join([code_aux:to_list(Dir)]), % Normalize
    case get_name(Dir) of
	N ->
	    case check_path([D]) of
		true ->
		    {ok,N,D};
		Error ->
		    Error
	    end;
	_ ->
	    {error,bad_name}
    end.


del_ebin(Dir) ->
    case filename:basename(Dir) of
	"ebin" -> filename:dirname(Dir);
	_      -> Dir
    end.



replace_name(Dir, Db) ->
    case get_name(Dir) of
	Dir ->
	    false;
	Name ->
	    delete_name(Name, Db),
	    insert_name(Name, Dir, Db)
    end.

delete_name(Name, Db) ->
    ets:delete(Db, Name).

delete_name_dir(Dir, Db) ->
    case get_name(Dir) of
	Dir  -> false;
	Name ->
	    Dir0 = del_ebin(Dir),
	    case lookup_name(Name, Db) of
		{ok, Dir0} ->
		    ets:delete(Db, Name), 
		    true;
		_ -> false
	    end
    end.

lookup_name(Name, Db) ->
    case ets:lookup(Db, Name) of
	[{Name, Dir}] -> {ok, Dir};
	_             -> false
    end.


%%
%% Fetch a directory.
%%
do_dir(Root,lib_dir,_) ->
    filename:append(Root, "lib");
do_dir(Root,uc_dir,_) ->
    filename:append(Root, "uc");
do_dir(Root,root_dir,_) ->
    Root;
do_dir(Root,compiler_dir,NameDb) ->
    case lookup_name("compiler", NameDb) of
	{ok, Dir} -> Dir;
	_         -> ""
    end;
do_dir(Root,{lib_dir,Name},NameDb) ->
    case catch lookup_name(code_aux:to_list(Name), NameDb) of
	{ok, Dir} -> Dir;
	_         -> {error, bad_name}
    end;
do_dir(Root,{priv_dir,Name},NameDb) ->
    case catch lookup_name(code_aux:to_list(Name), NameDb) of
	{ok, Dir} -> filename:append(Dir, "priv");
	_         -> {error, bad_name}
    end;
do_dir(Root,_,_) ->
    'bad request to code'.



%% Put/Erase all library modules into local process dict

stick_library(LibDirListing, Db) ->
    putem(get_mods(LibDirListing, code_aux:objfile_extension()), Db).
unstick_library(LibDirListing, Db) ->
    eraseem(get_mods(LibDirListing, code_aux:objfile_extension()), Db).
    

putem([], _) -> done;
putem([M|Tail], Db) ->
    ets:insert(Db, {{sticky, code_aux:to_atom(M)}, true}),
    putem(Tail, Db).

eraseem([], _) -> done;
eraseem([M|Tail], Db) ->
    ets:delete(Db, {sticky, code_aux:to_atom(M)}),
    eraseem(Tail, Db).

get_mods([File|Tail], Extension) ->
    case filename:extension(File) of
	Extension ->
	    [list_to_atom(filename:basename(File, Extension)) |
	     get_mods(Tail, Extension)];
	_ ->
	    get_mods(Tail, Extension)
    end;
get_mods([], _) ->
    [].




add_paths(Where,[Dir|Tail],Path,NameDb) ->
    {_,NPath} = add_path(Where,Dir,Path,NameDb),
    add_paths(Where,Tail,NPath,NameDb);
add_paths(_,_,Path,_) ->
    {ok,Path}.




do_load_binary(Module,File,Binary,Db) ->
    case {modp(Module),modp(File)} of
	{true, true} when binary(Binary) ->
	    case erlang:module_loaded(code_aux:to_atom(Module)) of
		true ->
		    code_aux:do_purge(Module);
		false ->
		    ok
	    end,
	    try_load_module(File, Module, Binary, Db);
	_ ->
	    {error, badarg}
    end.

modp(Atom) when atom(Atom) -> true;
modp(List) when list(List) -> int_list(List);
modp(_)                    -> false.


load_abs(File, Db) ->
    Ext = code_aux:objfile_extension(),
    FileName0 = lists:concat([File, Ext]),
    FileName = filename:absname(FileName0),
    Mod = list_to_atom(filename:basename(FileName0, Ext)),
    case erl_prim_loader:get_file(FileName) of
	{ok,Bin,_} ->
	    try_load_module(FileName, Mod, Bin, Db);
	error ->
	    {error,nofile}
    end.

try_load_module(File, Mod, Bin, Db) ->
    M = code_aux:to_atom(Mod),
    case code_aux:sticky(M, Db) of
	true ->                         %% Sticky file reject the load
	    error_logger:error_msg("Can't load module that resides in sticky dir\n",[]),
	    {error, sticky_directory};
	false ->
	    case erlang:load_module(M, Bin) of
		{module,M} ->
		    add_module(M, File, Db),
		    {module,Mod};
		{error,What} ->
		    error_logger:error_msg("Loading of ~s failed: ~p\n", [File, What]),
		    {error,What}
	    end
    end.



int_list([H|T]) when integer(H) -> int_list(T);
int_list([_|T])                 -> false;
int_list([])                    -> true.



mod_to_bin([Dir|Tail],Mod) ->
    File = filename:append(Dir, code_aux:to_list(Mod) ++ code_aux:objfile_extension()),
    case erl_prim_loader:get_file(File) of
	error -> 
	    mod_to_bin(Tail,Mod);
	{ok,Bin,FName} ->
	    {Mod,Bin,FName}
    end;
mod_to_bin([],Mod) ->
    %% At last, try also erl_prim_loader's own method !!
    File = lists:concat([Mod,code_aux:objfile_extension()]),
    case erl_prim_loader:get_file(File) of
	error -> 
	    error;     % No more alternatives !
	{ok,Bin,FName} ->
	    {Mod,Bin,FName}
    end.

load_file(Mod,Path,Db) ->
    case mod_to_bin(Path,Mod) of
	error -> {error,nofile};
	{Mod,Binary,File} -> try_load_module(File, Mod, Binary, Db)
    end.





%% do_soft_purge(Module)
%% Purge old code only if no procs remain that run old code
%% Return true in that case, false if procs remain (in this
%% case old code is not purged)

do_soft_purge(Mod) ->
    M = code_aux:to_atom(Mod),
    catch do_soft_purge(processes(), M).

do_soft_purge([P|Ps], Mod) ->
    case erlang:check_process_code(P, Mod) of
	true ->
	    throw(false);
	false ->
	    do_soft_purge(Ps, Mod)
    end;
do_soft_purge([], Mod) ->
    catch erlang:purge_module(Mod),
    true.


is_loaded(Module, Db, Ints) ->
    M = code_aux:to_atom(Module),
    case ets:lookup(Db, M) of
       [File] ->
	   {file,element(2,File)};
       _ ->
	    case lists:member(M, Ints) of
		true ->
		    {file, interpreted};
		_ ->
		    false
	    end
   end.

%% -------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------

all_loaded(Db,Int) ->
    %% ++ is not efficient for long lists but here we know that 
    %% the list of interpreted modules is short 
    code_server_int:ints(Int) ++ all_l(Db). 

all_l(Db) -> all_l(Db, ets:slot(Db,0), 1, []).

all_l(Db, '$end_of_table', _, Acc) ->
    Acc;
all_l(Db, ModInfo, N, Acc) ->
    NewAcc = strip_mod_info(ModInfo,Acc), 
    all_l(Db, ets:slot(Db,N), N + 1, NewAcc).


strip_mod_info([{{sticky,_},_}|T], Acc) -> strip_mod_info(T, Acc);
strip_mod_info([{M,F,_}|T], Acc)        -> strip_mod_info(T,[{M,F}|Acc]);
strip_mod_info([H|T], Acc)              -> strip_mod_info(T,[H|Acc]);
strip_mod_info([], Acc)                 -> Acc.


%% Check if a module was loaded relative current directory
%% (at the time of loading).
rel_loaded_p(Mod,Db) ->
    case ets:lookup(Db, Mod) of
	[{_,_,true}] -> true;
	_            -> false
    end.



