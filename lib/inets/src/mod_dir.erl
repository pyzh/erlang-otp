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
-module(mod_dir).
-export([do/1]).

-include("httpd.hrl").

%% do

do(Info) ->
    case Info#mod.method of
	"GET" ->
	    case httpd_util:key1search(Info#mod.data,status) of
		%% A status code has been generated!
		{StatusCode,PhraseArgs,Reason} ->
		    {proceed,Info#mod.data};
		%% No status code has been generated!
		undefined ->
		    case httpd_util:key1search(Info#mod.data,response) of
			%% No response has been generated!
			undefined ->
			    do_mod_dir(Info);
			%% A response has been generated or sent!
			Response ->
			    {proceed,Info#mod.data}
		    end
	    end;
	%% Not a GET method!
	_ ->
	    {proceed,Info#mod.data}
    end.

do_mod_dir(Info) ->
    Path = mod_alias:path(Info#mod.data,Info#mod.config_db,
			  Info#mod.request_uri),
    DefaultPath = mod_alias:default_index(Info#mod.config_db,Path),
    %% Is it a directory?
    case file:read_file_info(DefaultPath) of
	{ok,FileInfo} when FileInfo#file_info.type == directory ->
	    DecodedRequestURI=
		httpd_util:decode_hex(Info#mod.request_uri),
	    case dir(DefaultPath,
		     string:strip(DecodedRequestURI,right,$/),
		     Info#mod.config_db) of
		{ok, Dir} ->
		    Response=["Content-Type: text/html\r\n",
			      "Content-Length: ",
			      integer_to_list(httpd_util:flatlength(Dir)),
			      "\r\n\r\n",Dir],	
		    {proceed,[{response,{200,Response}},
			      {mime_type,"text/html"}|Info#mod.data]};
		{error, Reason} ->
		    {proceed,[{status,{404,none,Reason}}|Info#mod.data]}
	    end;
	{ok,FileInfo} ->
	    {proceed,Info#mod.data};
	{error,Reason} ->
	    {proceed,[{status,{404,Info#mod.request_uri,
			       ?NICE("Can't access "++DefaultPath)}}|
		      Info#mod.data]}
    end.

dir(Path,RequestURI,ConfigDB) ->
  case file:list_dir(Path) of
    {ok,FileList} ->
      SortedFileList=lists:sort(FileList),
      {ok,[header(Path,RequestURI),
	   body(Path,RequestURI,ConfigDB,SortedFileList),
	   footer(Path,SortedFileList)]};
    {error,Reason} ->
      {error,?NICE("Can't open directory "++Path)}
  end.

%% header

header(Path,RequestURI) ->
  Header=
    "<HTML>\n<HEAD>\n<TITLE>Index of "++RequestURI++"</TITLE>\n</HEAD>\n<BODY>\n<H1>Index of "++
    RequestURI++"</H1>\n<PRE><IMG SRC=\""++icon(blank)++
    "\" ALT="     "> Name                   Last modified         Size  Description
<HR>\n",
  case regexp:sub(RequestURI,"[^/]*\$","") of
    {ok,"/",_} ->
      Header;
    {ok,ParentRequestURI,_} ->
      {ok,ParentPath,_}=regexp:sub(string:strip(Path,right,$/),"[^/]*\$",""),
      Header++format(ParentPath,ParentRequestURI)
  end.

format(Path,RequestURI) ->
  {ok,FileInfo}=file:read_file_info(Path),
  {{Year,Month,Day},{Hour,Minute,Second}}=FileInfo#file_info.mtime,
  io_lib:format("<IMG SRC=\"~s\" ALT=\"[~s]\"> <A HREF=\"~s\">Parent directory</A>       ~2.2.0w-~s-~w ~2.2.0w:~2.2.0w        -\n",
		[icon(back),"DIR",RequestURI,Day,
		 httpd_util:month(Month),Year,Hour,Minute]).

%% body

body(Path,RequestURI,ConfigDB,[]) ->
  [];
body(Path,RequestURI,ConfigDB,[Entry|Rest]) ->
  [format(Path,RequestURI,ConfigDB,Entry)|body(Path,RequestURI,ConfigDB,Rest)].

format(Path,RequestURI,ConfigDB,Entry) ->
  case file:read_file_info(Path++"/"++Entry) of
    {ok,FileInfo} when FileInfo#file_info.type == directory ->
      {{Year,Month,Day},{Hour,Minute,Second}}=FileInfo#file_info.mtime,
      EntryLength=length(Entry),
      if
	EntryLength > 21 ->
	  io_lib:format("<IMG SRC=\"~s\" ALT=\"[~s]\"> <A HREF=\"~s\">~-21.s..</A>~2.2.0w-~s-~w ~2.2.0w:~2.2.0w        -\n",
			[icon(folder),"DIR",RequestURI++"/"++Entry++"/",Entry,
			 Day,httpd_util:month(Month),Year,Hour,Minute]);
	true ->
	  io_lib:format("<IMG SRC=\"~s\" ALT=\"[~s]\"> <A HREF=\"~s\">~s</A>~*.*c~2.2.0w-~s-~w ~2.2.0w:~2.2.0w        -\n",
			[icon(folder),"DIR",RequestURI++"/"++Entry++"/",Entry,
			 23-EntryLength,23-EntryLength,$ ,Day,
			 httpd_util:month(Month),Year,Hour,Minute])
      end;
    {ok,FileInfo} ->
      {{Year,Month,Day},{Hour,Minute,Second}}=FileInfo#file_info.mtime,
      Suffix=httpd_util:suffix(Entry),
      MimeType=httpd_util:lookup_mime(ConfigDB,Suffix,""),
      EntryLength=length(Entry),
      if
	EntryLength > 21 ->
	  io_lib:format("<IMG SRC=\"~s\" ALT=\"[~s]\"> <A HREF=\"~s\">~-21.s..</A>~2.2.0w-~s-~w ~2.2.0w:~2.2.0w~8wk  ~s\n",
			[icon(Suffix,MimeType),Suffix,RequestURI++"/"++Entry,
			 Entry,Day,httpd_util:month(Month),Year,Hour,Minute,
			 trunc(FileInfo#file_info.size/1024+1),MimeType]);
	true ->
	  io_lib:format("<IMG SRC=\"~s\" ALT=\"[~s]\"> <A HREF=\"~s\">~s</A>~*.*c~2.2.0w-~s-~w ~2.2.0w:~2.2.0w~8wk  ~s\n",
			[icon(Suffix,MimeType),Suffix,RequestURI++"/"++Entry,
			 Entry,23-EntryLength,23-EntryLength,$ ,Day,
			 httpd_util:month(Month),Year,Hour,Minute,
			 trunc(FileInfo#file_info.size/1024+1),MimeType])
      end;
    {error,Reason} ->
      ""
  end.

%% footer

footer(Path,FileList) ->
  case lists:member("README",FileList) of
    true ->
      {ok,Body}=file:read_file(Path++"/README"),
      "</PRE>\n<HR>\n<PRE>\n"++binary_to_list(Body)++
	"\n</PRE>\n</BODY>\n</HTML>\n";
    false ->
      "</PRE>\n</BODY>\n</HTML>\n"
  end.

%%
%% Icon mappings are hard-wired ala default Apache (Ugly!)
%%

icon(Suffix,MimeType) ->
  case icon(Suffix) of
    undefined ->
      case MimeType of
	[$t,$e,$x,$t,$/|_] ->
	  "/icons/text.gif";
	[$i,$m,$a,$g,$e,$/|_] ->
	  "/icons/image2.gif";
	[$a,$u,$d,$i,$o,$/|_] ->
	  "/icons/sound2.gif";
	[$v,$i,$d,$e,$o,$/|_] ->
	  "/icons/movie.gif";
	_ ->
	  "/icons/unknown.gif"
      end;
    Icon ->
      Icon
  end.

icon(blank) -> "/icons/blank.gif";
icon(back) -> "/icons/back.gif";
icon(folder) -> "/icons/folder.gif";
icon("bin") -> "/icons/binary.gif";
icon("exe") -> "/icons/binary.gif";
icon("hqx") -> "/icons/binhex.gif";
icon("tar") -> "/icons/tar.gif";
icon("wrl") -> "/icons/world2.gif";
icon("wrl.gz") -> "/icons/world2.gif";
icon("vrml") -> "/icons/world2.gif";
icon("vrm") -> "/icons/world2.gif";
icon("iv") -> "/icons/world2.gif";
icon("Z") -> "/icons/compressed.gif";
icon("z") -> "/icons/compressed.gif";
icon("tgz") -> "/icons/compressed.gif";
icon("gz") -> "/icons/compressed.gif";
icon("zip") -> "/icons/compressed.gif";
icon("ps") -> "/icons/a.gif";
icon("ai") -> "/icons/a.gif";
icon("eps") -> "/icons/a.gif";
icon("html") -> "/icons/layout.gif";
icon("shtml") -> "/icons/layout.gif";
icon("htm") -> "/icons/layout.gif";
icon("pdf") -> "/icons/layout.gif";
icon("txt") -> "/icons/text.gif";
icon("erl") -> "/icons/burst.gif";
icon("c") -> "/icons/c.gif";
icon("pl") -> "/icons/p.gif";
icon("py") -> "/icons/p.gif";
icon("for") -> "/icons/f.gif";
icon("dvi") -> "/icons/dvi.gif";
icon("uu") -> "/icons/uuencoded.gif";
icon("conf") -> "/icons/script.gif";
icon("sh") -> "/icons/script.gif";
icon("shar") -> "/icons/script.gif";
icon("csh") -> "/icons/script.gif";
icon("ksh") -> "/icons/script.gif";
icon("tcl") -> "/icons/script.gif";
icon("tex") -> "/icons/tex.gif";
icon("core") -> "/icons/tex.gif";
icon(_) -> undefined.
