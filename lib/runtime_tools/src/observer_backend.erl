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
-module(observer_backend).

%% General
-export([vsn/0]).

%% etop stuff
-export([etop_collect/1]).
-include("observer_backend.hrl").

%% ttb stuff
-export([ttb_init_node/3,
	 ttb_write_trace_info/3,
	 ttb_write_binary/2,
	 ttb_stop/1,
	 ttb_fetch/2,
	 ttb_get_filenames/1]).
-define(CHUNKSIZE,8191). % 8 kbytes - 1 byte

vsn() ->
    case application:load(runtime_tools) of
	R when R=:=ok; R=:={error,{already_loaded,runtime_tools}} -> 
	    application:get_key(runtime_tools,vsn);
	Error -> Error
    end.



%%
%% etop backend
%%
etop_collect(Collector) ->
    ProcInfo = 	lists:flatmap(
	  fun(P) -> 
		  case erlang:is_process_alive(P) of
		      true ->
			  Name = case pi(P,registered_name) of
				     [] -> 
					 pi(P,initial_call);
				     N -> 
					 N
				 end,
			  [#etop_proc_info{pid=P,
					   mem=pi(P,memory),
					   reds=pi(P,reductions),
					   name=Name,
					   cf=pi(P,current_function),
					   mq=pi(P,message_queue_len)}];
		      false ->
			  []
		  end
	  end,
	  lists:delete(self(),processes())),
    Collector ! {self(),#etop_info{now = now(),
				   n_procs = length(ProcInfo),
				   run_queue = erlang:statistics(run_queue),
				   wall_clock = erlang:statistics(wall_clock),
				   runtime = erlang:statistics(runtime),
				   memi = [{total, c:memory(total)},
					   {processes, c:memory(processes)}, 
					   {ets, c:memory(ets)},
					   {atom, c:memory(atom)},
					   {code, c:memory(code)},
					   {binary, c:memory(binary)}],
				   procinfo = ProcInfo
				  }}.


pi(P,Key) ->
    case catch process_info(P,Key) of
	{'EXIT',_Reason} -> 0; % oops - bad timing, the process just died
	{Key,Value} -> Value;
	[] -> []
    end.



%%
%% ttb backend
%%
ttb_init_node(MetaFile,PI,Traci) ->
    if
	is_list(MetaFile);
	is_atom(MetaFile) ->
	    file:delete(MetaFile);
	true -> 				% {local,_,_}
	    ok
    end,
    Self = self(),
    MetaPid = spawn(fun() -> ttb_meta_tracer(MetaFile,PI,Self) end),
    receive {MetaPid,started} -> ok end,
    MetaPid ! {metadata,Traci},
    case PI of
	true ->
	    Proci = pnames(),
	    MetaPid ! {metadata,Proci};
	false ->
	    ok
    end,
    {ok,MetaPid}.

ttb_write_trace_info(MetaPid,Key,What) ->
    MetaPid ! {metadata,Key,What},
    ok.

ttb_meta_tracer(MetaFile,PI,Parent) ->
    case PI of
	true ->
	    ReturnMS = [{'_',[],[{return_trace}]}],
	    erlang:trace_pattern({erlang,spawn,3},ReturnMS,[meta]),
	    erlang:trace_pattern({erlang,spawn_link,3},ReturnMS,[meta]),
	    erlang:trace_pattern({erlang,spawn_opt,1},ReturnMS,[meta]),
	    erlang:trace_pattern({erlang,register,2},[],[meta]),
	    erlang:trace_pattern({global,register_name,2},[],[meta]);
	false ->
	    ok
    end,
    Parent ! {self(),started},
    ttb_meta_tracer_loop(MetaFile,PI,dict:new()).

ttb_meta_tracer_loop(MetaFile,PI,Acc) ->
    receive
	{trace_ts,_,call,{erlang,register,[Name,Pid]},_} ->
	    ttb_store_meta({pid,{Pid,Name}},MetaFile),
	    ttb_meta_tracer_loop(MetaFile,PI,Acc);
	{trace_ts,_,call,{global,register_name,[Name,Pid]},_} ->
	    ttb_store_meta({pid,{Pid,{global,Name}}},MetaFile),
	    ttb_meta_tracer_loop(MetaFile,PI,Acc);
	{trace_ts,CallingPid,call,{erlang,spawn_opt,[{M,F,Args,_}]},_} ->
	    MFA = {M,F,length(Args)},
	    NewAcc = dict:update(CallingPid,
				 fun(Old) -> [MFA|Old] end, [MFA], 
				 Acc),
	    ttb_meta_tracer_loop(MetaFile,PI,NewAcc);
	{trace_ts,CallingPid,return_from,{erlang,spawn_opt,_Arity},Ret,_} ->
	    case Ret of
		{NewPid,_Mref} when is_pid(NewPid) -> ok;
		NewPid when is_pid(NewPid) -> ok
	    end,
	    NewAcc = 
		dict:update(CallingPid,
			    fun([H|T]) -> 
				    ttb_store_meta({pid,{NewPid,H}},MetaFile),
				    T 
			    end,
			    Acc),
	    ttb_meta_tracer_loop(MetaFile,PI,NewAcc);
	{trace_ts,CallingPid,call,{erlang,Spawn,[M,F,Args]},_} 
	when Spawn==spawn;Spawn==spawn_link ->
	    MFA = {M,F,length(Args)},
	    NewAcc = dict:update(CallingPid,
				 fun(Old) -> [MFA|Old] end, [MFA], 
				 Acc),
	    ttb_meta_tracer_loop(MetaFile,PI,NewAcc);

	{trace_ts,CallingPid,return_from,{erlang,Spawn,_Arity},NewPid,_} 
	when Spawn==spawn;Spawn==spawn_link ->
	    NewAcc = 
		dict:update(CallingPid,
			    fun([H|T]) -> 
				    ttb_store_meta({pid,{NewPid,H}},MetaFile),
				    T
			    end,
			    Acc),
	    ttb_meta_tracer_loop(MetaFile,PI,NewAcc);

	{metadata,Data} when list(Data) ->
	    ttb_store_meta(Data,MetaFile),
	    ttb_meta_tracer_loop(MetaFile,PI,Acc);

	{metadata,Key,Fun} when function(Fun) ->
	    ttb_store_meta([{Key,Fun()}],MetaFile),
	    ttb_meta_tracer_loop(MetaFile,PI,Acc);

	{metadata,Key,What} ->
	    ttb_store_meta([{Key,What}],MetaFile),
	    ttb_meta_tracer_loop(MetaFile,PI,Acc);

	stop when PI=:=true ->
	    erlang:trace_pattern({erlang,spawn,3},false,[meta]),
	    erlang:trace_pattern({erlang,spawn_link,3},false,[meta]),
	    erlang:trace_pattern({erlang,spawn_opt,1},false,[meta]),
	    erlang:trace_pattern({erlang,register,2},false,[meta]),
	    erlang:trace_pattern({global,register_name,2},false,[meta]);
	stop ->
	    ok
    end.

pnames() ->
    Processes = processes(),
    Globals = lists:map(fun(G) -> {global:whereis_name(G),G} end, 
			global:registered_names()),
    lists:flatten(lists:foldl(fun(Pid,Acc) -> [pinfo(Pid,Globals)|Acc] end, 
			      [], Processes)).

pinfo(P,Globals) ->
    case process_info(P,registered_name) of
	[] ->
	    case lists:keysearch(P,1,Globals) of
		{value,{P,G}} -> {pid,{P,{global,G}}};
		false -> 
		    case process_info(P,initial_call) of
			{_,I} -> {pid,{P,I}};
			undefined -> [] % the process has terminated
		    end
	    end;
	{_,R} -> {pid,{P,R}};
	undefined -> [] % the process has terminated
    end.


ttb_store_meta(Data,{local,MetaFile,Port}) when list(Data) ->
    ttb_send_to_port(Port,MetaFile,Data);
ttb_store_meta(Data,MetaFile) when list(Data) ->
    {ok,Fd} = file:open(MetaFile,[raw,append]),
    ttb_write_binary(Fd,Data),
    file:close(Fd);
ttb_store_meta(Data,MetaFile) ->
    ttb_store_meta([Data],MetaFile).

ttb_write_binary(Fd,[H|T]) ->
    file:write(Fd,ttb_make_binary(H)),
    ttb_write_binary(Fd,T);
ttb_write_binary(_Fd,[]) ->
    ok.

ttb_send_to_port(Port,MetaFile,[H|T]) ->
    B1 = ttb_make_binary(H),
    B2 = term_to_binary({metadata,MetaFile,B1}),
    erlang:port_command(Port,B2),
    ttb_send_to_port(Port,MetaFile,T);
ttb_send_to_port(_Port,_MetaFile,[]) ->
    ok.

ttb_make_binary(Term) ->
    B = term_to_binary(Term),
    SizeB = size(B),
    if SizeB > 255 ->
	    %% size is bigger than 8 bits, must therefore add an extra
	    %% size field
	    SB = term_to_binary({'$size',SizeB}),
	    <<(size(SB)):8, SB/binary, B/binary>>;
        true ->
	    <<SizeB:8, B/binary>>
    end.

    
%% Stop ttb
ttb_stop(MetaPid) ->
    Ref = erlang:monitor(process,MetaPid),
    MetaPid ! stop,
    %% Must wait for the process to terminate there
    %% because dbg will be stopped when this function
    %% returns, and then the Port (in {local,MetaFile,Port})
    %% cannot be accessed any more.
    receive {'DOWN', Ref, process, MetaPid, _Info} -> ok end,
    seq_trace:reset_trace(),
    seq_trace:set_system_tracer(false).

%% Fetch ttb logs from remote node
ttb_fetch(MetaFile,{Port,Host}) ->
    erlang:process_flag(priority,low),
    Files = ttb_get_filenames(MetaFile),
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {packet, 2}]),
    send_files({Sock,Host},Files),
    ok = gen_tcp:close(Sock).


send_files({Sock,Host},[File|Files]) ->
    {ok,Fd} = file:open(File,[raw,read,binary]),
    gen_tcp:send(Sock,<<1,(list_to_binary(File))/binary>>),
    send_chunks(Sock,Fd),
    file:delete(File),
    send_files({Sock,Host},Files);
send_files({_Sock,_Host},[]) ->
    done.

send_chunks(Sock,Fd) ->
    case file:read(Fd,?CHUNKSIZE) of
	{ok,Bin} -> 
	    ok = gen_tcp:send(Sock, <<0,Bin/binary>>),
	    send_chunks(Sock,Fd);
	eof ->
	    ok;
	{error,Reason} ->
	    ok = gen_tcp:send(Sock, <<2,(term_to_binary(Reason))/binary>>)
    end.

ttb_get_filenames(MetaFile) ->
    Dir = filename:dirname(MetaFile),
    Root = filename:rootname(filename:basename(MetaFile)),
    {ok,List} = file:list_dir(Dir),
    match_filenames(Dir,Root,List,[]).

match_filenames(Dir,MetaFile,[H|T],Files) ->
    case lists:prefix(MetaFile,H) of
	true -> match_filenames(Dir,MetaFile,T,[filename:join(Dir,H)|Files]);
	false -> match_filenames(Dir,MetaFile,T,Files)
    end;
match_filenames(_Dir,_MetaFile,[],Files) ->
    Files.
