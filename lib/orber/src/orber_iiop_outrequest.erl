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
%%--------------------------------------------------------------------
%% File: orber_iiop_inrequest.erl
%% Author: Lars Thorsen
%% 
%% Description:
%%    This file contains the handling of incommingoutgoing requests
%%
%% Creation date: 990426
%%
%%-----------------------------------------------------------------
-module(orber_iiop_outrequest).

-behaviour(gen_server).
-include_lib("orber/src/orber_iiop.hrl").
-include_lib("orber/include/corba.hrl").
-include_lib("orber/src/orber_debug.hrl").

%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([start/0, request/10, reply/5, locate/6, locate_reply/5]).



%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 code_change/3, terminate/2, stop/2]).


%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
start() ->
    gen_server:start_link(orber_iiop_outrequest, [], []).

request(Pid, RequestId, ObjKey, Op, Parameters, TypeCodes, ResponseExpected, 
	ReplyTo, Socket, SocketType) ->
    gen_server:cast(Pid, {request, RequestId, ObjKey, Op, Parameters, TypeCodes,
			  ResponseExpected, ReplyTo, Socket, SocketType}).

reply(Pid, ReplyHeader, Rest, Len, ByteOrder) ->
    gen_server:cast(Pid, {reply, ReplyHeader, Rest, Len, ByteOrder}).

locate(Pid, RequestId, ObjKey, ReplyTo, Socket, SocketType) ->
    gen_server:cast(Pid, {locate_request, RequestId, ObjKey, ReplyTo, 
			  Socket, SocketType}).    

locate_reply(Pid, ReplyHeader, Rest, Len, ByteOrder) ->
    gen_server:cast(Pid, {locate_reply, ReplyHeader, Rest, Len, ByteOrder}).

%%-----------------------------------------------------------------
%% Internal interface functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: stop/2 (Only used for test purpose !!!!!!)
%%-----------------------------------------------------------------
stop(Pid, Timeout) ->
    gen_server:call(Pid, stop, Timeout).

%%-----------------------------------------------------------------
%% Server functions
%%-----------------------------------------------------------------
%%-----------------------------------------------------------------
%% Func: init/1
%%-----------------------------------------------------------------
init(_) ->
    {ok, []}.

%%-----------------------------------------------------------------
%% Func: terminate/2
%%-----------------------------------------------------------------
terminate(Reason, State) ->
    ok.

%%-----------------------------------------------------------------
%% Func: handle_call/3
%%-----------------------------------------------------------------

handle_call(stop, From, State) ->
    {stop, normal, ok, State};
handle_call(_, _, State) ->
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: handle_cast/2
%%-----------------------------------------------------------------
handle_cast({request, RequestId, ObjKey, Op, Parameters, TypeCodes,
	     ResponseExpected, ReplyTo, Socket, SocketType},
	    State) ->
    GIOP_version = orber:giop_version(),
    case catch cdr_encode:enc_request(GIOP_version, ObjKey,  RequestId, ResponseExpected,
				      Op, Parameters,
				      [], TypeCodes) of
	{'EXCEPTION', E} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', E}),
	    {stop, normal, []};
	{'EXIT', R} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'MARSHAL'{completion_status=?COMPLETED_NO}}),
	    {stop, normal, []};
	Request ->
	    ?IIOP_SOCKET_MOD:write(SocketType, Socket, Request),
	    case ResponseExpected of
		'true' ->
		    {noreply, {ReplyTo, GIOP_version, TypeCodes, Op, 
			       Parameters, Socket, SocketType}};
		'false' ->
		    gen_server:reply(ReplyTo, ok),
		    {stop, normal, []}
	    end
    end;
handle_cast({reply, ReplyHeader, Rest, Len, ByteOrder},
	    {ReplyTo, GIOP_version, TypeCodes, Op, Parameters, Socket, 
	     SocketType}) ->
    case catch decode_reply_body(ReplyHeader, GIOP_version, TypeCodes,
				 Rest, Len, ByteOrder) of
	{'EXCEPTION', DecodeException} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', DecodeException});
	{'EXIT', message_error} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'COMM_FAILURE'{completion_status=?COMPLETED_NO}});
	{'EXIT', R} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'UNKNOWN'{completion_status=?COMPLETED_MAYBE}});
	'message_error' ->
	    %% Perhaps a resend should be done when a message error occurs
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'COMM_FAILURE'{completion_status=?COMPLETED_NO}});
	{Result, Par} ->
	    %% Check request id 
	    case ReplyHeader#reply_header.reply_status of
		'no_exception' ->
		    case Par of
			[] ->
			    gen_server:reply(ReplyTo, Result);
			_ ->
			    L = [Result | Par],
			    gen_server:reply(ReplyTo, list_to_tuple(L))
		    end;
		'system_exception' ->
		    gen_server:reply(ReplyTo, {'EXCEPTION', Result});
		'user_exception' ->
		    gen_server:reply(ReplyTo, {'EXCEPTION', Result});
		'location_forward' ->
		    corba:call(Result, Op, Parameters, TypeCodes) %%???????? LTH
	    end	  
    end,
    {stop, normal, []};
handle_cast({locate_request, RequestId, ObjKey, ReplyTo, Socket, SocketType}, 
	    State) ->
    GIOP_version = orber:giop_version(),
    case catch cdr_encode:enc_locate_request(GIOP_version, ObjKey,  RequestId) of
	{'EXCEPTION', E} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', E}),
	    {stop, normal, []};
	{'EXIT', R} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'MARSHAL'{completion_status=?COMPLETED_NO}}),
	    {stop, normal, []};
	Request ->
	    ?IIOP_SOCKET_MOD:write(SocketType, Socket, Request),
	    {noreply, {ReplyTo, GIOP_version, Socket, SocketType}}
    end;
handle_cast({locate_reply, ReplyHeader, Rest, Len, ByteOrder},
	    {ReplyTo, GIOP_version, Socket, SocketType}) ->
    case catch cdr_decode:dec_locate_reply_body(GIOP_version, ReplyHeader, Rest, Len, ByteOrder) of
	{'EXCEPTION', DecodeException} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', DecodeException});
	{'EXIT', message_error} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'COMM_FAILURE'{completion_status=?COMPLETED_NO}});
	{'EXIT', R} ->
	    gen_server:reply(ReplyTo, {'EXCEPTION', #'UNKNOWN'{completion_status=?COMPLETED_MAYBE}});
	[] ->
	    gen_server:reply(ReplyTo, ReplyHeader#locate_reply_header.locate_status);
	ObjRef ->
	    gen_server:reply(ReplyTo, {ReplyHeader#locate_reply_header.locate_status, ObjRef})
    end,
    {stop, normal, []};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_, State) ->
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: handle_info/2
%%-----------------------------------------------------------------
handle_info(stop, State) ->
    {stop, normal, State};
handle_info(X,State) ->
    {noreply, State}.

%%-----------------------------------------------------------------
%% Func: code_change/3
%%-----------------------------------------------------------------
code_change(OldVsn, State, Extra) ->
    {ok, State}.


%%-----------------------------------------------------------------
%% Internal functions
%%-----------------------------------------------------------------

decode_reply_body(ReplyHeader, Version, TypeCodes, Rest, Len, ByteOrder) ->			
	case ReplyHeader#reply_header.reply_status of
	    'no_exception' ->
		{R, P, _} = cdr_decode:dec_reply_body(Version, TypeCodes, Rest, Len, ByteOrder),
		{R, P};
	    'system_exception' ->
		{R, _} = cdr_decode:dec_system_exception(Version, Rest, Len, ByteOrder),
		{R, []};
	    'user_exception' ->
		{R, _} = cdr_decode:dec_user_exception(Version, Rest, Len, ByteOrder),
		{R, []};
	    'location_forward' ->
		{R, _, _} = cdr_decode:dec_type('tk_objref', Version, Rest, Len, ByteOrder),
		{R, []}
	end.


%%-----------------------------------------------------------------
%% Utility Functions
%%-----------------------------------------------------------------
%result_to_list({'EXCEPTION', E}, _) ->
%    {'EXCEPTION', E};
%result_to_list(Result, {TkRes, _, TkOut}) ->
%   case length(TkOut) of
%       0 ->
%	   [Result];
%       N ->
%	   tuple_to_list(Result)
%   end.

%marshal_exception(Version, Id, Exception) ->
%    {TypeOfException, ExceptionTypeCode} =
%	orber_typedefs:get_exception_def(Exception),
%    cdr_encode:enc_reply(Version,
%			 Id,
%			 TypeOfException,
%			 {ExceptionTypeCode, [], []}, 
%			 Exception, []).


