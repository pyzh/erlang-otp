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
%% File: orber_request_number.erl
%% Author: Lars Thorsen
%% 
%% Description:
%%    This file contains the request number server in Orber
%%
%% Creation date: 970917
%% 
%%-----------------------------------------------------------------
-module(orber_request_number).

-behaviour(gen_server).

%%-----------------------------------------------------------------
%% External exports
%%-----------------------------------------------------------------
-export([start/1, get/0, reset/0]).

%%-----------------------------------------------------------------
%% Internal exports
%%-----------------------------------------------------------------
-export([init/1, terminate/2, handle_call/3]).
-export([handle_cast/2, handle_info/2, code_change/3]).

%%-----------------------------------------------------------------
%% External interface functions
%%-----------------------------------------------------------------
start(Opts) ->
    gen_server:start_link({local, orber_reqno}, orber_request_number, Opts, []).

get() ->
    gen_server:call(orber_reqno, get, infinity).

reset() ->
    gen_server:call(orber_reqno, reset, infinity).

%%-----------------------------------------------------------------
%% Server functions
%%-----------------------------------------------------------------
init(Opts) ->
    {ok, 0}.

terminate(Reason, State) ->
	    ok.

handle_call(get, From, State) ->
    {reply, State, State+1};
handle_call(reset, From, State) ->
    {reply, ok, 0}.

handle_cast(_, State) ->
    {noreply,  State}.

handle_info(_, State) ->
    {noreply,  State}.

code_change(OldVsn, State, Extra) ->
    {ok, State}.


