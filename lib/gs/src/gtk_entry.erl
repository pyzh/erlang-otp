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
%% ------------------------------------------------------------
%% Basic Entry Type
%% ------------------------------------------------------------

-module(gtk_entry).

%%------------------------------------------------------------------------------
%% 			    ENTRY OPTIONS
%%
%%  Attributes:
%%	anchor			n,w,s,e,nw,se,ne,sw,center
%%	bg			Color
%%	bw			Int
%%	data			Data
%%	fg			Color
%%      font                    Font
%%	height			Int
%%	highlightbg		Color
%%	highlightbw		Int	(Pixels)
%%	highlightfg		Color
%%	insertbg		Color
%%	insertbw		Int	(0 or 1 Pixels ???)
%%	justify			left|right|center
%%	relief			Relief	[flat|raised|sunken|ridge|groove]
%%	selectbg		Color
%%	selectbw		Int	(Pixels)
%%	selectfg		Color
%%	text			String
%%	width			Int
%%	x			Int
%%	xselection		Bool
%%	y			Int
%%
%%  Commands:
%%	delete			Index | {From, To}
%%	enable			Bool
%%	insert			{index,String}
%%	select			{From, To} | clear
%%	setfocus		Bool
%%
%%  Events:
%%	buttonpress		[Bool | {Bool, Data}]
%%	buttonrelease		[Bool | {Bool, Data}]
%%	configure		[Bool | {Bool, Data}]
%%	destroy			[Bool | {Bool, Data}]
%%	enter			[Bool | {Bool, Data}]
%%	focus			[Bool | {Bool, Data}]
%%	keypress		[Bool | {Bool, Data}]
%%	keyrelease		[Bool | {Bool, Data}]
%%	leave			[Bool | {Bool, Data}]
%%	motion			[Bool | {Bool, Data}]
%%
%%  Read options:
%%	children
%%	id
%%	index			Index	   => Int
%%	parent
%%	type
%%
%%
%%  Not Implemented:
%%	cursor			??????
%%	focus			?????? (-takefocus)
%%	font			??????
%%	hscroll			??????
%%	show			??????
%%	state			??????
%%

-export([create/3,config/3,read/3,delete/2,event/5,option/5,read_option/5]).

-include("gtk.hrl").

%%-----------------------------------------------------------------------------
%%			MANDATORY INTERFACE FUNCTIONS
%%-----------------------------------------------------------------------------
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: create/7
%% Purpose    	: Create a widget of the type defined in this module.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
create(DB, GtkId, Opts) ->
    TkW = gtk_generic:mk_tkw_child(DB,GtkId),
    PlacePreCmd = [";place ", TkW],
    Ngtkid = GtkId#gtkid{widget=TkW},
    case gtk_generic:make_command(Opts,Ngtkid,TkW,"", PlacePreCmd,DB) of
	{error,Reason} -> {error,Reason};
	Cmd when list(Cmd) ->
	    case gtk:call(["entry ", TkW,Cmd]) of
		{result, _} ->
		    gtk:exec(
		      [TkW," conf -bo 2 -relief sunken -highlightth 2;"]),
		    Ngtkid;
		Bad_Result ->
		    {error, Bad_Result}
	    end
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: config/3
%% Purpose    	: Configure a widget of the type defined in this module.
%% Args        	: DB	  - The Database
%%		  Gtkid   - The gtkid of the widget
%%		  Opts    - A list of options for configuring the widget
%%
%% Return 	: [true | {bad_result, Reason}]
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
config(DB, Gtkid, Opts) ->
    TkW = Gtkid#gtkid.widget,
    SimplePreCmd = [TkW, " conf"],
    PlacePreCmd = [";place ", TkW],
    gtk_generic:mk_cmd_and_exec(Opts,Gtkid,TkW,SimplePreCmd,PlacePreCmd,DB).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: read/3
%% Purpose    	: Read one option from a widget
%% Args        	: DB	  - The Database
%%		  Gtkid   - The gtkid of the widget
%%		  Opt     - An option to read
%%
%% Return 	: [OptionValue | {bad_result, Reason}]
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
read(DB, Gtkid, Opt) ->
    gtk_generic:read_option(DB, Gtkid, Opt).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: delete/2
%% Purpose    	: Delete widget from databas and return tkwidget to destroy
%% Args        	: DB	  - The Database
%%		  Gtkid   - The gtkid of the widget
%%
%% Return 	: TkWidget to destroy
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
delete(DB, Gtkid) ->
    gtk_db:delete_widget(DB, Gtkid),
    Gtkid#gtkid.widget.


event(DB, Gtkid, Etype, Edata, Args) ->
    gtk_generic:event(DB, Gtkid, Etype, Edata, Args).


%%------------------------------------------------------------------------------
%%			MANDATORY FUNCTIONS
%%------------------------------------------------------------------------------
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: option/4
%% Purpose    	: Take care of options
%% Args        	: Option  - An option tuple
%%		  Gtkid   - The gtkid of the widget
%%		  TkW     - The  tk-widget
%%		  DB	  - The Database
%%
%% Return 	: A tuple {OptionType, OptionCmd}
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
option(Option, Gtkid, TkW, DB,_) ->
    case Option of
	{font,    Font} ->
	    gtk_db:insert_opt(DB,Gtkid,Option),
	    {s, [" -font ", gtk_font:choose_ascii(DB,Font)]};
	{insertbg,    Color} -> {s, [" -insertba ", gtk:to_color(Color)]};
	{insertbw,    Width} -> {s, [" -insertbo ", gtk:to_ascii(Width)]};
	{justify,       How} -> {s, [" -ju ", gtk:to_ascii(How)]};
	{text,          Str} ->
	    {c, [TkW," del 0 end; ",TkW," ins 0 ", gtk:to_ascii(Str)]};
	{xselection,   Bool} -> {s, [" -exportse ", gtk:to_ascii(Bool)]};

	{delete, {From, To}} ->
	    {c, [TkW, " del ", p_index(From), $ , p_index(To)]};
	{delete,      Index} -> {c, [TkW, " de ", p_index(Index)]};
	{insert, {Idx, Str}} ->
	    {c, [TkW, " ins ", gtk:to_ascii(Idx),$ , gtk:to_ascii(Str)]};
	{select,      clear} -> {c, [TkW, " sel clear"]};
	{select, {From, To}} ->
	    {c, [TkW, " sel range ", p_index(From), $ , p_index(To)]};
	_                    -> invalid_option
    
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Function   	: read_option/5
%% Purpose    	: Take care of a read option
%% Args        	: DB	  - The Database
%%		  Gtkid   - The gtkid of the widget
%%		  Option  - An option
%%
%% Return 	: The value of the option or invalid_option
%%		  [OptionValue | {bad_result, Reason}]
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
read_option(Option,Gtkid,TkW,DB,_) -> 
    case Option of
	insertbg      -> tcl2erl:ret_color([TkW," cg -insertba"]);
	insertbw      -> tcl2erl:ret_int([TkW," cg -insertbo"]);
	font -> gtk_db:opt(DB,Gtkid,font,undefined);
	justify       -> tcl2erl:ret_atom([TkW," cg -jus"]);
	text          -> tcl2erl:ret_str([TkW," get"]);
	xselection    -> tcl2erl:ret_bool([TkW," cg -exports"]);
	{index, Idx}  -> tcl2erl:ret_int([TkW, "cg ind ", p_index(Idx)]);
	_ -> {bad_result, {Gtkid#gtkid.objtype, invalid_option, Option}}
    end.

%%------------------------------------------------------------------------------
%%			       PRIMITIVES
%%------------------------------------------------------------------------------
p_index(Index) when integer(Index) -> gtk:to_ascii(Index);
p_index(insert) -> "insert";
p_index(last)   -> "end";
p_index(Idx)    -> gs:error("Bad index in entry: ~w~n",[Idx]),0.


%%% ----- Done -----
