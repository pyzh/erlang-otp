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
%% Purpose : Convert annotated kernel expressions to annotated beam format.

-module(v3_life).

-export([module/2]).

-export([vdb_find/2]).

-import(lists, [map/2,foldl/3,foldr/3,mapfoldl/3,filter/2]).
-import(ordsets, [add_element/2,del_element/2,is_element/2,
		  intersection/2,union/1,union/2,subtract/2]).

-include("sys_kernel.hrl").
-include("beam_life.hrl").

get_kanno(Kthing) -> element(2, Kthing).
set_kanno(Kthing, Anno) -> setelement(2, Kthing, Anno).

module(#k_mdef{anno=A,name=M,exports=Es,attributes=As,body=Fs0}, Options) ->
    Fs1 = map(fun function/1, Fs0),
    {ok,{M,Es,As,Fs1}}.

%% function(Kfunc) -> Func.

function(#k_fdef{anno=A,func=F,arity=Ar,vars=Vs,body=Kb}) ->
    As = var_list(Vs),
    Vdb0 = foldl(fun ({var,N}, Vdb) -> new_var(N, 0, Vdb) end, [], As),
    %% Force a top-level match!
    B0 = case Kb of
	     #k_match{} -> Kb;
	     Other ->
		 Ka = get_kanno(Kb),
		 #k_match{anno=#k{us=Ka#k.us,ns=[],a=Ka#k.a},
			  vars=Vs,body=Kb,ret=[]}
	 end,
    {B1,MaxI,Vdb1} = body(B0, 1, Vdb0),
    {function,F,Ar,As,B1,Vdb1}.

%% body(Kbody, I, Vdb) -> {[Expr],MaxI,Vdb}.

body(#k_seq{arg=Ke,body=Kb}, I, Vdb0) ->
    %%ok = io:fwrite("body:~p~n", [{Ke,I,Vdb0}]),
    A = get_kanno(Ke),
    Vdb1 = use_vars(A#k.us, I, new_vars(A#k.ns, I, Vdb0)),
    {Es,MaxI,Vdb2} = body(Kb, I+1, Vdb1),
    E = expr(Ke, I, Vdb2),
    {[E|Es],MaxI,Vdb2};
body(Ke, I, Vdb0) ->
    %%ok = io:fwrite("body:~p~n", [{Ke,I,Vdb0}]),
    A = get_kanno(Ke),
    Vdb1 = use_vars(A#k.us, I, new_vars(A#k.ns, I, Vdb0)),
    E = expr(Ke, I, Vdb1),
    {[E],I,Vdb1}.

%% guard(Kguard, I, Vdb) -> {[Expr],MaxI,Vdb}.
%%  A guard is like a body but much more specialised.

guard(#k_seq{arg=Ke,body=Kb}, I, Vdb0) ->
    %% ok = io:fwrite("guard:~p~n", [{Ke,I,Vdb0}]),
    A = get_kanno(Ke),
    Vdb1 = use_vars(A#k.us, I, new_vars(A#k.ns, I, Vdb0)),
    {Es,MaxI,Vdb2} = guard(Kb, I+1, Vdb1),
    E = guard_expr(Ke, I, Vdb2),
    {[E|Es],MaxI,Vdb2};
guard(Ke, I, Vdb0) ->
    %% ok = io:fwrite("guard:~p~n", [{Ke,I,Vdb0}]),
    A = get_kanno(Ke),
    Vdb1 = use_vars(A#k.us, I, new_vars(A#k.ns, I, Vdb0)),
    E = guard_expr(Ke, I, Vdb1),
    {[E],I+1,Vdb1}.

%% guard_expr(Call, I, Vdb) -> Expr
%%  We know that guard bifs are tests if they return no values,
%%  otherwise just bif.

guard_expr(#k_bif{anno=A,op=Op,args=As,ret=[]}, I, Vdb) ->
    #l{ke={test,test_op(Op),atomic_list(As)},i=I,a=A#k.a};
guard_expr(#k_bif{anno=A,op=Op,args=As,ret=Rs}, I, Vdb) ->
    #l{ke={bif,bif_op(Op),atomic_list(As),var_list(Rs)},i=I,a=A#k.a};
guard_expr(#k_put{anno=A,arg=Arg,ret=Rs}, I, Vdb) ->
    #l{ke={set,var_list(Rs),literal(Arg)},i=I,a=A#k.a}.

%% expr(Kexpr, I, Vdb) -> Expr.

expr(#k_call{anno=A,op=#k_internal{}=Op,args=As,ret=Rs}, I, Vdb) ->
    internal_call(A, Op, As, Rs, I, Vdb);
expr(#k_call{anno=A,op=Op,args=As,ret=Rs}, I, Vdb) ->
    #l{ke={call,call_op(Op),atomic_list(As),var_list(Rs)},i=I,a=A#k.a};
expr(#k_enter{anno=A,op=Op,args=As}, I, Vdb) ->
    #l{ke={enter,call_op(Op),atomic_list(As)},i=I,a=A#k.a};
expr(#k_bif{anno=A,op=Op,args=As,ret=[]}, I, Vdb) ->
    %% Must generate unique variable here.
    #l{ke={bif,bif_op(Op),atomic_list(As),[{var,I}]},i=I,a=A#k.a};
expr(#k_bif{anno=A,op=Op,args=As,ret=Rs}, I, Vdb) ->
    #l{ke={bif,bif_op(Op),atomic_list(As),var_list(Rs)},i=I,a=A#k.a};
expr(#k_match{anno=A,body=Kb,ret=Rs}, I, Vdb) ->
    Mdb = vdb_sub(I, I+1, Vdb),
    M = match(Kb, A#k.us, I+1, Mdb),
    #l{ke={match,M,var_list(Rs)},i=I,vdb=use_vars(A#k.us, I, Mdb),a=A#k.a};
expr(#k_catch{anno=A,body=Kb,ret=[R]}, I, Vdb) ->
    %% Lock variables that are alive before the catch and used afterwards.
    %% Don't lock variables that are only used inside the catch.
    %% Add catch tag 'variable'.
    Cdb0 = vdb_sub(I, I+1, Vdb),
    {Es,Cmax,Cdb1} = body(Kb, I+1, add_var({catch_tag,I}, I, 1000000, Cdb0)),
    #l{ke={'catch',Es,variable(R)},i=I,vdb=Cdb1,a=A#k.a};
expr(#k_receive{anno=A,var=V,body=Kb,timeout=T,action=Ka,ret=Rs}, I, Vdb) ->
    Rdb = vdb_sub(I, I+1, Vdb),
    M = match(Kb, A#k.us, I+1, new_var(V#k_var.name, I, Rdb)),
    {Tes,MaxI,Adb} = body(Ka, I+1, Rdb),
    #l{ke={receive_loop,atomic(T),variable(V),M,
	   #l{ke=Tes,i=I+1,vdb=Adb,a=[]},var_list(Rs)},
       i=I,vdb=use_vars(A#k.us, I, Vdb),a=A#k.a};
expr(#k_receive_accept{anno=A}, I, Vdb) ->
    #l{ke=receive_accept,i=I,a=A#k.a};
expr(#k_receive_reject{anno=A}, I, Vdb) ->
    #l{ke=receive_reject,i=I,a=A#k.a};
expr(#k_receive_next{anno=A}, I, Vdb) ->
    #l{ke=receive_next,i=I,a=A#k.a};
expr(#k_put{anno=A,arg=Arg,ret=Rs}, I, Vdb) ->
    #l{ke={set,var_list(Rs),literal(Arg)},i=I,a=A#k.a};
expr(#k_break{anno=A,args=As}, I, Vdb) ->
    #l{ke={break,atomic_list(As)},i=I,a=A#k.a};
expr(#k_return{anno=A,args=As}, I, Vdb) ->
    #l{ke={return,atomic_list(As)},i=I,a=A#k.a}.

%% call_op(Op) -> Op.
%% bif_op(Op) -> Op.
%% test_op(Op) -> Op.
%%  Do any necessary name translations here to munge into beam format.

call_op(#k_local{name=N}) -> N; 
call_op(#k_remote{mod=erlang,name='++'}) -> {remote,erlang,append};
call_op(#k_remote{mod=erlang,name='--'}) -> {remote,erlang,subtract};
call_op(#k_remote{mod=M,name=N}) -> {remote,M,N};
call_op(Other) -> variable(Other).

bif_op(#k_local{name=N}) -> N; 
bif_op(#k_remote{mod=M,name=N}) -> N.

test_op(#k_local{name=N}) -> N; 
test_op(#k_remote{mod=M,name=N}) -> N.

%% internal_call(Anno, Op, [Arg], [Ret], I, Vdb) -> Expr.
%%  Handling of internal calls, these are special.

internal_call(A, #k_internal{name=make_fun},
	      [#k_atom{name=Fun},#k_int{val=Arity},#k_int{val=Id}|Free],
	      Rs, I, Vdb) ->
    #l{ke={call,{make_fun,Fun,Arity,Id},var_list(Free),var_list(Rs)},
       i=I,a=A#k.a}.

%% match(Kexpr, [LockVar], I, Vdb) -> Expr.
%%  Convert match tree to old format.  We do the match_fail internal
%%  call explicitly here.

match(#k_alt{anno=A,first=Kf,then=Kt}, Ls, I, Vdb0) ->
    Vdb1 = use_vars(union(A#k.us, Ls), I, Vdb0),
    F = match(Kf, Ls, I+1, Vdb1),
    T = match(Kt, Ls, I+1, Vdb1),
    #l{ke={alt,F,T},i=I,vdb=Vdb1,a=A#k.a};
match(#k_select{anno=A,var=V,types=Kts}, Ls0, I, Vdb0) ->
    Ls1 = add_element(V#k_var.name, Ls0),
    Vdb1 = use_vars(union(A#k.us, Ls1), I, Vdb0),
    Ts = map(fun (Tc) -> type_clause(Tc, Ls1, I+1, Vdb1) end, Kts),
    #l{ke={select,literal(V),Ts},i=I,vdb=Vdb1,a=A#k.a};
match(#k_guard{anno=A,clauses=Kcs}, Ls, I, Vdb0) ->
    Vdb1 = use_vars(union(A#k.us, Ls), I, Vdb0),
    Cs = map(fun (G) -> guard_clause(G, Ls, I+1, Vdb1) end, Kcs),
    #l{ke={guard,Cs},i=I,vdb=Vdb1,a=A#k.a};
match(#k_seq{arg=#k_put{anno=A,arg=Arg,ret=[R]},
	     body=#k_enter{op=#k_internal{name=match_fail,arity=1},args=[R]}},
      Ls, I, Vdb) ->
    match_fail(Arg, A#k.us, Ls, I, use_vars(Ls, I, Vdb));
match(#k_enter{anno=A,op=#k_internal{name=match_fail,arity=1},args=[Arg]},
      Ls, I, Vdb) ->
    match_fail(Arg, A#k.us, Ls, I, use_vars(Ls, I, Vdb));
match(Other, Ls, I, Vdb0) ->
    Vdb1 = use_vars(Ls, I, Vdb0),
    {B,MaxI,Vdb2} = body(Other, I+1, Vdb1),
    #l{ke={block,B},i=I,vdb=Vdb2,a=[]}.

type_clause(#k_type_clause{anno=A,type=T,values=Kvs}, Ls, I, Vdb0) ->
    Vdb1 = use_vars(union(A#k.us, Ls), I, Vdb0),
    Vs = map(fun (Vc) -> val_clause(Vc, Ls, I+1, Vdb1) end, Kvs),
    #l{ke={type_clause,type(T),Vs},i=I,vdb=Vdb1,a=A#k.a}.

val_clause(#k_val_clause{anno=A,val=V,body=Kb}, Ls0, I, Vdb0) ->
    Ps = pat_vars(V),
    Bus = (get_kanno(Kb))#k.us,
    Ls1 = union(intersection(Ps, Bus), Ls0),
    Vdb1 = use_vars(union(A#k.us, Ls1), I, new_vars(Ps, I, Vdb0)),
    B = match(Kb, Ls1, I+1, Vdb1),
    #l{ke={val_clause,literal(V),B},i=I,vdb=use_vars(Bus, I+1, Vdb1),a=A#k.a}.

guard_clause(#k_guard_clause{anno=A,guard=Kg,body=Kb}, Ls, I, Vdb0) ->
    {G,MaxG,Vdb1} = guard(Kg, I+1, Vdb0),
    Vdb2 = use_vars(union(A#k.us, Ls), MaxG, Vdb1),
    B = match(Kb, Ls, MaxG, Vdb2),
    #l{ke={guard_clause,G,B},
       i=I,vdb=use_vars((get_kanno(Kg))#k.us, MaxG, Vdb2),
       a=A#k.a}.

%% match_fail(FailValue, [UsedVar], [LockVar], I, Vdb) -> Expr.
%%  Generate the correct match_fail instruction.

match_fail(#k_atom{name=function_clause}, [], Ls, I, Vdb) ->
    #l{ke={match_fail,function_clause},i=I,vdb=Vdb};
match_fail(#k_tuple{es=[#k_atom{name=badmatch},Val]}, Us, Ls, I, Vdb) ->
    #l{ke={match_fail,{badmatch,literal(Val)}},
       i=I,vdb=use_vars(Us, I, Vdb)};
match_fail(#k_tuple{es=[#k_atom{name=case_clause},Val]}, Us, Ls, I, Vdb) ->
    #l{ke={match_fail,{case_clause,literal(Val)}},
       i=I,vdb=use_vars(Us, I, Vdb)};
match_fail(#k_atom{name=if_clause}, [], Ls, I, Vdb) ->
    #l{ke={match_fail,if_clause},i=I,vdb=Vdb}.

%% type(Ktype) -> Type.

type(k_int) -> integer;
type(k_float) -> float;
type(k_atom) -> atom;
type(k_nil) -> nil;
type(k_cons) -> cons;
type(k_tuple) -> tuple.

%% variable(Klit) -> Lit.
%% var_list([Klit]) -> [Lit].

variable(#k_var{name=N}) -> {var,N}.

var_list(Ks) -> map(fun variable/1, Ks).

%% atomic(Klit) -> Lit.
%% atomic_list([Klit]) -> [Lit].

atomic(#k_var{name=N}) -> {var,N};
atomic(#k_int{val=I}) -> {integer,I};
atomic(#k_float{val=F}) -> {float,F};
atomic(#k_atom{name=N}) -> {atom,N};
atomic(#k_char{val=C}) -> {char,C};
%%atomic(#k_string{val=S}) -> {string,S};
atomic(#k_nil{}) -> nil.

atomic_list(Ks) -> map(fun atomic/1, Ks).

%% literal(Klit) -> Lit.
%% lit_list([Klit]) -> [Lit].

literal(#k_var{name=N}) -> {var,N};
literal(#k_int{val=I}) -> {integer,I};
literal(#k_float{val=F}) -> {float,F};
literal(#k_atom{name=N}) -> {atom,N};
literal(#k_char{val=C}) -> {char,C};
literal(#k_string{val=S}) -> {string,S};
literal(#k_nil{}) -> nil;
literal(#k_cons{head=H,tail=T}) ->
    {cons,[literal(H),literal(T)]};
literal(#k_tuple{es=Es}) ->
    {tuple,lit_list(Es)}.

lit_list(Ks) -> map(fun literal/1, Ks).

%% pat_vars(Pattern) -> [VarName].

pat_vars(#k_var{name=N}) -> [N];
pat_vars(#k_int{}) -> [];
pat_vars(#k_float{}) -> [];
pat_vars(#k_atom{}) -> [];
pat_vars(#k_char{}) -> [];
pat_vars(#k_string{}) -> [];
pat_vars(#k_nil{}) -> [];
pat_vars(#k_cons{head=H,tail=T}) ->
    union(pat_vars(H), pat_vars(T));
pat_vars(#k_tuple{es=Es}) ->
    pat_list_vars(Es).

pat_list_vars(Ps) ->
    foldl(fun (P, Vs) -> union(pat_vars(P), Vs) end, [], Ps).

%% new_var(VarName, I, Vdb) -> Vdb.
%% new_vars([VarName], I, Vdb) -> Vdb.
%% use_var(VarName, I, Vdb) -> Vdb.
%% use_vars([VarName], I, Vdb) -> Vdb.
%% add_var(VarName, F, L, Vdb) -> Vdb.

new_var(V, I, Vdb) ->
    case vdb_find(V, Vdb) of
	{V,F,L} when I < F -> vdb_store(V, I, L, Vdb);
	{V,F,L} -> Vdb;
	error -> vdb_store(V, I, I, Vdb)
    end.

new_vars(Vs, I, Vdb0) ->
    foldl(fun (V, Vdb) -> new_var(V, I, Vdb) end, Vdb0, Vs).

use_var(V, I, Vdb) ->
    case vdb_find(V, Vdb) of
	{V,F,L} when I > L -> vdb_store(V, F, I, Vdb);
	{V,F,L} -> Vdb;
	error -> vdb_store(V, I, I, Vdb)
    end.

use_vars(Vs, I, Vdb0) ->
    foldl(fun (V, Vdb) -> use_var(V, I, Vdb) end, Vdb0, Vs).

add_var(V, F, L, Vdb) ->
    use_var(V, L, new_var(V, F, Vdb)).

vdb_find(V, [{V1,F,L}=Vd|Vdb]) when V < V1 -> error;
vdb_find(V, [{V1,F,L}=Vd|Vdb]) when V == V1 -> Vd;
vdb_find(V, [{V1,F,L}=Vd|Vdb]) when V > V1 -> vdb_find(V, Vdb);
vdb_find(V, []) -> error.

vdb_store(V, F, L, [{V1,F1,L1}=Vd|Vdb]) when V < V1 -> [{V,F,L},Vd|Vdb];
vdb_store(V, F, L, [{V1,F1,L1}=Vd|Vdb]) when V == V1 -> [{V,F,L}|Vdb];
vdb_store(V, F, L, [{V1,F1,L1}=Vd|Vdb]) when V > V1 ->
    [Vd|vdb_store(V, F, L, Vdb)];
vdb_store(V, F, L, []) -> [{V,F,L}].

%% vdb_sub(Min, Max, Vdb) -> Vdb.

vdb_sub(Min, Max, Vdb) ->
    [ if L >= Max -> {V,F,1000000};
	 true -> Vd
      end || {V,F,L}=Vd <- Vdb, F < Min, L >= Min ].
