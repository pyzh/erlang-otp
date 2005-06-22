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
-module(httpd_response).
-export([generate_and_send_response/1, send_status/3, send_header/3, 
	 send_chunk/3, send_final_chunk/2, split_header/2,
	 is_disable_chunked_send/1, cache_headers/1]).

-include("httpd.hrl").
-include("http.hrl").

-define(VMODULE,"RESPONSE").
-include("httpd_verbosity.hrl").

%% If peername does not exist the client already discarded the
%% request so we do not need to send a reply.
generate_and_send_response(#mod{init_data =
				#init_data{peername = {_,"unknown"}}}) ->
    ok;
generate_and_send_response(#mod{config_db = ConfigDB} = ModData) ->
    ?vtrace("send -> Request line: ~p", [ModData#mod.request_line]),
    Modules = httpd_util:lookup(ConfigDB,modules,
				[mod_get, mod_head, mod_log]),
    case traverse_modules(ModData, Modules) of
	done ->
	    ok;
	{proceed, Data} ->
	    case httpd_util:key1search(Data, status) of
		{StatusCode, PhraseArgs, Reason} ->
		    ?vdebug("send -> proceed/status: ~n"
			    "~n   StatusCode: ~p"
			    "~n   PhraseArgs: ~p"
			    "~n   Reason:     ~p",
			    [StatusCode, PhraseArgs, Reason]),
		    send_status(ModData, StatusCode, PhraseArgs),
		    ok;		
		undefined ->
		    case httpd_util:key1search(Data, response) of
			{already_sent, StatusCode, Size} ->
			    ?vtrace("send -> already sent: "
				    "~n   StatusCode: ~p"
				    "~n   Size:       ~p", 
				    [StatusCode, Size]),
			    ok;
			{response, Header, Body} -> %% New way
			    send_response(ModData, Header, Body),
			    ok;
			{StatusCode, Response} ->   %% Old way
			    send_response_old(ModData, StatusCode, Response),
			    ok;
			undefined ->
			    ?vtrace("send -> undefined response", []),
			    send_status(ModData, 500, none),
			    ok
		    end
	    end
    end.


%% traverse_modules

traverse_modules(ModData,[]) ->
    {proceed,ModData#mod.data};
traverse_modules(ModData,[Module|Rest]) ->
    case (catch apply(Module,do,[ModData])) of
	{'EXIT', Reason} ->
	    ?vlog("traverse_modules -> exit reason: ~p",[Reason]),
	    String = 
		lists:flatten(
		  io_lib:format("traverse exit from apply: ~p:do => ~n~p",
				[Module, Reason])),
	    report_error(mod_log, ModData#mod.config_db, String),
	    report_error(mod_disk_log, ModData#mod.config_db, String),
	    done;
	done ->
	    done;
	{break,NewData} ->
	    {proceed,NewData};
	{proceed,NewData} ->
	    traverse_modules(ModData#mod{data=NewData},Rest)
    end.

%% send_status %%


send_status(ModData, 100, _PhraseArgs) ->
    send_header(ModData, 100, [{content_length, "0"}]);

send_status(#mod{socket_type = SocketType, 
		 socket      = Socket, 
		 config_db   = ConfigDB} = ModData, StatusCode, PhraseArgs) ->

    ReasonPhrase = httpd_util:reason_phrase(StatusCode),
    Message      = httpd_util:message(StatusCode, PhraseArgs, ConfigDB),
    Body         = get_body(ReasonPhrase, Message),

    send_header(ModData, StatusCode, [{content_type, "text/html"},
			    {content_length, integer_to_list(length(Body))}]),
    httpd_socket:deliver(SocketType, Socket, Body).


get_body(ReasonPhrase, Message)->
    "<HTML>
       <HEAD>
           <TITLE>"++ReasonPhrase++"</TITLE>
      </HEAD>
      <BODY>
      <H1>"++ReasonPhrase++"</H1>\n"++Message++"\n</BODY>
      </HTML>\n".
 

send_response(ModData, Header, Body) ->
    ?vtrace("send_response -> (new) entry with"
	    "~n   Header:       ~p", [Header]),
    case httpd_util:key1search(Header, code) of
	undefined ->
	    %% No status code 
	    %% Ooops this must be very bad:
	    %% generate a 404 content not availible
	    send_status(ModData, 404, "The file is not availible");
	StatusCode ->
	    case send_header(ModData, StatusCode, lists:keydelete(code, 1,
							       Header)) of
		ok ->
		    send_body(ModData, StatusCode, Body);
		Error ->
		    ?vlog("head delivery failure: ~p", [Error]),
		    done   
	    end
    end.

send_header(#mod{socket_type = Type, socket = Sock, 
		 http_version = Ver,  connection = Conn} = _ModData, 
	    StatusCode, KeyValueTupleHeaders) ->
    ?vtrace("send_header -> entry with"
	    "~n   Ver:  ~p"
	    "~n   Conn: ~p", [Ver, Conn]),
    Headers = create_header(lists:map(fun transform/1, KeyValueTupleHeaders)),
    NewVer = case {Ver, StatusCode} of
		 {[], _} ->
		     %% May be implicit!
		     "HTTP/0.9";
		 {unknown, 408} ->
		     %% This will proably never happen! It means the
		     %% server has timed out the request without
		     %% receiving a version for the request!  Send the
		     %% lowest version so to ensure that the client
		     %% will be able to handle it, probably the
		     %% sensible thing to do!
		     "HTTP/0.9";
		 _ ->
		     Ver
	     end,
    StatusLine = [NewVer, " ", io_lib:write(StatusCode), " ",
		  httpd_util:reason_phrase(StatusCode), ?CRLF],
    ConnectionHeader = get_connection(Conn, NewVer),
    Head = list_to_binary([StatusLine, Headers, ConnectionHeader , ?CRLF]),
    ?vtrace("deliver head", []),
    httpd_socket:deliver(Type, Sock, Head).

send_body(#mod{socket_type = Type, socket = Socket}, _, nobody) ->
    ?vtrace("send_body -> no body", []),
    httpd_socket:close(Type, Socket),
    ok;

send_body(#mod{socket_type = Type, socket = Sock}, 
	  _StatusCode, Body) when list(Body) ->
    ?vtrace("deliver body of size ~p", [length(Body)]),
    httpd_socket:deliver(Type, Sock, Body);

send_body(#mod{socket_type = Type, socket = Sock} = ModData, 
	  StatusCode, {Fun, Args}) ->
    case (catch apply(Fun, Args)) of
	close ->
	    httpd_socket:close(Type, Sock),
	    done;

	sent ->
	    {proceed,[{response,{already_sent, StatusCode, 
				 httpd_util:key1search(ModData#mod.data,
						       content_length)}}]};
	{ok, Body} ->
	    ?vtrace("deliver body", []),
	    case httpd_socket:deliver(Type, Sock, Body) of
		ok ->
		    {proceed,[{response,
			       {already_sent, StatusCode, 
				httpd_util:key1search(ModData#mod.data,
						      content_length)}}]};
		Error ->
		    ?vlog("body delivery failure: ~p", [Error]),
		    done
	    end;	    

	Error ->
	    ?vlog("failure of apply(~p,~p): ~p", [Fun, Args, Error]),
	    done
    end.

split_header([$: | Value], AccName) ->
    Name = httpd_util:to_lower(string:strip(AccName)),
    {lists:reverse(Name), 
     string:strip(string:strip(string:strip(Value, right, ?LF), right, ?CR))};
split_header([Char | Rest], AccName) ->
    split_header(Rest, [Char | AccName]).

send_chunk(_, <<>>, _) ->
    ok;
send_chunk(_, [], _) ->
    ok;

send_chunk(#mod{http_version = "HTTP/1.1", 
		socket_type = Type, socket = Sock}, Response0, false) ->
    Response = http_chunk:encode(Response0),
    httpd_socket:deliver(Type, Sock, Response);

send_chunk(#mod{socket_type = Type, socket = Sock} = _ModData, Response, _) ->
    httpd_socket:deliver(Type, Sock, Response).

send_final_chunk(#mod{http_version = "HTTP/1.1", 
		      socket_type = Type, socket = Sock}, false) ->
    httpd_socket:deliver(Type, Sock, http_chunk:encode_last());
send_final_chunk(#mod{socket_type = Type, socket = Sock}, _) ->
    httpd_socket:close(Type, Sock).

is_disable_chunked_send(Db) ->
    httpd_util:lookup(Db, disable_chunked_transfer_encoding_send, false).

%% Return a HTTP-header field that indicates that the 
%% connection will be inpersistent
get_connection(true,"HTTP/1.0")->
    "Connection:close\r\n";
get_connection(false,"HTTP/1.1") ->
    "Connection:close\r\n";
get_connection(_,_) ->
    "".

cache_headers(#mod{config_db = Db}) ->
    case httpd_util:lookup(Db, script_nocache, false) of
	true ->
	    Date = httpd_util:rfc1123_date(),
	    [{"cache-control", "no-cache"},
	     {"pragma", "no-cache"},
	     {"expires", Date}];
	false ->
	    []
    end.

create_header(KeyValueTupleHeaders) ->
    NewHeaders = add_default_headers([{"date", httpd_util:rfc1123_date()},
				      {"content-type", "text/html"},
				      {"server", ?SERVER_SOFTWARE}], 
				     KeyValueTupleHeaders),
    lists:map(fun({Key, Value}) -> Key ++ ":" ++ Value ++ ?CRLF end,
	      NewHeaders).

add_default_headers([], Headers) ->
    Headers;

add_default_headers([Header = {Default, _} | Defaults], Headers) ->
    case lists:keysearch(Default, 1, Headers) of
	{value, _} ->
	    add_default_headers(Defaults, Headers);
	_ ->
	    add_default_headers(Defaults, [Header | Headers])
    end.

transform({content_type, Value}) ->
    {"content-type", Value};
transform({accept_ranges, Value}) ->
     {"accept-ranges", Value};
transform({cache_control, Value}) ->
     {"cache-control",Value};
transform({transfer_encoding, Value}) ->
    {"transfer-encoding", Value};
transform({content_encoding, Value}) ->
    {"content-encoding", Value};
transform({content_language, Value}) ->
    {"content-language", Value};
transform({retry_after, Value}) ->
    {"retry-after", Value};
transform({content_location, Value}) ->
    {"Content-Location:", Value};
transform({content_length, Value}) ->
    {"content-length", Value};
transform({content_MD5, Value}) ->
    {"content-md5", Value};
transform({content_range, Value}) ->
    {"content-range", Value};
transform({last_modified, Value}) ->
    {"last-modified", Value};
transform({Field, Value}) when is_atom(Field) ->
    {atom_to_list(Field), Value};
transform({Field, Value}) when is_list(Field) ->
    {Field, Value}.

%%----------------------------------------------------------------------
%% This is the old way of sending data it is strongly encouraged to 
%% Leave this method and go on to the newer form of response
%% OTP-4408
%%----------------------------------------------------------------------
send_response_old(#mod{method      = "HEAD"} = ModData,
		  StatusCode, Response) ->
    ?vtrace("send_response_old(HEAD) -> entry with"
	    "~n   StatusCode: ~p"
	    "~n   Response:   ~p",
	    [StatusCode,Response]),

    NewResponse = lists:flatten(Response),
    
    case httpd_util:split(NewResponse, [?CR, ?LF, ?CR, ?LF],2) of
	{ok, [Head, Body]} ->
	    NewHead = handle_headers(string:tokens(Head, [?CR,?LF]), []),
	    send_header(ModData, StatusCode, [{content_length,
					    content_length(Body)} | NewHead]);
	{ok, [NewResponse]} ->
	    send_header(ModData, StatusCode, [{content_length,
					       content_length(NewResponse)}]);
	_Error ->
	    send_status(ModData, 500, "Internal Server Error")
    end;

send_response_old(#mod{socket_type = Type, 
		       socket      = Sock} = ModData,
		  StatusCode, Response) ->
    ?vtrace("send_response_old -> entry with"
	    "~n   StatusCode: ~p"
	    "~n   Response:   ~p",
	    [StatusCode,Response]),
    
    NewResponse = lists:flatten(Response),
    
    case httpd_util:split(NewResponse, [?CR, ?LF, ?CR, ?LF], 2) of
	{ok, [Head, Body]} ->
	    {ok, NewHead} = handle_headers(string:tokens(Head, [?CR,?LF]), []),
	    send_header(ModData, StatusCode, [{content_length,
					       content_length(Body)} | 
					      NewHead]),
	    httpd_socket:deliver(Type, Sock, Body);
	{ok, [NewResponse]} ->
	    send_header(ModData, StatusCode, [{content_length,
					       content_length(NewResponse)}]),
	    httpd_socket:deliver(Type, Sock, NewResponse);

	{error, _Reason} ->
	    send_status(ModData, 500, "Internal Server Error")
    end.

content_length(Body)->
    integer_to_list(httpd_util:flatlength(Body)).

report_error(Mod, ConfigDB, Error) ->
    Modules = httpd_util:lookup(ConfigDB, modules,
				[mod_get, mod_head, mod_log]),
    case lists:member(Mod, Modules) of
	true ->
	    Mod:report_error(ConfigDB, Error);
	_ ->
	    ok
    end.

handle_headers([], NewHeaders) ->
    {ok, NewHeaders};

handle_headers([Header | Headers], NewHeaders) -> 
    {FieldName, FieldValue} = split_header(Header, []),
    handle_headers(Headers, 
		   [{FieldName, FieldValue}| NewHeaders]).
    	
