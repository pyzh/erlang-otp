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
%% Version of the SNMP Toolkit (as a string())
-define(version, "3.0").

%%----------------------------------------------------------------------
%% Note: All internal representations may be changed without notice.
%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Variablebinding
%% oid: a list of integers (see snmp_misc:is_oid)
%% variabletype corresponds to type in the asn1_type.
%% variabletype=='NULL' =>
%%     value== 'NULL' | noSuchObject | noSuchInstance | endOfMibView
%% else: variabletype == <one of the types defined in rfc1903>;
%%                       'INTEGER' | 'Integer32' | 'OCTET STRING' |
%%                       'OBJECT IDENTIFIER' | 'IpAddress' | 'Counter32' |
%%                       'TimeTicks' | 'Opaque' | 'Counter64' | 'Unsigned32'
%% value: a value.
%% org_index: an integer. Its position in the original varbindlist (the one
%%            from the get- or set-request).
%%----------------------------------------------------------------------
-record(varbind, {oid, variabletype, value, org_index}).

%%-----------------------------------------------------------------
%% Internal Variablebinding
%% status = noError | ErrorStatus
%% mibentry = A mibentry if status == noError
%% varbind = a varbind-record
%%-----------------------------------------------------------------
-record(ivarbind, {status = noError, mibentry, varbind}).

%%----------------------------------------------------------------------
%% ASN1_type. Everything that is needed to represent a typed variable.
%% BERtype: Type used during Basic Encoding/Decoding Rules
%% aliasname: The name of the derived type as defined in the MIB
%% assocList can be list of:
%% {enums, [{up, 1}, {down, 2}, {right, 3}, {left, 4}]}
%%----------------------------------------------------------------------
-record(asn1_type, {bertype, lo, hi, assocList = [], imported = false,
		    aliasname, implied = false}).


%%----------------------------------------------------------------------
%% MibEntry
%% aliasname is the name for the oid.
%% asn1_type is a record of asn1_type.
%% entrytype: variable | table | tableColumn | internal
%% access: notAccessible | readOnly | readWrite | readCreate     (see rfc 1142)
%% assocList: list of
%% {table_info, #table_info}      when entrytype == table
%% {varable_info, #variable_info} when entrytype == variable
%% {table_name, TableName}        when entrytype == table_column
%% {table_entry_with_sequence, NameOfSequence} when entrytype == table_entry
%%----------------------------------------------------------------------
-record(me, {oid, entrytype, aliasname, asn1_type,
	     access, mfa, imported = false, assocList = []}).

%% oidobjects is a list of {oid, asn1_type} to be sent in the trap.
-record(trap, {trapname, enterpriseoid, specificcode, oidobjects}).

%% oidobjects is a list of {oid, asn1_type} to be sent in the trap.
-record(notification, {trapname, oid, oidobjects}).

%%----------------------------------------------------------------------
%% This is how a mib is represented on disk (as a binary)
%% types is: [asn1_type()]
%% variable_infos is a list of {Name,  variable_info-record}
%% table_infos is a list of {Name,  table_info-record}
%%----------------------------------------------------------------------
-record(mib, {misc = [], mib_format_version = "2.0", name = "",
              mes = [], asn1_types = [], traps = [], variable_infos = [],
              table_infos = []}).

%%----------------------------------------------------------------------
%% version = 'version-1' | 'version-2' | 'version-3'
%% vsn_hdr is dependent on version.  If v1 | v2 it's the community string,
%% if v3 its a v3_hdr record
%% data is a PDU (v1 & v2c) or a (possibly encrypted) ScopedPDU (v3)
%%
%% The constant SNMP_USE_V3 is used for compatibility reasons.  In earlier
%% versions, the vsn_hdr field was called 'community'.  This only worked
%% for v1 and v2c.  Thus, the filed is renamed to vsn_hdr, and the
%% content depend on the version as described above.  An application
%% that handles not only v1 and v2c, but also v3, *must* define the
%% constant SNMP_USE_V3 before including this header file.  This 
%% ensures that the application can refer to the field as 'vsn_hdr'.
%% An old application, that doesn't handle v3, doesn't define
%% the constant, can still refer to the field as 'coomunity'.
%%----------------------------------------------------------------------
-ifdef(SNMP_USE_V3).
-record(message, {version, vsn_hdr, data}).
-else.
-record(message, {version, community, data}).
-endif.

-record(v3_hdr, {msgID, msgMaxSize, msgFlags,
		 msgSecurityModel, msgSecurityParameters, hdr_size}).

-record(scopedPdu, {contextEngineID, contextName, data}).

%%-----------------------------------------------------------------
%% USM Security Model
%%-----------------------------------------------------------------
-record(usmSecurityParameters, {msgAuthoritativeEngineID,
				msgAuthoritativeEngineBoots,
				msgAuthoritativeEngineTime,
				msgUserName,
				msgAuthenticationParameters,
				msgPrivacyParameters}).

%%----------------------------------------------------------------------
%% type: 'get-request' | 'get-next-request' | 'get-bulk-request' |
%% 'get-response' | 'set-request' | 'inform-request' | 'snmpv2-trap' | report
%% (see rfc 1905)
%% request_id, error_status and error_index are integers.
%% varbinds: a list of varbinds.
%%----------------------------------------------------------------------
%%               if bulk        non-repeaters max-repetitions  resp
-record(pdu, {type, request_id, error_status, error_index, varbinds}).

-record(trappdu, {enterprise, agent_addr, generic_trap, specific_trap,
		  time_stamp, varbinds}).

%%-----------------------------------------------------------------
%% This record should be used when a Mnesia table for variables
%% is created.
%%-----------------------------------------------------------------
-record(snmp_variables, {name, value}).

%%-----------------------------------------------------------------
%% STD security models (from rfc2271)
%%-----------------------------------------------------------------
-define(SEC_ANY, 0).
-define(SEC_V1, 1).
-define(SEC_V2C, 2).
-define(SEC_USM, 3).

%%-----------------------------------------------------------------
%% The OTP Security Model (ericsson * 256 + otp)
%% (works for Community based SNMP i.e. v1 and v2c)
%%-----------------------------------------------------------------
-define(SEC_OTP, 49427).

%%-----------------------------------------------------------------
%% STD message processing models (from rfc2271)
%%-----------------------------------------------------------------
-define(MP_V1, 0).
-define(MP_V2C, 1).
-define('MP_V2U*', 2).
-define(MP_V3, 3).

%%-----------------------------------------------------------------
%% Mib Views
%%-----------------------------------------------------------------
-define(view_included, 1).
-define(view_excluded, 2).

%%-----------------------------------------------------------------
%% From SNMPv2-SMI
%%-----------------------------------------------------------------
-define(zeroDotZero, [0,0]).
