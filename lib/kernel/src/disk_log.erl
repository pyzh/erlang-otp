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
-module(disk_log).

%% Efficient file based log - process part

-export([start/0, istart_link/0, 
	 log/2, log_terms/2, blog/2, blog_terms/2,
	 alog/2, alog_terms/2, balog/2, balog_terms/2,
	 close/1, lclose/1, lclose/2, sync/1, open/1, 
	 truncate/1, truncate/2, btruncate/2,
	 reopen/2, reopen/3, breopen/3, inc_wrap_file/1, change_size/2,
	 change_notify/3, change_header/2, 
	 chunk/2, chunk/3, chunk_step/3, chunk_info/1,
	 block/1, block/2, unblock/1, info/1, format_error/1,
	 accessible_logs/0]).

%% Internal exports
-export([init/1, internal_open/2,
	 system_continue/3, system_terminate/4, system_code_change/4]).

%% To be used by wrap_log_reader only.
-export([ichunk_end/2]).

-record(state, {queue = [], parent, cnt = 0, args,
		error_status = ok   %%  ok | {error, Reason}
	       }).

-include("disk_log.hrl").

-define(failure(Error, Function, Arg), 
	{{failed, Error}, [{?MODULE, Function, Arg}]}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%-----------------------------------------------------------------
%% This module implements the API, and the processes for each log.
%% There is one process/log.
%%-----------------------------------------------------------------      

open(A) ->
    disk_log_server:open(check_arg(A, #arg{options = A})).

log(Log, Term) -> 
    req(Log, {log, term_to_binary(Term)}).

blog(Log, Bytes) ->
    req(Log, {blog, check_bytes(Bytes)}).

log_terms(Log, Terms) ->
    Bs = lists:map(fun term_to_binary/1, Terms),
    req(Log, {log, Bs}).

blog_terms(Log, Bytess) ->
    Bs = lists:map(fun check_bytes/1, Bytess),
    req(Log, {blog, Bs}).

alog(Log, Term) -> 
    notify(Log, {alog, term_to_binary(Term)}).

alog_terms(Log, Terms) ->
    Bs = lists:map(fun term_to_binary/1, Terms),
    notify(Log, {alog, Bs}).

balog(Log, Bytes) -> 
    notify(Log, {balog, check_bytes(Bytes)}).

balog_terms(Log, Bytess) ->
    Bs = lists:map(fun check_bytes/1, Bytess),
    notify(Log, {balog, Bs}).

close(Log) -> 
    req(Log, close).

lclose(Log) ->
    lclose(Log, node()).

lclose(Log, Node) ->
    lreq(Log, close, Node).

truncate(Log) -> 
    req(Log, {truncate, none, truncate, 1}).

truncate(Log, Head) ->
    req(Log, {truncate, {ok, term_to_binary(Head)}, truncate, 2}).

btruncate(Log, Head) ->
    req(Log, {truncate, {ok, check_bytes(Head)}, btruncate, 2}).

reopen(Log, NewFile) ->
    req(Log, {reopen, NewFile, none, reopen, 2}).

reopen(Log, NewFile, NewHead) ->
    req(Log, {reopen, NewFile, {ok, term_to_binary(NewHead)}, reopen, 3}).

breopen(Log, NewFile, NewHead) ->
    req(Log, {reopen, NewFile, {ok, check_bytes(NewHead)}, breopen, 3}).

inc_wrap_file(Log) -> 
    req(Log, inc_wrap_file).

change_size(Log, NewSize) -> 
    req(Log, {change_size, NewSize}).

change_notify(Log, Pid, NewNotify) -> 
    req(Log, {change_notify, Pid, NewNotify}).

change_header(Log, NewHead) ->
    req(Log, {change_header, NewHead}).

sync(Log) -> 
    req(Log, sync).

block(Log) -> 
    block(Log, true).

block(Log, QueueLogRecords) -> 
    req(Log, {block, QueueLogRecords}).

unblock(Log) -> 
    req(Log, unblock).

format_error(Error) ->
    do_format_error(Error).

info(Log) -> 
    sreq(Log, info).
	      

%% This function Takes 3 args, a Log, a Continuation and N.
%% It retuns a {Cont2, ObjList} | eof | {error, Reason}
%% The initial continuation is the atom 'start'

chunk(Log, Cont) ->
    chunk(Log, Cont, infinity).

chunk(Log, Cont, infinity) ->
    %% There cannot be more than ?MAX_CHUNK_SIZE terms in a chunk.
    ichunk(Log, Cont, ?MAX_CHUNK_SIZE);
chunk(Log, Cont, N) when integer(N), N > 0 ->
    ichunk(Log, Cont, N).

ichunk(Log, start, N) ->
    R = sreq(Log, {chunk, 0, list_to_binary([]), N}),
    ichunk_end(R, Log);
ichunk(Log, More, N) when record(More, continuation) ->
    R = req2(More#continuation.pid, 
	     {chunk, More#continuation.pos, More#continuation.b, N}),
    ichunk_end(R, Log);
ichunk(_Log, Error, _) ->
    Error.

ichunk_end({C, R}, Log) when record(C, continuation) ->
    ichunk_end(R, read_write, Log, C, 0, []);
ichunk_end({C, R, Bad}, Log) when record(C, continuation) ->
    ichunk_end(R, read_only, Log, C, Bad, []);    
ichunk_end(R, _Log) ->
    R.

%% Create the terms on the client's heap, not the server's.
ichunk_end([B | Bs], Mode, Log, C, Bad, A) ->
    case catch binary_to_term(B) of
	{'EXIT', _} when read_write == Mode ->
	    InfoList = info(Log),
	    {value, {file, FileName}} = lists:keysearch(file, 1, InfoList),
            File = case C#continuation.pos of
		       Pos when integer(Pos) -> FileName; % halt log 
		       {FileNo, _} -> add_ext(FileName, FileNo) % wrap log
		   end,
	    {error, {corrupt_log_file, File}};
	{'EXIT', _} when read_only == Mode ->
	    Reread = lists:foldl(fun(Bin, Sz) -> Sz+size(Bin)+?HEADERSZ end, 
				 0, Bs),
	    NewPos = case C#continuation.pos of
			 Pos when integer(Pos) -> Pos-Reread;
			 {FileNo, Pos} -> {FileNo, Pos-Reread}
		     end,
	    NewBad = Bad + ?HEADERSZ, % the whole header is deemed bad
	    {C#continuation{pos = NewPos, b = B}, lists:reverse(A), NewBad};
	T ->
	    ichunk_end(Bs, Mode, Log, C, Bad, [T | A])
    end;
ichunk_end([], _Mode, _Log, C, Bad, A) when Bad > 0 ->
    {C, lists:reverse(A), Bad};
ichunk_end([], _Mode, _Log, C, Bad, A) when Bad == 0 ->
    {C, lists:reverse(A)}.

chunk_step(Log, Cont, N) when integer(N) ->
    ichunk_step(Log, Cont, N).

ichunk_step(Log, start, N) ->
    sreq(Log, {chunk_step, 0, N});
ichunk_step(_Log, More, N) when record(More, continuation) ->
    req2(More#continuation.pid, {chunk_step, More#continuation.pos, N});
ichunk_step(_Log, Error, _) ->
    Error.

chunk_info(More) when record(More, continuation) ->
   [{node, node(More#continuation.pid)}];
chunk_info(BadCont) ->
   {error, {no_continuation, BadCont}}.

accessible_logs() ->
    disk_log_server:accessible_logs().

istart_link() ->  
    {ok, proc_lib:spawn_link(disk_log, init, [self()])}.

%% Only for backwards compatibility, could probably be removed.
start() ->
    disk_log_server:start().

internal_open(Pid, A) ->
    req2(Pid, {internal_open, A}).

check_arg([], Res) -> 
    Ret = case Res#arg.head of
	      none ->
		  {ok, Res};
	      _ ->
		  case check_head(Res#arg.head, Res#arg.format) of
		      {ok, Head} ->
			  {ok, Res#arg{head = Head}};
		      Error ->
			  Error
		  end
	  end,

    if  %% check result
	Res#arg.name == 0 -> 
	    {error, {badarg, name}};
	Res#arg.file == none ->
	    case catch lists:concat([Res#arg.name, ".LOG"]) of
		{'EXIT',_} -> {error, {badarg, file}};
		FName ->  check_arg([], Res#arg{file = FName})
	    end;
	Res#arg.repair == truncate, Res#arg.mode == read_only ->
	    {error, {badarg, repair_read_only}};
	Res#arg.type == halt, tuple(Res#arg.size) ->
	    {error, {badarg, size}};
	Res#arg.type == wrap, Res#arg.size == infinity ->
	    case disk_log_1:read_size_file(Res#arg.file) of
		{0, 0} ->
		    {error, {badarg, size}};
		{FileSz, NoOf} ->
		    check_arg([], Res#arg{size = {FileSz, NoOf}})
	    end;
	Res#arg.type == wrap, tuple(Res#arg.size) ->
	    case disk_log_1:read_size_file(Res#arg.file) of
		{0, 0} ->
		    Ret;
		OldSize when OldSize == Res#arg.size ->
		    Ret;
		_OldSize when Res#arg.repair == truncate ->
		    Ret;
		OldSize ->
		    {error, {size_mismatch, OldSize, Res#arg.size}}
	    end;
	Res#arg.type == wrap ->
	    {error, {badarg, size}};
	true ->
	    Ret
    end;
check_arg([{file, F} | Tail], Res) when list(F) ->
    check_arg(Tail, Res#arg{file = F});
check_arg([{file, F} | Tail], Res) when atom(F) ->
    check_arg(Tail, Res#arg{file = F});
check_arg([{linkto, Pid} |Tail], Res) when pid(Pid) ->
    check_arg(Tail, Res#arg{linkto = Pid});
check_arg([{linkto, none} |Tail], Res) ->
    check_arg(Tail, Res#arg{linkto = none});
check_arg([{name, Name}|Tail], Res) ->
    check_arg(Tail, Res#arg{name =Name});
check_arg([{repair, true}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = true});
check_arg([{repair, false}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = false});
check_arg([{repair, truncate}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = truncate});
check_arg([{size, Int}|Tail], Res) when integer(Int), Int > 0 ->
    check_arg(Tail, Res#arg{size = Int});
check_arg([{size, infinity}|Tail], Res) ->
    check_arg(Tail, Res#arg{size = infinity});
check_arg([{size, {MaxB,MaxF}}|Tail], Res) when integer(MaxB), integer(MaxF),
						MaxB > 0, MaxF > 0, 
						MaxF < ?MAX_FILES ->
    check_arg(Tail, Res#arg{size = {MaxB, MaxF}});
check_arg([{type, wrap}|Tail], Res) ->
    check_arg(Tail, Res#arg{type = wrap});
check_arg([{type, halt}|Tail], Res) ->
    check_arg(Tail, Res#arg{type = halt});
check_arg([{format, internal}|Tail], Res) ->
    check_arg(Tail, Res#arg{format = internal});
check_arg([{format, external}|Tail], Res) ->
    check_arg(Tail, Res#arg{format = external});
check_arg([{distributed, []}|Tail], Res) ->
    check_arg(Tail, Res#arg{distributed = false});
check_arg([{distributed, Nodes}|Tail], Res) when list(Nodes) ->
    check_arg(Tail, Res#arg{distributed = {true, Nodes}});
check_arg([{notify, true}|Tail], Res) ->
    check_arg(Tail, Res#arg{notify = true});
check_arg([{notify, false}|Tail], Res) ->
    check_arg(Tail, Res#arg{notify = false});
check_arg([{head_func, HeadFunc}|Tail], Res)  ->
    check_arg(Tail, Res#arg{head = {head_func, HeadFunc}});
check_arg([{head, Term}|Tail], Res) ->
    check_arg(Tail, Res#arg{head = {head, Term}});
check_arg([{mode, read_only}|Tail], Res) ->
    check_arg(Tail, Res#arg{mode = read_only});
check_arg([{mode, read_write}|Tail], Res) ->
    check_arg(Tail, Res#arg{mode = read_write});
check_arg(Arg, _) ->
    {error, {badarg, Arg}}.

%%%-----------------------------------------------------------------
%%% Server functions
%%%-----------------------------------------------------------------
init(Parent) ->
    process_flag(trap_exit, true),
    loop(#state{parent = Parent}).

loop(State) ->
    receive
	Message ->
	    handle(Message, State)
    end.

handle({From, {log, B}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok, L#log.format == internal ->
	    case do_log(L, B) of
		N when integer(N) ->
		    reply(From, ok, (state_ok(S))#state{cnt = S#state.cnt+N});
		{error, Error, N} ->
		    S1 = S#state{cnt = S#state.cnt + N},
		    reply(From, Error, state_err(S1, Error));
		Error ->
		    F = if binary(B) -> log; true -> log_terms end,
		    do_exit(S, From, Error, ?failure(Error, F, 2))
	    end;
	L when L#log.status == ok, L#log.format == external ->
	    reply(From, {error, {format_external, L#log.name}}, S);
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {log, B}} | S#state.queue]})
    end;    

handle({From, {blog, B}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok ->
	    case do_log(L, B) of
		N when integer(N) ->
		    reply(From, ok, (state_ok(S))#state{cnt = S#state.cnt+N});
		{error, Error, N} ->
		    S1 = S#state{cnt = S#state.cnt + N},
		    reply(From, Error, state_err(S1, Error));
		Error ->
		    F = if binary(B) -> blog; true -> blog_terms end,
		    do_exit(S, From, Error, ?failure(Error, F, 2))
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {blog, B}} | S#state.queue]})
    end;

handle({alog, B}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    notify_owners({read_only,B}),
	    loop(S);
	L when L#log.status == ok, L#log.format == internal ->
	    case do_log(L, B) of
		N when integer(N) ->
		    loop((state_ok(S))#state{cnt = S#state.cnt + N});
		{error, {error, {full, _Name}}, 0} ->
		    loop(state_ok(S));
		{error, Error, N} ->
		    S1 = S#state{cnt = S#state.cnt + N},
		    loop(state_err(S1, Error));
		Error ->
		    do_stop(S),
		    F = if binary(B) -> alog; true -> alog_terms end,
		    exit(?failure(Error, F, 2))
	    end;
	L when L#log.status == ok ->
	    notify_owners({format_external, B}),
	    loop(S);
	L when L#log.status == {blocked, false} ->
	    notify_owners({blocked_log, B}),
	    loop(S);
	_ ->
	    loop(S#state{queue = [{alog, B} | S#state.queue]})
    end;

handle({balog, B}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    notify_owners({read_only,B}),
	    loop(S);
	L when L#log.status == ok ->
	    case do_log(L, B) of
		N when integer(N) ->
		    loop((state_ok(S))#state{cnt = S#state.cnt + N});
		{error, {error, {full, _Name}}, 0} ->
		    loop(state_ok(S));
		{error, Error, N} ->
		    S1 = S#state{cnt = S#state.cnt + N},
		    loop(state_err(S1, Error));
		Error ->
		    do_stop(S),
		    F = if binary(B) -> balog; true -> balog_terms end,
		    exit(?failure(Error, F, 2))
	    end;
	L when L#log.status == {blocked, false} ->
	    notify_owners({blocked_log, B}),
	    loop(S);
	_ ->
	    loop(S#state{queue = [{balog, B} | S#state.queue]})
    end;

handle({From, {block, QueueLogRecs}}, S) ->
    case get(log) of
	L when L#log.status == ok ->
	    do_block(From, QueueLogRecs, L),
	    reply(From, ok, S);
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {block, QueueLogRecs}} |
				  S#state.queue]})
    end;
    
handle({From, unblock}, S) ->
    case get(log) of
	L when L#log.status == ok ->
	    reply(From, {error, {not_blocked, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    S2 = do_unblock(L, S),
	    reply(From, ok, S2);
	L ->
	    reply(From, {error, {not_blocked_by_pid, L#log.name}}, S)
    end;

handle({From, sync}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok ->
	    Res = do_sync(L),
	    reply(From, Res, state_err(S, Res));
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, sync} | S#state.queue]})
    end;

handle({From, {truncate, Head, F, A}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok ->
	    H = merge_head(Head, L#log.head),
	    case catch do_trunc(L, H) of
		ok ->
		    erase(is_full),
		    notify_owners({truncated, S#state.cnt}),
		    N = if Head == none -> 0; true -> 1 end,
		    reply(From, ok, (state_ok(S))#state{cnt = N});
		Error ->
		    do_exit(S, From, Error, ?failure(Error, F, A))
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {truncate, Head, F, A}} 
				  | S#state.queue]})
    end;

handle({From, {chunk, Pos, B, N}},  S) ->
    case get(log) of
	L when L#log.status == ok ->	
	    R = do_chunk(L, Pos, B, N),
	    reply(From, R, S);
	L when L#log.blocked_by == From ->	
	    R = do_chunk(L, Pos, B, N),
	    reply(From, R, S);
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L ->
	    loop(S#state{queue = [{From, {chunk, Pos, B, N}} | S#state.queue]})
    end;

handle({From, {chunk_step, Pos, N}},  S) ->
    case get(log) of
	L when L#log.status == ok ->	
	    R = do_chunk_step(L, Pos, N),
	    reply(From, R, S);
	L when L#log.blocked_by == From ->	
	    R = do_chunk_step(L, Pos, N),
	    reply(From, R, S);
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {chunk_step, Pos, N}}
				  | S#state.queue]})
    end;

handle({From, {change_notify, Pid, NewNotify}}, S) ->
    case get(log) of
	L when L#log.status == ok ->
	    case do_change_notify(L, Pid, NewNotify) of
		{ok, L1} ->
		    put(log, L1),
		    reply(From, ok, S);
		Error ->
		    reply(From, Error, S)
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {change_notify, Pid, NewNotify}}
				  | S#state.queue]})
    end;

handle({From, {change_header, NewHead}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok ->
	    case check_head(NewHead, L#log.format) of 
		{ok, Head} ->
		    put(log, L#log{head = mk_head(Head, L#log.format)}),
		    reply(From, ok, S);
		Error ->
		    reply(From, Error, S)
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {change_header, NewHead}}
				  | S#state.queue]})
    end;

handle({From, {change_size, NewSize}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok ->	
	    case check_size(L#log.type, NewSize) of
		ok ->
		    case catch do_change_size(L, NewSize) of % does the put
			ok ->
			    reply(From, ok, S);
			{big, CurSize} ->
			    reply(From, 
				  {error, 
				   {new_size_too_small, L#log.name, CurSize}},
				  S);
			Else ->
			    reply(From, Else, state_err(S, Else))
		    end;
		not_ok ->
		    reply(From, {error, {badarg, size}}, S)
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, {change_size, NewSize}} 
				  | S#state.queue]})
    end;

handle({From, inc_wrap_file}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.type == halt ->
	    reply(From, {error, {halt_log, L#log.name}}, S);
	L when L#log.status == ok ->	
	    case catch do_inc_wrap_file(L) of
		{ok, L2, Lost} ->
		    put(log, L2),
		    notify_owners({wrap, Lost}),
		    reply(From, ok, S#state{cnt = S#state.cnt-Lost});
		{error, Error, L2} ->
		    put(log, L2),		    
		    reply(From, Error, state_err(S, Error));
		Error ->
		    do_exit(S, From, Error, ?failure(Error, inc_wrap_file, 1))
	    end;
	L when L#log.status == {blocked, false} ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	L when L#log.blocked_by == From ->
	    reply(From, {error, {blocked_log, L#log.name}}, S);
	_ ->
	    loop(S#state{queue = [{From, inc_wrap_file} | S#state.queue]})
    end;

handle({From, {reopen, NewFile, Head, F, A}}, S) ->
    case get(log) of
	L when L#log.mode == read_only ->
	    reply(From, {error, {read_only_mode, L#log.name}}, S);
	L when L#log.status == ok, L#log.filename /= NewFile  ->
	    case catch close_disk_log2(L) of % erases log
		closed ->
		    File = L#log.filename,
		    case catch rename_file(File, NewFile, L#log.type) of
			ok ->
			    H = merge_head(Head, L#log.head),
			    % do_open puts log
			    case do_open((S#state.args)#arg{name = L#log.name,
							    repair = truncate,
							    head = H,
							    file = File}) of
				{ok, Res, L2, Cnt} ->
				    put(log, L2#log{owners = L#log.owners,
						    head = L#log.head,
						    users = L#log.users}),
				    notify_owners({truncated, S#state.cnt}),
				    erase(is_full),
				    case Res of
					{error, _} ->
					    do_exit(S, From, Res, 
						    ?failure(Res, F, A));
					_ ->
					    reply(From, ok, S#state{cnt = Cnt})
				    end;
				Res ->
				    do_exit(S, From, Res, ?failure(Res, F, A))
			    end;
			Error ->
			    do_exit(S, From, Error, ?failure(Error, reopen, 2))
		    end;
		Error ->
		    do_exit(S, From, Error, ?failure(Error, F, A))
	    end;
	L when L#log.status == ok ->
	    reply(From, {error, {same_file_name, L#log.name}}, S);
	L ->
	    reply(From, {error, {blocked_log, L#log.name}}, S)
    end;

handle({From, {internal_open, A}}, S) ->
    case get(log) of
	undefined ->
	    case do_open(A) of % does the put
		{ok, Res, L, Cnt} ->
		    put(log, opening_pid(A#arg.linkto, A#arg.notify, L)),
		    reply(From, Res, S#state{args=A, cnt=Cnt});
		Res ->
		    do_fast_exit(S, From, Res, ?failure(Res, open, 1))
	    end;
	L ->
	    TestH = mk_head(A#arg.head, A#arg.format),
	    case compare_arg(A#arg.options, S#state.args, TestH, L#log.head) of
		ok ->
		    case add_pid(A#arg.linkto, A#arg.notify, L) of
			{ok, L1} ->
			    put(log, L1),
			    reply(From, {ok, L#log.name}, S);
			Error ->
			    reply(From, Error, S)
		    end;
		Error ->
		    reply(From, Error, S)
	    end
    end;

handle({From, close}, S) ->
    case do_close(From, S) of
	{stop, S1} ->
	    do_exit(S, From, ok, normal);
	{continue, S1} ->
	    reply(From, ok, S1)
    end;

handle({From, info}, S) ->
    reply(From, do_info(get(log), S#state.cnt), S);

handle({'EXIT', From, Reason}, S) when From == S#state.parent ->
    %% Parent orders shutdown
    do_stop(S),
    exit(Reason);
      
handle({'EXIT', From, _Reason}, S) ->
    L = get(log),
    case is_owner(From, L) of
	{true, _Notify} ->
	    case close_owner(From, L, S) of
		{stop, S1} ->
		    do_stop(S1),
		    exit(normal);
		{continue, S1} ->
		    loop(S1)
	    end;
	false ->
	    %% 'users' is not decremented.
	    S1 = do_unblock(From, get(log), S),
	    loop(S1)
    end;

handle({system, From, Req}, S) ->
    sys:handle_system_msg(Req, From, S#state.parent, ?MODULE, [], S);

handle(_, S) ->
    loop(S).

%% -> {ok, Log} | Error
do_change_notify(L, Pid, Notify) ->
    case is_owner(Pid, L) of
	{true, Notify} ->
	    {ok, L};
	{true, _OldNotify} when Notify /= true, Notify /= false ->
	    {error, {badarg, notify}};
	{true, _OldNotify} ->
	    Owners = lists:keydelete(Pid, 1, L#log.owners),
	    L1 = L#log{owners = [{Pid, Notify} | Owners]},
	    {ok, L1};
	false ->
	    {error, {not_owner, Pid}}
    end.

%% -> {stop, S} | {continue, S}
do_close(Pid, S) ->
    L = get(log),
    case is_owner(Pid, L) of
	{true, _Notify} ->
	    close_owner(Pid, L, S);
	false ->
	    close_user(Pid, L, S)
    end.

%% -> {stop, S} | {continue, S}
close_owner(Pid, L, S) ->
    L1 = L#log{owners = lists:keydelete(Pid, 1, L#log.owners)},
    put(log, L1),
    S2 = do_unblock(Pid, get(log), S),
    unlink(Pid),
    do_close2(L1, S2).
    
%% -> {stop, S} | {continue, S}
close_user(Pid, L, S) when L#log.users > 0 ->
    L1 = L#log{users = L#log.users - 1},
    put(log, L1),
    S2 = do_unblock(Pid, get(log), S),
    do_close2(L1, S2);
close_user(_Pid, _L, S) ->
    {continue, S}.

do_close2(L, S) when L#log.users == 0, L#log.owners == [] ->
    {stop, S};
do_close2(_L, S) ->
    {continue, S}.

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(_Parent, _, State) ->
    loop(State).

system_terminate(Reason, _Parent, _, State) ->
    do_stop(State),
    exit(Reason).

%%-----------------------------------------------------------------
%% Temporay code for upgrade.
%%-----------------------------------------------------------------
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
do_exit(S, From, Message, Reason) ->
    do_stop(S),    
    disk_log_server:close(self()),
    From ! {disk_log, self(), Message},
    exit(Reason).

do_fast_exit(S, From, Message, Reason) ->
    do_stop(S),
    From ! {disk_log, self(), Message},
    exit(Reason).

do_stop(S) ->
    proc_q(S#state.queue),
    close_disk_log(get(log)).

proc_q([{From, _R}|Tail]) ->
    From ! {disk_log, self(), {error, disk_log_stopped}},
    proc_q(Tail);
proc_q([_|T]) -> %% async stuff 
    proc_q(T);
proc_q([]) ->
    ok.

%% -> log()
opening_pid(Pid, Notify, L) ->
    {ok, L1} = add_pid(Pid, Notify, L),
    L1.

%% -> {ok, log()} | Error
add_pid(Pid, Notify, L) when pid(Pid) ->
    case is_owner(Pid, L) of
	false ->
            link(Pid),
	    {ok, L#log{owners = [{Pid, Notify} | L#log.owners]}};
	{true, Notify}  ->
%%	    {error, {pid_already_connected, L#log.name}};
	    {ok, L};
	{true, CurNotify} when Notify /= CurNotify ->
	    {error, {arg_mismatch, notify, CurNotify, Notify}}
    end;
add_pid(_NotAPid, _Notify, L) ->
    {ok, L#log{users = L#log.users + 1}}.

unblock_pid(Pid, L) when pid(Pid) ->
    case is_owner(L#log.blocked_by, L) of
	{true, _Notify} ->
	    ok;
	false ->
	    unlink(L#log.blocked_by)
    end;
unblock_pid(_NotAPid, _L) ->
    ok.

%% -> true | false
is_owner(Pid, L) ->
    case lists:keysearch(Pid, 1, L#log.owners) of
	{value, {_Pid, Notify}} ->
	    {true, Notify};
	false ->
	    false
    end.

%% ok | throw(Error)
rename_file(File, NewFile, halt) ->
    file:rename(File, NewFile);
rename_file(File, NewFile, wrap) ->
    rename_file(wrap_file_extensions(File), File, NewFile, ok).

rename_file([Ext|Exts], File, NewFile, Res) ->
    NRes = case file:rename(add_ext(File, Ext), add_ext(NewFile, Ext)) of
	       ok ->
		   Res;
	       Else ->
		   Else
	   end,
    rename_file(Exts, File, NewFile, NRes);
rename_file([], _File, _NewFiles, Res) -> Res.

%% "Old" error messages have been kept, arg_mismatch has been added.
compare_arg([], _A, none, _OrigHead) ->
    % no header option given
    ok;
compare_arg([], _A, Head, OrigHead) when Head /= OrigHead ->
    {error, {arg_mismatch, head, OrigHead, Head}};
compare_arg([], _A, _Head, _OrigHead) ->
    ok;
compare_arg([{Attr, Val} | Tail], A, Head, OrigHead) ->
    case compare_arg(Attr, Val, A) of
	{not_ok, OrigVal} -> 
	    {error, {arg_mismatch, Attr, OrigVal, Val}};
	ok -> 
	    compare_arg(Tail, A, Head, OrigHead);
	Error -> 
	    Error
    end.

compare_arg(file, F, A) when F /= A#arg.file ->
    {error, {name_already_open, A#arg.name}};
compare_arg(mode, read_only, A) when A#arg.mode == read_write ->
    {error, {open_read_write, A#arg.name}};
compare_arg(mode, read_write, A) when A#arg.mode == read_only ->
    {error, {open_read_only, A#arg.name}};
compare_arg(type, T, A) when T /= A#arg.type ->
    {not_ok, A#arg.type};
compare_arg(format, F, A) when F /= A#arg.format ->
    {not_ok, A#arg.format};
compare_arg(repair, R, A) when R /= A#arg.repair ->
    %% not used, but check it anyway...
    {not_ok, A#arg.repair};
compare_arg(_Attr, _Val, _A) -> 
    ok.

%% -> {ok, Res, log(), Cnt} | Error
do_open(A) ->
    L = #log{name = A#arg.name,
	     filename = A#arg.file,
	     size = A#arg.size,
	     head = mk_head(A#arg.head, A#arg.format),
	     mode = A#arg.mode},
    do_open2(L, A).
	    
mk_head({head, Term}, internal) -> {ok, term_to_binary(Term)};
mk_head({head, Bytes}, external) -> {ok, check_bytes(Bytes)};
mk_head(H, _) -> H.

check_bytes(Binary) when binary(Binary) ->     
    Binary;
check_bytes(Bytes) -> 
    list_to_binary(Bytes).

%%-----------------------------------------------------------------
%% Change size of the logs in runtime.
%%-----------------------------------------------------------------
%% -> ok | {big, CurSize} | throw(Error)
do_change_size(L, NewSize) when L#log.type == halt ->
    Fd = (L#log.extra)#halt.fd,
    {ok, CurSize} = file:position(Fd, cur),
    if
	NewSize == infinity ->
	    erase(is_full),
	    put(log, L#log{extra = #halt{fd = Fd, size = NewSize}}),
	    ok;
	CurSize =< NewSize ->
	    erase(is_full),
	    put(log, L#log{extra = #halt{fd = Fd, size = NewSize}}),
	    ok;
	true ->
	    {big, CurSize}
    end;
do_change_size(L, NewSize) when L#log.type == wrap ->
    {ok, Handle} = disk_log_1:change_size_wrap(L#log.extra, NewSize),
    erase(is_full),
    put(log, L#log{extra = Handle}),
    ok.

%% -> {ok, Head} | Error; Head = none | {head, H} | {M,F,A}
check_head({head, none}, _Format) ->
    {ok, none};
check_head({head_func, {M, F, A}}, _Format) when atom(M), atom(F), list(A) ->
    {ok, {M, F, A}};
check_head({head, Head}, external) ->
    case catch check_bytes(Head) of
	{'EXIT', _} ->
	    {error, {badarg, head}};
	_ ->
	    {ok, {head, Head}}
    end;
check_head({head, Term}, internal) ->
    {ok, {head, Term}};
check_head(_Head, _Format) ->
    {error, {badarg, head}}.

check_size(wrap, {NewMaxB,NewMaxF}) when
  integer(NewMaxB), integer(NewMaxF),
  NewMaxB > 0, NewMaxF > 0, NewMaxF < ?MAX_FILES ->
    ok;
check_size(halt, NewSize) when integer(NewSize), NewSize > 0 ->
    ok;
check_size(halt, infinity) ->
    ok;
check_size(_, _) ->
    not_ok.

%%-----------------------------------------------------------------
%% Increment a wrap log.
%%-----------------------------------------------------------------
%% -> {ok, log(), Lost} | {error, Error, log()} | throw(Error)
do_inc_wrap_file(L) ->
    #log{format = Format, extra = Handle} = L,
    case Format of
	internal ->
	    case disk_log_1:mf_int_inc(Handle, L#log.head) of
		{ok, Handle2, Lost} ->
		    {ok, L#log{extra = Handle2}, Lost};
		{error, Error, Handle2} ->
		    {error, Error, L#log{extra = Handle2}}
	    end;
	external ->
	    case disk_log_1:mf_ext_inc(Handle, L#log.head) of
		{ok, Handle2, Lost} ->
		    {ok, L#log{extra = Handle2}, Lost};
		{error, Error, Handle2} ->
		    {error, Error, L#log{extra = Handle2}}
	    end
    end.


%%-----------------------------------------------------------------
%% Open a log file.
%%-----------------------------------------------------------------
%% -> {ok, Reply, log(), Cnt} | Error
%% Note: the header is always written, even if the log size is too small.
do_open2(L, #arg{type = halt, format = internal, name = Name, 
		 file = FName, repair = Repair, size = Size, mode = Mode}) ->
    case catch disk_log_1:int_open(FName, Repair, Mode, L#log.head) of
	{ok, {_Alloc, Fd, {NoItems, _NoBytes}}} ->
	    {ok, {ok, Name}, L#log{format_type = halt_int, 
				   extra = #halt{fd = Fd, size =Size}}, 
	     NoItems};
	{repaired, Fd, Rec, Bad} ->
	    {ok, {repaired, Name, {recovered, Rec}, {badbytes, Bad}},
	     L#log{format_type = halt_int, extra = #halt{fd = Fd, size =Size}},
	     Rec};
	Error ->
	    Error
    end;
do_open2(L, #arg{type = wrap, format = internal, size = {MaxB, MaxF}, 
		 name = Name, repair = Repair, file = FName, mode = Mode}) ->
    case catch 
      disk_log_1:mf_int_open(FName, MaxB, MaxF, Repair, Mode, L#log.head) of
	{ok, Handle, Cnt} ->
	    {ok, {ok, Name}, L#log{type = wrap,
				   format_type = wrap_int, 
				   extra = Handle}, Cnt};
	{repaired, Handle, Rec, Bad, Cnt} ->
	    {ok, {repaired, Name, {recovered, Rec}, {badbytes, Bad}},
	     L#log{type = wrap, format_type = wrap_int, extra = Handle}, Cnt};
	Error ->
	    Error
    end;
do_open2(L, #arg{type = halt, format = external, file = FName, name = Name,
		 size = Size, repair = Repair, mode = Mode}) ->
    case catch disk_log_1:ext_open(FName, Repair, Mode, L#log.head) of
	{ok, {_Alloc, Fd, {NoItems, _NoBytes}}} ->
	    {ok, {ok, Name}, L#log{format_type = halt_ext, 
				   format = external,
				   extra = #halt{fd = Fd, size =Size}}, 
	     NoItems};
	Error ->
	    Error
    end;
do_open2(L, #arg{type = wrap, format = external, size = {MaxB, MaxF},
		 name = Name, file = FName, repair = Repair, mode = Mode}) ->
    case catch 
      disk_log_1:mf_ext_open(FName, MaxB, MaxF, Repair, Mode, L#log.head) of
	{ok, Handle, Cnt} ->
	    {ok, {ok, Name}, L#log{type = wrap,
				   format_type = wrap_ext, 
				   extra = Handle,
				   format = external}, Cnt};
	Error ->
	    Error
    end.

%% -> closed
close_disk_log(undefined) ->
    closed;
close_disk_log(L) ->
    unblock_pid(L#log.blocked_by, L),
    F = fun({Pid, _}) -> 
		unlink(Pid) 
	end,
    lists:foreach(F, L#log.owners),
    catch close_disk_log2(L),
    closed.

%% -> closed | throw(Error)
close_disk_log2(L) ->
    case L of
	#log{format_type = halt_int, extra = Halt} ->
	    disk_log_1:close(Halt#halt.fd, L#log.filename);
	#log{format_type = wrap_int, mode = Mode, extra = Handle} ->
	    disk_log_1:mf_int_close(Handle, Mode);
	#log{format_type = halt_ext, extra = Halt} ->
	    file:close(Halt#halt.fd);
	#log{format_type = wrap_ext, mode = Mode, extra = Handle} ->
	    disk_log_1:mf_ext_close(Handle, Mode)
    end,
    erase(log),
    closed.

do_format_error({error, Module, Error}) ->
    Module:format_error(Error);
do_format_error({error, Reason}) ->
    do_format_error(Reason);
do_format_error({Node, Error = {error, _Reason}}) ->
    lists:append(io_lib:format("~p: ", [Node]), do_format_error(Error));
do_format_error({badarg, Arg}) ->
    io_lib:format("The argument ~p is missing, not recognized or "
		  "not wellformed~n", [Arg]);
do_format_error({size_mismatch, OldSize, ArgSize}) ->
    io_lib:format("The given size ~p does not match the size ~p found on "
		  "the disk log size file~n", [ArgSize, OldSize]);
do_format_error({read_only_mode, Log}) ->
    io_lib:format("The disk log ~p has been opened read-only, but the "
		  "requested operation needs read-write access~n", [Log]);
do_format_error({format_external, Log}) ->
    io_lib:format("The requested operation can only be applied on internally "
		  "formatted disk logs, but ~p is externally formatted~n",
		  [Log]);
do_format_error({blocked_log, Log}) ->
    io_lib:format("The blocked disk log ~p does not queue requests, or "
		  "the log has been blocked by the calling process~n", [Log]);
do_format_error({full, Log}) ->
    io_lib:format("The halt log ~p is full~n", [Log]);
do_format_error({not_blocked, Log}) ->
    io_lib:format("The disk log ~p is not blocked~n", [Log]);
do_format_error({not_owner, Pid}) ->
    io_lib:format("The pid ~p is not an owner of the disk log~n", [Pid]);
do_format_error({not_blocked_by_pid, Log}) ->
    io_lib:format("The disk log ~p is blocked, but only the blocking pid "
		  "can unblock a disk log~n", [Log]);
do_format_error({new_size_too_small, Log, CurrentSize}) ->
    io_lib:format("The current size ~p of the halt log ~p is greater than the "
		  "requested new size~n", [CurrentSize, Log]);
do_format_error({halt_log, Log}) ->
    io_lib:format("The halt log ~p cannot be wrapped~n", [Log]);
do_format_error({same_file_name, Log}) ->
    io_lib:format("Current and new file name of the disk log ~p "
		  "are the same~n", [Log]);
do_format_error({arg_mismatch, Option, FirstValue, ArgValue}) ->
    io_lib:format("The value ~p of the disk log option ~p does not match "
		  "the current value ~p~n", [ArgValue, Option, FirstValue]);
do_format_error({name_already_open, Log}) ->
    io_lib:format("The disk log ~p has already opened another file~n", [Log]);
do_format_error({node_already_open, Log}) ->
    io_lib:format("The distribution option of the disk log ~p does not match "
		  "already open log~n", [Log]);
do_format_error({open_read_write, Log}) ->
    io_lib:format("The disk log ~p has already been opened read-write~n", 
		  [Log]);
do_format_error({open_read_only, Log}) ->
    io_lib:format("The disk log ~p has already been opened read-only~n", 
		  [Log]);
do_format_error({not_internal_wrap, Log}) ->
    io_lib:format("The requested operation cannot be applied since ~p is not "
		  "an internally formatted disk log~n", [Log]);
do_format_error(no_such_log) ->
    io_lib:format("There is no disk log with the given name~n", []);
do_format_error(nonode) ->
    io_lib:format("There seems to be no node up that can handle "
		  "the request~n", []);
do_format_error(nodedown) ->
    io_lib:format("There seems to be no node up that can handle "
		  "the request~n", []);
do_format_error({corrupt_log_file, FileName}) ->
    io_lib:format("The wrap log file ~s contains corrupt data~n", [FileName]);
do_format_error({need_repair, FileName}) ->
    io_lib:format("The wrap log file ~s has not been closed properly and "
		  "needs repair~n", [FileName]);
do_format_error({not_a_log_file, FileName}) ->
    io_lib:format("The file ~s is not a wrap log file~n", [FileName]);
do_format_error({invalid_header, InvalidHeader}) ->
    io_lib:format("The disk log header is not wellformed: ~p~n", 
		  [InvalidHeader]);
do_format_error(end_of_log) ->
    io_lib:format("An attempt was made to step outside a not yet "
		  "full wrap log~n", []);
do_format_error({invalid_index_file, FileName}) ->
    io_lib:format("The wrap log index file ~s cannot be used~n",
		  [FileName]);
do_format_error({no_continuation, BadCont}) ->
    io_lib:format("The term ~p is not a chunk continuation~n", [BadCont]);
do_format_error({file_error, FileName, Reason}) ->
    io_lib:format("~s: ~p~n", [FileName, file:format_error(Reason)]);
do_format_error(E) ->
    io_lib:format("~p~n", [E]).

do_info(L, Cnt) ->
    #log{name = Name, type = Type, mode = Mode, filename = File, 
	 extra = Extra, status = Status, owners = Owners, users = Users,
	 format = Format, head = Head} = L,
    Size = case Type of
	       wrap ->
		   disk_log_1:get_wrap_size(Extra);
	       halt ->
		   Extra#halt.size
	   end,
    Distribution =
	case disk_log_server:get_log_pids(Name) of
	    {local, _Pid} -> 
		local;
	    {distributed, Pids} ->
		lists:map(fun(P) -> node(P) end, Pids);		
	    undefined -> % "cannot happen"
		[]
	end,
    RW = case Type of
	     wrap when Mode == read_write ->
		 #handle{curB = CurB, curF = CurF, 
			 cur_cnt = CurCnt, acc_cnt = AccCnt, 
			 noFull = NoFull, accFull = AccFull} = Extra,
		 NewAccFull = AccFull + NoFull,
		 NewExtra = Extra#handle{noFull = 0, accFull = NewAccFull},
		 put(log, L#log{extra = NewExtra}),
		 [{no_current_bytes, CurB},
		  {no_current_items, CurCnt},
		  {no_items, Cnt},
		  {no_written_items, CurCnt + AccCnt},
		  {current_file, CurF},
		  {no_overflows, {NewAccFull, NoFull}}
		 ];
	     halt when Mode == read_write ->
		 IsFull = case get(is_full) of 
			      undefined -> false; 
			      _ -> true 
			  end,
		 [{full, IsFull},
		  {no_written_items, Cnt}
		 ];
	     _ when Mode == read_only ->
		 []
	 end,
    HeadL = case Mode of
		read_write ->
		    [{head, Head}];
		read_only ->
		    []
	    end,
    Common = [{name, Name},
	      {file, File},
	      {type, Type},
	      {format, Format},
	      {size, Size},
	      {items, Cnt}, % kept for "backward compatibility" (undocumented)
	      {owners, Owners},
	      {users, Users}] ++
	     HeadL ++
	     [{mode, Mode},
	      {status, Status},
	      {node, node()},
	      {distributed, Distribution}
	     ],
    Common ++ RW.

do_block(Pid, QueueLogRecs, L) ->
    L2 = L#log{status = {blocked, QueueLogRecs}, blocked_by = Pid},
    put(log, L2),
    case is_owner(Pid, L2) of
	{true, _Notify} ->
	    ok;
	false ->
	    link(Pid)
    end.

do_unblock(Pid, L, S) when L#log.blocked_by == Pid ->
    do_unblock(L, S);
do_unblock(_Pid, _L, S) ->
    S.

do_unblock(L, S) ->
    unblock_pid(L#log.blocked_by, L),
    L2 = L#log{blocked_by = none, status = ok},
    put(log, L2),
    send_self(S#state.queue),
    S#state{queue = []}.

send_self(L) ->
    lists:foreach(fun(M) -> self() ! M end, lists:reverse(L)).

%% -> integer() | {error, Error, integer()} | FatalError
do_log(#log{format_type = halt_int, filename = FileName, extra = Halt}, B)
  when Halt#halt.size == infinity ->
    log_bin(Halt#halt.fd, FileName, B);
do_log(L, B) when L#log.format_type == halt_int ->
    #log{name = Name, filename = FileName, extra = Halt} = L,
    #halt{fd = Fd, size = Sz} = Halt,
    {ok, CurSize} = file:position(Fd, cur),
    BSize = sz(B),
    IsFull = get(is_full),
    if
	IsFull == true ->
	    {error, {error, {full, Name}}, 0};
	CurSize + BSize =< Sz ->
	    log_bin(Fd, FileName, B);
	true ->
	    put(is_full, true),
	    notify_owners(full),
	    {error, {error, {full, Name}}, 0}
    end;
do_log(L, B) when L#log.format_type == wrap_int ->
    case catch disk_log_1:mf_int_log(L#log.extra, B, L#log.head) of
	{ok, Handle, Logged, Lost} ->
	    notify_owners({wrap, Lost}),
	    put(log, L#log{extra = Handle}),
	    Logged - Lost;
	{ok, Handle, Logged} ->
	    put(log, L#log{extra = Handle}),
	    Logged;
	{error, Error, Handle, Logged, Lost} ->
	    put(log, L#log{extra = Handle}),
	    {error, Error, Logged - Lost};
	FatalError ->
	    FatalError
    end;
do_log(L, B) when L#log.format_type == halt_ext ->
    #log{filename = FName, extra = Halt} = L,
    #halt{fd = Fd, size = Sz} = Halt,
    {ok, CurSize} = file:position(Fd, cur),
    BSize = xsz(B),
    IsFull = get(is_full),
    if
	IsFull == true ->
	    {error, {error, {full, L#log.name}}, 0};
	CurSize + BSize =< Sz ->
	    if
		binary(B) ->
		    write_bins([B], Fd, FName, 0);
		true ->
		    write_bins(B, Fd, FName, 0)
	    end;
	true ->
	    put(is_full, true),
	    notify_owners(full),
	    {error, {error, {full, L#log.name}}, 0}
    end;
do_log(L, B) when L#log.format_type == wrap_ext ->
    case disk_log_1:mf_ext_log(L#log.extra, B, L#log.head) of
	{ok, Handle, Logged, Lost} ->
	    notify_owners({wrap, Lost}),
	    put(log, L#log{extra = Handle}),
	    Logged - Lost;
	{ok, Handle, Logged} ->
	    put(log, L#log{extra = Handle}),
	    Logged;
	{error, Error, Handle, Logged, Lost} ->
	    put(log, L#log{extra = Handle}),
	    {error, Error, Logged - Lost}
    end.

log_bin(Fd, FileName, B) ->
    case catch disk_log_1:log(Fd, FileName, B) of
	N when integer(N) ->
	    N;
	Error ->
	    {error, Error, 0}
    end.

write_bins([], _Fd, _FName, N) -> N;
write_bins([B|Bs], Fd, FName, N) ->
    case file:write(Fd, B) of
	ok    -> write_bins(Bs, Fd, FName, N + 1);
	{error, Error} -> {error, {file_error, FName, Error}}
    end.

sz(B) when binary(B) -> size(B) + ?HEADERSZ;
sz([B|T]) when binary(B) -> size(B) + ?HEADERSZ + sz(T);
sz([]) -> 0.
	
xsz(B) when binary(B) -> size(B);
xsz([B|T]) when binary(B) -> size(B) + xsz(T);
xsz([]) -> 0.
	
do_sync(#log{format_type = halt_int, extra = Halt}) ->
    disk_log_1:sync(Halt#halt.fd);
do_sync(#log{format_type = wrap_int, extra = Handle}) ->
    disk_log_1:mf_int_sync(Handle);
do_sync(#log{format_type = halt_ext, extra = Halt}) ->
    file:sync(Halt#halt.fd);
do_sync(#log{format_type = wrap_ext, extra = Handle}) ->
    disk_log_1:mf_ext_sync(Handle).

%% -> ok | Error | throw(Error)
do_trunc(L, Head) when L#log.format_type == halt_int ->
    Fd = (L#log.extra)#halt.fd,
    disk_log_1:truncate(Fd, L#log.filename, Head);
do_trunc(L, Head) when L#log.format_type == halt_ext ->
    Fd = (L#log.extra)#halt.fd,
    file:position(Fd, bof),
    file:truncate(Fd),
    case Head of
	{ok, H} ->
	    case file:write(Fd, H) of
		ok -> ok;
		{error, Error} -> {error, {file_error, L#log.filename, Error}}
	    end;
	none -> ok
    end;
do_trunc(L, Head) when L#log.type == wrap ->
    Handle = L#log.extra,
    OldHead = L#log.head,
    {MaxB, MaxF} = disk_log_1:get_wrap_size(Handle),
    ok = do_change_size(L, {MaxB, 1}),
    NewLog = trunc_wrap((get(log))#log{head = Head}),
    %% Just to remove all files with suffix > 1:
    NewLog2 = trunc_wrap(NewLog),
    NewHandle = (NewLog2#log.extra)#handle{noFull = 0, accFull = 0},
    do_change_size(NewLog2#log{extra = NewHandle, head = OldHead}, 
		   {MaxB, MaxF}).

trunc_wrap(L) ->
    case do_inc_wrap_file(L) of
	{ok, L2, _Lost} ->
	    L2;
	{error, Error, L2} ->
	    throw(Error)
    end.

do_chunk(L, Pos, B, N) when L#log.format_type == halt_int ->
    Fd = (L#log.extra)#halt.fd,
    case L#log.mode of
	read_only ->
	    disk_log_1:chunk_read_only(Fd, L#log.filename, Pos, B, N);
	read_write ->
	    disk_log_1:chunk(Fd, L#log.filename, Pos, B, N)
    end;
do_chunk(#log{format_type = wrap_int, mode = read_only, 
	      extra = Handle}, Pos, B, N) ->
    disk_log_1:mf_int_chunk_read_only(Handle, Pos, B, N);
do_chunk(#log{format_type = wrap_int, extra = Handle}, Pos, B, N) ->
    disk_log_1:mf_int_chunk(Handle, Pos, B, N);
do_chunk(Log, _Pos, _B, _) ->
    {error, {format_external, Log#log.name}}.

do_chunk_step(#log{format_type = wrap_int, extra = Handle}, Pos, N) ->
    disk_log_1:mf_int_chunk_step(Handle, Pos, N);
do_chunk_step(Log, _Pos, _N) ->
    {error, {not_internal_wrap, Log#log.name}}.

reply(To, Rep, S) ->
    To ! {disk_log, self(), Rep},
    loop(S).

req(Log, R) ->
    case disk_log_server:get_log_pids(Log) of
	{local, Pid} ->
	    monitor_request(Pid, R);
	undefined ->
	    {error, no_such_log};
	{distributed, Pids} ->
	    multi_req({self(), R}, Pids)
    end.

multi_req(Msg, Pids) ->
    Refs = 
	lists:map(fun(Pid) ->
			  Ref = erlang:monitor(process, Pid),
			  Pid ! Msg,
			  {Pid, Ref}
		  end, Pids),
    lists:foldl(fun({Pid, Ref}, Reply) ->
			receive
			    {'DOWN', Ref, process, Pid, _Info} ->
				Reply;
			    {disk_log, Pid, _Reply} ->
				erlang:demonitor(Ref),
				receive 
				    {'DOWN', Ref, process, Pid, _Reason} ->
					ok
				after 0 -> 
					ok
				end
			end
		end, {error, nonode}, Refs).

sreq(Log, R) ->
    case nearby_pid(Log, node()) of
	undefined ->
	    {error, no_such_log};
	Pid ->
	    monitor_request(Pid, R)
    end.

%% Local req - always talk to log on Node
lreq(Log, R, Node) ->
    case nearby_pid(Log, Node) of
	Pid when pid(Pid), node(Pid) == Node ->
	    monitor_request(Pid, R);
	_Else ->
	    {error, no_such_log}
    end.

nearby_pid(Log, Node) ->
    case disk_log_server:get_log_pids(Log) of
	undefined ->
	    undefined;
	{local, Pid} ->
	    Pid;
	{distributed, Pids} ->
	    get_near_pid(Pids, Node)
    end.

get_near_pid([Pid | _], Node) when node(Pid) == Node -> Pid;
get_near_pid([Pid], _ ) -> Pid;
get_near_pid([_ | T], Node) -> get_near_pid(T, Node).

monitor_request(Pid, Req) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {self(), Req},
    receive 
	{'DOWN', Ref, process, Pid, _Info} ->
	    {error, no_such_log};
	{disk_log, Pid, Reply} ->
	    erlang:demonitor(Ref),
	    receive 
		{'DOWN', Ref, process, Pid, normal} -> 
		    Reply
	    after 0 ->
		    Reply
	    end
    end.

req2(Pid, R) ->
    monitor_request(Pid, R).

merge_head(none, Head) ->
    Head;
merge_head(Head, _) ->
    Head.

%% -> List of extensions of existing files (no dot included) | throw(FileError)
wrap_file_extensions(File) -> 
    {_CurF, _CurFSz, _TotSz, NoOfFiles} =
	disk_log_1:read_index_file(File),
    Fs = if 
	     NoOfFiles >= 1 ->
		 lists:seq(1, NoOfFiles);
	     NoOfFiles == 0 ->
		 []
	 end,
    Fun = fun(Ext) ->
		  case file:read_file_info(add_ext(File, Ext)) of
		      {ok, _} ->
			  true;
		      _Else ->
			  false
		  end
	  end,
    lists:filter(Fun, ["idx", "siz" | Fs]).

add_ext(File, Ext) ->
    lists:concat([File, ".", Ext]).

notify(Log, R) ->
    case disk_log_server:get_log_pids(Log) of
	undefined ->
	    {error, no_such_log};
	{local, Pid} ->
	    Pid ! R,
	    ok;
	{distributed, Pids} ->
	    lists:foreach(fun(Pid) -> Pid ! R end, Pids),
	    ok
    end.

notify_owners(Note) ->
    L = get(log),
    Msg = {disk_log, node(), L#log.name, Note},
    lists:foreach(fun({Pid, true}) -> Pid ! Msg;
		     (_) -> ok
		  end, L#log.owners).

state_ok(S) when S#state.error_status == ok -> S;
state_ok(S) ->
    notify_owners({error_status, ok}),
    S#state{error_status = ok}.

%% Note: Err = ok | {error, Reason}
state_err(S, Err) when S#state.error_status == Err -> S;
state_err(S, Err) ->
    notify_owners({error_status, Err}),
    S#state{error_status = Err}.