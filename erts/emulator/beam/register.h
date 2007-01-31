/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */
/*
** Registered processes
*/

#ifndef __REGPROC_H__
#define __REGPROC_H__

#ifndef __SYS_H__
#include "sys.h"
#endif

#ifndef __HASH_H__
#include "hash.h"
#endif

#ifndef __PROCESS_H__
#include "erl_process.h"
#endif

struct port;

typedef struct reg_proc
{
    HashBucket bucket;  /* MUST BE LOCATED AT TOP OF STRUCT!!! */
    Process *p;         /* The process registerd (only one of this and
			   'pt' is non-NULL */
    struct port *pt;    /* The port registered */
    Eterm name;         /* Atom name */
} RegProc;

int process_reg_size(void);
int process_reg_sz(void);
void init_register_table(void);
void register_info(int, void *);
int erts_register_name(Process *, Eterm, Eterm);
Eterm erts_whereis_name_to_id(Process *, Eterm);
void erts_whereis_name(Process *, Uint32,
		       Eterm, Process**, Uint32, int,
		       struct port**);
Process *erts_whereis_process(Process *, Uint32, Eterm, Uint32, int);
int erts_unregister_name(Process *, Uint32, struct port *, Eterm);

#endif
