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
%%%----------------------------------------------------------------------
%%% File    : client.erl
%%% Author  : Babbis Xagorarakis <babbis@balin>
%%% Purpose : 
%%% Created : 22 Oct 1998 by Babbis Xagorarakis <babbis@balin>
%%%----------------------------------------------------------------------

-module(client).
-author('babbis@balin').

-export([produce/0,init/3,call/0]).

-define(SERVER,{rmod_random_impl,
		list_to_atom("babbis@"++hd(tl(string:tokens(atom_to_list(node()),"@"))))}).
-define(CLIENTMOD,'rmod_random').
-define(TIMEOUT,5000).

produce() ->
    ?CLIENTMOD:produce(?SERVER,?TIMEOUT).


init(Seed1, Seed2, Seed3) ->
    io:format("Init..."),
    ?CLIENTMOD:init(?SERVER,Seed1, Seed2, Seed3),
    io:format("ok\n").


call() ->
    init(1,2,3),
    produce(0).


produce(10) ->
    ok;
produce(Ctr) ->
    N = produce(),
    io:format("Random~p = ~p\n",[Ctr,N]),
    produce(Ctr+1).
