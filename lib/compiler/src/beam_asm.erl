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
%% Purpose : Assembler for threaded Beam.

-module(beam_asm).

-export([module/3,format_error/1]).
-export([objfile_extension/0]).
-export([encode/2]).

-include("beam_opcodes.hrl").

module(Code, Abst, Opts) ->
    case catch assemble(Code, Abst, Opts) of
	{'EXIT', What} ->
	    {error, [{none, ?MODULE, {crashed, What}}]};
	{error, Error} ->
	    {error, [{none, ?MODULE, Error}]};
	Bin when binary(Bin) ->
	    {ok, Bin}
    end.

objfile_extension() ->
    ".beam".

format_error({too_big, Number, Bits}) ->
    io_lib:format("[Internal error] Number '~p' too big to represent in ~p bits",
		  [Number, Bits]);
format_error({crashed, Why}) ->
    io_lib:format("beam_asm_int: EXIT: ~p", [Why]).

assemble({Mod,Exp,Attr,Asm,NumLabels}, Abst, Opts) ->
    {1,Dict0} = beam_dict:atom(Mod, beam_dict:new()),
    assemble(Exp, Attr, Asm, NumLabels, Dict0, Abst, Opts).

assemble(Exp, Attr, Asm, NumLabels, Dict0, Abst, Opts) ->
    %% Divided into two functions to avoid saving Asm on the stack.  (Hack!)
    NumFuncs = length(Asm),
    {Code,Dict1} = assemble(Asm, Exp, Dict0, []),
    build_file(Code, Attr, Dict1, NumLabels, NumFuncs, Abst, Opts).

assemble([{function, Name, Arity, Entry, Asm}| T], Exp, Dict0, Acc) ->
    Dict1 = case lists:member({Name, Arity}, Exp) of
		true ->
		    beam_dict:export(Name, Arity, Entry, Dict0);
		false ->
		    beam_dict:local(Name, Arity, Entry, Dict0)
	    end,
    {Code, Dict2} = assemble_function(Asm, Acc, Dict1),
    assemble(T, Exp, Dict2, Code);
assemble([], Exp, Dict0, Acc) ->
    {IntCodeEnd, Dict1} = make_op(int_code_end, Dict0),
    {list_to_binary(lists:reverse(Acc, [IntCodeEnd])), Dict1}.

assemble_function([H|T], Acc, Dict0) ->
    {Code, Dict} = make_op(H, Dict0),
    assemble_function(T, [Code| Acc], Dict);
assemble_function([], Code, Dict) ->
    {Code, Dict}.

build_file(Code, Attr, Dict, NumLabels, NumFuncs, Abst, Opts) ->
    %% Create the code chunk.

    CodeChunk = chunk("Code",
		      [opcode_int32(16),
		       opcode_int32(beam_opcodes:format_number()),
		       opcode_int32(beam_dict:highest_opcode(Dict)),
		       opcode_int32(NumLabels),
		       opcode_int32(NumFuncs)],
		      Code),

    %% Create the atom table chunk.

    {NumAtoms, AtomTab} = beam_dict:atom_table(Dict),
    AtomChunk = chunk("Atom", opcode_int32(NumAtoms), AtomTab),

    %% Create the import table chunk.

    {NumImps, ImpTab0} = beam_dict:import_table(Dict),
    Imp = flatten_imports(ImpTab0),
    ImportChunk = chunk("ImpT", opcode_int32(NumImps), Imp),

    %% Create the export table chunk.

    {NumExps, ExpTab0} = beam_dict:export_table(Dict),
    Exp = flatten_exports(ExpTab0),
    ExpChunk = chunk("ExpT", opcode_int32(NumExps), Exp),

    %% Create the local function table chunk.

    {NumLocals, Locals} = beam_dict:local_table(Dict),
    Loc = flatten_exports(Locals),
    LocChunk = chunk("LocT", opcode_int32(NumLocals), Loc),

    %% Create the string table chunk.

    {StringSize, StringTab} = beam_dict:string_table(Dict),
    StringChunk = chunk("StrT", StringTab),

    %% Create the attributes and compile info chunks.

    Essentials = [AtomChunk, CodeChunk, StringChunk, ImportChunk, ExpChunk],
    {Attributes, Compile} = build_attributes(Opts, Attr, Essentials),
    AttrChunk = chunk("Attr", Attributes),
    CompileChunk = chunk("CInf", Compile),

    %% Create the abstract code chunk.

    AbstChunk = chunk("Abst", Abst),

    %% Create IFF chunk.

    build_form("BEAM", [Essentials,
			LocChunk,
			AttrChunk,
			CompileChunk,
			build_flags(Opts, []),
			AbstChunk]).

%% Build an IFF form.

build_form(Id, Chunks0) when length(Id) == 4, list(Chunks0) ->
    Chunks = list_to_binary(Chunks0),
    Size = size(Chunks),
    0 = Size rem 4,				% Assertion: correct padding?
    list_to_binary(["FOR1", opcode_int32(Size+4), Id|Chunks]).

%% Build a correctly padded chunk (with no sub-header).

chunk(Id, Contents) when length(Id) == 4, binary(Contents) ->
    Size = size(Contents),
    [Id, opcode_int32(Size), Contents| pad(Size)];
chunk(Id, Contents) when list(Contents) ->
    chunk(Id, list_to_binary(Contents)).

%% Build a correctly padded chunk (with a sub-header).

chunk(Id, Head, Contents) when length(Id) == 4, binary(Head), binary(Contents) ->
    Size = size(Head)+size(Contents),
    [Id, opcode_int32(Size), Head, Contents| pad(Size)];
chunk(Id, Head, Contents) when list(Head) ->
    chunk(Id, list_to_binary(Head), Contents);
chunk(Id, Head, Contents) when list(Contents) ->
    chunk(Id, Head, list_to_binary(Contents)).

pad(Size) ->
    case Size rem 4 of
	0 -> [];
	Rem -> lists:duplicate(4 - Rem, 0)
    end.

build_flags([trace|T], Acc) ->
    build_flags(T, [chunk("Trac", [])|Acc]);
build_flags([_|T], Acc) ->
    build_flags(T, Acc);
build_flags([], Acc) ->
    list_to_binary(Acc).

flatten_exports(Exps) ->
    F = fun({F, A, L}) -> [opcode_int32(F), opcode_int32(A), opcode_int32(L)] end,
    list_to_binary(lists:map(F, Exps)).

flatten_imports(Imps) ->
    F = fun({M, F, A}) -> [opcode_int32(M), opcode_int32(F), opcode_int32(A)] end,
    list_to_binary(lists:map(F, Imps)).

build_attributes(Opts, Attr, Essentials) ->
    {{Y,Mo,D},{H,Mi,S}} = erlang:universaltime(),
    Compile = [{time,{Y,Mo,D,H,Mi,S}},{options,Opts}],
    {term_to_binary(calc_vsn(Attr, Essentials)),term_to_binary(Compile)}.

%%
%% If the attributes contains no 'vsn' attribute, we'll insert one
%% with an MD5 "checksum" calculated on the code as its value.
%% We'll not change an existing 'vsn' attribute.
%%

calc_vsn(Attr, Essentials) ->
    case lists:keymember(vsn, 1, Attr) of
	true ->
	    Attr;
	false ->
	    case catch erlang:md5(Essentials) of
		{'EXIT', _} ->
		    Attr;
		MD5 when binary(MD5) ->
		    Number = list_to_number(binary_to_list(MD5), 0),
		    [{vsn, [Number]}|Attr]
	    end
    end.

list_to_number([H|T], Acc) ->
    list_to_number(T, Acc bsl 8 bor H);
list_to_number([], Acc) ->
    Acc.

opcode_int32(I) when I > 16#ffffffff ->
    throw({error, {too_big, I, 32}});
opcode_int32(I) ->
    [(I bsr 24) band 16#ff,
     (I bsr 16) band 16#ff,
     (I bsr 8) band 16#ff,
     I band 16#ff].

bif_type('-', 1)    -> negate;
bif_type('+', 2)    -> {op, m_plus};
bif_type('-', 2)    -> {op, m_minus};
bif_type('*', 2)    -> {op, m_times};
bif_type('/', 2)    -> {op, m_div};
bif_type('div', 2)  -> {op, int_div};
bif_type('rem', 2)  -> {op, int_rem};
bif_type('band', 2) -> {op, int_band};
bif_type('bor', 2)  -> {op, int_bor};
bif_type('bxor', 2) -> {op, int_bxor};
bif_type('bsl', 2)  -> {op, int_bsl};
bif_type('bsr', 2)  -> {op, int_bsr};
bif_type('bnot', 1) -> {op, int_bnot};
bif_type(_, _)      -> bif.

make_op(Comment, Dict) when element(1, Comment) == '%' ->
    {[], Dict};
make_op({'%live',R}, Dict) ->
    {[], Dict};
make_op({bif, Bif, nofail, [], Dest}, Dict) ->
    encode_op(bif0, [{extfunc, erlang, Bif, 0}, Dest], Dict);
make_op({bif, Bif, Fail, Args, Dest}, Dict) ->
    Arity = length(Args),
    case bif_type(Bif, Arity) of
	{op, Op} ->
	    make_op(list_to_tuple([Op, Fail|Args++[Dest]]), Dict);
	negate ->
	    %% Fake negation operator.
	    make_op({m_minus, Fail, {integer,0}, hd(Args), Dest}, Dict);
	bif ->
	    BifOp = list_to_atom(lists:concat([bif, Arity])),
	    encode_op(BifOp, [Fail, {extfunc, erlang, Bif, Arity}|Args++[Dest]],
		      Dict)
    end;
make_op({test, Cond, Fail, Src}, Dict) ->
    make_op({Cond, Fail, Src}, Dict);
make_op({test, Cond, Fail, S1, S2}, Dict) ->
    make_op({Cond, Fail, S1, S2}, Dict);
make_op(Op, Dict) when atom(Op) ->
    encode_op(Op, [], Dict);
make_op({Name, Arg1}, Dict) ->
    encode_op(Name, [Arg1], Dict);
make_op({Name, Arg1, Arg2}, Dict) ->
    encode_op(Name, [Arg1, Arg2], Dict);
make_op({Name, Arg1, Arg2, Arg3}, Dict) ->
    encode_op(Name, [Arg1, Arg2, Arg3], Dict);
make_op({Name, Arg1, Arg2, Arg3, Arg4}, Dict) ->
    encode_op(Name, [Arg1, Arg2, Arg3, Arg4], Dict);
make_op({Name, Arg1, Arg2, Arg3, Arg4, Arg5}, Dict) ->
    encode_op(Name, [Arg1, Arg2, Arg3, Arg4, Arg5], Dict);
make_op({Name, Arg1, Arg2, Arg3, Arg4, Arg5, Arg6}, Dict) ->
    encode_op(Name, [Arg1, Arg2, Arg3, Arg4, Arg5, Arg6], Dict).

encode_op(Name, Args, Dict0) when atom(Name) ->
    {EncArgs, Dict1} = encode_args(Args, Dict0),
    Op = beam_opcodes:opcode(Name, length(Args)),
    Dict2 = beam_dict:opcode(Op, Dict1),
    {[Op| EncArgs], Dict2}.

encode_args([Arg| T], Dict0) ->
    {EncArg, Dict1} = encode_arg(Arg, Dict0),
    {EncTail, Dict2} = encode_args(T, Dict1),
    {[EncArg| EncTail], Dict2};
encode_args([], Dict) ->
    {[], Dict}.

encode_arg({x, X}, Dict) ->
    {encode(?tag_x, X), Dict};
encode_arg({y, Y}, Dict) ->
    {encode(?tag_y, Y), Dict};
encode_arg({atom, Atom}, Dict0) when atom(Atom) ->
    {Index, Dict} = beam_dict:atom(Atom, Dict0),
    {encode(?tag_a, Index), Dict};
encode_arg({i, N}, Dict) ->
    {encode(?tag_i, N), Dict};
encode_arg({integer, N}, Dict) ->
    {encode(?tag_i, N), Dict};
encode_arg(nil, Dict) ->
    {encode(?tag_a, 0), Dict};
encode_arg({f, W}, Dict) ->
    {encode(?tag_f, W), Dict};
encode_arg({arity, Arity}, Dict) ->
    {encode(?tag_u, Arity), Dict};
encode_arg({'char', C}, Dict) ->
    {encode(?tag_h, C), Dict};
encode_arg({string, String}, Dict0) ->
    {Offset, Dict} = beam_dict:string(String, Dict0),
    {encode(?tag_u, Offset), Dict};
encode_arg({bignum, Arity, Sign}, Dict) when 0 =< Sign, Sign =< 1  ->
    {encode(?tag_u, Arity * 2 + Sign), Dict};
encode_arg({bignum_part, Part}, Dict) ->
    {encode(?tag_u, Part), Dict};
encode_arg({extfunc, M, F, A}, Dict0) ->
    {Index, Dict} = beam_dict:import(M, F, A, Dict0),
    {encode(?tag_u, Index), Dict};
encode_arg({old_list, List}, Dict) ->
    encode_list(List, Dict, []);
encode_arg({list, List}, Dict0) ->
    {L, Dict} = encode_list(List, Dict0, []),
    {[encode(?tag_z, 1), encode(?tag_u, length(List))|L], Dict};
encode_arg({float, Float}, Dict) when float(Float) ->
    {[encode(?tag_z, 0)|float_to_bytes(Float)], Dict};
encode_arg(Float, Dict) when float(Float) ->
    {[encode(?tag_z, 0)|float_to_bytes(Float)], Dict};
encode_arg(Int, Dict) when integer(Int) ->
    {encode(?tag_u, Int), Dict};
encode_arg(Atom, Dict0) when atom(Atom) ->
    {Index, Dict} = beam_dict:atom(Atom, Dict0),
    {encode(?tag_a, Index), Dict};
encode_arg(Other, Dict) ->
    exit({badarg, encode_arg, [Other]}).

encode_list([H|T], Dict, Acc) when list(H) ->
    exit({illegal_nested_listed, encode_arg, [H|T]});
encode_list([H|T], Dict0, Acc) ->
    {Enc, Dict} = encode_arg(H, Dict0),
    encode_list(T, Dict, [Enc|Acc]);
encode_list([], Dict, Acc) ->
    {lists:reverse(Acc), Dict}.

encode(Tag, N) when N < 0 ->
    encode1(Tag, negative_to_bytes(N, []));
encode(Tag, N) when N < 16 ->
    (N bsl 4) bor Tag;
encode(Tag, N) when N < 16#800  ->
    [((N bsr 3) band 2#11100000) bor Tag bor 2#00001000, N band 16#ff];
encode(Tag, N) ->
    encode1(Tag, to_bytes(N, [])).

encode1(Tag, Bytes) ->
    case length(Bytes) of
	Num when 2 =< Num, Num =< 8 ->
	    [((Num-2) bsl 5) bor 2#00011000 bor Tag| Bytes];
	Num when 8 < Num ->
	    [2#11111000 bor Tag, encode(?tag_u, Num-9)| Bytes]
    end.

to_bytes(0, [B|Acc]) when B < 128 ->
    [B|Acc];
to_bytes(N, Acc) ->
    to_bytes(N bsr 8, [N band 16#ff| Acc]).

negative_to_bytes(-1, [B1, B2|T]) when B1 > 127 ->
    [B1, B2|T];
negative_to_bytes(N, Acc) ->
    negative_to_bytes(N bsr 8, [N band 16#ff|Acc]).

float_to_bytes(F) when float(F) ->
    {High, Low} =
	case erlang:float_to_words(1.0) of
	    {0, _} ->				% Little-endian.
		{B1, B2} = erlang:float_to_words(F),
		{B2, B1};
	_ ->					% Big-endian.
	    erlang:float_to_words(F)
    end,
    Mask = 16#FFFFffff,
    float_to_bytes((High band Mask) bsl 32 bor (Low band Mask), 8, []).

float_to_bytes(0, 0, Acc) ->
    Acc;
float_to_bytes(N, Count, Acc) ->
    float_to_bytes(N bsr 8, Count-1, [N band 16#ff| Acc]).

