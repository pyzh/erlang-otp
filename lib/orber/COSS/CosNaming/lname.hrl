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
%% File: lname.hrl
%% Author: Lars Thorsen
%% 
%% Creation date: 970926
%% Modified:
%%-----------------------------------------------------------------

%% LName interface exceptions
-record('LName_NoComponent', {'OE_ID'="PIDL:LName/NoComponent:1.0"}).
-record('LName_InvalidName', {'OE_ID'="PIDL:LName/InvalidName:1.0"}).
% This exception is not used in our implementation.
-record('LName_Overflow', {'OE_ID'="PIDL:LName/Overflow:1.0"}). 

%% LNameComponent interface exceptions
-record('LNameComponent_NotSet',
	{'OE_ID'="PIDL:LNameComponent/NotSet:1.0"}).
