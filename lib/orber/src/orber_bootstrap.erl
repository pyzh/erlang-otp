%%--------------------------------------------------------------------
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
%%-----------------------------------------------------------------
%% File: orber_bootstrap.erl
%% Author: Lars Thorsen
%% 
%% Description:
%%    This file contains the bootstrap handling interface
%%
%% Creation date: 970827
%%
%%-----------------------------------------------------------------
-module(orber_bootstrap).

-behaviour(gen_server).

-include_lib("orber/include/corba.hrl").
-include_lib("orber/src/orber_iiop.hrl").
%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([start/1]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([init/1, terminate/2, handle_call/3, handle_info/2]).
-export([handle_cast/2, code_change/3]).

%%-----------------------------------------------------------------
%% Server state record
%%-----------------------------------------------------------------
-record(state, {port, portNo}).

%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
start(Opts) ->
    gen_server:start_link({local, orber_bootstrap}, orber_bootstrap, Opts, []).

%%-----------------------------------------------------------------
%% Server functions
%%-----------------------------------------------------------------
init({port, normal, PortNo}) ->
    Port = open_port({spawn, cmd_string(PortNo)}, [{packet, 4}]),
    {ok, #state{port=Port, portNo=PortNo}}.

terminate(Reason, State) ->
    State#state.port ! {self(), close},
    Port = State#state.port,
    receive
	{ Port, closed} ->
	    ok
    after 1000 ->
	    error_logger:error_msg("orber_bootstrap: port not stopped"),
	    ok
    end.

%%-----------------------------------------------------------------
%% Func: handle_call/3
%%-----------------------------------------------------------------
handle_call(_, _, State) ->
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: handle_cast/2
%%-----------------------------------------------------------------
handle_cast(_, State) ->
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: handle_info/2
%%-----------------------------------------------------------------
handle_info({Port, {data, Data}}, State) when State#state.port == Port ->
    case catch cdr_decode:dec_message(null, Data) of
	{'EXCEPTION', _} ->
	    Reply = cdr_encode:enc_message_error(orber:giop_version());
	{'EXIT', _} ->
	    Reply = cdr_encode:enc_message_error(orber:giop_version());
	{Version, Hdr, Par, TypeCodes} ->
	    Result = corba:request_from_iiop(Hdr#request_header.object_key,
					     list_to_atom(Hdr#request_header.operation),
					     Par, [], 'true'),
	    case result_to_list(Result, TypeCodes) of
		[{'EXCEPTION', Exception} | _] ->
		    {TypeOfException, ExceptionTypeCode} =
			orber_typedefs:get_exception_def(Exception),
		    Reply = cdr_encode:enc_reply(Version,
						 Hdr#request_header.request_id,
						 TypeOfException,
						 {ExceptionTypeCode, [], []}, 
						 Exception, []);
		[Res |OutPar] ->
		    Reply = cdr_encode:enc_reply(Version,
			      Hdr#request_header.request_id,
			      'no_exception',
			      TypeCodes,
			      Res, OutPar);
		_ ->
		    E = #'INTERNAL'{completion_status=?COMPLETED_MAYBE},
		    {TypeOfException, ExceptionTypeCode} =
			orber_typedefs:get_exception_def(E),
		    Reply = cdr_encode:enc_reply(Version,
						 Hdr#request_header.request_id,
						 TypeOfException,
						 {ExceptionTypeCode, [], []}, 
						 E, [])
	    end
    end,
    Port ! {self(), {command, Reply}},
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: code_change/3
%%-----------------------------------------------------------------
code_change(OldVsn, State, Extra) ->
    {ok, State}.


%%-----------------------------------------------------------------
%% Internal Functions
%%-----------------------------------------------------------------
cmd_string(PortNo) ->
    PrivDir = code:priv_dir(orber),
    PrivDir ++ "/bin/obj_init_port -p " ++ integer_to_list(PortNo).


result_to_list(Result, {TkRes, _, TkOut}) ->
   case length(TkOut) of
       0 ->
	   [Result];
       N ->
	   tuple_to_list(Result)
   end.
