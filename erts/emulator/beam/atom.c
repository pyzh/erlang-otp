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

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "hash.h"
#include "atom.h"

#define ATOM_SIZE  3000
#define ATOM_LIMIT (1024*1024)
#define ATOM_RATE  100

IndexTable atom_table;    /* The index table */

/* functions for allocating space for the ext of atoms. We do not
** use malloc for each atom to prevent excessive memory fragmentation
*/

typedef struct _atom_text {
    struct _atom_text* next;
    char text[ATOM_TEXT_SIZE];
} AtomText;

static AtomText* text_list;  /* list of text buffers */

static byte *atom_text_pos;
static byte *atom_text_end;
uint32 reserved_atom_space;      /* Total amount of atom text space */
uint32 atom_space;	         /* Amount of atom text space used */

/*
** Print info about atom tables
*/
void atom_info(to)
CIO to;
{
    index_info(to, &atom_table);
    erl_printf(to,"Atom space  %d/%d\n", atom_space, reserved_atom_space);
}

/*
** Allocate an atom text segments
*/
static void more_atom_space()
{
    AtomText* ptr;

    if ((ptr = (AtomText*) sys_alloc_from(1,sizeof(AtomText))) == NULL)
	erl_exit(1, "out of memory -- panic");
    ptr->next = text_list;
    text_list = ptr;

    atom_text_pos = ptr->text;
    atom_text_end = atom_text_pos + ATOM_TEXT_SIZE;
    reserved_atom_space += sizeof(AtomText);

    VERBOSE(erl_printf(COUT,"Allocated %d atom space\n",
		       ATOM_TEXT_SIZE););
}

/*
** Allocate string space with in an atom text segment
*/

static byte *atom_text_alloc(bytes)
int bytes;
{
    byte *res;

    if (bytes >= ATOM_TEXT_SIZE)
	erl_exit(1, "absurdly large atom --- panic\n");

    if (atom_text_pos + bytes >= atom_text_end)
	more_atom_space();
    res = atom_text_pos;
    atom_text_pos += bytes;
    atom_space    += bytes;
    return res;
}

/*
** Calculate atom hash value
** use hash algorrithm hashpjw (from Dragon Book)
*/

static HashValue atom_hash(obj)
Atom* obj;
{
    byte* p = obj->name;
    int len = obj->len;
    HashValue h = 0, g;

    while(len--) {
	h = (h << 4) + *p++;
	if ((g = h & 0xf0000000)) {
	    h ^= (g >> 24);
	    h ^= g;
	}
    }
    return h;
}


static int atom_cmp(tmpl, obj)
Atom* tmpl; Atom* obj;
{
    if (tmpl->len == obj->len &&
	sys_memcmp(tmpl->name, obj->name, tmpl->len) == 0)
	return 0;
    return 1;
}


static Atom* atom_alloc(tmpl)
Atom* tmpl;
{
    Atom* obj = (Atom*) fix_alloc_from(11, atom_desc);

    if (tmpl->slot.index != -2) {
	obj->name = atom_text_alloc(tmpl->len);
	sys_memcpy(obj->name, tmpl->name, tmpl->len);
    }
    else
	obj->name = tmpl->name;
    obj->len = tmpl->len;
    obj->slot.index = -1;
    return obj;
}

/* Reuse atom  text ??? */

static void atom_free(obj)
Atom* obj;
{
    fix_free(atom_desc, (void*) obj);
}


int atom_get(name, len)
byte* name; int len;
{
    Atom a;

    a.len = len;
    a.name = name;

    return index_get(&atom_table, (void*) &a);
}

int atom_put(name, len)
byte* name; int len;
{
    Atom a;

    a.len = len;
    a.name = name;
    a.slot.index = -1;

    return index_put(&atom_table, (void*) &a);
}

/* Insert atom but do not allocate memory for name */


int atom_static_put(name, len)
byte* name; int len;
{
    Atom a;

    a.len = len;
    a.name = name;
    a.slot.index = -2;

    return index_put(&atom_table, (void*) &a);
}

void init_atom_table()
{
    HashFunctions f;
    int i;
    Atom a;

    f.hash = (H_FUN) atom_hash;
    f.cmp  = (HCMP_FUN) atom_cmp;
    f.alloc = (HALLOC_FUN) atom_alloc;
    f.free = (HFREE_FUN) atom_free;

    atom_text_pos = NULL;
    atom_text_end = NULL;
    reserved_atom_space = 0;
    atom_space = 0;
    text_list = NULL;

    index_init(&atom_table, "atom_tab",
	       ATOM_SIZE, ATOM_LIMIT, ATOM_RATE, f);
    more_atom_space();

    /* Ordinary atoms */
    for (i = 1; erl_atom_names[i] != 0; i++) {
	a.len = strlen(erl_atom_names[i]);
	a.name = erl_atom_names[i];
	a.slot.index = i;
	index_put(&atom_table, (void*) &a);
    }
}

void dump_atoms(CIO fd)
{
   int i = -1;

   while ((i = index_iter(&atom_table, i)) != -1)
   {
      print_atom(i, fd);
      erl_putc('\n', fd);
   }
}
