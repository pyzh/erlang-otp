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

%% Definition of the Erlang grammar.

Nonterminals
form
attribute attr_val
function function_clauses function_clause
clause_args clause_guard clause_body
expr expr_100 expr_200 expr_300 expr_400 expr_500 expr_600 expr_700 expr_800
expr_max
list tail
list_comprehension lc_expr lc_exprs
tuple
%struct
record_expr record_tuple record_field record_fields
if_expr if_clause if_clauses case_expr cr_clause cr_clauses receive_expr
fun_expr fun_clause fun_clauses
query_expr
function_call argument_list
exprs guard
atomic strings
prefix_op mult_op add_op list_op comp_op
rule rule_clauses rule_clause rule_args rule_guard rule_body
binary bin_elements bin_element bit_expr
opt_bit_size_expr bit_size_expr opt_bit_type_list bit_type_list bit_type.

Terminals
atom float integer string var

'(' ')' ',' '->' ':-' '{' '}' '[' ']' '|' '||' '<-' ';' ':' '#' '.'
'after' 'begin' 'case' 'catch' 'end' 'fun' 'if' 'of' 'receive' 'when' 'query'

'bnot' 'not'
'*' '/' 'div' 'rem' 'band' 'and'
'+' '-' 'bor' 'bxor' 'bsl' 'bsr' 'or' 'xor'
'++' '--'
'==' '/=' '=<' '<' '>=' '>' '=:=' '=/='
'<<' '>>'
'!' '='
dot.

Rootsymbol form.


form -> attribute dot : '$1'.
form -> function dot : '$1'.
form -> rule dot : '$1'.

attribute -> '-' atom '(' attr_val ')' : build_attribute('$2', '$4').

attr_val -> exprs : '$1'.

function -> function_clauses : build_function('$1').

function_clauses -> function_clause : ['$1'].
function_clauses -> function_clause ';' function_clauses : ['$1'|'$3'].

function_clause -> atom clause_args clause_guard clause_body :
	{clause,line('$1'),element(3, '$1'),'$2','$3','$4'}.


clause_args -> argument_list : element(1, '$1').

clause_guard -> 'when' guard : '$2'.
clause_guard -> '$empty' : [].

clause_body -> '->' exprs: '$2'.


expr -> 'catch' expr : {'catch',line('$1'),'$2'}.
expr -> expr_100 : '$1'.

expr_100 -> expr_200 '=' expr_100 : {match,line('$2'),'$1','$3'}.
expr_100 -> expr_200 '!' expr_100 : mkop('$1', '$2', '$3').
expr_100 -> expr_200 : '$1'.

expr_200 -> expr_300 comp_op expr_300 :
	mkop('$1', '$2', '$3').
expr_200 -> expr_300 : '$1'.

expr_300 -> expr_400 list_op expr_300 :
	mkop('$1', '$2', '$3').
expr_300 -> expr_400 : '$1'.

expr_400 -> expr_400 add_op expr_500 :
	mkop('$1', '$2', '$3').
expr_400 -> expr_500 : '$1'.

expr_500 -> expr_500 mult_op expr_600 :
	mkop('$1', '$2', '$3').
expr_500 -> expr_600 : '$1'.

expr_600 -> prefix_op expr_700 :
	mkop('$1', '$2').
expr_600 -> expr_700 : '$1'.

expr_700 -> function_call : '$1'.
expr_700 -> record_expr : '$1'.
expr_700 -> expr_800 : '$1'.

expr_800 -> expr_max ':' expr_max :
	{remote,line('$2'),'$1','$3'}.
expr_800 -> expr_max : '$1'.

expr_max -> var : '$1'.
expr_max -> atomic : '$1'.
expr_max -> list : '$1'.
expr_max -> binary : '$1'.
expr_max -> list_comprehension : '$1'.
expr_max -> tuple : '$1'.
%%expr_max -> struct : '$1'.
expr_max -> '(' expr ')' : '$2'.
expr_max -> 'begin' exprs 'end' : {block,line('$1'),'$2'}.
expr_max -> if_expr : '$1'.
expr_max -> case_expr : '$1'.
expr_max -> receive_expr : '$1'.
expr_max -> fun_expr : '$1'.
expr_max -> query_expr : '$1'.


list -> '[' ']' : {nil,line('$1')}.
list -> '[' expr tail : {cons,line('$1'),'$2','$3'}.

tail -> ']' : {nil,line('$1')}.
tail -> '|' expr ']' : '$2'.
tail -> ',' expr tail : {cons,line('$2'),'$2','$3'}.


binary -> '<<' '>>' : {bin,line('$1'),[]}.
binary -> '<<' bin_elements '>>' : {bin,line('$1'),'$2'}.

bin_elements -> bin_element : ['$1'].
bin_elements -> bin_element ',' bin_elements : ['$1'|'$3'].

bin_element -> bit_expr opt_bit_size_expr opt_bit_type_list :
	{bin_element,line('$1'),'$1','$2','$3'}.

bit_expr -> prefix_op expr_max : mkop('$1', '$2').
bit_expr -> expr_max : '$1'.

opt_bit_size_expr -> ':' bit_size_expr : '$2'.
opt_bit_size_expr -> '$empty' : default.

opt_bit_type_list -> '/' bit_type_list : '$2'.
opt_bit_type_list -> '$empty' : default.

bit_type_list -> bit_type '-' bit_type_list : ['$1' | '$3'].
bit_type_list -> bit_type : ['$1'].

bit_type -> atom             : element(3,'$1').
bit_type -> atom ':' integer : { element(3,'$1'), element(3,'$3') }.

bit_size_expr -> expr_max : '$1'.


list_comprehension -> '[' expr '||' lc_exprs ']' :
	{lc,line('$1'),'$2','$4'}.

lc_exprs -> lc_expr : ['$1'].
lc_exprs -> lc_expr ',' lc_exprs : ['$1'|'$3'].

lc_expr -> expr : '$1'.
lc_expr -> expr '<-' expr : {generate,line('$2'),'$1','$3'}.


tuple -> '{' '}' : {tuple,line('$1'),[]}.
tuple -> '{' exprs '}' : {tuple,line('$1'),'$2'}.


%%struct -> atom tuple :
%%	{struct,line('$1'),element(3, '$1'),element(3, '$2')}.


%% N.B. This is called from expr_700.
%% N.B. Field names are returned as the complete object, even if they are
%% always atoms for the moment, this might change in the future.

record_expr -> '#' atom '.' atom :
	{record_index,line('$1'),element(3, '$2'),'$4'}.
record_expr -> '#' atom record_tuple :
	{record,line('$1'),element(3, '$2'),'$3'}.
record_expr -> expr_max '#' atom '.' atom :
	{record_field,line('$2'),'$1',element(3, '$3'),'$5'}.
record_expr -> expr_max '#' atom record_tuple :
	{record,line('$2'),'$1',element(3, '$3'),'$4'}.
record_expr -> expr_max '.' atom :
	{record_field,line('$2'),'$1','$3'}.

record_tuple -> '{' '}' : [].
record_tuple -> '{' record_fields '}' : '$2'.

record_fields -> record_field : ['$1'].
record_fields -> record_field ',' record_fields : ['$1' | '$3'].

record_field -> atom '=' expr : {record_field,line('$1'),'$1','$3'}.


%% N.B. This is called from expr_700.

function_call -> expr_800 argument_list :
	{call,line('$1'),'$1',element(1, '$2')}.


if_expr -> 'if' if_clauses 'end' : {'if',line('$1'),'$2'}.

if_clauses -> if_clause : ['$1'].
if_clauses -> if_clause ';' if_clauses : ['$1' | '$3'].

if_clause -> guard clause_body :
	{clause,line(hd(hd('$1'))),[],'$1','$2'}.


case_expr -> 'case' expr 'of' cr_clauses 'end' :
	{'case',line('$1'),'$2','$4'}.

cr_clauses -> cr_clause : ['$1'].
cr_clauses -> cr_clause ';' cr_clauses : ['$1' | '$3'].

cr_clause -> expr clause_guard clause_body :
	{clause,line('$1'),['$1'],'$2','$3'}.

receive_expr -> 'receive' cr_clauses 'end' :
	{'receive',line('$1'),'$2'}.
receive_expr -> 'receive' 'after' expr clause_body 'end' :
	{'receive',line('$1'),[],'$3','$4'}.
receive_expr -> 'receive' cr_clauses 'after' expr clause_body 'end' :
	{'receive',line('$1'),'$2','$4','$5'}.


fun_expr -> 'fun' atom '/' integer :
	{'fun',line('$1'),{function,element(3, '$2'),element(3, '$4')}}.
fun_expr -> 'fun' fun_clauses 'end' :
	build_fun(line('$1'), '$2').

fun_clauses -> fun_clause : ['$1'].
fun_clauses -> fun_clause ';' fun_clauses : ['$1' | '$3'].

fun_clause -> argument_list clause_guard clause_body :
	{Args,Pos} = '$1',
	{clause,Pos,'fun',Args,'$2','$3'}.


query_expr -> 'query' list_comprehension 'end' :
	{'query',line('$1'),'$2'}.


argument_list -> '(' ')' : {[],line('$1')}.
argument_list -> '(' exprs ')' : {'$2',line('$1')}.


exprs -> expr : ['$1'].
exprs -> expr ',' exprs : ['$1' | '$3'].

guard -> exprs : ['$1'].
guard -> exprs ';' guard : ['$1'|'$3'].

atomic -> integer : '$1'.
atomic -> float : '$1'.
atomic -> atom : '$1'.
atomic -> strings : '$1'.

strings -> string : '$1'.
strings -> string strings :
	{string,line('$1'),element(3, '$1') ++ element(3, '$2')}.

prefix_op -> '+' : '$1'.
prefix_op -> '-' : '$1'.
prefix_op -> 'bnot' : '$1'.
prefix_op -> 'not' : '$1'.

mult_op -> '/' : '$1'.
mult_op -> '*' : '$1'.
mult_op -> 'div' : '$1'.
mult_op -> 'rem' : '$1'.
mult_op -> 'band' : '$1'.
mult_op -> 'and' : '$1'.

add_op -> '+' : '$1'.
add_op -> '-' : '$1'.
add_op -> 'bor' : '$1'.
add_op -> 'bxor' : '$1'.
add_op -> 'bsl' : '$1'.
add_op -> 'bsr' : '$1'.
add_op -> 'or' : '$1'.
add_op -> 'xor' : '$1'.

list_op -> '++' : '$1'.
list_op -> '--' : '$1'.

comp_op -> '==' : '$1'.
comp_op -> '/=' : '$1'.
comp_op -> '=<' : '$1'.
comp_op -> '<' : '$1'.
comp_op -> '>=' : '$1'.
comp_op -> '>' : '$1'.
comp_op -> '=:=' : '$1'.
comp_op -> '=/=' : '$1'.

rule -> rule_clauses : build_rule('$1').

rule_clauses -> rule_clause : ['$1'].
rule_clauses -> rule_clause ';' rule_clauses : ['$1'|'$3'].

rule_clause -> atom clause_args clause_guard rule_body :
	{clause,line('$1'),element(3, '$1'),'$2','$3','$4'}.


rule_args -> argument_list : element(1, '$1').

rule_guard -> 'when' guard : '$2'.
rule_guard -> '$empty' : [].

rule_body -> ':-' lc_exprs: '$2'.


Erlang code.

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

-export([parse_form/1,parse_exprs/1,parse_term/1]).
-export([normalise/1,abstract/1,tokens/1,tokens/2]).
-export([abstract/2]).
-export([inop_prec/1,preop_prec/1,func_prec/0,max_prec/0]).

-compile({inline,[{mkop,3},{mkop,2},{line,1}]}).	%Thrilling!

%% mkop(Op, Arg) -> {op,Line,Op,Arg}.
%% mkop(Left, Op, Right) -> {op,Line,Op,Left,Right}.

mkop(L, {Op,Pos}, R) -> {op,Pos,Op,L,R}.

mkop({Op,Pos}, A) -> {op,Pos,Op,A}.

%% keep track of line info in tokens
line(Tup) -> element(2, Tup).

%% Entry points compatible to old erl_parse.
%% These really suck and are only here until Calle gets multiple
%% entry points working.

parse_form(Tokens) ->
    parse(Tokens).

parse_exprs(Tokens) ->
    case parse([{atom,0,f},{'(',0},{')',0},{'->',0}|Tokens]) of
	{ok,{function,Lf,f,0,[{clause,Lc,[],[],Exprs}]}} ->
	    {ok,Exprs};
	{error,E} -> {error,E}
    end.

parse_term(Tokens) ->
    case parse([{atom,0,f},{'(',0},{')',0},{'->',0}|Tokens]) of
	{ok,{function,Lf,f,0,[{clause,Lc,[],[],[Expr]}]}} ->
	    case catch normalise(Expr) of
		{'EXIT',R} ->
		    {error,{line(Expr),?MODULE,"bad term"}};
		Term -> {ok,Term}
	    end;
	{ok,{function,Lf,f,0,[{clause,Lc,[],[],[E1,E2|Es]}]}} ->
	    {error,{line(E2),?MODULE,"bad term"}};
	{error,E} -> {error,E}
    end.

%% build_attribute(AttrName, AttrValue) ->
%%	{attribute,Line,module,Module}
%%	{attribute,Line,export,Exports}
%%	{attribute,Line,import,Imports}
%%	{attribute,Line,record,{Name,Inits}}
%%	{attribute,Line,file,{Name,Line}}
%%	{attribute,Line,Name,Val}

build_attribute({atom,La,module}, Val) ->
    case Val of
	[{atom,Lm,Module}] -> {attribute,La,module,Module};
	Other -> return_error(La, "bad module declaration")
    end;
build_attribute({atom,La,export}, Val) ->
    case Val of
	[ExpList] ->
	    {attribute,La,export,farity_list(ExpList)};
	Other -> return_error(La, "bad export declaration")
    end;
build_attribute({atom,La,import}, Val) ->
    case Val of
	[{atom,Lm,Mod},ImpList] ->
	    {attribute,La,import,{Mod,farity_list(ImpList)}};
	Other -> return_error(La, "bad import declaration")
    end;
build_attribute({atom,La,record}, Val) ->
    case Val of
	[{atom,Ln,Record},RecTuple] ->
	    {attribute,La,record,{Record,record_tuple(RecTuple)}};
	Other -> return_error(La, "bad record declaration")
    end;
build_attribute({atom,La,file}, Val) ->
    case Val of
	[{string,Ln,Name},{integer,Ll,Line}] ->
	    {attribute,La,file,{Name,Line}};
	Other -> return_error(La, "bad file declaration")
    end;
build_attribute({atom,La,Attr}, Val) ->
    case Val of
	[Expr] ->
	    {attribute,La,Attr,term(Expr)};
	Other -> return_error(La, "bad attribute")
    end.

farity_list({cons,Lc,{op,Lo,'/',{atom,La,A},{integer,Li,I}},Tail}) ->
    [{A,I}|farity_list(Tail)];
farity_list({nil,Ln}) -> [];
farity_list(Other) ->
    return_error(line(Other), "bad function arity").

record_tuple({tuple,Lt,Fields}) ->
    record_fields(Fields);
record_tuple(Other) ->
    return_error(line(Other), "bad record declaration").

record_fields([{atom,La,A}|Fields]) ->
    [{record_field,La,{atom,La,A}}|record_fields(Fields)];
record_fields([{match,Lm,{atom,La,A},Expr}|Fields]) ->
    [{record_field,La,{atom,La,A},Expr}|record_fields(Fields)];
record_fields([Other|Fields]) ->
    return_error(line(Other), "bad record field");
record_fields([]) -> [].

term(Expr) ->
    case catch normalise(Expr) of
	{'EXIT',R} -> return_error(line(Expr), "bad attribute");
	Term -> Term
    end.

%% build_function([Clause]) -> {function,Line,Name,Arity,[Clause]}

build_function(Cs) ->
    Name = element(3, hd(Cs)),
    Arity = length(element(4, hd(Cs))),
    {function,line(hd(Cs)),Name,Arity,check_clauses(Cs, Name, Arity)}.

%% build_rule([Clause]) -> {rule,Line,Name,Arity,[Clause]'}

build_rule(Cs) ->
    Name = element(3, hd(Cs)),
    Arity = length(element(4, hd(Cs))),
    {rule,line(hd(Cs)),Name,Arity,check_clauses(Cs, Name, Arity)}.

%% build_fun(Line, [Clause]) -> {'fun',Line,{clauses,[Clause]}}.

build_fun(Line, Cs) ->
    Arity = length(element(4, hd(Cs))),
    {'fun',Line,{clauses,check_clauses(Cs, 'fun', Arity)}}.

check_clauses(Cs, Name, Arity) ->
     mapl(fun ({clause,L,N,As,G,B}) when N == Name, length(As) == Arity ->
		 {clause,L,As,G,B};
	     ({clause,L,N,As,G,B}) ->
		 return_error(L, "head mismatch") end, Cs).

%% mapl(F,List)
%% an alternative map which always maps from left to right
%% and makes it possible to interrupt the mapping with throw on
%% the first occurence from left as expected.
%% can be removed when the jam machine (and all other machines)
%% uses the standardized (Erlang 5.0) evaluation order (from left to right)
mapl(F, [H|T]) ->
	V = F(H),
	[V | mapl(F,T)];
mapl(_, []) ->
	[].

%% normalise(AbsTerm)
%% abstract(Term)
%%  Convert between the abstract form of a term and a term.

normalise({atom,_,A}) -> A;
normalise({integer,_,I}) -> I;
normalise({float,_,F}) -> F;
normalise({char,_,C}) -> C;
normalise({string,_,S}) -> S;
normalise({nil,_}) -> [];
normalise({bin,_,Fs}) ->
    {value, B, _} =
	eval_bits:expr_grp(Fs, [],
			   fun(E, _) ->
				   {value, normalise(E), []}
			   end, [], true),
    B;
normalise({cons,_,Head,Tail}) ->
    [normalise(Head)|normalise(Tail)];
normalise({tuple,_,Args}) ->
    list_to_tuple(normalise_list(Args));
%% Special case for unary +/-.
normalise({op,_,'+',{integer,_,I}}) -> I;
normalise({op,_,'+',{float,_,F}}) -> F;
normalise({op,_,'-',{integer,_,I}}) -> -I;
normalise({op,_,'-',{float,_,F}}) -> -F.

normalise_list([H|T]) ->
    [normalise(H)|normalise_list(T)];
normalise_list([]) ->
    [].

abstract(T) when atom(T) ->
    {atom,0,T};
abstract(T) when integer(T) ->
    {integer,0,T};
abstract(T) when float(T) ->
    {float,0,T};
abstract([]) ->
    {nil,0};
abstract(B) when binary(B) ->
    {bin, 0, lists:map(fun(Byte) ->
			       {bin_element, 0,
				{integer, 0, Byte}, default, default}
		       end,
		       binary_to_list(B))};
abstract([C|T]) when integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C]);
abstract([H|T]) ->
    {cons,0,abstract(H),abstract(T)};
abstract(Tuple) when tuple(Tuple) ->
    {tuple,0,abstract_list(tuple_to_list(Tuple))}.

abstract_string([C|T], String) when integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C|String]);
abstract_string([], String) ->
    {string, 0, lists:reverse(String)};
abstract_string(T, String) ->
    not_string(String, abstract(T)).

not_string([C|T], Result) ->
    not_string(T, {cons, 0, {integer, 0, C}, Result});
not_string([], Result) ->
    Result.

abstract_list([H|T]) ->
    [abstract(H)|abstract_list(T)];
abstract_list([]) ->
    [].

%%% abstract/2 keeps the line number
abstract(T, Line) when atom(T) ->
    {atom,Line,T};
abstract(T, Line) when integer(T) ->
    {integer,Line,T};
abstract(T, Line) when float(T) ->
    {float,Line,T};
abstract([], Line) ->
    {nil,Line};
abstract(B, Line) when binary(B) ->
    {bin, Line, lists:map(fun(Byte) ->
			       {bin_element, Line,
				{integer, Line, Byte}, default, default}
		       end,
		       binary_to_list(B))};
abstract([C|T], Line) when integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C], Line);
abstract([H|T], Line) ->
    {cons,Line,abstract(H, Line),abstract(T, Line)};
abstract(Tuple, Line) when tuple(Tuple) ->
    {tuple,Line,abstract_list(tuple_to_list(Tuple), Line)}.

abstract_string([C|T], String, Line) when integer(C), 0 =< C, C < 256 ->
    abstract_string(T, [C|String], Line);
abstract_string([], String, Line) ->
    {string, Line, lists:reverse(String)};
abstract_string(T, String, Line) ->
    not_string(String, abstract(T, Line), Line).

not_string([C|T], Result, Line) ->
    not_string(T, {cons, Line, {integer, Line, C}, Result}, Line);
not_string([], Result, Line) ->
    Result.

abstract_list([H|T], Line) ->
    [abstract(H, Line)|abstract_list(T, Line)];
abstract_list([], Line) ->
    [].

%% tokens(AbsTerm) -> [Token]
%% tokens(AbsTerm, More) -> [Token]
%%  Generate a list of tokens representing the abstract term.

tokens(Abs) ->
    tokens(Abs, []).

tokens({atom,L,A}, More) -> [{atom,L,A}|More];
tokens({integer,L,N}, More) -> [{integer,L,N}|More];
tokens({float,L,F}, More) -> [{float,L,F}|More];
tokens({char,L,C}, More) -> [{char,L,C}|More];
tokens({var,L,V}, More) -> [{var,L,V}|More];
tokens({string,L,S}, More) -> [{string,L,S}|More];
tokens({nil,L}, More) -> [{'[',L},{']',L}|More];
tokens({cons,L,Head,Tail}, More) ->
    [{'[',L}|tokens(Head, tokens_tail(Tail, More))];
tokens({tuple,L,[]}, More) ->
    [{'{',L},{'}',L}|More];
tokens({tuple,L,[E|Es]}, More) ->
    [{'{',L}|tokens(E, tokens_tuple(Es, line(E), More))].

tokens_tail({cons,L,Head,Tail}, More) ->
    [{',',L}|tokens(Head, tokens_tail(Tail, More))];
tokens_tail({nil,L}, More) ->
    [{']',L}|More];
tokens_tail(Other, More) ->
    L = line(Other),
    [{'|',L}|tokens(Other, [{']',L}|More])].

tokens_tuple([E|Es], Line, More) ->
    [{',',Line}|tokens(E, tokens_tuple(Es, line(E), More))];
tokens_tuple([], Line, More) ->
    [{'}',Line}|More].

%% Give the relative precedences of operators.

inop_prec('=') -> {200,100,100};
inop_prec('!') -> {200,100,100};
inop_prec('==') -> {300,200,300};
inop_prec('/=') -> {300,200,300};
inop_prec('=<') -> {300,200,300};
inop_prec('<') -> {300,200,300};
inop_prec('>=') -> {300,200,300};
inop_prec('>') -> {300,200,300};
inop_prec('=:=') -> {300,200,300};
inop_prec('=/=') -> {300,200,300};
inop_prec('++') -> {300,300,400};
inop_prec('--') -> {300,300,400};
inop_prec('+') -> {400,400,500};
inop_prec('-') -> {400,400,500};
inop_prec('bor') -> {400,400,500};
inop_prec('bxor') -> {400,400,500};
inop_prec('bsl') -> {400,400,500};
inop_prec('bsr') -> {400,400,500};
inop_prec('or') -> {400,400,500};
inop_prec('xor') -> {400,400,500};
inop_prec('*') -> {500,500,600};
inop_prec('/') -> {500,500,600};
inop_prec('div') -> {500,500,600};
inop_prec('rem') -> {500,500,600};
inop_prec('band') -> {500,500,600};
inop_prec('and') -> {500,500,600};
inop_prec('#') -> {800,700,800};
inop_prec(':') -> {900,800,900}.

preop_prec('catch') -> {0,100};
preop_prec('+') -> {600,700};
preop_prec('-') -> {600,700};
preop_prec('bnot') -> {600,700};
preop_prec('not') -> {600,700};
preop_prec('#') -> {700,800}.

func_prec() -> {800,700}.

max_prec() -> 900.