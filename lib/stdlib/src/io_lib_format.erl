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
-module(io_lib_format).

%% Formatting functions of io library.

-export([fwrite/2,fwrite_g/1,indentation/2]).

-import(string, [chars/2,chars/3]).

%% fwrite(Format, ArgList) -> [Char].
%%  Format the arguments in ArgList after string Format. Just generate
%%  an error if there is an error in the arguments.
%%
%%  To do the printing command correctly we need to calculate the
%%  current indentation for everything before it. This may be very
%%  expensive, especially when it is not needed, so we first determine
%%  if, and for how long, we need to calculate the indentations. We do
%%  this by first collecting all the control sequences and
%%  corresponding arguments, then counting the print sequences and
%%  then building the output.  This method has some drawbacks, it does
%%  two passes over the format string and creates more temporary data,
%%  and it also splits the handling of the control characters into two
%%  parts.

fwrite(Format, Args) when atom(Format) ->
    fwrite(atom_to_list(Format), Args);
fwrite(Format, Args) ->
    Cs = collect(Format, Args),
    Pc = pcount(Cs),
    build(Cs, Pc, 0).

collect([$~|Fmt0], Args0) ->
    {C,Fmt1,Args1} = collect_cseq(Fmt0, Args0),
    [C|collect(Fmt1, Args1)];
collect([C|Fmt], Args) ->
    [C|collect(Fmt, Args)];
collect([], []) -> [].

collect_cseq(Fmt0, Args0) ->
    {F,Ad,Fmt1,Args1} = field_width(Fmt0, Args0),
    {P,Fmt2,Args2} = precision(Fmt1, Args1),
    {Pad,Fmt3,Args3} = pad_char(Fmt2, Args2),
    {C,As,Fmt4,Args4} = collect_cc(Fmt3, Args3),
    {{C,As,F,Ad,P,Pad},Fmt4,Args4}.

field_width([$-|Fmt0], Args0) ->
    {F,Fmt,Args} = field_value(Fmt0, Args0),
    field_width(-F, Fmt, Args);
field_width(Fmt0, Args0) ->
    {F,Fmt,Args} = field_value(Fmt0, Args0),
    field_width(F, Fmt, Args).

field_width(F, Fmt, Args) when F < 0 ->
    {-F,left,Fmt,Args};
field_width(F, Fmt, Args) when F >= 0 ->
    {F,right,Fmt,Args}.

precision([$.|Fmt], Args) ->
    field_value(Fmt, Args);
precision(Fmt, Args) ->
    {none,Fmt,Args}.

field_value([$*|Fmt], [A|Args]) when integer(A) ->
    {A,Fmt,Args};
field_value([C|Fmt], Args) when C >= $0, C =< $9 ->
    field_value([C|Fmt], Args, 0);
field_value(Fmt, Args) ->
    {none,Fmt,Args}.

field_value([C|Fmt], Args, F) when C >= $0, C =< $9 ->
    field_value(Fmt, Args, 10*F + (C - $0));
field_value(Fmt, Args, F) ->		%Default case
    {F,Fmt,Args}.

pad_char([$.,$*|Fmt], [Pad|Args]) -> {Pad,Fmt,Args};
pad_char([$.,Pad|Fmt], Args) -> {Pad,Fmt,Args};
pad_char(Fmt, Args) -> {$\s,Fmt,Args}.

%% collect_cc([FormatChar], [Argument]) ->
%%	{Control,[ControlArg],[FormatChar],[Arg]}.
%%  Here we collect the argments for each control character.
%%  Be explicit to cause failure early.

collect_cc([$w|Fmt], [A|Args]) -> {$w,[A],Fmt,Args};
collect_cc([$p|Fmt], [A|Args]) -> {$p,[A],Fmt,Args};
collect_cc([$W|Fmt], [A,Depth|Args]) -> {$W,[A,Depth],Fmt,Args};
collect_cc([$P|Fmt], [A,Depth|Args]) -> {$P,[A,Depth],Fmt,Args};
collect_cc([$s|Fmt], [A|Args]) -> {$s,[A],Fmt,Args};
collect_cc([$e|Fmt], [A|Args]) -> {$e,[A],Fmt,Args};
collect_cc([$f|Fmt], [A|Args]) -> {$f,[A],Fmt,Args};
collect_cc([$g|Fmt], [A|Args]) -> {$g,[A],Fmt,Args};
collect_cc([$c|Fmt], [A|Args]) -> {$c,[A],Fmt,Args};
collect_cc([$~|Fmt], Args) -> {$~,[],Fmt,Args};
collect_cc([$n|Fmt], Args) -> {$n,[],Fmt,Args};
collect_cc([$i|Fmt], [A|Args]) -> {$i,[A],Fmt,Args}.

%% pcount([ControlC]) -> Count.
%%  Count the number of print requests.

pcount(Cs) -> pcount(Cs, 0).

pcount([{$p,As,F,Ad,P,Pad}|Cs], Acc) -> pcount(Cs, Acc+1);
pcount([{$P,As,F,Ad,P,Pad}|Cs], Acc) -> pcount(Cs, Acc+1);
pcount([C|Cs], Acc) -> pcount(Cs, Acc);
pcount([], Acc) -> Acc.

%% build([Control], Pc, Indentation) -> [Char].
%%  Interpret the control structures. Count the number of print
%%  remaining and only calculate indentation when necessary. Must also
%%  be smart when calculating indentation for characters in format.

build([{C,As,F,Ad,P,Pad}|Cs], Pc0, I) ->
    S = control(C, As, F, Ad, P, Pad, I),
    Pc1 = decr_pc(C, Pc0),
    if
	Pc1 > 0 -> [S|build(Cs, Pc1, indentation(S, I))];
	true -> [S|build(Cs, Pc1, I)]
    end;
build([$\n|Cs], Pc, I) -> [$\n|build(Cs, Pc, 0)];
build([$\t|Cs], Pc, I) -> [$\t|build(Cs, Pc, ((I + 8) div 8) * 8)];
build([C|Cs], Pc, I) -> [C|build(Cs, Pc, I+1)];
build([], Pc, I) -> [].

decr_pc($p, Pc) -> Pc - 1;
decr_pc($P, Pc) -> Pc - 1;
decr_pc(C, Pc) -> Pc.

%% control(FormatChar, [Argument], FieldWidth, Adjust, Precision, PadChar,
%%	   Indentation) ->
%%	[Char]
%%  This is the main dispatch function for the various formatting commands.
%%  Field widths and precisions have already been calculated.

control($w, [A], F, Adj, P, Pad, I) ->
    term(io_lib:write(A, -1), F, Adj, P, Pad);
control($p, [A], F, Adj, P, Pad, I) ->
    print(A, -1, F, Adj, P, Pad, I);
control($W, [A,Depth], F, Adj, P, Pad, I) when integer(Depth) ->
    term(io_lib:write(A, Depth), F, Adj, P, Pad);
control($P, [A,Depth], F, Adj, P, Pad, I) when integer(Depth) ->
    print(A, Depth, F, Adj, P, Pad, I);
control($s, [A], F, Adj, P, Pad, I) when atom(A) ->
    string(atom_to_list(A), F, Adj, P, Pad);
control($s, [L], F, Adj, P, Pad, I) ->
    true = io_lib:deep_char_list(L),		%Check if L a character list
    string(L, F, Adj, P, Pad);
control($e, [A], F, Adj, P, Pad, I) when float(A) ->
    fwrite_e(A, F, Adj, P, Pad);
control($f, [A], F, Adj, P, Pad, I) when float(A) ->
    fwrite_f(A, F, Adj, P, Pad);
control($g, [A], F, Adj, P, Pad, I) when float(A) ->
    fwrite_g(A, F, Adj, P, Pad);
control($c, [A], F, Adj, P, Pad, I) when integer(A) ->
    char(A band 255, F, Adj, P, Pad);
control($~, [], F, Adj, P, Pad, I) -> char($~, F, Adj, P, Pad);
control($n, [], F, Adj, P, Pad, I) -> newline(F, Adj, P, Pad);
control($i, [A], F, Adj, P, Pad, I) -> [].

%% indentation([Char], Indentation) -> Indentation.
%%  Calculate the indentation of the end of a string given its start
%%  indentation. We assume tabs at 8 cols.

indentation([$\n|Cs], I) -> indentation(Cs, 0);
indentation([$\t|Cs], I) -> indentation(Cs, ((I + 8) div 8) * 8);
indentation([C|Cs], I) when integer(C) ->
    indentation(Cs, I+1);
indentation([C|Cs], I) ->
    indentation(Cs, indentation(C, I));
indentation([], I) -> I.

%% term(TermList, Field, Adjust, Precision, PadChar)
%%  Output the characters in a term.

term(T, none, Adj, none, Pad) -> T;
term(T, none, Adj, P, Pad) -> term(T, P, Adj, P, Pad);
term(T, F, Adj, none, Pad) -> term(T, F, Adj, min(flat_length(T), F), Pad);
term(T, F, Adj, P, Pad) when F >= P ->
    adjust_error(T, F, Adj, P, Pad).

%% print(Term, Depth, Field, Adjust, Precision, PadChar, Indentation)
%%  Print a term.

print(T, D, none, Adj, P, Pad, I) -> print(T, D, 80, Adj, P, Pad, I);
print(T, D, F, Adj, none, Pad, I) -> print(T, D, F, Adj, I+1, Pad, I);
print(T, D, F, right, P, Pad, I) ->
    io_lib_pretty:print(T, P, F, D).

%% fwrite_e(Float, Field, Adjust, Precision, PadChar)

fwrite_e(Fl, none, Adj, none, Pad) ->		%Default values
    fwrite_e(Fl, none, Adj, 6, Pad);
fwrite_e(Fl, none, Adj, P, Pad) when P >= 2 ->
    float_e(Fl, float_data(Fl), P);
fwrite_e(Fl, F, Adj, none, Pad) ->
    fwrite_e(Fl, F, Adj, 6, Pad);
fwrite_e(Fl, F, Adj, P, Pad) when P >= 2 ->
    adjust_error(float_e(Fl, float_data(Fl), P), F, Adj, F, Pad).

float_e(Fl, Fd, P) when Fl < 0.0 ->		%Negative numbers
    [$-|float_e(-Fl, Fd, P)];
float_e(Fl, {Ds,E}, P) ->
    case float_man(Ds, 1, P-1) of
	{[$0|Fs],true} -> [[$1|Fs]|float_exp(E)];
	{Fs,false} -> [Fs|float_exp(E-1)]
    end.

%% float_man([Digit], Icount, Dcount) -> {[Chars],CarryFlag}.
%%  Generate the characters in the mantissa from the digits with Icount
%%  characters before the '.' and Dcount decimals. Handle carry and let
%%  caller decide what to do at top.

float_man(Ds, 0, Dc) ->
    {Cs,C} = float_man(Ds, Dc),
    {[$.|Cs],C};
float_man([D|Ds], I, Dc) ->
    case float_man(Ds, I-1, Dc) of
	{Cs,true} when D == $9 -> {[$0|Cs],true};
	{Cs,true} -> {[D+1|Cs],false};
	{Cs,false} -> {[D|Cs],false}
    end;
float_man([], I, Dc) ->				%Pad with 0's
    {chars($0, I, [$.|chars($0, Dc)]),false}.

float_man([D|Ds], 0) when D >= $5 -> {[],true};
float_man([D|Ds], 0) -> {[],false};
float_man([D|Ds], Dc) ->
    case float_man(Ds, Dc-1) of
	{Cs,true} when D == $9 -> {[$0|Cs],true};
	{Cs,true} -> {[D+1|Cs],false}; 
	{Cs,false} -> {[D|Cs],false}
    end;
float_man([], Dc) -> {chars($0, Dc),false}.	%Pad with 0's

%% float_exp(Exponent) -> [Char].
%%  Generate the exponent of a floating point number. Alwayd include sign.

float_exp(E) when E >= 0 ->
    [$e,$+|integer_to_list(E)];
float_exp(E) ->
    [$e|integer_to_list(E)].

%% fwrite_f(FloatData, Field, Adjust, Precision, PadChar)

fwrite_f(Fl, none, Adj, none, Pad) ->		%Default values
    fwrite_f(Fl, none, Adj, 6, Pad);
fwrite_f(Fl, none, Adj, P, Pad) when P >= 1 ->
    float_f(Fl, float_data(Fl), P);
fwrite_f(Fl, F, Adj, none, Pad) ->
    fwrite_f(Fl, F, Adj, 6, Pad);
fwrite_f(Fl, F, Adj, P, Pad) when P >= 1 ->
    adjust_error(float_f(Fl, float_data(Fl), P), F, Adj, F, Pad).

float_f(Fl, Fd, P) when Fl < 0.0 ->
    [$-|float_f(-Fl, Fd, P)];
float_f(Fl, {Ds,E}, P) when E =< 0 ->
    float_f(Fl, {chars($0, -E+1, Ds),1}, P);	%Prepend enough 0's
float_f(Fl, {Ds,E}, P) ->
    case float_man(Ds, E, P) of
	{Fs,true} -> "1" ++ Fs;			%Handle carry
	{Fs,false} -> Fs
    end.

%% float_data([FloatChar]) -> {[Digit],Exponent}

float_data(Fl) ->
    float_data(float_to_list(Fl), []).

float_data([$e|E], Ds) ->
    {reverse(Ds),list_to_integer(E)+1};
float_data([D|Cs], Ds) when D >= $0, D =< $9 ->
    float_data(Cs, [D|Ds]);
float_data([D|Cs], Ds) ->
    float_data(Cs, Ds).

%% fwrite_g(Float)
%% fwrite_g(Float, Field, Adjust, Precision, PadChar)
%%  Use the f form if Float is > 0.1 and < 10^4, else the e form.
%%  Precision always means the # of significant digits.

fwrite_g(Fl) ->
    fwrite_g(Fl, none, right, none, $\s).

fwrite_g(Fl, F, Adj, none, Pad) ->
    fwrite_g(Fl, F, Adj, 6, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 0.1 ->
    fwrite_e(Fl, F, Adj, P, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 1.0 ->
    fwrite_f(Fl, F, Adj, P, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 10.0 ->
    fwrite_f(Fl, F, Adj, P-1, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 100.0 ->
    fwrite_f(Fl, F, Adj, P-2, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 1000.0 ->
    fwrite_f(Fl, F, Adj, P-3, Pad);
fwrite_g(Fl, F, Adj, P, Pad) when abs(Fl) < 10000.0 ->
    fwrite_f(Fl, F, Adj, P-4, Pad);
fwrite_g(Fl, F, Adj, P, Pad) ->
    fwrite_e(Fl, F, Adj, P, Pad).

%% string(String, Field, Adjust, Precision, PadChar)

string(S, none, Adj, none, Pad) -> S;
string(S, F, Adj, none, Pad) ->
    string(S, F, Adj, min(flat_length(S), F), Pad);
string(S, none, Adj, P, Pad) ->
    string:left(flatten(S), P, Pad);
string(S, F, Adj, P, Pad) when F >= P ->
    adjust(string:left(flatten(S), P, Pad), chars(Pad, F - P), Adj).

%% char(Char, Field, Adjust, Precision, PadChar) -> [Char].

char(C, none, Adj, none, Pad) -> [C];
char(C, F, Adj, none, Pad) -> chars(C, F);
char(C, none, Adj, P, Pad) -> chars(C, P);
char(C, F, Adj, P, Pad) when F >= P ->
    adjust(chars(C, P), chars(Pad, F - P), Adj).

%% newline(Field, Adjust, Precision, PadChar) -> [Char].

newline(none, Adj, P, Pad) -> "\n";
newline(F, right, P, Pad) -> chars($\n, F).

%% adjust_error([Char], Field, Adjust, Max, PadChar) -> [Char].
%%  Adjust the characters within the field if length less than Max padding
%%  with PadChar.

adjust_error(Cs, F, Adj, M, Pad) ->
    L = flat_length(Cs),
    if
	L > M ->
	    adjust(chars($*, M), chars(Pad, F - M), Adj);
	true ->
	    adjust(Cs, chars(Pad, F - L), Adj)
    end.

adjust(Data, Pad, left) -> [Data,Pad];
adjust(Data, Pad, right) -> [Pad,Data].

%%
%% Utilities
%%

reverse(List) ->
    reverse(List, []).

reverse([H|T], Stack) ->
    reverse(T, [H|Stack]);
reverse([], Stack) -> Stack.

min(L, R) when L < R -> L;
min(L, R) -> R.

%% flatten(List)
%%  Flatten a list.

flatten(List) -> flatten(List, []).

flatten([H|T], Cont) when list(H) ->
    flatten(H, [T|Cont]);
flatten([H|T], Cont) ->
    [H|flatten(T, Cont)];
flatten([], [H|Cont]) -> flatten(H, Cont);
flatten([], []) -> [].

%% flat_length(List)
%%  Calculate the length of a list of lists.

flat_length(List) -> flat_length(List, 0).

flat_length([H|T], L) when list(H) ->
    flat_length(H, flat_length(T, L));
flat_length([H|T], L) ->
    flat_length(T, L + 1);
flat_length([], L) -> L.
