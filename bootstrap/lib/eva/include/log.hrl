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
%% Record: log
%% Types: name = atom()         : the unique name of the log.
%%        wrapt = integer()     : the min wrap time for the log. if
%%                                it wraps more often an alarm is sent
%%        admin_status = up | down
%%        oper_status = up | down
%% Purpose: The definition of a log.
%%-----------------------------------------------------------------
-record(log, {name, type, wrapt, admin_status = up, oper_status = up}).