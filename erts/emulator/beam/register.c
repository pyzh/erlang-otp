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
** Manage Registered processes
*/
#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "hash.h"
#include "atom.h"
#include "register.h"

Hash process_reg;

#define PREG_HASH_SIZE 10

void register_info(to)
CIO to;
{
    hash_info(to, &process_reg);
}


static HashValue reg_hash(obj)
RegProc* obj;
{
    return (HashValue) obj->name;
}

static int reg_cmp(tmpl, obj)
RegProc* tmpl; RegProc* obj;
{
    return (tmpl->name == obj->name) ? 0 : 1;
}

static RegProc* reg_alloc(tmpl)
RegProc* tmpl;
{
    RegProc* obj = (RegProc*) fix_alloc(preg_desc);

    obj->name = tmpl->name;
    obj->p = tmpl->p;
    return obj;
}

static void reg_free(obj)
RegProc* obj;
{
    fix_free(preg_desc, (void*) obj);
}

void init_register_table()
{
    HashFunctions f;

    f.hash = (H_FUN) reg_hash;
    f.cmp  = (HCMP_FUN) reg_cmp;
    f.alloc = (HALLOC_FUN) reg_alloc;
    f.free = (HFREE_FUN) reg_free;

    hash_init(&process_reg, "process_reg", PREG_HASH_SIZE, f);
}

/*
** Register a process (cant be registerd twice)
** Returns 0 if process already registered
** Returns rp the processes registered (does not have to be p)
*/
Process* register_process(name, p)
int name; Process* p;
{
    RegProc r, *rp;

    if (p->reg != (RegProc*) 0)
	return (Process*) 0;

    r.name = name;
    r.p = p;
    
    rp = (RegProc*) hash_put(&process_reg, (void*) &r);
    if (rp->p == p)
	p->reg = rp;
    return rp->p;
}

/*
** Find registered process (whereis)
*/
Process* whereis_process(name)
int name;
{
    RegProc r, *rp;

    r.name = name;
    if ((rp = (RegProc*) hash_get(&process_reg, (void*) &r)) != NULL)
	return rp->p;
    return (Process*) 0;
}

/*
** Unregister a process 
** Return 0 if not registered
** Otherwise returns the process unregisterd
*/
Process* unregister_process(name)
int name;
{
    RegProc r, *rp;

    r.name = name;
    if ((rp = (RegProc*) hash_get(&process_reg, (void*) &r)) != NULL) {
	Process* p = rp->p;
	if (p->status == P_EXITING)
	   p->reg_atom = name;
	p->reg = NULL;
	hash_erase(&process_reg, (void*) &r);
	return p;
    }
    return (Process*) 0;
}

