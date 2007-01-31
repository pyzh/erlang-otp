%% -*- erlang-indent-level: 2 -*-
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Copyright (c) 2001 by Erik Johansson.  All Rights Reserved 
%% ====================================================================
%%  Filename : 	hipe_icode_primops.erl
%%  Module   :	hipe_icode_primops
%%  Purpose  :  
%%  Notes    : 
%%  History  :	* 2001-06-13 Erik Johansson (happi@csd.uu.se): 
%%               Created.
%%
%% $Id$
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(hipe_icode_primops).

-export([is_safe/1, fails/1, pp/2, type/1, type/2]).

-include("hipe_icode_primops.hrl").

%%---------------------------------------------------------------------

%% Note that 'unsafe_...' operations are generally "safe", i.e., it is
%% typically unsafe to use them unless you have extra information about
%% the call (e.g., if the types are known). However, if they have been
%% correctly introduced in the code, most of them are also OK to remove
%% if the result is not used.

is_safe('+') -> false;           % XXX: Correct?
is_safe(call_fun) -> false;      % XXX: Correct?
is_safe(check_get_msg) -> false; % XXX: Correct?
is_safe(clear_timeout) -> false; % XXX: Correct?
is_safe(cons) -> true;
%% is_safe(conv_to_float) -> false; % XXX: Correct?
is_safe(extra_unsafe_add) -> true;
is_safe(extra_unsafe_sub) -> true;
is_safe(fcheckerror) -> false;   % XXX: Correct?
is_safe(fclearerror) -> false;   % XXX: Correct?
is_safe(fp_add) -> false;        % XXX: Correct?
is_safe(fp_div) -> false;        % XXX: Correct?
is_safe(fp_mul) -> false;        % XXX: Correct?
is_safe(fp_sub) -> false;        % XXX: Correct?
is_safe(mktuple) -> true;
is_safe(next_msg) -> false;      % XXX: Correct?
is_safe(redtest) -> false;       % XXX: Correct?
is_safe(select_msg) -> false;    % XXX: Correct?
is_safe(self) -> true;
is_safe(set_timeout) -> false;   % XXX: Correct?
is_safe(suspend_msg) -> false;   % XXX: Correct?
is_safe(unsafe_add) -> true;
is_safe(unsafe_band) -> true;
is_safe(unsafe_bnot) -> true;
is_safe(unsafe_bor) -> true;
%% is_safe(unsafe_bsl) -> true;  % XXX: Correct?
%% is_safe(unsafe_bsr) -> true;  % XXX: Correct?
is_safe(unsafe_bxor) -> true;
is_safe(unsafe_hd) -> true;
is_safe(unsafe_sub) -> true;
is_safe(unsafe_tag_float) -> true;
is_safe(unsafe_tl) -> true;
is_safe(unsafe_untag_float) -> true;
is_safe(#apply_N{}) -> false;    % XXX: Correct?
is_safe(#closure_element{}) -> true;
%% is_safe(#element{}) -> false;                            % XXX: Correct?
%% is_safe({hipe_bs_primop, bs_bits_to_bytes}) -> false;    % XXX: Correct?
%% is_safe({hipe_bs_primop, bs_bits_to_bytes2}) -> false;   % XXX: Correct?
is_safe({hipe_bs_primop, bs_final2}) -> true;
%% is_safe({hipe_bs_primop, bs_start_match}) -> false;	    % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_add,_}}) -> false;          % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_add,_,_}}) -> false;        % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_get_binary,_,_}}) -> false; % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_get_binary_all,_}}) -> false; % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_get_integer,_,_}}) -> false; % XXX: Correct?
is_safe({hipe_bs_primop, {bs_create_space,_,_}}) -> false;  % XXX: Correct?
is_safe({hipe_bs_primop, {bs_init2,_}}) -> true;            % XXX: Correct?
is_safe({hipe_bs_primop, {bs_init2,_,_}}) -> true;          % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_binary,_,_}}) -> false;    % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_binary_all,_}}) -> false;  % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_float,_,_,_}}) -> false;   % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_integer,_,_,_}}) -> false; % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_string,_,_}}) -> false;    % XXX: Correct?
is_safe({hipe_bs_primop, {bs_put_string,_,_,_}}) -> false;  % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_skip_bits,_}}) -> false;    % XXX: Correct?
%% is_safe({hipe_bs_primop, {bs_skip_bits_all,_}}) -> false;% XXX: Correct?
is_safe({hipe_bs_primop, {bs_test_tail,_}}) -> false;       % XXX: Correct?
is_safe({hipe_bs_primop, {unsafe_bs_put_integer,_,_,_}}) -> false; % XXX: Correct?
%% is_safe({hipe_bs_primop2,{bs_get_binary_2,_,_}}) -> false; % XXX: Correct?
is_safe({hipe_bs_primop2,{bs_get_binary_all_2,_,_}}) -> false; % XXX: Correct?
%% is_safe({hipe_bs_primop2,{bs_get_float_2,_,_}}) -> false; % XXX: Correct?
is_safe({hipe_bs_primop2,{bs_get_integer_2,_,_}}) -> false; % XXX: Correct?
is_safe({hipe_bs_primop2,{bs_restore_2,_}}) -> true;
is_safe({hipe_bs_primop2,{bs_save_2,_}}) -> true;
is_safe({hipe_bs_primop2,{bs_skip_bits_2,_}}) -> false;     % XXX: Correct?
is_safe({hipe_bs_primop2,{bs_skip_bits_all_2,_,_}}) -> false; % XXX: Correct?
%% is_safe({hipe_bs_primop2,{bs_start_match_2,_}}) -> false;  % XXX: Correct?
is_safe({hipe_bs_primop2,{bs_test_tail_2,_}}) -> false;     % XXX: Correct?
is_safe({hipe_bsi_primop, bs_add}) -> false;                % XXX: Correct?
is_safe({hipe_bsi_primop, bs_div_test}) -> true;            % XXX: Correct?
is_safe({hipe_bsi_primop, bs_get_orig}) -> true;            % XXX: Correct?
is_safe({hipe_bsi_primop, bs_get_orig_offset}) -> true;
is_safe({hipe_bsi_primop, bs_get_size}) -> true;
is_safe({hipe_bsi_primop, bs_size_test}) -> false;          % XXX: Correct?
is_safe({hipe_bsi_primop, bs_size_test_all}) -> false;      % XXX: Correct?
is_safe({hipe_bsi_primop,{bs_get_binary,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_binary,_Size,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_binary_all,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_float,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_float,_Size,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_integer,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_get_integer,_Size,_Offset,_Flags}}) -> true;
is_safe({hipe_bsi_primop,{bs_make_size,_Size}}) -> false;   % XXX: Correct?
is_safe(#mkfun{}) -> true;
is_safe(#unsafe_element{}) -> true;
is_safe(#unsafe_update_element{}) -> true.


fails('+') -> true;               % XXX: Correct?
fails('-') -> true;               % XXX: Correct?
fails('*') -> true;               % XXX: Correct?
fails('/') -> true;               % XXX: Correct?
fails('bnot') -> true;            % XXX: Correct?
fails('band') -> true;            % XXX: Correct?
fails('bor') -> true;             % XXX: Correct?
fails('bsl') -> true;             % XXX: Correct?
fails('bsr') -> true;             % XXX: Correct?
fails('bxor') -> true;            % XXX: Correct?
fails('div') -> true;             % XXX: Correct?
fails('rem') -> true;             % XXX: Correct?
fails(call_fun) -> true;          % XXX: Correct?
fails(check_get_msg) -> true;     % XXX: Correct?
fails(clear_timeout) -> true;     % XXX: Correct?
fails(cons) -> false;
fails(conv_to_float) -> true;     % XXX: Correct?
fails(extra_unsafe_add) -> false; % XXX: Correct?
fails(extra_unsafe_sub) -> false; % XXX: Correct?
fails(fcheckerror) -> true;       % XXX: Correct?
fails(fclearerror) -> false;
fails(fp_add) -> false;
fails(fp_div) -> false;
fails(fp_mul) -> false;
fails(fp_sub) -> false;
fails(mktuple) -> false;
fails(next_msg) -> false;
fails(redtest) -> true;           % XXX: Correct?
fails(select_msg) -> true;        % XXX: Correct?
fails(self) -> false;
fails(set_timeout) -> true;       % XXX: Correct?
fails(suspend_msg) -> true;       % XXX: Correct?
fails(unsafe_untag_float) -> false;
fails(unsafe_tag_float) -> false;
fails(unsafe_add) -> false;
fails(unsafe_band) -> false;
fails(unsafe_bnot) -> false;
fails(unsafe_bor) -> false;
fails(unsafe_bsl) -> false;
fails(unsafe_bsr) -> false;
fails(unsafe_bxor) -> false;
fails(unsafe_hd) -> false;
fails(unsafe_sub) -> false;
%% fails(unsafe_tag_float) -> true;  % XXX: Correct?
fails(unsafe_tl) -> false;
%% fails(unsafe_untag_float) -> true;  % XXX: Correct?
fails(#apply_N{}) -> true;        % XXX: Correct?
fails(#closure_element{}) -> false;
fails(#element{}) -> true;      % XXX: Correct?
fails({hipe_bs_primop, bs_bits_to_bytes}) -> true;           % XXX: Correct?
fails({hipe_bs_primop, bs_bits_to_bytes2}) -> true;          % XXX: Correct?
fails({hipe_bs_primop, bs_final2}) -> true;                  % XXX: Correct?
fails({hipe_bs_primop, bs_start_match}) -> true;             % XXX: Correct?
fails({hipe_bs_primop, {bs_add,_}}) -> true;                 % XXX: Correct?
fails({hipe_bs_primop, {bs_add,_,_}}) -> true;               % XXX: Correct?
%% fails({hipe_bs_primop, {bs_create_space,_,_}}) -> true;   % XXX: Correct?
fails({hipe_bs_primop, {bs_get_binary,_,_}}) -> true;        % XXX: Correct?
fails({hipe_bs_primop, {bs_get_binary_all,_}}) -> true;      % XXX: Correct?
fails({hipe_bs_primop, {bs_get_integer,_,_}}) -> true;       % XXX: Correct?
fails({hipe_bs_primop, {bs_init2,_}}) -> true;               % XXX: Correct?
fails({hipe_bs_primop, {bs_init2,_,_}}) -> true;             % XXX: Correct?
fails({hipe_bs_primop, {bs_put_binary,_,_}}) -> true;        % XXX: Correct?
fails({hipe_bs_primop, {bs_put_binary_all,_}}) -> true;      % XXX: Correct?
fails({hipe_bs_primop, {bs_put_float,_,_,_}}) -> true;       % XXX: Correct?
fails({hipe_bs_primop, {bs_put_integer,_,_,_}}) -> true;     % XXX: Correct?
fails({hipe_bs_primop, {bs_put_string,_,_}}) -> true;        % XXX: Correct?
fails({hipe_bs_primop, {bs_put_string,_,_,_}}) -> true;      % XXX: Correct?
%% fails({hipe_bs_primop, {bs_test_tail,_}}) -> true;	     % XXX: Correct?
fails({hipe_bs_primop, {bs_skip_bits,_}}) -> true;	     % XXX: Correct?
fails({hipe_bs_primop, {bs_skip_bits_all,_}}) -> true;	     % XXX: Correct?
fails({hipe_bs_primop, {bs_test_tail,_}}) -> true;	     % XXX: Correct?
fails({hipe_bs_primop, {unsafe_bs_put_integer,_,_,_}}) -> true; % XXX: Correct?
fails({hipe_bs_primop2, {bs_get_binary_2,_,_}}) -> true;     % XXX: Correct?
fails({hipe_bs_primop2, {bs_get_binary_all_2,_,_}}) -> true; % XXX: Correct?
fails({hipe_bs_primop2, {bs_get_float_2,_,_}}) -> true;      % XXX: Correct?
fails({hipe_bs_primop2, {bs_get_integer_2,_,_}}) -> true;    % XXX: Correct?
fails({hipe_bs_primop2, {bs_restore_2,_}}) -> true;          % XXX: Correct?
fails({hipe_bs_primop2, {bs_save_2,_}}) -> true;             % XXX: Correct?
fails({hipe_bs_primop2, {bs_skip_bits_2,_}}) -> true;        % XXX: Correct?
fails({hipe_bs_primop2, {bs_skip_bits_all_2,_,_}}) -> true;  % XXX: Correct?
fails({hipe_bs_primop2, {bs_start_match_2,_}}) -> true;      % XXX: Correct?
fails({hipe_bs_primop2, {bs_test_tail_2,_}}) -> true;        % XXX: Correct?
fails({hipe_bsi_primop, bs_add}) -> true;                    % XXX: Correct?
fails({hipe_bsi_primop, bs_div_test}) -> true;               % XXX: Correct?
fails({hipe_bsi_primop, bs_get_orig}) -> true;               % XXX: Correct?
fails({hipe_bsi_primop, bs_get_orig_offset}) -> true;        % XXX: Correct?
fails({hipe_bsi_primop, bs_get_size}) -> true;               % XXX: Correct?
fails({hipe_bsi_primop, bs_size_test}) -> true;              % XXX: Correct?
fails({hipe_bsi_primop, bs_size_test_all}) -> true;          % XXX: Correct?
fails({hipe_bsi_primop,{bs_get_binary,_,_}}) -> true;        % XXX: Correct?
fails({hipe_bsi_primop,{bs_get_binary,_,_,_}}) -> true;      % XXX: Correct?
fails({hipe_bsi_primop,{bs_get_binary_all,_,_}}) -> true;    % XXX: Correct?
%% fails({hipe_bsi_primop,{bs_get_float,_,_}}) -> true;      % XXX: Correct?
%% fails({hipe_bsi_primop,{bs_get_float,_,_,_}}) -> true;    % XXX: Correct?
%% fails({hipe_bsi_primop,{bs_get_integer,_,_}}) -> true;    % XXX: Correct?
fails({hipe_bsi_primop,{bs_get_integer,_,_,_}}) -> true;     % XXX: Correct?
fails({hipe_bsi_primop,{bs_make_size,_}}) -> true;           % XXX: Correct?
fails(#mkfun{}) -> false;
fails(#unsafe_element{}) -> false;
fails(#unsafe_update_element{}) -> false;
%% Apparently, we are calling fails/1 for all MFAs which are compiled.
%% This is weird and we should restructure the compiler to avoid
%% calling fails/1 for things that are not primops.
fails({M, F, A}) when is_atom(M), is_atom(F), is_integer(A), 0 =< A, A =< 255 -> true.

%%=====================================================================
%% Pretty printing
%%=====================================================================

pp(Op, Dev) ->
  case Op of
    #apply_N{arity=N} ->
      io:format(Dev, "apply_N<~w>/", [N]);
    #closure_element{n=N} ->
      io:format(Dev, "closure_element<~w>", [N]);
    {X, BsOp} when X =:= hipe_bs_primop; X =:= hipe_bs_primop2 ->
      case BsOp of
	{bs_create_space, Size, _} ->
	  io:format(Dev, "bs_create_space<~w>", [Size]);
	{bs_put_binary_all, Flags} -> 
	  io:format(Dev, "bs_put_binary_all<~w>", [Flags]);
	{bs_put_binary, Size} ->
	  io:format(Dev, "bs_put_binary<~w>", [Size]);
	{bs_put_binary, Flags, Size} ->
	  io:format(Dev, "bs_put_binary<~w, ~w>", [Flags, Size]);
	{bs_put_float, Flags, Size, _ConstInfo} ->
	  io:format(Dev, "bs_put_float<~w, ~w>", [Flags, Size]);
	{bs_put_string, String, SizeInBytes} ->
	  io:format(Dev, "bs_put_string<~w, ~w>", [String, SizeInBytes]);
	{bs_put_integer, Bits, Flags, _ConstInfo} ->
	  io:format(Dev, "bs_put_integer<~w, ~w>", [Bits, Flags]);
	{unsafe_bs_put_integer, Bits, Flags, _ConstInfo} ->
	  io:format(Dev, "unsafe_bs_put_integer<~w, ~w>", [Bits, Flags]);
	{bs_skip_bits_all, Flags} ->
	  io:format(Dev, "bs_skip_bits_all<~w>", [Flags]);
	{bs_skip_bits, Unit} ->
	  io:format(Dev, "bs_skip_bits<~w>", [Unit]);
	{bs_skip_bits_all_2, Unit, Flags} ->
	  io:format(Dev, "bs_skip_bits_all<~w,~w>", [Unit,Flags]);
	{bs_skip_bits_2, Unit} ->
	  io:format(Dev, "bs_skip_bits<~w>", [Unit]);
	bs_start_match ->
	  io:format(Dev, "bs_start_match", []);
	{bs_start_match_2, Max} ->
	  io:format(Dev, "bs_start_match<~w>", [Max]);
	{bs_get_integer, Size, Flags} ->
	  io:format(Dev, "bs_get_integer<~w, ~w>", [Size, Flags]);
	{bs_get_float, Size, Flags} ->
	  io:format(Dev, "bs_get_float<~w, ~w>", [Size, Flags]);
	{bs_get_binary, Size, Flags} ->
	  io:format(Dev, "bs_get_binary<~w, ~w>", [Size, Flags]);
	{bs_get_binary_all, Flags} ->
	  io:format(Dev, "bs_get_binary_all<~w>", [Flags]);
	{bs_test_tail, NumBits} ->
	  io:format(Dev, "bs_test_tail<~w>", [NumBits]);
	{bs_restore, Index} ->
	  io:format(Dev, "bs_restore<~w>", [Index]);
	{bs_save, Index} ->
	  io:format(Dev, "bs_save<~w>", [Index]);
	{bs_get_integer_2, Size, Flags} ->
	  io:format(Dev, "bs_get_integer<~w, ~w>", [Size, Flags]);
	{bs_get_float_2, Size, Flags} ->
	  io:format(Dev, "bs_get_float<~w, ~w>", [Size, Flags]);
	{bs_get_binary_2, Size, Flags} ->
	  io:format(Dev, "bs_get_binary<~w, ~w>", [Size, Flags]);
	{bs_get_binary_all_2,Unit,Flags} ->
	  io:format(Dev, "bs_get_binary_all<~w,~w>", [Unit,Flags]);
	{bs_test_tail_2,NumBits} ->
	  io:format(Dev, "bs_test_tail<~w>", [NumBits]);
	{bs_restore_2, Index} ->
	  io:format(Dev, "bs_restore<~w>", [Index]);
	{bs_save_2, Index} ->
	  io:format(Dev, "bs_save<~w>", [Index]);
	{bs_init, _, _} ->
	  io:format(Dev, "bs_init", []);
	{bs_init, _} ->
	  io:format(Dev, "bs_init", []);
	{bs_init2, Size, Flags} ->
	  io:format(Dev, "bs_init2<~w, ~w>", [Size, Flags]);
	{bs_init2,Flags} ->
	  io:format(Dev, "bs_init2<~w>", [Flags]);
	{bs_need_buf, Need} ->
	  io:format(Dev, "bs_need_buf<~w>", [Need]);
	{bs_add, Unit} ->
	  io:format(Dev, "bs_add<~w>", [Unit]);
	{bs_add, Const, Unit} ->
	  io:format(Dev, "bs_add<~w, ~w>", [Const, Unit]);
	bs_bits_to_bytes ->
	  io:format(Dev, "bs_bits_to_bytes", []);
	bs_final ->
	  io:format(Dev, "bs_final", [])
      end;
    {hipe_bsi_primop, BsOp} ->
      case BsOp of
	bs_add ->
	  io:format(Dev, "bs_add", []);
	bs_div_test ->
	  io:format(Dev, "bs_div_test", []);
	bs_get_orig ->
	  io:format(Dev, "bs_get_orig", []);
	bs_get_orig_offset ->
	  io:format(Dev, "bs_get_orig_offset", []);
	bs_get_size ->
	  io:format(Dev, "bs_get_size", []);
	bs_size_test ->
	  io:format(Dev, "bs_size_test", []);
	bs_size_test_all ->
	  io:format(Dev, "bs_size_test_all", []);
	{bs_get_binary, Offset, Flags} ->
	  io:format(Dev, "bs_get_binary<~w, ~w>", [Offset, Flags]);
	{bs_get_binary, Size, Offset, Flags} ->
	  io:format(Dev, "bs_get_binary<~w, ~w, ~w>", [Size, Offset, Flags]);
	{bs_get_binary_all, Offset, Flags} ->
	  io:format(Dev, "bs_get_binary_all<~w, ~w>", [Offset, Flags]);
	{bs_get_integer, Offset, Flags} ->
	  io:format(Dev, "bs_get_integer<~w, ~w>", [Offset, Flags]);
	{bs_get_integer, Size, Offset, Flags} ->
	  io:format(Dev, "bs_get_integer<~w, ~w, ~w>", [Size, Offset, Flags]);
	{bs_get_float, Offset, Flags} ->
	  io:format(Dev, "bs_get_float<~w, ~w>", [Offset, Flags]);
	{bs_get_float, Size, Offset, Flags} ->
	  io:format(Dev, "bs_get_float<~w, ~w, ~w>", [Size, Offset, Flags]);
	{bs_make_size, Unit} ->
	   io:format(Dev, "bs_make_size<~w>", [Unit])
      end;
    #mkfun{mfa={Mod, Fun, Arity}, magic_num=Unique, index=I} ->
      io:format(Dev, "mkfun<~w,~w,~w,~w,~w>", [Mod, Fun, Arity, Unique, I]);
    #unsafe_element{index=N} ->
      io:format(Dev, "unsafe_element<~w>", [N]);
    #unsafe_update_element{index=N} ->
      io:format(Dev, "unsafe_update_element<~w>", [N]);
    Fun ->
      io:format(Dev, "~w", [Fun])
  end.

%%=====================================================================
%% Type handling
%%=====================================================================

type(Primop, Args) ->
  case Primop of
%%% -----------------------------------------------------
%%% Arithops
    '+' ->
      erl_bif_types:type(erlang, '+', 2, Args);
    '-' ->
      erl_bif_types:type(erlang, '-', 2, Args);
    '*' ->
      erl_bif_types:type(erlang, '*', 2, Args);
    '/' ->
      erl_bif_types:type(erlang, '/', 2, Args);
    'band' ->
      erl_bif_types:type(erlang, 'band', 2, Args);
    'bnot' ->
      erl_bif_types:type(erlang, 'bnot', 1, Args);
    'bor' ->
      erl_bif_types:type(erlang, 'bor', 2, Args);
    'bxor' ->
      erl_bif_types:type(erlang, 'bxor', 2, Args);
    'bsl' ->
      erl_bif_types:type(erlang, 'bsl', 2, Args);
    'bsr' ->
      erl_bif_types:type(erlang, 'bsr', 2, Args);
    'div' ->
      erl_bif_types:type(erlang, 'div', 2, Args);
    'rem' ->
      erl_bif_types:type(erlang, 'rem', 2, Args);
    extra_unsafe_add ->
      erl_bif_types:type(erlang, '+', 2, Args);
    unsafe_add ->
      erl_bif_types:type(erlang, '+', 2, Args);
    unsafe_bnot ->
      erl_bif_types:type(erlang, 'bnot', 1, Args);
    unsafe_bor ->
      erl_bif_types:type(erlang, 'bor', 2, Args);
    unsafe_band ->
      erl_bif_types:type(erlang, 'band', 2, Args);
    unsafe_bxor ->
      erl_bif_types:type(erlang, 'bxor', 2, Args);
    unsafe_sub ->
      erl_bif_types:type(erlang, '-', 2, Args);
%%% -----------------------------------------------------
%%% Lists
    cons ->
      [HeadType, TailType] = Args,
      erl_types:t_cons(HeadType, TailType);
    unsafe_hd ->
      [Type] = Args,
      case erl_types:t_is_cons(Type) of
	true -> erl_types:t_cons_hd(Type);
	false -> erl_types:t_none()
      end;
    unsafe_tl ->
      [Type] = Args,
      case erl_types:t_is_cons(Type) of
	true -> erl_types:t_cons_tl(Type);
	false -> erl_types:t_none()
      end;
%%% -----------------------------------------------------
%%% Tuples
    mktuple ->
      erl_types:t_tuple(Args);
    #element{} ->
      erl_bif_types:type(erlang, element, 2, Args);
    #unsafe_element{index=N} ->
      [Type] = Args,
      case erl_types:t_is_tuple(Type) of
	false ->
	  erl_types:t_none();
	true ->
	  Index = erl_types:t_from_term(N),
	  erl_bif_types:type(erlang, element, 2, [Index|Args])
      end;
    #unsafe_update_element{index=N} ->
      %% Same, same
      erl_bif_types:type(erlang, setelement, 3, [erl_types:t_integer(N)|Args]);
%%% -----------------------------------------------------
%%% Floats
    fclearerror ->
      erl_types:t_any();
    fcheckerror ->
      erl_types:t_any();
    unsafe_tag_float ->
      erl_types:t_float();
    %% These might look surprising, but the return is an untagged
    %% float and we have no type for untagged values.
    conv_to_float ->
      erl_types:t_any();
    unsafe_untag_float ->
      erl_types:t_any();
    fp_add ->
      erl_types:t_any();
    fp_sub ->
      erl_types:t_any();
    fp_mul ->
      erl_types:t_any();
    fp_div ->
      erl_types:t_any();
    fnegate ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Binaries    
    {hipe_bs_primop, {bs_get_integer, Size, Flags}} ->
      Signed = Flags band 4,
      if (length(Args) =:= 4) and (Signed =:= 0) -> 
	  erl_types:t_from_range(0, round(math:pow(2, Size)) - 1);
	  %% No variable part of the size parameter.
%% 	  if Size < 9, Signed =:= 0 -> erl_types:t_byte();
%% 	     Size < 21, Signed =:= 0 -> erl_types:t_char();
%% 	     true -> erl_types:t_integer()
%%	  end;
	 true -> erl_types:t_integer()
      end;
    {hipe_bs_primop, {bs_get_float, _, _}} ->
      erl_types:t_float();
    {hipe_bs_primop, {bs_get_binary, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_get_binary_all, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop2, {bs_get_integer_2, Size, Flags}} ->
      Signed = Flags band 4,
      if (length(Args) =:= 1) and (Signed =:= 0) -> 
	  %% No variable part of the size parameter.
	  erl_types:t_from_range(0, round(math:pow(2, Size)) - 1);
%% 	  if Size < 9, Signed =:= 0 -> erl_types:t_byte();
%% 	     Size < 21, Signed =:= 0 -> erl_types:t_char();
%% 	     true -> erl_types:t_integer()
%% 	  end;
	 true -> erl_types:t_integer()
      end;
    {hipe_bs_primop2, {bs_get_float_2, _, _}} ->
      erl_types:t_float();
    {hipe_bs_primop2, {bs_get_binary_2, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop2, {bs_get_binary_all_2,_, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, bs_final} ->
      erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_integer, _, _}} ->
      erl_types:t_integer();
    {hipe_bsi_primop, {bs_get_integer, Size, _, Flags}} ->
      Signed = Flags band 4,
      if Signed =:= 0 ->
	  erl_types:t_from_range(0, round(math:pow(2, Size)) - 1);
%%       if Size < 9, Signed =:= 0 -> erl_types:t_byte();
%% 	 Size < 21, Signed =:= 0 -> erl_types:t_char();
%% 	 true -> erl_types:t_integer()
%%       end;
	 true ->
	  erl_types:t_integer()
      end;
    {hipe_bsi_primop, {bs_get_float, _, _}} ->
      erl_types:t_float();
    {hipe_bsi_primop, {bs_get_float, _, _, _}} ->
      erl_types:t_float();
    {hipe_bsi_primop, {bs_get_binary, _, _}} ->
	erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_binary, _, _, _}} ->
      erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_binary_all, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_init2,_,_}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_init2,_}} ->
      erl_types:t_binary();
    {X, _BsOp} when X =:= hipe_bs_primop;
		    X =:= hipe_bs_primop2;
		    X =:= hipe_bsi_primop ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Funs
    #mkfun{mfa={_M, _F, A}} ->
      %% Note that the arity includes the bound variables in args
      erl_types:t_fun(A - length(Args), erl_types:t_any());
    #apply_N{} ->
      erl_types:t_any();
    Op when Op =:= call_fun; Op =:= enter_fun ->
      [Fun0|TailArgs0] = lists:reverse(Args),
      TailArgs = lists:reverse(TailArgs0),
      Fun = erl_types:t_inf(erl_types:t_fun(), Fun0),
      case erl_types:t_is_fun(Fun) of
	true ->
	  case erl_types:t_fun_args(Fun) of
	    any ->
	      erl_types:t_any();
	    FunArgs ->
	      case check_fun_args(FunArgs, TailArgs) of
		ok ->
		  erl_types:t_fun_range(Fun);
		error ->
		  erl_types:t_none()
	      end
	  end;
	false ->
	  erl_types:t_none()
      end;
%%% -----------------------------------------------------
%%% Communication
    check_get_msg ->
      erl_types:t_any();
    clear_timeout ->
      erl_types:t_any();
    next_msg ->
      erl_types:t_any();
    select_msg ->
      erl_types:t_any();
    set_timeout ->
      erl_types:t_any();
    suspend_msg ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Other
    #closure_element{} ->
      erl_types:t_any();
    redtest ->
      erl_types:t_any();
    {M, F, A} ->
      erl_bif_types:type(M, F, A, Args)
  end.


type(Primop) ->
  case Primop of
%%% -----------------------------------------------------
%%% Arithops
    'bnot' ->
      erl_bif_types:type(erlang, 'bnot', 1);
    '+' ->
      erl_bif_types:type(erlang, '+', 2);
    '-' ->
      erl_bif_types:type(erlang, '-', 2);
    '*' ->
      erl_bif_types:type(erlang, '*', 2);
    '/' ->
      erl_bif_types:type(erlang, '/', 2);
    'div' ->
      erl_bif_types:type(erlang, 'div', 2);
    'rem' ->
      erl_bif_types:type(erlang, 'rem', 2);
    'band' ->
      erl_bif_types:type(erlang, 'band', 2);
    'bor' ->
      erl_bif_types:type(erlang, 'bor', 2);
    'bxor' ->
      erl_bif_types:type(erlang, 'bxor', 2);
    'bsr' ->
      erl_bif_types:type(erlang, 'bsr', 2);
    'bsl' ->
      erl_bif_types:type(erlang, 'bsl', 2);
    unsafe_add ->
      erl_bif_types:type(erlang, '+', 2);
    extra_unsafe_add ->
      erl_bif_types:type(erlang, '+', 2);
    unsafe_sub ->
      erl_bif_types:type(erlang, '-', 2);
    unsafe_bor ->
      erl_bif_types:type(erlang, 'bor', 2);
    unsafe_band ->
      erl_bif_types:type(erlang, 'band', 2);
    unsafe_bxor ->
      erl_bif_types:type(erlang, 'bxor', 2);
%%% -----------------------------------------------------
%%% Lists
    cons ->
      erl_types:t_cons();
    unsafe_hd ->
      erl_bif_types:type(erlang, hd, 1);
    unsafe_tl ->
      erl_bif_types:type(erlang, tl, 1);
%%% -----------------------------------------------------
%%% Tuples
    mktuple ->
      erl_types:t_tuple();
    #element{} ->
      erl_bif_types:type(erlang, element, 2);
    #unsafe_element{} ->
      erl_bif_types:type(erlang, element, 2);
    #unsafe_update_element{} ->
      erl_bif_types:type(erlang, setelement, 3);
%%% -----------------------------------------------------
%%% Floats
    fclearerror ->
      erl_types:t_any();
    fcheckerror ->
      erl_types:t_any();
    unsafe_tag_float ->
      erl_types:t_float();
    %% These might look surprising, but the return is an untagged
    %% float and we have no type for untagged values.
    conv_to_float ->
      erl_types:t_any();
    unsafe_untag_float ->
      erl_types:t_any();
    fp_add ->
      erl_types:t_any();
    fp_sub ->
      erl_types:t_any();
    fp_mul ->
      erl_types:t_any();
    fp_div ->
      erl_types:t_any();
    fnegate ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Binaries    
    {hipe_bs_primop, {bs_get_integer, _Size, _Flags}} ->
      erl_types:t_integer();
    {hipe_bs_primop, {bs_get_float, _, _}} ->
      erl_types:t_float();
    {hipe_bs_primop, {bs_get_binary, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_get_binary_all, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, bs_final} ->
      erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_integer, _, _}} ->
      erl_types:t_integer();
    {hipe_bsi_primop, {bs_get_integer, _Size, _, _Flags}} ->
      erl_types:t_integer();
    {hipe_bsi_primop, {bs_get_float, _, _}} ->
      erl_types:t_float();
    {hipe_bsi_primop, {bs_get_float, _, _, _}} ->
      erl_types:t_float();
    {hipe_bsi_primop, {bs_get_binary, _, _}} ->
      erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_binary, _, _, _}} ->
      erl_types:t_binary();
    {hipe_bsi_primop, {bs_get_binary_all, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_init2, _, _}} ->
      erl_types:t_binary();
    {hipe_bs_primop, {bs_init2, _}} ->
      erl_types:t_binary();
    {X, _BsOp} when X =:= hipe_bs_primop; 
		    X =:= hipe_bs_primop2;
		    X =:= hipe_bsi_primop ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Funs
    #mkfun{} ->
      %% Note that the arity includes the bound variables in args
      erl_types:t_fun();
    #apply_N{} ->
      erl_types:t_any();
    call_fun ->
      erl_types:t_any();
    enter_fun ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Communication
    check_get_msg ->
      erl_types:t_any();
    clear_timeout ->
      erl_types:t_any();
    next_msg ->
      erl_types:t_any();
    select_msg ->
      erl_types:t_any();
    set_timeout ->
      erl_types:t_any();
    suspend_msg ->
      erl_types:t_any();
%%% -----------------------------------------------------
%%% Other
    #closure_element{} ->
      erl_types:t_any();
    redtest ->
      erl_types:t_any();
    {M, F, A} ->
      erl_bif_types:type(M, F, A)
  end.


%%=====================================================================
%% Auxiliary functions
%%=====================================================================

check_fun_args([T1|Left1], [T2|Left2]) ->
  Inf = erl_types:t_inf(T1, T2),
  case erl_types:t_inf(Inf, T2) of
    Inf ->
      check_fun_args(Left1, Left2);
    _ ->
      error
  end;
check_fun_args([], []) ->
  ok;
check_fun_args(_, _) ->
  error.
